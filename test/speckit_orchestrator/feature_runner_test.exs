defmodule SpeckitOrchestrator.FeatureRunnerTest do
  # async: false — swaps the global :jido_claude sdk_module + a scenario flag.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.{
    Feature,
    FeatureAgent,
    FeatureRunner,
    Ledger,
    RunContext,
    Worktree
  }

  # Fake SDK that branches on the prompt so a single fake drives every phase.
  # The scenario is read from app env so each test picks happy/escalate/halt.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      # The real CLI writes files into its cwd; the artifact gate reads them, so
      # the fake must too — otherwise every phase looks successful while writing
      # nothing, which is exactly the false-green the gate exists to catch.
      # `:test_artifact_hook` lets a test suppress one phase's artifact to
      # exercise the gate.
      case Application.get_env(:speckit_orchestrator, :test_artifact_hook) do
        nil -> SpeckitOrchestrator.FakeArtifacts.write(prompt, options)
        hook when is_function(hook, 2) -> hook.(prompt, options)
      end

      scenario = Application.get_env(:speckit_orchestrator, :test_fake_scenario, :happy)

      cond do
        scenario == :transient_once and first_call?() ->
          transient_drop_messages()

        scenario == :remediation_transient_once and remediation_prompt?(prompt) and
            first_call?() ->
          transient_drop_messages()

        # A genuine (non-transient) remediation failure — never retried, stops
        # the resume before the target phase runs (FR-006/SC-005).
        # The 017 auto-remediation corrective step (distinct from 013's
        # pre-phase remediation) errors, so the loop stops at
        # :remediation_failed with the analyze run already recorded.
        scenario == :auto_remediation_error and auto_remediation_prompt?(prompt) ->
          [
            %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
            %Message{
              type: :result,
              subtype: :error,
              data: %{
                session_id: "s",
                result: "Corrective step failed: cannot resolve the finding.",
                is_error: true,
                total_cost_usd: nil
              },
              raw: %{}
            }
          ]

        scenario == :remediation_error and remediation_prompt?(prompt) ->
          [
            %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
            %Message{
              type: :result,
              subtype: :error,
              data: %{
                session_id: "s",
                result: "Remediation failed: unresolvable conflict in plan.md.",
                is_error: true,
                total_cost_usd: nil
              },
              raw: %{}
            }
          ]

        true ->
          text = response_text(prompt)

          [
            %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
            %Message{
              type: :assistant,
              data: %{session_id: "s", message: %{"content" => text}},
              raw: %{}
            },
            %Message{
              type: :result,
              subtype: :success,
              data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.10},
              raw: %{}
            }
          ]
      end
    end

    defp remediation_prompt?(prompt), do: String.contains?(prompt, "Remediation for feature")

    defp auto_remediation_prompt?(prompt),
      do: String.contains?(prompt, "analyze auto-remediation loop")

    # First call drops mid-response: an error result carrying a server-drop
    # signature. Must be retried, not fail the feature.
    defp transient_drop_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{
            session_id: "s",
            result: "API Error: Server error mid-response.",
            is_error: true,
            total_cost_usd: nil
          },
          raw: %{}
        }
      ]
    end

    # True exactly once (the first query call), via a test-provided counter Agent.
    defp first_call? do
      case Application.get_env(:speckit_orchestrator, :test_transient_counter) do
        nil -> false
        agent -> Agent.get_and_update(agent, fn n -> {n == 0, n + 1} end)
      end
    end

    defp response_text(prompt) do
      scenario = Application.get_env(:speckit_orchestrator, :test_fake_scenario, :happy)

      cond do
        String.contains?(prompt, "clarify reviewer") ->
          case scenario do
            :escalate ->
              "Reviewed the spec.\n\n## NEEDS HUMAN\nProration semantics unspecified."

            # Reviewer converged and *mentions* the marker inline while saying it
            # did NOT escalate — must not trip the line-anchored heading match.
            :clarify_prose_marker ->
              "Spec decisive. No `## NEEDS HUMAN` — nothing material left; all edge cases defaulted."

            _ ->
              "Clarified: all ambiguities resolved from the constitution."
          end

        String.contains?(prompt, "pull-request description") ->
          ~s|{"commit_message":"feat(001): built core ledger","pr_title":"Add core ledger","pr_body":"## Summary\\n- built the ledger"}|

        String.contains?(prompt, "/speckit.analyze") ->
          case scenario do
            :halt ->
              ~s({"summary":"violation","findings":[{"severity":"critical","title":"float money"}]})

            :bad_analyze ->
              "No JSON here, just prose — malformed analyze output."

            scen when scen in [:analyze_high, :auto_remediation_error] ->
              ~s({"summary":"gaps","findings":[{"severity":"high","title":"plan.md missing"}]})

            _ ->
              ~s({"summary":"clean","findings":[]})
          end

        String.contains?(prompt, "ready for human PR review") ->
          case scenario do
            :converge_not_ready ->
              "Branch is spec-only; acceptance criteria not satisfiable.\n\n## CONVERGE: NOT READY"

            _ ->
              "Tests green, committed.\n\n## CONVERGE: READY"
          end

        true ->
          "Phase completed."
      end
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :happy)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :test_fake_scenario)
    end)

    :ok
  end

  defp feature,
    do: %Feature{
      id: "001",
      number: 1,
      slug: "core-ledger",
      path: "docs/breakdown/001-core-ledger.md"
    }

  # 017's auto-remediation loop defaults to **on**, so every test that uses an
  # at-or-above-threshold analyze finding purely as a mechanism to reach a
  # terminal state must pin it off — otherwise it exercises the loop by
  # accident and the gate's reason arrives decorated (research R16). Tests that
  # are *about* the loop live in analyze_runner_test.exs.
  defp loop_off, do: %RunContext{auto_remediation: false}

  # --- store-backed run_key for tests exercising 018 recording (T032-T034) ---
  defp open_store_run(feature_ids \\ ["001"]) do
    repo_id = "o:feature-runner-test-#{System.unique_integer([:positive])}"

    features =
      Enum.map(feature_ids, fn id ->
        %{
          feature_id: id,
          slug: "feature-#{id}",
          path: "specs/#{id}",
          number: String.to_integer(id),
          group: :backlog,
          created_at: nil
        }
      end)

    {:ok, run_id} =
      SpeckitOrchestrator.Store.Writer.open_run(repo_id, %{
        features: features,
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {repo_id, run_id}
  end

  # --- real base repo + worktree for the containment assertions ---
  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # `:stack_base` builds an extra branch off main carrying its own commit and
  # forks the feature's worktree from it, modelling the stacked workflow's
  # `main <- 000 <- 001` shape.
  defp scaffolded_worktree(opts \\ []) do
    repo = Path.join(System.tmp_dir!(), "fr_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "fr_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    base =
      case Keyword.get(opts, :stack_base) do
        nil ->
          "HEAD"

        branch ->
          git!(repo, ["checkout", "-q", "-b", branch])
          File.write!(Path.join(repo, "below.txt"), "from the branch below\n")
          git!(repo, ["add", "-A"])
          git!(repo, ["commit", "-q", "-m", "below"])
          git!(repo, ["checkout", "-q", "main"])
          branch
      end

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    {:ok, wt} = Worktree.create(feature(), repo: repo, worktree_root: root, base: base)
    wt
  end

  test "happy path: runs the full pipeline to :done and removes the worktree" do
    wt = scaffolded_worktree()
    {:ok, ledger} = Ledger.start_link(budget: 100, name: nil)

    result = FeatureRunner.run(feature(), worktree: wt, ledger: ledger, notify: self())

    assert result.status == :done
    assert result.cost_total > 0
    assert_received {:feature_finished, "001", :done, _}
    refute File.dir?(wt.path)
    assert Ledger.spent(ledger) == result.cost_total
  end

  test "clarify escalation: stops at :escalated and keeps the worktree" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :escalated
    assert_received {:feature_finished, "001", :escalated, :needs_human}
    assert File.dir?(wt.path)
  end

  test "clarify that only mentions the marker in prose does not escalate" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :clarify_prose_marker)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    # Line-anchored heading match: an inline `## NEEDS HUMAN` mention in a
    # negation sentence is not an escalation — the pipeline runs to :done.
    assert result.status == :done
    assert_received {:feature_finished, "001", :done, _}
    refute File.dir?(wt.path)
  end

  test "clarify escalates on a spec-file NEEDS HUMAN even when its response is clean" do
    wt = scaffolded_worktree()
    # A prior phase left an unresolved marker in the spec; the clarify response
    # (scenario :happy) reads clean. The gate must catch the spec-file marker.
    spec_dir = Path.join(wt.path, "specs/001-core-ledger")
    File.mkdir_p!(spec_dir)
    File.write!(Path.join(spec_dir, "spec.md"), "# Spec\n\n## NEEDS HUMAN\nQ1 unresolved\n")

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :escalated
    assert_received {:feature_finished, "001", :escalated, :needs_human}
    assert File.dir?(wt.path)
  end

  test "retries a transient phase failure, then runs to :done" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Application.put_env(:speckit_orchestrator, :test_transient_counter, counter)
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :transient_once)

    on_exit(fn ->
      Application.delete_env(:speckit_orchestrator, :test_transient_counter)
      if Process.alive?(counter), do: Agent.stop(counter)
    end)

    wt = scaffolded_worktree()
    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    # First (specify) call dropped mid-response; the phase was retried and the
    # feature still reached :done. Calls = 1 dropped + 7 phases + 1 describe
    # (019: every run authors a PR description via Describe.run/3 on :done,
    # unconditionally).
    assert result.status == :done
    assert Agent.get(counter, & &1) == 9
  end

  test "stacked PR publish :done — describe authors the commit message + PR text" do
    wt = scaffolded_worktree()
    # Give the commit something to include so the authored message actually lands.
    File.write!(Path.join(wt.path, "note.txt"), "generated\n")

    run_key = open_store_run()
    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)
    assert result.status == :done

    # Commit message on the branch is the Claude-authored one (not the template).
    {subject, 0} = System.cmd("git", ["-C", wt.repo, "log", "-1", "--format=%s", wt.branch])
    assert subject =~ "feat(001): built core ledger"

    # PR title/body were recorded (018 — replaces `Describe.write_pr/3`) in
    # the same transaction as the feature's terminal status, for the facade
    # to open the PR with.
    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    feature_record = Enum.find(detail.features, &(&1.feature_id == "001"))
    assert %{pr_title: "Add core ledger", pr_body: body} = feature_record.pr_description
    assert body =~ "Summary"
  end

  test "analyze critical: stops at :halted and keeps the worktree" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_context: loop_off())

    assert result.status == :halted
    assert_received {:feature_finished, "001", :halted, :critical_finding}
    assert File.dir?(wt.path)
  end

  # --- artifact + converge gates: the false-green class ---------------------
  #
  # Regression for a live run against quickpoll: a stale `plan_stack` contradicted
  # the target, so `/speckit.plan` REFUSED and asked which stack to use. In a
  # headless run nobody answers, so plan wrote no plan.md — yet its transcript was
  # a perfectly successful response. tasks/implement then no-opped ("No plan.md
  # yet"), analyze reported the gap as `high`, converge said "Not ready for PR
  # review", and the feature still reached :done and opened a PR for a spec-only
  # branch. Only checking the filesystem catches this.

  defp fake_writing_all_but(skipped) do
    scenario = fn prompt, opts ->
      SpeckitOrchestrator.FakeArtifacts.write(prompt, opts, except: skipped)
    end

    Application.put_env(:speckit_orchestrator, :test_artifact_hook, scenario)
    on_exit(fn -> Application.delete_env(:speckit_orchestrator, :test_artifact_hook) end)
  end

  test "plan that returns success but writes no plan.md fails the feature" do
    fake_writing_all_but([:plan])
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :failed
    # The gate names the file it looked for inside this feature's spec dir,
    # not a cross-feature glob pattern (see SpecDir).
    assert result.reason == {:missing_artifact, :plan, "plan.md"}
    # kept for post-mortem, never removed
    assert File.dir?(wt.path)
  end

  test "tasks that writes no tasks.md fails the feature" do
    fake_writing_all_but([:tasks])
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :failed
    assert result.reason == {:missing_artifact, :tasks, "tasks.md"}
  end

  test "implement that writes only spec files (no code) fails the feature" do
    fake_writing_all_but([:implement])
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :failed
    assert result.reason == {:missing_artifact, :implement, "implementation changes"}
  end

  test "converge reporting NOT READY fails the feature instead of reaching :done" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :converge_not_ready)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :failed
    assert result.reason == :converge_not_ready
    assert File.dir?(wt.path)
  end

  test "analyze high findings escalate for a human" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_context: loop_off())

    assert result.status == :escalated
    assert result.reason == :high_findings
    assert File.dir?(wt.path)
  end

  # One knob: the severity threshold decides both when auto-remediation runs
  # and when the gate diverts to a human (amended Constitution Principle V).
  test "threshold :critical lets a High finding advance to implement, not escalate" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "gate-threshold-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :remediation, :start],
      fn _event, _meas, meta, _ -> send(test_pid, {:attempt, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_context: %RunContext{auto_remediation_threshold: "critical"}
      )

    # High is below the threshold, so nothing is remediated AND the gate does
    # not divert — the feature runs through to the end of the pipeline.
    refute result.status == :escalated
    refute result.reason == :high_findings
    assert result.status == :done
    refute_received {:attempt, _meta}
  end

  test "threshold :critical still halts the feature on a Critical finding" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_context: %RunContext{
          auto_remediation: false,
          auto_remediation_threshold: "critical"
        }
      )

    assert result.status == :halted
    assert result.reason == :critical_finding
  end

  # Regression: the failed-remediation path returns the *remediation* agent, so
  # recording it as the `:analyze` attempt overwrote the analyze run at the same
  # attempt_id — the stored analyze row showed the corrective step's outcome,
  # cost and transcript, and analyze's own record was lost.
  test "a failed corrective step does not overwrite the analyze run's own record" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :auto_remediation_error)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)

    assert result.status == :failed
    assert result.reason == :remediation_failed

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features

    analyze = Enum.find(feature_detail.phase_attempts, &(&1.phase == :analyze))
    corrective = Enum.find(feature_detail.phase_attempts, &(&1.phase == :auto_remediation))

    # Both rows exist and each carries its own outcome — analyze succeeded, the
    # corrective step is the thing that errored.
    assert analyze.outcome == :ok
    assert corrective.outcome == :error

    # The analyze row must not have inherited the corrective step's identity.
    assert analyze.label == "analyze-a1"
    refute analyze.ended_at == corrective.ended_at

    # The checkpoint is still written for the boundary, at the analyze phase
    # (FR-012b — auto-remediation is a sub-step, never a pipeline position).
    assert feature_detail.checkpoint.phase == :analyze
    assert feature_detail.checkpoint.status == :failed
    assert feature_detail.checkpoint.reason == :remediation_failed
  end

  test "phase :analyze delegates to AnalyzeRunner — the loop runs below the gate (017)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "delegation-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :remediation, :start],
      fn _event, _meas, meta, _ -> send(test_pid, {:attempt, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    run_key = open_store_run()

    # No run_context ⇒ the shipped defaults ⇒ the loop is on. The finding
    # persists, so both attempts are spent and the gate then decides from the
    # final run, with the reason naming exhaustion (FR-006).
    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)

    assert result.status == :escalated
    assert result.reason == {:high_findings, :auto_remediation_exhausted}

    assert_received {:attempt, %{phase: :analyze, attempt: 1, limit: 2, threshold: :high}}
    assert_received {:attempt, %{phase: :analyze, attempt: 2, limit: 2}}
    refute_received {:attempt, %{attempt: 3}}

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features
    assert Enum.map(feature_detail.remediation_attempts, & &1.ordinal) == [1, 2]
    assert Enum.any?(feature_detail.phase_attempts, &(&1.phase == :analyze))
  end

  # ---- feature 021: exhaustion policy :proceed -------------------------------

  test "exhaustion policy :proceed advances past a persistent High finding, annotates the store, and decorates the :done reason" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    test_pid = self()
    handler = "exhaustion-proceed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :remediation, :start],
      fn _event, _meas, meta, _ -> send(test_pid, {:attempt, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_key: run_key,
        run_context: %RunContext{auto_remediation_exhaustion_policy: "proceed"}
      )

    # Advanced past the gate instead of escalating, and the pipeline finished
    # unattended — no operator input, worktree removed like any other :done.
    assert result.status == :done
    assert result.reason == {:done, :advanced_with_unresolved_findings}
    assert_received {:feature_finished, "001", :done, {:done, :advanced_with_unresolved_findings}}
    refute File.dir?(wt.path)

    # Auto-remediation spent exactly attempt_limit attempts, no more.
    assert_received {:attempt, %{phase: :analyze, attempt: 1, limit: 2, threshold: :high}}
    assert_received {:attempt, %{phase: :analyze, attempt: 2, limit: 2}}
    refute_received {:attempt, %{attempt: 3}}

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features

    assert %{
             policy: "proceed",
             attempts_used: 2,
             attempt_limit: 2,
             threshold: "high",
             findings: [%{"severity" => "high"} | _]
           } = feature_detail.advanced_with_findings
  end

  test "exhaustion policy :escalate is byte-identical to the pre-021 escalation (SC-002)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_key: run_key,
        run_context: %RunContext{auto_remediation_exhaustion_policy: "escalate"}
      )

    assert result.status == :escalated
    assert result.reason == {:high_findings, :auto_remediation_exhausted}
    assert File.dir?(wt.path)

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features
    assert feature_detail.advanced_with_findings == nil
  end

  test "no exhaustion_policy opt (default :escalate) is byte-identical to the pre-021 escalation (SC-002)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)

    assert result.status == :escalated
    assert result.reason == {:high_findings, :auto_remediation_exhausted}
    assert File.dir?(wt.path)

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features
    assert feature_detail.advanced_with_findings == nil
  end

  # FR-015: with auto-remediation disabled, the exhaustion policy has no
  # observable effect for either value — there is no loop to exhaust.
  test "exhaustion policy :proceed with auto-remediation disabled has no effect (FR-015)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        run_key: run_key,
        run_context: %RunContext{
          auto_remediation: false,
          auto_remediation_exhaustion_policy: "proceed"
        }
      )

    assert result.status == :escalated
    assert result.reason == :high_findings
    assert File.dir?(wt.path)

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features
    assert feature_detail.advanced_with_findings == nil
  end

  test "pinning the loop off makes no remediation call and leaves the reason bare (SC-007a)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :analyze_high)
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "delegation-off-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :remediation, :start],
      fn _event, _meas, meta, _ -> send(test_pid, {:attempt, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result = FeatureRunner.run(feature(), worktree: wt, notify: self(), run_context: loop_off())

    assert result.reason == :high_findings
    refute_received {:attempt, _meta}
    refute File.exists?(Path.join(wt.path, ".speckit_logs/05-remediation-a1.md"))
  end

  test "runs without a worktree (dry run in base repo), notify as a function" do
    me = self()
    notify = fn id, status, reason -> send(me, {:notified, id, status, reason}) end
    result = FeatureRunner.run(feature(), notify: notify)
    assert result.status == :done
    assert_received {:notified, "001", :done, _}
  end

  test "malformed analyze JSON fails the feature at analyze (never a silent pass)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :bad_analyze)
    result = FeatureRunner.run(feature(), notify: self())
    assert result.status == :failed
    assert result.reason == {:analyze, :error}
  end

  test "emits phase + terminal telemetry and records per-phase transcripts in the store" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    test_pid = self()
    handler = "tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:speckit, :phase, :stop], [:speckit, :feature, :terminal]],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{phase: :specify, outcome: :ok, model: "sonnet"}}

    assert_received {:tele, [:speckit, :feature, :terminal], %{status: :escalated}}

    # worktree kept on escalation -> phase attempts + transcripts recorded
    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    [feature_detail] = detail.features
    assert Enum.find(feature_detail.phase_attempts, &(&1.phase == :specify))
    clarify = Enum.find(feature_detail.phase_attempts, &(&1.phase == :clarify))
    assert {:ok, %{body: clarify_body}} = SpeckitOrchestrator.Store.transcript(clarify.attempt_id)
    assert clarify_body =~ "NEEDS HUMAN"
  end

  test "per-phase checkpoint written after each successful phase — overwritten (not appended) as the pipeline advances (018, store-backed)" do
    wt = scaffolded_worktree()
    run_context = %RunContext{}
    run_key = open_store_run()

    test_pid = self()
    handler = "checkpoint-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :start],
      fn _event, _meas, %{phase: phase}, _ ->
        if phase in [:clarify, :plan] do
          send(
            test_pid,
            {:checkpoint_at, phase, SpeckitOrchestrator.Store.checkpoint(run_key, "001")}
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(),
      worktree: wt,
      notify: self(),
      run_context: run_context,
      run_key: run_key
    )

    assert_received {:checkpoint_at, :clarify, {:ok, record}}
    assert record.last_completed_phase == :specify
    assert record.status == :in_progress

    assert_received {:checkpoint_at, :plan, {:ok, record2}}
    assert record2.last_completed_phase == :clarify
    assert record2.status == :in_progress
  end

  test "the feature_run row reads :running while the feature is in flight, not the status it started from (018, store-backed)" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    test_pid = self()
    handler = "started-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :start],
      fn _event, _meas, %{phase: phase}, _ ->
        if phase == :specify do
          {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
          send(test_pid, {:row_at_specify, hd(detail.features)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(), worktree: wt, notify: self(), run_key: run_key)

    assert_received {:row_at_specify, row}
    assert row.status == :running
    assert %DateTime{} = row.started_at

    # …and the terminal write still lands, so the row is only :running while
    # the feature actually is.
    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    assert hd(detail.features).status == :escalated
  end

  @tag :integration
  test "commits the worktree once per phase — a phase-boundary commit exists after each phase that changed something" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    FeatureRunner.run(feature(), worktree: wt, notify: self(), run_context: loop_off())

    {log, 0} = System.cmd("git", ["-C", wt.repo, "log", "--format=%s", wt.branch])

    # specify/plan/tasks each write a real artifact (FakeArtifacts), so each
    # gets its own phase-boundary commit. clarify and analyze write nothing in
    # this harness (018: no durable-transcript-file side effect to fall back
    # on) — `Worktree.commit/2` correctly no-ops when there is nothing staged,
    # so neither appears in the log.
    assert log =~ "speckit: 001 checkpoint after specify"
    refute log =~ "speckit: 001 checkpoint after clarify"
    assert log =~ "speckit: 001 checkpoint after plan"
    assert log =~ "speckit: 001 checkpoint after tasks"
    refute log =~ "speckit: 001 checkpoint after analyze"
  end

  @tag :integration
  test "on :done, handle_worktree squashes per-phase commits into exactly one commit since the fork point" do
    wt = scaffolded_worktree()
    {base_sha, 0} = System.cmd("git", ["-C", wt.repo, "rev-parse", "main"])
    base_sha = String.trim(base_sha)

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())
    assert result.status == :done

    {count, 0} =
      System.cmd("git", ["-C", wt.repo, "rev-list", "--count", "#{base_sha}..#{wt.branch}"])

    assert String.trim(count) == "1"

    {log, 0} = System.cmd("git", ["-C", wt.repo, "log", "--format=%s", wt.branch])
    refute log =~ "checkpoint after"
  end

  @tag :integration
  test "on :done, the squash forks from :stack_base, so a stacked feature stays a child of the branch below it" do
    # The stack: main <- feature/000-below <- (this feature). Squashing against
    # Config.pr_base() ("main") instead of the stack base would reset past
    # 000's commit, reparenting this feature onto main and swallowing 000's
    # changes into its own diff — which is what made the stacked PR conflict
    # with the branch it targets.
    wt = scaffolded_worktree(stack_base: "feature/000-below")

    {below_sha, 0} =
      System.cmd("git", ["-C", wt.repo, "rev-parse", "feature/000-below"])

    below_sha = String.trim(below_sha)

    result =
      FeatureRunner.run(feature(),
        worktree: wt,
        notify: self(),
        stack_base: "feature/000-below"
      )

    assert result.status == :done

    # Exactly one commit on top of the branch below — not on top of main.
    {count, 0} =
      System.cmd("git", ["-C", wt.repo, "rev-list", "--count", "#{below_sha}..#{wt.branch}"])

    assert String.trim(count) == "1"

    # …and that commit's parent is the branch below itself.
    {parent, 0} = System.cmd("git", ["-C", wt.repo, "rev-parse", "#{wt.branch}^"])
    assert String.trim(parent) == below_sha

    # The file 000 added is untouched by this feature's diff — it is inherited
    # history, not re-proposed content.
    {diff, 0} =
      System.cmd("git", ["-C", wt.repo, "diff", "--name-only", "#{below_sha}..#{wt.branch}"])

    refute diff =~ "below.txt"
  end

  @tag :integration
  test "on a kept terminal (:escalated), per-phase checkpoint commits remain — squash is not called" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()
    {base_sha, 0} = System.cmd("git", ["-C", wt.repo, "rev-parse", "main"])
    base_sha = String.trim(base_sha)

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())
    assert result.status == :escalated

    {count, 0} =
      System.cmd("git", ["-C", wt.repo, "rev-list", "--count", "#{base_sha}..#{wt.branch}"])

    # specify wrote a real artifact and got its own phase-boundary commit;
    # clarify (which escalates) wrote nothing in this harness, so there is
    # exactly one commit — the point of this test is that it is still the
    # per-phase message, not squash's, proving squash was never called for a
    # kept terminal (contrast the :done test above, which asserts the
    # opposite: no "checkpoint after" message survives the squash).
    assert String.trim(count) == "1"

    {log, 0} = System.cmd("git", ["-C", wt.repo, "log", "--format=%s", wt.branch])
    assert log =~ "speckit: 001 checkpoint after specify"
  end

  test "breaker tripping mid-run halts the feature (drain, not kill)" do
    # budget below one phase's cost -> after the first phase records cost, the
    # breaker trips and the runner halts before the next phase.
    {:ok, ledger} = Ledger.start_link(budget: 0.05, name: nil)
    result = FeatureRunner.run(feature(), ledger: ledger, notify: self())
    assert result.status == :halted
    assert result.reason == :breaker
    assert_received {:feature_finished, "001", :halted, :breaker}
  end

  test "start_phase: :plan resumes mid-pipeline, skipping specify/clarify" do
    # :halt keeps the worktree (analyze critical -> :halted); :done removes it
    # entirely, which would defeat this assertion regardless of start phase.
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    result =
      FeatureRunner.run(feature(),
        start_phase: :plan,
        worktree: wt,
        notify: self(),
        run_context: loop_off(),
        run_key: run_key
      )

    assert result.status == :halted

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    phases = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> Enum.map(& &1.phase)
    assert :plan in phases
    refute :specify in phases
    refute :clarify in phases
  end

  test "no start_phase: begins at :specify, step 1 (explicit no-regression)" do
    # :halt keeps the worktree (analyze critical -> :halted) so the recorded
    # attempt survives for inspection.
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()
    run_key = open_store_run()

    test_pid = self()
    handler = "tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :stop],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(),
      worktree: wt,
      notify: self(),
      run_context: loop_off(),
      run_key: run_key
    )

    assert_received {:tele, [:speckit, :phase, :stop], %{phase: :specify, step: 1}}

    {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
    specify = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> hd()
    assert specify.phase == :specify
    assert specify.step == 1
  end

  test "start_phase: :plan begins at step 3, matching its pipeline position" do
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :stop],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(), start_phase: :plan, worktree: wt, notify: self())

    assert_received {:tele, [:speckit, :phase, :stop], %{phase: :plan, step: 3}}
  end

  test "a phase call timeout marks the feature :failed" do
    # 1ms timeout forces the call to die; the runner catches and fails the feature.
    result = FeatureRunner.run(feature(), phase_timeout: 1, notify: self())
    assert result.status == :failed
    assert_received {:feature_finished, "001", :failed, _}
  end

  test "resume_phase stays fixed at the anchor phase as phase advances" do
    # Drives the agent directly (bypassing FeatureRunner.run/2's opaque
    # synchronous loop) so state can be inspected between phase.run calls.
    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "resume-anchor-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, agent} =
      AgentServer.call(
        pid,
        Signal.new!(
          "feature.init",
          %{feature: feature(), phase: :plan, resume_prompt: "pick up at plan"},
          source: "/test"
        ),
        5_000
      )

    assert agent.state.resume_phase == :plan
    assert agent.state.resume_prompt == "pick up at plan"

    {:ok, _agent} =
      AgentServer.call(pid, Signal.new!("phase.run", %{phase: :plan}, source: "/test"), 5_000)

    {:ok, agent} =
      AgentServer.call(pid, Signal.new!("phase.run", %{phase: :tasks}, source: "/test"), 5_000)

    assert agent.state.phase == :tasks
    assert agent.state.resume_phase == :plan

    GenServer.stop(pid, :normal)
  end

  # --- pre-phase remediation (feature 013) -----------------------------------

  describe "pre-phase remediation" do
    test "runs exactly once, before the target phase, which then observes the remediated artifacts" do
      Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
      wt = scaffolded_worktree()

      hook = fn prompt, options ->
        cwd =
          case options do
            %{cwd: cwd} -> cwd
            list when is_list(list) -> Keyword.get(list, :cwd)
            _ -> nil
          end

        if cwd && String.contains?(prompt, "Remediation for feature") do
          File.write!(Path.join(cwd, "REMEDIATED.marker"), "fixed\n")
        else
          SpeckitOrchestrator.FakeArtifacts.write(prompt, options)
        end
      end

      Application.put_env(:speckit_orchestrator, :test_artifact_hook, hook)
      on_exit(fn -> Application.delete_env(:speckit_orchestrator, :test_artifact_hook) end)

      test_pid = self()
      handler = "remediation-order-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:speckit, :phase, :start],
        fn _event, _meas, %{phase: phase}, _ -> send(test_pid, {:phase_start, phase}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      run_key = open_store_run()

      result =
        FeatureRunner.run(feature(),
          worktree: wt,
          notify: self(),
          remediation_prompt: "Fix the money-type Critical.",
          run_context: loop_off(),
          run_key: run_key
        )

      assert result.status == :halted

      # remediation started (and thus completed) before the target phase
      assert_received {:phase_start, :remediation}
      assert_received {:phase_start, :specify}

      {:ok, detail} = SpeckitOrchestrator.Store.run(run_key)
      phases = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> Enum.map(& &1.phase)
      assert :remediation in phases
      assert :specify in phases

      # the marker remediation wrote is still there — the target phase (and
      # every phase after it) ran against the artifacts remediation left
      assert File.exists?(Path.join(wt.path, "REMEDIATED.marker"))
    end

    test "a transient remediation failure is auto-retried and the resume proceeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Application.put_env(:speckit_orchestrator, :test_transient_counter, counter)
      Application.put_env(:speckit_orchestrator, :test_fake_scenario, :remediation_transient_once)

      on_exit(fn ->
        Application.delete_env(:speckit_orchestrator, :test_transient_counter)
        if Process.alive?(counter), do: Agent.stop(counter)
      end)

      wt = scaffolded_worktree()

      result =
        FeatureRunner.run(feature(),
          worktree: wt,
          notify: self(),
          remediation_prompt: "Fix the money-type Critical."
        )

      # First remediation call dropped mid-response; retried once, then the
      # whole pipeline still reaches :done.
      assert result.status == :done
      assert Agent.get(counter, & &1) == 2
    end

    test "a genuine remediation failure stops the resume before the target phase runs" do
      Application.put_env(:speckit_orchestrator, :test_fake_scenario, :remediation_error)
      wt = scaffolded_worktree()

      result =
        FeatureRunner.run(feature(),
          worktree: wt,
          notify: self(),
          remediation_prompt: "Fix the money-type Critical."
        )

      assert result.status == :failed
      assert result.reason == :remediation_failed
      assert_received {:feature_finished, "001", :failed, :remediation_failed}
      # worktree kept for post-mortem, never removed
      assert File.dir?(wt.path)
      # the target phase (specify) never ran
      refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
    end

    test "an absent, blank, or whitespace-only remediation_prompt runs no remediation step (FR-004/SC-002)" do
      for prompt <- [nil, "", "   \n\t "] do
        wt = scaffolded_worktree()
        {:ok, ledger} = Ledger.start_link(budget: 100, name: nil)

        test_pid = self()
        handler = "no-remediation-tele-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          [:speckit, :phase, :start],
          fn _event, _meas, %{phase: phase}, _ -> send(test_pid, {:phase_start, phase}) end,
          nil
        )

        result =
          FeatureRunner.run(feature(),
            worktree: wt,
            ledger: ledger,
            notify: self(),
            remediation_prompt: prompt
          )

        :telemetry.detach(handler)

        assert result.status == :done
        refute_received {:phase_start, :remediation}
        refute File.exists?(Path.join(wt.path, ".speckit_logs/00-remediation.md"))
        assert Ledger.spent(ledger) == result.cost_total
      end
    end
  end

  # --- pre-phase remediation is scoped to this one resume (feature 013, US3) -

  test "a remediation step at one target phase never re-fires as the pipeline advances to a later phase" do
    # :happy (default) scenario clears the analyze gate, so the pipeline keeps
    # advancing past :analyze into :implement and beyond — proving remediation
    # ran exactly once, before :analyze only, and never again for any
    # subsequent phase (FR-005/SC-003).
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "remediation-scope-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :start],
      fn _event, _meas, %{phase: phase}, _ -> send(test_pid, {:phase_start, phase}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      FeatureRunner.run(feature(),
        start_phase: :analyze,
        worktree: wt,
        notify: self(),
        remediation_prompt: "Fix the money-type Critical."
      )

    assert result.status == :done

    starts = collect_phase_starts([])
    assert Enum.count(starts, &(&1 == :remediation)) == 1

    # remediation precedes only the target phase (:analyze) — first in the
    # recorded order, immediately followed by :analyze, and does not recur
    # before :implement or any phase after it
    assert starts == [:remediation, :analyze, :implement, :converge]
  end

  defp collect_phase_starts(acc) do
    receive do
      {:phase_start, phase} -> collect_phase_starts([phase | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
