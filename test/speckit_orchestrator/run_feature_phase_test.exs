defmodule SpeckitOrchestrator.Actions.RunFeaturePhaseTest do
  # async: false — toggles the global :jido_harness providers / :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Actions.RunFeaturePhase
  alias SpeckitOrchestrator.{Config, Feature, PhaseRequest}

  # Fake SDK that reports the built prompt back to the test process so the
  # resume-guidance injection can be asserted end-to-end (no CLI, no spend).
  defmodule CapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _opts) do
      send(self(), {:captured_prompt, prompt})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-cap",
            result: "ok",
            num_turns: 1,
            duration_ms: 1,
            is_error: false,
            total_cost_usd: 0.0,
            usage: %{input_tokens: 0, output_tokens: 0},
            model: "m"
          },
          raw: %{}
        }
      ]
    end
  end

  # Fake SDK whose session reports success while one tool call never returns —
  # the event-level signature of a model that ended its turn mid-flight.
  defmodule StrandingSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _opts) do
      [
        tool_use("call-1", "Read"),
        tool_result("call-1"),
        tool_use("call-2", "Task"),
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-strand",
            result: "Waiting on agents before filling plan.md.",
            num_turns: 2,
            duration_ms: 1,
            is_error: false,
            total_cost_usd: 0.0,
            usage: %{input_tokens: 0, output_tokens: 0},
            model: "m"
          },
          raw: %{}
        }
      ]
    end

    defp tool_use(id, name) do
      %Message{
        type: :assistant,
        data: %{
          message: %{
            "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}]
          }
        },
        raw: %{}
      }
    end

    defp tool_result(id) do
      %Message{
        type: :user,
        data: %{
          message: %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => id,
                "content" => "ok",
                "is_error" => false
              }
            ]
          }
        },
        raw: %{}
      }
    end
  end

  defp context(state_overrides \\ %{}) do
    base = %{
      feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
      worktree: nil,
      layout: nil,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      resume_phase: nil,
      resume_prompt: nil
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  test "resume_prompt re-injects on every retry of the resumed phase" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx =
      context(%{
        resume_phase: :analyze,
        resume_prompt: "resolved: use integer cents"
      })

    assert {:ok, _} = RunFeaturePhase.run(%{phase: :analyze}, ctx)
    assert_received {:captured_prompt, prompt1}

    assert {:ok, _} = RunFeaturePhase.run(%{phase: :analyze}, ctx)
    assert_received {:captured_prompt, prompt2}

    for prompt <- [prompt1, prompt2] do
      assert prompt =~ "Operator guidance (resume): resolved: use integer cents"
    end

    assert prompt1 == prompt2
  end

  # A chunked implement resume: guidance lands on the first dispatched
  # task-phase and on the sweep (the session that owns the leftovers an
  # operator is usually resuming for), never on the task-phases in between.
  test "resume_prompt reaches the first chunk and the sweep, not middle task-phases" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx = context(%{resume_phase: :implement, resume_prompt: "T105: defer M3/M4/M7"})
    tp = %SpeckitOrchestrator.TaskPlan.TaskPhase{ordinal: 1, number: "1", title: "Setup", tasks: []}
    task = %SpeckitOrchestrator.TaskPlan.Task{id: "T105", text: "manual scenarios", line: 1}

    calls = [
      {%{phase: :implement, scope: {:task_phase, tp}, first_chunk: true}, true},
      {%{phase: :implement, scope: {:task_phase, tp}}, false},
      {%{phase: :implement, scope: {:sweep, [task]}}, true}
    ]

    for {params, expected?} <- calls do
      assert {:ok, _} = RunFeaturePhase.run(params, ctx)
      assert_received {:captured_prompt, prompt}
      assert (prompt =~ "Operator guidance (resume): T105: defer M3/M4/M7") == expected?
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  @all_phases [:specify, :clarify, :plan, :tasks, :analyze, :implement]

  test "resume guidance reaches only the resume phase, never downstream" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx = context(%{resume_phase: :clarify, resume_prompt: "use REST, not GraphQL"})

    prompts =
      for phase <- @all_phases, into: %{} do
        assert {:ok, _} = RunFeaturePhase.run(%{phase: phase}, ctx)
        assert_received {:captured_prompt, prompt}
        {phase, prompt}
      end

    assert prompts[:clarify] =~ "Operator guidance (resume): use REST, not GraphQL"

    for phase <- @all_phases, phase != :clarify do
      refute prompts[phase] =~ "use REST, not GraphQL"
    end
  end

  test "a fresh run (no resume state) builds byte-identical prompts on every phase" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx = context()
    feature = ctx.agent.state.feature

    for phase <- @all_phases do
      assert {:ok, _} = RunFeaturePhase.run(%{phase: phase}, ctx)
      assert_received {:captured_prompt, prompt}

      expected = PhaseRequest.build(feature, phase, cwd: Config.repo()).prompt
      assert prompt == expected
    end
  end

  test "a scoped implement request defers the artifact gate to ChunkRunner's roll-up" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    tmp = Path.join(System.tmp_dir!(), "rfp_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.cmd("git", ["init"], cd: tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    ctx = context(%{worktree: %{path: tmp}})

    # no scope: the artifact gate reports the missing implementation
    assert {:ok, update} = RunFeaturePhase.run(%{phase: :implement}, ctx)
    assert update.last_signals == %{missing_artifact: "implementation changes"}

    tp = %SpeckitOrchestrator.TaskPlan.TaskPhase{
      ordinal: 1,
      number: "1",
      title: "Setup",
      tasks: []
    }

    # scoped: the gate is deferred — always {:ok, %{}}
    assert {:ok, update2} =
             RunFeaturePhase.run(%{phase: :implement, scope: {:task_phase, tp}}, ctx)

    assert update2.last_signals == %{}
  end

  # A stacked worktree carries every earlier feature's specs/ directory. These
  # cases pin that the gates ask about the feature being built, not about
  # whatever `specs/**` happens to match first (which is reliably the oldest
  # feature, since Path.wildcard/1 sorts).
  describe "gates in a stacked worktree" do
    defp stacked_worktree(opts) do
      tmp = Path.join(System.tmp_dir!(), "rfp_stack_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      # The inherited feature: complete, and carrying a NEEDS HUMAN marker
      # because it escalated when it ran.
      File.mkdir_p!(Path.join(tmp, "specs/001-core"))
      File.write!(Path.join(tmp, "specs/001-core/plan.md"), "# 001 plan\n")
      File.write!(Path.join(tmp, "specs/001-core/tasks.md"), "- [x] T001\n")

      File.write!(
        Path.join(tmp, "specs/001-core/spec.md"),
        "# 001\n\n## NEEDS HUMAN\n\nmonth-end proration is ambiguous\n"
      )

      Enum.each(Keyword.get(opts, :own_files, []), fn {leaf, body} ->
        File.mkdir_p!(Path.join(tmp, "specs/002-next"))
        File.write!(Path.join([tmp, "specs/002-next", leaf]), body)
      end)

      tmp
    end

    defp with_capturing_sdk do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)
    end

    defp feature_002_ctx(tmp) do
      context(%{
        worktree: %{path: tmp},
        feature: %Feature{id: "002", number: 2, slug: "next", path: "002.md"}
      })
    end

    test "the plan gate is not satisfied by an inherited feature's plan.md" do
      with_capturing_sdk()
      tmp = stacked_worktree(own_files: [])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, feature_002_ctx(tmp))

      # 001's plan.md exists and would have satisfied a specs/**/plan.md glob.
      assert File.regular?(Path.join(tmp, "specs/001-core/plan.md"))
      assert update.last_signals == %{missing_artifact: "plan.md", artifact_absent_at_start?: true}
    end

    test "the plan gate passes on the feature's own plan.md" do
      with_capturing_sdk()
      tmp = stacked_worktree(own_files: [{"plan.md", "# 002 plan\n"}])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, feature_002_ctx(tmp))
      assert update.last_signals == %{artifact_absent_at_start?: false}
    end

    test "the tasks gate is not satisfied by an inherited feature's tasks.md" do
      with_capturing_sdk()
      tmp = stacked_worktree(own_files: [])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :tasks}, feature_002_ctx(tmp))
      assert update.last_signals == %{missing_artifact: "tasks.md", artifact_absent_at_start?: true}
    end

    test "the clarify gate does not escalate on a marker left in another feature's spec" do
      with_capturing_sdk()
      tmp = stacked_worktree(own_files: [{"spec.md", "# 002\n\nall clear\n"}])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :clarify}, feature_002_ctx(tmp))

      # 001's spec.md carries the marker; scanning specs/**/spec.md escalated
      # every descendant of an escalated feature forever.
      assert File.read!(Path.join(tmp, "specs/001-core/spec.md")) =~ "## NEEDS HUMAN"
      assert update.last_signals == %{needs_human?: false}
    end

    test "the clarify gate still escalates on a marker in the feature's own spec" do
      with_capturing_sdk()
      tmp = stacked_worktree(own_files: [{"spec.md", "# 002\n\n## NEEDS HUMAN\n\nwhich tz?\n"}])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :clarify}, feature_002_ctx(tmp))
      assert update.last_signals == %{needs_human?: true}
    end
  end

  # Feature 022 net one (FR-009/FR-010/FR-011): an ambiguous own-prefix match
  # is unresolved, exactly like a wholly missing directory — it must never
  # settle on either candidate, even when one of them is a real, otherwise
  # legitimate-looking directory for this feature's own numeric prefix.
  describe "an ambiguous own-prefix match reads as unresolved (feature 022 net one)" do
    defp ambiguous_worktree(opts) do
      tmp = Path.join(System.tmp_dir!(), "rfp_ambiguous_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      # Two directories sharing the feature's "002-" prefix, neither the exact
      # `002-<slug>` name — candidate 1 never matches, candidate 3 sees two.
      File.mkdir_p!(Path.join(tmp, "specs/002-next"))
      File.mkdir_p!(Path.join(tmp, "specs/002-next-alt"))

      Enum.each(Keyword.get(opts, :files, []), fn {dir, leaf, body} ->
        File.write!(Path.join([tmp, "specs/#{dir}", leaf]), body)
      end)

      tmp
    end

    defp feature_orphan_ctx(tmp) do
      context(%{
        worktree: %{path: tmp},
        feature: %Feature{id: "002", number: 2, slug: "orphan", path: "002.md"}
      })
    end

    test "the plan gate treats it as missing, not as either candidate's file" do
      with_capturing_sdk()
      tmp = ambiguous_worktree(files: [{"002-next", "plan.md", "# plan\n"}])

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, feature_orphan_ctx(tmp))

      assert File.regular?(Path.join(tmp, "specs/002-next/plan.md"))
      assert update.last_signals == %{missing_artifact: "plan.md", artifact_absent_at_start?: true}
    end

    test "the clarify gate does not escalate on a marker in either ambiguous candidate" do
      with_capturing_sdk()

      tmp =
        ambiguous_worktree(
          files: [{"002-next-alt", "spec.md", "# spec\n\n## NEEDS HUMAN\n\nwhich one?\n"}]
        )

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :clarify}, feature_orphan_ctx(tmp))

      assert File.read!(Path.join(tmp, "specs/002-next-alt/spec.md")) =~ "## NEEDS HUMAN"
      assert update.last_signals == %{needs_human?: false}
    end
  end

  test "a harness error is folded into an :error outcome (no crash, no cost)" do
    original = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)

    assert {:ok, update} = RunFeaturePhase.run(%{phase: :specify}, context())
    assert update.last_outcome == :error
    assert update.last_result == nil
    assert [%{phase: :specify, outcome: :error}] = update.history
  end

  describe "the plan gate reads substance, not just existence" do
    defp planned_worktree(plan_body, template_body) do
      tmp = Path.join(System.tmp_dir!(), "rfp_subst_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "specs/001-s"))
      File.mkdir_p!(Path.join(tmp, ".specify/templates"))
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      File.write!(Path.join(tmp, ".specify/templates/plan-template.md"), template_body)
      if plan_body, do: File.write!(Path.join(tmp, "specs/001-s/plan.md"), plan_body)
      tmp
    end

    @template File.read!(Path.expand("../fixtures/templates/plan-template.md", __DIR__))

    test "an untouched template copy fails the gate as an unfilled artifact" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      tmp = planned_worktree(@template, @template)
      ctx = context(%{worktree: %{path: tmp}})

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, ctx)

      assert update.last_signals == %{
               missing_artifact: "plan.md (unfilled template)",
               unfilled_artifact?: true,
               artifact_absent_at_start?: false
             }
    end

    test "a real plan still passes, template on disk or not" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      tmp = planned_worktree("# Plan: real\n\nWe will use Elixir.\n", @template)
      ctx = context(%{worktree: %{path: tmp}})

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, ctx)
      assert update.last_signals == %{artifact_absent_at_start?: false}
    end
  end

  describe "the incomplete-session gate" do
    defp with_stranding_sdk do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, StrandingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)
    end

    test "an ungated phase that ends with work outstanding is an error" do
      with_stranding_sdk()

      assert {:ok, update} = RunFeaturePhase.run(%{phase: :clarify}, context())
      assert update.last_outcome == :error
      assert update.last_signals == %{outstanding_work?: true}
    end

    test "a gated phase whose artifact is filled in is left alone" do
      with_stranding_sdk()

      tmp = Path.join(System.tmp_dir!(), "rfp_strand_ok_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "specs/001-s"))
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      File.write!(Path.join(tmp, "specs/001-s/plan.md"), "# Plan: real\n\nElixir.\n")

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :plan}, context(%{worktree: %{path: tmp}}))

      assert update.last_outcome == :ok
      assert update.last_signals == %{artifact_absent_at_start?: false}
    end

    test "a gated phase whose artifact is missing reports the incomplete session" do
      with_stranding_sdk()

      tmp = Path.join(System.tmp_dir!(), "rfp_strand_bad_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "specs/001-s"))
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :plan}, context(%{worktree: %{path: tmp}}))

      assert update.last_outcome == :error
      assert update.last_signals == %{outstanding_work?: true, artifact_absent_at_start?: true}
    end

    test "a scoped implement chunk is never pre-empted — the roll-up owns that gate" do
      with_stranding_sdk()

      tmp = Path.join(System.tmp_dir!(), "rfp_strand_chunk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      tp = %SpeckitOrchestrator.TaskPlan.TaskPhase{
        ordinal: 1,
        number: "1",
        title: "Setup",
        tasks: []
      }

      assert {:ok, update} =
               RunFeaturePhase.run(
                 %{phase: :implement, scope: {:task_phase, tp}},
                 context(%{worktree: %{path: tmp}})
               )

      assert update.last_outcome == :ok
      assert update.last_signals == %{}
    end
  end

  describe "artifact_absent_at_start? probe (net two arming signal)" do
    setup do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)
      :ok
    end

    for phase <- [:specify, :plan, :tasks] do
      test "set for armed phase #{phase} when the worktree exists and the artifact is absent" do
        tmp = Path.join(System.tmp_dir!(), "rfp_probe_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        System.cmd("git", ["init"], cd: tmp)
        on_exit(fn -> File.rm_rf(tmp) end)

        assert {:ok, update} =
                 RunFeaturePhase.run(%{phase: unquote(phase)}, context(%{worktree: %{path: tmp}}))

        assert update.last_signals.artifact_absent_at_start? == true
      end
    end

    for {phase, leaf} <- [specify: "spec.md", plan: "plan.md", tasks: "tasks.md"] do
      test "clear for armed phase #{phase} when the artifact is already present at start" do
        tmp = Path.join(System.tmp_dir!(), "rfp_probe_#{System.unique_integer([:positive])}")
        File.mkdir_p!(Path.join(tmp, "specs/001-s"))
        System.cmd("git", ["init"], cd: tmp)
        on_exit(fn -> File.rm_rf(tmp) end)
        File.write!(Path.join(tmp, "specs/001-s/#{unquote(leaf)}"), "content\n")

        assert {:ok, update} =
                 RunFeaturePhase.run(%{phase: unquote(phase)}, context(%{worktree: %{path: tmp}}))

        assert update.last_signals.artifact_absent_at_start? == false
      end
    end

    for phase <- [:clarify, :analyze, :implement, :converge] do
      test "never set for unarmed phase #{phase}, worktree or not" do
        tmp = Path.join(System.tmp_dir!(), "rfp_probe_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        System.cmd("git", ["init"], cd: tmp)
        on_exit(fn -> File.rm_rf(tmp) end)

        assert {:ok, with_wt} =
                 RunFeaturePhase.run(%{phase: unquote(phase)}, context(%{worktree: %{path: tmp}}))

        refute Map.has_key?(with_wt.last_signals, :artifact_absent_at_start?)

        assert {:ok, without_wt} = RunFeaturePhase.run(%{phase: unquote(phase)}, context())
        refute Map.has_key?(without_wt.last_signals, :artifact_absent_at_start?)
      end
    end

    test "not set for an armed phase when there is no worktree (dry run)" do
      assert {:ok, update} = RunFeaturePhase.run(%{phase: :plan}, context())
      refute Map.has_key?(update.last_signals, :artifact_absent_at_start?)
    end

    test "unaffected by the artifact gate's own verdict — set even when the gate fails" do
      tmp = Path.join(System.tmp_dir!(), "rfp_probe_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :tasks}, context(%{worktree: %{path: tmp}}))

      assert update.last_signals.missing_artifact == "tasks.md"
      assert update.last_signals.artifact_absent_at_start? == true
    end
  end

  describe "branch drift (027, US2)" do
    test "a session that leaves the orchestrator's branch fails the phase with drift naming both branches" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      tmp = Path.join(System.tmp_dir!(), "rfp_drift_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      {_, 0} = System.cmd("git", ["init", "-b", "feature/001-s"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "seed\n")
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], cd: tmp)

      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "seed"],
        cd: tmp
      )

      on_exit(fn -> File.rm_rf(tmp) end)

      # The stubbed harness session's own effect: it moved HEAD off the branch
      # the orchestrator expects — exactly what the mod-player incident's
      # target-side hook did mid-`specify`.
      {_, 0} = System.cmd("git", ["checkout", "-b", "other"], cd: tmp)

      worktree = %SpeckitOrchestrator.Worktree{
        path: tmp,
        branch: "feature/001-s",
        repo: tmp,
        feature_id: "001"
      }

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :clarify}, context(%{worktree: worktree}))

      assert update.last_outcome == :error
      assert update.last_signals == %{branch_drift: %{expected: "feature/001-s", observed: "other"}}
    end

    test "a detached HEAD counts as drift too" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      tmp = Path.join(System.tmp_dir!(), "rfp_drift_detached_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      {_, 0} = System.cmd("git", ["init", "-b", "feature/001-s"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "seed\n")
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], cd: tmp)

      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "seed"],
        cd: tmp
      )

      on_exit(fn -> File.rm_rf(tmp) end)
      {_, 0} = System.cmd("git", ["checkout", "--detach", "HEAD"], cd: tmp)

      worktree = %SpeckitOrchestrator.Worktree{
        path: tmp,
        branch: "feature/001-s",
        repo: tmp,
        feature_id: "001"
      }

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :clarify}, context(%{worktree: worktree}))

      assert update.last_outcome == :error
      assert %{branch_drift: %{expected: "feature/001-s", observed: {:detached, _sha}}} =
               update.last_signals
    end

    test "a session that stayed on the expected branch is unaffected" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      tmp = Path.join(System.tmp_dir!(), "rfp_no_drift_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init", "-b", "feature/001-s"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      worktree = %SpeckitOrchestrator.Worktree{
        path: tmp,
        branch: "feature/001-s",
        repo: tmp,
        feature_id: "001"
      }

      assert {:ok, update} =
               RunFeaturePhase.run(%{phase: :clarify}, context(%{worktree: worktree}))

      refute Map.has_key?(update.last_signals, :branch_drift)
      assert update.last_outcome == :ok
    end
  end
end
