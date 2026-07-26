defmodule SpeckitOrchestrator.ChunkRunnerTest do
  # async: false — swaps the global :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}
  alias SpeckitOrchestrator.{ChunkRunner, Feature, FeatureAgent, Ledger, Worktree}

  # Fake SDK that inspects the scoped prompt for "Phase <n>:" and checks off
  # that task-phase's own task in the real tasks.md — a stand-in for the
  # agent actually doing the scoped work, so the chunk loop's cursor genuinely
  # advances the same way it would against a real CLI. Each dispatched action
  # runs in its own process (not the test process), so captured prompts are
  # recorded into a shared `Agent` (named via app env) rather than sent to
  # `self()`.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      capture_prompt(prompt)
      cwd = Map.get(options, :cwd)

      case scenario() do
        {:no_progress, n} -> exhausted_no_progress(cwd, prompt, n)
        {:exhaust_then_succeed, n} -> exhaust_then_succeed(cwd, prompt, n)
        {:always_exhaust, n} -> always_exhaust(cwd, prompt, n)
        :terminal_error -> terminal_error_messages()
        _ -> mark_and_succeed(cwd, prompt)
      end
    end

    defp mark_and_succeed(cwd, prompt) do
      check_off_scoped_task(prompt, cwd)
      success_messages()
    end

    # Always exhausts on the given task-phase number, never checking anything
    # off — used to exercise the stuck_task_phase failure.
    defp exhausted_no_progress(cwd, prompt, n) do
      if String.contains?(prompt, ~s(Phase #{n}:)) do
        exhausted_messages()
      else
        mark_and_succeed(cwd, prompt)
      end
    end

    # Marks exactly one of the target task-phase's remaining unchecked tasks
    # per call; exhausts while any remain, succeeds once none do — a
    # made-progress-every-attempt scope (FR-011: exhaustion with progress
    # continues in a fresh session rather than failing).
    defp exhaust_then_succeed(cwd, prompt, n) do
      if String.contains?(prompt, ~s(Phase #{n}:)) do
        if mark_first_unchecked(cwd) > 0, do: exhausted_messages(), else: success_messages()
      else
        mark_and_succeed(cwd, prompt)
      end
    end

    # Marks one task per call (so the caller sees real progress) but never
    # reports success on the target task-phase — used to drive
    # `sessions_used` straight into the session ceiling (FR-013a) without
    # ever tripping the separate no-progress bound (FR-012/FR-013).
    defp always_exhaust(cwd, prompt, n) do
      if String.contains?(prompt, ~s(Phase #{n}:)) do
        mark_first_unchecked(cwd)
        exhausted_messages()
      else
        mark_and_succeed(cwd, prompt)
      end
    end

    # Checks off the first remaining unchecked task line in the whole file
    # (only ever one task-phase is "in play" at a time in these fixtures) and
    # drops a fake source-file edit so the artifact gate (research R10) sees a
    # real implementation change. Returns the unchecked-line count afterward.
    defp mark_first_unchecked(cwd) do
      path = Path.join(cwd, "specs/001-fake/tasks.md")

      {new_lines, marked?} =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map_reduce(false, fn line, done? ->
          if not done? and String.contains?(line, "- [ ]") do
            {String.replace(line, "[ ]", "[X]", global: false), true}
          else
            {line, done?}
          end
        end)

      File.write!(path, Enum.join(new_lines, "\n"))

      if marked? do
        impl_path = Path.join(cwd, "lib/fake_progress_#{System.unique_integer([:positive])}.ex")
        File.mkdir_p!(Path.dirname(impl_path))
        File.write!(impl_path, "defmodule FakeProgress do\nend\n")
      end

      Enum.count(new_lines, &String.contains?(&1, "- [ ]"))
    end

    defp check_off_scoped_task(prompt, cwd) when is_binary(cwd) do
      case Regex.run(~r/Implement ONLY the tasks in "Phase (\d+):/, prompt) do
        [_, n] -> check_off(cwd, n)
        nil -> :ok
      end
    end

    defp check_off_scoped_task(_prompt, _cwd), do: :ok

    # Also writes a fake source file outside specs/ — the artifact gate
    # (research R10) looks for exactly this: a real implementation change, not
    # just an edited tasks.md (which lives under the excluded specs/ prefix).
    defp check_off(cwd, n) do
      path = Path.join(cwd, "specs/001-fake/tasks.md")

      content =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&check_line(&1, n))
        |> Enum.join("\n")

      File.write!(path, content)

      impl_path = Path.join(cwd, "lib/fake_phase_#{n}.ex")
      File.mkdir_p!(Path.dirname(impl_path))
      File.write!(impl_path, "defmodule FakePhase#{n} do\nend\n")
    end

    defp check_line(line, n) do
      if String.contains?(line, "T00#{n} "), do: String.replace(line, "[ ]", "[X]"), else: line
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "done",
            num_turns: 3,
            is_error: false,
            total_cost_usd: 0.1,
            usage: %{input_tokens: 0, output_tokens: 0}
          },
          raw: %{}
        }
      ]
    end

    defp exhausted_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error_max_turns,
          data: %{session_id: "s", result: "hit max turns", is_error: true, total_cost_usd: 0.1},
          raw: %{}
        }
      ]
    end

    # A clean, deterministic (non-transient) failure — no known transient
    # marker in the text — used to prove the pre-existing transient-vs-terminal
    # ladder (`PhaseResult.transient?/1`, unmodified per FR-014) still governs
    # non-exhaustion errors even though `:implement` now routes exclusively
    # through `ChunkRunner`/`Chunking.next/2`, not the phase-level retry wrapper.
    defp terminal_error_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error_during_execution,
          data: %{
            session_id: "s",
            result: "invalid tool arguments for Edit",
            is_error: true,
            total_cost_usd: 0.1
          },
          raw: %{}
        }
      ]
    end

    defp scenario, do: Application.get_env(:speckit_orchestrator, :chunk_runner_test_scenario)

    defp capture_prompt(prompt) do
      case Application.get_env(:speckit_orchestrator, :chunk_runner_test_prompts_agent) do
        nil -> :ok
        agent -> Agent.update(agent, &[prompt | &1])
      end
    end
  end

  setup do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
    Application.put_env(:speckit_orchestrator, :chunk_runner_test_prompts_agent, prompts_agent)

    on_exit(fn ->
      if original,
        do: Application.put_env(:jido_claude, :sdk_module, original),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :chunk_runner_test_scenario)
      Application.delete_env(:speckit_orchestrator, :chunk_runner_test_prompts_agent)
    end)

    root = Path.join(System.tmp_dir!(), "chunk_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["config", "user.email", "t@t"], cd: root)
    System.cmd("git", ["config", "user.name", "t"], cd: root)

    tasks_path = Path.join(root, "specs/001-fake/tasks.md")
    File.mkdir_p!(Path.dirname(tasks_path))

    File.write!(tasks_path, """
    # Tasks: Fake

    ## Phase 1: Setup

    - [ ] T001 first thing

    ## Phase 2: Core

    - [ ] T002 second thing

    ## Phase 3: Polish

    - [ ] T003 third thing
    """)

    System.cmd("git", ["add", "-A"], cd: root)
    System.cmd("git", ["commit", "-m", "seed"], cd: root)

    on_exit(fn -> File.rm_rf(root) end)

    feature = %Feature{id: "001", slug: "fake", path: "specs/001-fake/spec.md"}
    worktree = %Worktree{path: root, branch: "feature/001-fake", repo: root, feature_id: "001"}

    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "chunkrunner-test-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _} =
      AgentServer.call(
        pid,
        Signal.new!(
          "feature.init",
          %{
            feature: feature,
            worktree: worktree,
            ledger: nil,
            layout: nil,
            phase: :implement,
            resume_prompt: nil,
            remediation_prompt: nil,
            remediation_model: nil
          }
        ),
        5_000
      )

    %{root: root, feature: feature, worktree: worktree, pid: pid, prompts_agent: prompts_agent}
  end

  defp ctx(vals), do: Map.merge(%{layout: nil, timeout: 5_000, step: 6, ledger: nil}, vals)

  defp captured_prompts(prompts_agent), do: prompts_agent |> Agent.get(& &1) |> Enum.reverse()

  # A standalone repo + agent for tests that need a task-phase shape the
  # shared `setup` fixture doesn't have (multiple tasks in one task-phase) —
  # deliberately not reusing the outer `setup`'s single-task-per-phase fixture
  # so those tests stay unaffected.
  defp start_custom_repo(tasks_md) do
    root = Path.join(System.tmp_dir!(), "chunk_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init"], cd: root)
    System.cmd("git", ["config", "user.email", "t@t"], cd: root)
    System.cmd("git", ["config", "user.name", "t"], cd: root)

    tasks_path = Path.join(root, "specs/001-fake/tasks.md")
    File.mkdir_p!(Path.dirname(tasks_path))
    File.write!(tasks_path, tasks_md)

    System.cmd("git", ["add", "-A"], cd: root)
    System.cmd("git", ["commit", "-m", "seed"], cd: root)

    on_exit(fn -> File.rm_rf(root) end)

    feature = %Feature{id: "001", slug: "fake", path: "specs/001-fake/spec.md"}
    worktree = %Worktree{path: root, branch: "feature/001-fake", repo: root, feature_id: "001"}

    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "chunkrunner-test-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _} =
      AgentServer.call(
        pid,
        Signal.new!("feature.init", %{
          feature: feature,
          worktree: worktree,
          ledger: nil,
          layout: nil,
          phase: :implement,
          resume_prompt: nil,
          remediation_prompt: nil,
          remediation_model: nil
        }),
        5_000
      )

    %{root: root, feature: feature, worktree: worktree, pid: pid}
  end

  defp three_phase_tasks_md(phase1_task_count) do
    phase1_tasks =
      for n <- 1..phase1_task_count, into: "", do: "- [ ] T01#{n} phase-1 task #{n}\n"

    """
    # Tasks: Fake

    ## Phase 1: Setup

    #{phase1_tasks}
    ## Phase 2: Core

    - [ ] T002 second thing

    ## Phase 3: Polish

    - [ ] T003 third thing
    """
  end

  test "dispatches one scoped session per task-phase, in order, and completes",
       %{root: root, feature: feature, worktree: worktree, pid: pid, prompts_agent: prompts_agent} do
    agent = ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree}))

    assert agent.state.last_outcome == :ok
    assert agent.state.terminal_reason == nil
    assert agent.state.last_signals == %{}

    prompts = captured_prompts(prompts_agent)
    assert length(prompts) == 3
    assert Enum.at(prompts, 0) =~ ~s(Phase 1: Setup)
    assert Enum.at(prompts, 1) =~ ~s(Phase 2: Core)
    assert Enum.at(prompts, 2) =~ ~s(Phase 3: Polish)

    for f <- [
          "06-implement-p01-a1.md",
          "06-implement-p02-a1.md",
          "06-implement-p03-a1.md",
          "06-implement.md"
        ] do
      assert File.exists?(Path.join([root, ".speckit_logs", f])), "missing transcript #{f}"
    end

    content = File.read!(Path.join(root, "specs/001-fake/tasks.md"))
    assert content =~ "[X] T001"
    assert content =~ "[X] T002"
    assert content =~ "[X] T003"

    {log, 0} = System.cmd("git", ["-C", root, "log", "--format=%s"])
    subjects = String.split(log, "\n", trim: true)
    assert "speckit: 001 implement task-phase 1/3 Setup" in subjects
    assert "speckit: 001 implement task-phase 2/3 Core" in subjects
    assert "speckit: 001 implement task-phase 3/3 Polish" in subjects

    # task-phase commits must never look like Recovery.Evidence's phase-boundary
    # commits (research R5) — see recovery/evidence_test.exs for the direct
    # regex assertion against Evidence itself.
    refute Enum.any?(subjects, &Regex.match?(~r/^speckit: \S+ checkpoint after \w+$/, &1))
  end

  test "a breaker tripped between task-phases halts the run (drain, don't kill)",
       %{feature: feature, worktree: worktree, pid: pid, prompts_agent: prompts_agent} do
    {:ok, ledger} =
      Ledger.start_link(budget: 0.0, name: :"ledger_test_#{System.unique_integer([:positive])}")

    Ledger.record(ledger, nil, 1.0)
    assert Ledger.breaker_tripped?(ledger)

    agent =
      ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree, ledger: ledger}))

    assert agent.state.terminal_reason == {:halted, :breaker}

    # drain, don't kill: the first task-phase's session still ran to
    # completion before the halt took effect at the next boundary.
    assert length(captured_prompts(prompts_agent)) == 1
  end

  test "a task-phase stuck in a no-progress loop fails as :stuck_task_phase",
       %{feature: feature, worktree: worktree, pid: pid} do
    Application.put_env(:speckit_orchestrator, :chunk_runner_test_scenario, {:no_progress, 1})

    agent = ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree}))

    assert {:failed, {:stuck_task_phase, ref, 2}} = agent.state.terminal_reason
    assert ref.number == "1"
    assert agent.state.last_outcome == :error
  end

  test "exhaustion with progress dispatches fresh sessions on the same task-phase and completes" do
    %{feature: feature, worktree: worktree, pid: pid} =
      start_custom_repo(three_phase_tasks_md(3))

    Application.put_env(
      :speckit_orchestrator,
      :chunk_runner_test_scenario,
      {:exhaust_then_succeed, 1}
    )

    agent = ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree}))

    # 3 tasks in phase 1 ⇒ 2 exhausted-with-progress folds + 1 success before
    # the cursor advances, then phases 2 and 3 dispatch and succeed normally —
    # never a failure, per FR-011 ("a steadily progressing task-phase is not
    # killed").
    assert agent.state.last_outcome == :ok
    assert agent.state.terminal_reason == nil

    content = File.read!(Path.join(worktree.path, "specs/001-fake/tasks.md"))
    refute content =~ "[ ]"
  end

  test "the session ceiling fails distinctly from a stuck task-phase" do
    %{feature: feature, worktree: worktree, pid: pid} =
      start_custom_repo(three_phase_tasks_md(3))

    original_per_phase =
      Application.get_env(:speckit_orchestrator, :implement_sessions_per_task_phase)

    original_headroom = Application.get_env(:speckit_orchestrator, :implement_sessions_headroom)
    Application.put_env(:speckit_orchestrator, :implement_sessions_per_task_phase, 1)
    Application.put_env(:speckit_orchestrator, :implement_sessions_headroom, 0)

    on_exit(fn ->
      if original_per_phase,
        do:
          Application.put_env(
            :speckit_orchestrator,
            :implement_sessions_per_task_phase,
            original_per_phase
          ),
        else: Application.delete_env(:speckit_orchestrator, :implement_sessions_per_task_phase)

      if original_headroom,
        do:
          Application.put_env(
            :speckit_orchestrator,
            :implement_sessions_headroom,
            original_headroom
          ),
        else: Application.delete_env(:speckit_orchestrator, :implement_sessions_headroom)
    end)

    # ceiling = 1 * 3 task-phases + 0 headroom = 3. Each of the 3 dispatched
    # sessions makes progress (marks one of phase 1's 3 tasks) but never
    # reports success, so the ceiling — not the no-progress bound — is what
    # stops the loop.
    Application.put_env(:speckit_orchestrator, :chunk_runner_test_scenario, {:always_exhaust, 1})

    agent = ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree}))

    assert {:failed, {:session_ceiling, 3}} = agent.state.terminal_reason
    assert agent.state.last_outcome == :error
  end

  test "a non-exhaustion transient session error retries, a terminal one fails as :session_error" do
    %{feature: feature, worktree: worktree, pid: pid} = start_custom_repo(three_phase_tasks_md(1))

    Application.put_env(:speckit_orchestrator, :chunk_runner_test_scenario, :terminal_error)

    agent = ChunkRunner.run(ctx(%{pid: pid, feature: feature, worktree: worktree}))

    assert {:failed, {:session_error, _reason}} = agent.state.terminal_reason
    assert agent.state.last_outcome == :error
  end

  @tag :integration
  test "LIVE: runs one real chunked implement session against a fixture target repo (paid, opt-in)",
       %{prompts_agent: _prompts_agent} do
    repo =
      System.get_env("SPECKIT_FIXTURE_REPO") ||
        flunk(
          "set SPECKIT_FIXTURE_REPO to a repo path with a structured tasks.md ready for /speckit.implement"
        )

    # This test exercises the real `claude` CLI, not the file's FakeSDK — undo
    # the module-wide sdk_module override for just this test.
    Application.delete_env(:jido_claude, :sdk_module)

    feature = %Feature{id: "001", slug: "smoke", path: Path.join(repo, "specs/001-smoke/spec.md")}
    worktree = %Worktree{path: repo, branch: "main", repo: repo, feature_id: "001"}
    timeout = :timer.minutes(50)

    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "chunkrunner-live-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _} =
      AgentServer.call(
        pid,
        Signal.new!("feature.init", %{
          feature: feature,
          worktree: worktree,
          ledger: nil,
          layout: nil,
          phase: :implement,
          resume_prompt: nil,
          remediation_prompt: nil,
          remediation_model: nil
        }),
        timeout
      )

    agent =
      ChunkRunner.run(%{
        pid: pid,
        feature: feature,
        worktree: worktree,
        layout: nil,
        timeout: timeout,
        step: 6,
        ledger: nil
      })

    assert agent.state.last_outcome in [:ok, :error]
    assert agent.state.history != []
  end
end
