defmodule SpeckitOrchestrator.FeatureRunnerTest do
  # async: false — swaps the global :jido_claude sdk_module + a scenario flag.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.{
    Checkpoint,
    Describe,
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

            :analyze_high ->
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
    do: %Feature{id: "001", slug: "core-ledger", path: "docs/breakdown/001-core-ledger.md"}

  # --- real base repo + worktree for the containment assertions ---
  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_worktree do
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

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    {:ok, wt} = Worktree.create(feature(), repo: repo, worktree_root: root)
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
    # feature still reached :done. Calls = 1 dropped + 7 phases.
    assert result.status == :done
    assert Agent.get(counter, & &1) == 8
  end

  test "PR workflow :done — describe authors the commit message + PR text" do
    Application.put_env(:speckit_orchestrator, :pr_workflow, true)
    on_exit(fn -> Application.delete_env(:speckit_orchestrator, :pr_workflow) end)

    wt = scaffolded_worktree()
    # Give the commit something to include so the authored message actually lands.
    File.write!(Path.join(wt.path, "note.txt"), "generated\n")

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())
    assert result.status == :done

    # Commit message on the branch is the Claude-authored one (not the template).
    {subject, 0} = System.cmd("git", ["-C", wt.repo, "log", "-1", "--format=%s", wt.branch])
    assert subject =~ "feat(001): built core ledger"

    # PR title/body were written for the facade to open the PR with.
    assert {:ok, %{pr_title: "Add core ledger", pr_body: body}} = Describe.read_pr("001")
    assert body =~ "Summary"
  end

  test "analyze critical: stops at :halted and keeps the worktree" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

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
    assert result.reason == {:missing_artifact, :plan, "specs/**/plan.md"}
    # kept for post-mortem, never removed
    assert File.dir?(wt.path)
  end

  test "tasks that writes no tasks.md fails the feature" do
    fake_writing_all_but([:tasks])
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :failed
    assert result.reason == {:missing_artifact, :tasks, "specs/**/tasks.md"}
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

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert result.status == :escalated
    assert result.reason == :high_findings
    assert File.dir?(wt.path)
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

  test "emits phase + terminal telemetry and writes per-phase transcripts" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()

    test_pid = self()
    handler = "tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:speckit, :phase, :stop], [:speckit, :feature, :terminal]],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{phase: :specify, outcome: :ok, model: "sonnet"}}

    assert_received {:tele, [:speckit, :feature, :terminal], %{status: :escalated}}

    # worktree kept on escalation -> transcripts present
    assert File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
    assert File.read!(Path.join(wt.path, ".speckit_logs/02-clarify.md")) =~ "# clarify"
  end

  test "per-phase checkpoint written after each successful phase — overwritten (not appended) as the pipeline advances" do
    wt = scaffolded_worktree()
    run_context = %RunContext{pr_workflow: false, max_concurrency: 1}

    test_pid = self()
    handler = "checkpoint-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :start],
      fn _event, _meas, %{phase: phase}, _ ->
        if phase in [:clarify, :plan] do
          send(test_pid, {:checkpoint_at, phase, Checkpoint.read("001")})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    FeatureRunner.run(feature(), worktree: wt, notify: self(), run_context: run_context)

    assert_received {:checkpoint_at, :clarify, {:ok, record}}
    assert record["last_phase"] == "specify"
    assert record["status"] == "in_progress"
    assert is_map(record["context"])

    assert_received {:checkpoint_at, :plan, {:ok, record2}}
    assert record2["last_phase"] == "clarify"
    assert record2["status"] == "in_progress"
  end

  @tag :integration
  test "commits the worktree once per phase — a phase-boundary commit exists after each successful phase" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    FeatureRunner.run(feature(), worktree: wt, notify: self())

    {log, 0} = System.cmd("git", ["-C", wt.repo, "log", "--format=%s", wt.branch])

    assert log =~ "speckit: 001 checkpoint after specify"
    assert log =~ "speckit: 001 checkpoint after clarify"
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
  test "on a kept terminal (:escalated), per-phase checkpoint commits remain — squash is not called" do
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
    wt = scaffolded_worktree()
    {base_sha, 0} = System.cmd("git", ["-C", wt.repo, "rev-parse", "main"])
    base_sha = String.trim(base_sha)

    result = FeatureRunner.run(feature(), worktree: wt, notify: self())
    assert result.status == :escalated

    {count, 0} =
      System.cmd("git", ["-C", wt.repo, "rev-list", "--count", "#{base_sha}..#{wt.branch}"])

    assert String.to_integer(String.trim(count)) > 1

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
    # :halt keeps the worktree (analyze critical -> :halted) so the transcripts
    # written along the way survive for inspection; :done removes the worktree
    # entirely, which would defeat this assertion regardless of start phase.
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
    wt = scaffolded_worktree()

    result = FeatureRunner.run(feature(), start_phase: :plan, worktree: wt, notify: self())

    assert result.status == :halted
    assert File.exists?(Path.join(wt.path, ".speckit_logs/03-plan.md"))
    refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
    refute File.exists?(Path.join(wt.path, ".speckit_logs/02-clarify.md"))
  end

  test "no start_phase: begins at :specify, step 1 (explicit no-regression)" do
    # :halt keeps the worktree (analyze critical -> :halted) so the transcript
    # written along the way survives for inspection.
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
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

    FeatureRunner.run(feature(), worktree: wt, notify: self())

    assert_received {:tele, [:speckit, :phase, :stop], %{phase: :specify, step: 1}}
    assert File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
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

      result =
        FeatureRunner.run(feature(),
          worktree: wt,
          notify: self(),
          remediation_prompt: "Fix the money-type Critical."
        )

      assert result.status == :halted

      # remediation started (and thus completed) before the target phase
      assert_received {:phase_start, :remediation}
      assert_received {:phase_start, :specify}

      assert File.exists?(Path.join(wt.path, ".speckit_logs/00-remediation.md"))
      assert File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))

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
