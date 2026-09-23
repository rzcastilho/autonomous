defmodule SpeckitOrchestrator.ResumeRunTest do
  # async: false — real-named Coordinator/Ledger + global :transcript_root app
  # env, plus the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{
    Coordinator,
    Feature,
    Layout,
    Ledger,
    RepoIdentity,
    RunContext,
    Worktree
  }

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "rr_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    stop_coordinator()

    on_exit(fn ->
      stop_coordinator()
      File.rm_rf(root)
      if prev, do: Application.put_env(:speckit_orchestrator, :transcript_root, prev)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)
    end)

    %{root: root}
  end

  defp stop_coordinator do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || String.to_integer(id),
      slug: "f#{id}",
      path: "#{id}.md"
    }

  defp capturing_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp put_repo(repo) do
    prev = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, repo)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:speckit_orchestrator, :repo, prev),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)
  end

  # ---- store fixtures (018) --------------------------------------------------

  defp open_run(repo, layout, features, context) do
    repo_id = RepoIdentity.partition(repo)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features:
          Enum.map(
            features,
            &%{
              feature_id: &1.id,
              slug: &1.slug,
              path: &1.path,
              number: &1.number,
              group: &1.group,
              created_at: &1.created_at
            }
          ),
        settings: RunContext.to_map(context),
        scope: :ad_hoc,
        layout: layout
      })

    {repo_id, run_id}
  end

  defp minimal_attempt(feature_id, phase) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: 1,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: nil,
      error: nil
    }
  end

  # Builds a real git repo (no `%Layout{}` durable evidence needed anymore —
  # the store carries it), commits a boundary proving `id` finished, and
  # points `Config.repo/0` at it. Returns the `%Layout{}` for `open_run/4`.
  defp done_layout(id) do
    repo = Path.join(System.tmp_dir!(), "rr_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "Tester"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    git!(repo, ["remote", "add", "origin", "https://example.com/resume-run.git"])
    git!(repo, ["checkout", "-q", "-b", "feature/#{id}-f#{id}"])
    File.write!(Path.join(repo, "work.txt"), "done\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "speckit: #{id} checkpoint after converge"])
    git!(repo, ["checkout", "-q", "main"])
    on_exit(fn -> File.rm_rf(repo) end)

    put_repo(repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)
    layout
  end

  # A non-PR (:ad_hoc) done-signal for an already-open run — a converge
  # phase attempt whose transcript carries the ready marker, still recorded
  # `:pending` (`store_recorded_status/1` derives `:running` from the
  # attempt's presence alone).
  defp seed_converge_marker(run_key, feature_id) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, :converge),
        transcript: "Tests green.\n\n## CONVERGE: READY\n"
      })
  end

  # ---- mixed-state resume (T022) --------------------------------------------

  test "resume_run/1 does not re-run :done, releases the rest strictly in ascending numeric order" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    features = [feat("001"), feat("002"), feat("003"), feat("004")]
    context = %RunContext{budget_usd: 100.0}

    run_key =
      open_run(Application.get_env(:speckit_orchestrator, :repo), layout, features, context)

    seed_converge_marker(run_key, "001")

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_received {:started, "001", _}

    # 019: one feature runs at a time, in ascending numeric order — there is
    # no dependency fan-out anymore (`Release.next/3` rule 3/4), so "002"
    # alone releases first, then "003", then "004", strictly in sequence.
    assert_receive {:started, "002", n2}, 1_000
    refute_received {:started, "003", _}
    refute_received {:started, "004", _}
    n2.("002", :done, nil)

    assert_receive {:started, "003", n3}, 1_000
    refute_received {:started, "004", _}
    n3.("003", :done, nil)

    assert_receive {:started, "004", n4}, 1_000
    n4.("004", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002", "003", "004"]
  end

  # ---- fail-loud: missing/damaged run record (T023) --------------------------

  test "resume_run/1 with no run recorded returns {:error, :no_manifest} and starts no Coordinator" do
    assert {:error, :no_manifest} = SpeckitOrchestrator.resume_run()
    assert Process.whereis(@coordinator) == nil
  end

  # 018: a damaged row (`Records.decode/2`'s shape-mismatch branch) can no
  # longer be produced by a legitimate write — Mnesia enforces record arity
  # against the table's declared attributes at write time, unlike a plain
  # JSON file. That decode branch is covered directly at the unit level in
  # `test/speckit_orchestrator/store/records_test.exs`; nothing end-to-end
  # can reach it anymore.

  # ---- active-run guard (T024) -----------------------------------------------

  test "a live unfinished Coordinator already running refuses resume_run/1 without :force, and :force proceeds" do
    layout = done_layout("999-guard")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    open_run(repo, layout, [feat("001")], %RunContext{budget_usd: 100.0})

    # Simulate an active, unfinished run: a runner that never notifies.
    {:ok, blocking_pid} =
      Coordinator.start_link(
        features: [feat("999")],
        runner: fn _feature, _notify -> :ok end,
        name: @coordinator
      )

    assert {:error, {:active_run, ^blocking_pid}} = SpeckitOrchestrator.resume_run()
    # not clobbered — still alive, still the same pid.
    assert Process.alive?(blocking_pid)
    assert Process.whereis(@coordinator) == blocking_pid

    me = self()

    assert {:ok, new_pid} =
             SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me, force: true)

    on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)
    assert new_pid != blocking_pid
    refute Process.alive?(blocking_pid)
  end

  # ---- 026 US2: a worker-only active run guards resume_run/1 too ------------

  # Mirrors supersession_drain_test.exs's stub worker — polls the same
  # boundary predicate a real phase/chunk/remediation site would, never
  # killed from outside.
  defp drain_aware_worker(me) do
    send(me, :worker_running)
    wait_for_worker_drain(me)
  end

  defp wait_for_worker_drain(me) do
    if SpeckitOrchestrator.Workers.drain_requested?() do
      send(me, :worker_drained)
    else
      Process.sleep(20)
      wait_for_worker_drain(me)
    end
  end

  test "resume_run/1 refuses with {:error, {:active_run, worker_pid}} when only a worker is alive (no Coordinator), and starts no work (AS1, FR-005, SC-004)" do
    layout = done_layout("998-worker-guard")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key = open_run(repo, layout, [feat("998")], %RunContext{budget_usd: 100.0})

    me = self()
    {:ok, worker_pid} = SpeckitOrchestrator.Workers.spawn(run_key, "998", fn -> drain_aware_worker(me) end)
    assert_receive :worker_running, 2_000
    refute Process.whereis(@coordinator)

    assert {:error, {:active_run, ^worker_pid}} =
             SpeckitOrchestrator.resume_run(runner: capturing_runner(me))

    refute_received {:started, _, _}
    assert Process.alive?(worker_pid)

    Process.exit(worker_pid, :kill)
  end

  test "resume_run/1 :force drains the worker first, then proceeds (AS3, FR-006)" do
    layout = done_layout("997-worker-force")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key = open_run(repo, layout, [feat("997")], %RunContext{budget_usd: 100.0})

    me = self()
    {:ok, worker_pid} = SpeckitOrchestrator.Workers.spawn(run_key, "997", fn -> drain_aware_worker(me) end)
    assert_receive :worker_running, 2_000

    assert {:ok, new_pid} =
             SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me, force: true)

    on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)

    # resume_run/1's guard drains synchronously before anything else runs, so
    # by the time it returns the worker has already observed the request and
    # exited on its own — never killed from outside.
    assert_received :worker_drained
    refute Process.alive?(worker_pid)
    assert_receive {:started, "997", _notify}, 1_000
  end

  # ---- recorded context reapply, not live Config (T025) ----------------------
  #
  # 019 retired `:max_concurrency` (and the `Coordinator` `cap`/`set_cap/2`
  # it drove) — one-at-a-time release is now structural (`Release.next/3`
  # rule 3), not a configured cap, so there is no "recorded cap wins over a
  # differing live Config cap" scenario left to prove; sequential release is
  # unconditionally exercised by every test in this file (e.g. immediately
  # above) and by `coordinator_test.exs`/`release_test.exs` directly. What
  # remains meaningful here is that the run's other recorded settings
  # (`budget_usd`/`plan_stack`/`pr_base`/`pr_remote`) come from the STORE, not
  # live `Config` — `run_context_test.exs`/`resume_test.exs` already cover
  # `RunContext.merge/2`'s precedence directly; this proves it end-to-end
  # through `resume_run/1` specifically.
  test "the resumed run re-executes under the run's recorded budget_usd/plan_stack/pr_base/pr_remote, not live Config" do
    layout = done_layout("999-cap")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    context = %RunContext{
      budget_usd: 100.0,
      plan_stack: ["research", "plan"],
      pr_base: "develop",
      pr_remote: "upstream"
    }

    run_key = open_run(repo, layout, [feat("001"), feat("002"), feat("003")], context)

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:started, first_id, n1}, 1_000
    refute_received {:started, _, _}

    n1.(first_id, :done, nil)
    assert_receive {:started, second_id, n2}, 1_000
    refute_received {:started, _, _}
    n2.(second_id, :done, nil)

    assert_receive {:started, third_id, n3}, 1_000
    n3.(third_id, :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002", "003"]

    assert {:ok, detail} = Store.run(run_key)
    assert detail.settings["budget_usd"] == 100.0
    assert detail.settings["plan_stack"] == ["research", "plan"]
    assert detail.settings["pr_base"] == "develop"
    assert detail.settings["pr_remote"] == "upstream"
  end

  # ---- detect-only (T026) ----------------------------------------------------

  test "resumable_run/0 reports the reconciled summary and starts no Coordinator process" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key =
      open_run(repo, layout, [feat("001"), feat("002")], %RunContext{budget_usd: 100.0})

    seed_converge_marker(run_key, "001")

    # `002` has no durable evidence at all (no git branch/checkpoint), so it
    # reconciles to :pending — same "never actually progressed" conclusion
    # the pre-014 crash-recovery mapping reached, now derived from
    # repository evidence instead of assumed from a status string alone.
    assert {:ok, summary} = SpeckitOrchestrator.resumable_run()
    assert summary.statuses == %{"001" => :done, "002" => :pending}
    assert Process.whereis(@coordinator) == nil
  end

  test "resumable_run/0 returns :none when every feature is terminal/diverted" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key =
      open_run(repo, layout, [feat("001"), feat("002")], %RunContext{budget_usd: 100.0})

    :ok = Writer.record_feature_terminal(run_key, "001", :done, :test_fixture, [])
    :ok = Writer.record_feature_terminal(run_key, "002", :escalated, :test_fixture, [])

    assert :none = SpeckitOrchestrator.resumable_run()
    assert Process.whereis(@coordinator) == nil
  end

  test "resumable_run/0 returns {:error, :no_manifest} when nothing is recorded" do
    assert {:error, :no_manifest} = SpeckitOrchestrator.resumable_run()
  end

  # ---- cost continuity across a crash (T036-T037, US3, FR-012/013) -----------

  test "resume_run/1 with recorded spend >= budget trips the breaker and releases zero new features" do
    prev_budget = Ledger.snapshot(Ledger).budget
    on_exit(fn -> Ledger.set_budget(Ledger, prev_budget) end)

    :ok = Ledger.set_budget(Ledger, 5.0)

    layout = done_layout("999-breaker")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key =
      open_run(repo, layout, [feat("001")], %RunContext{budget_usd: 5.0})

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("001", :specify),
        cost: %{amount_usd: 5.0, kind: :estimate}
      })

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Ledger.breaker_tripped?(Ledger)
    refute_received {:started, _, _}

    assert_receive {:run_complete, report}, 1_000
    assert report.done == []

    # invariant: committed < budget + max single reservation still holds — no
    # reservation is granted once committed already fills the (restored) budget.
    assert Ledger.reserve(Ledger, 1) == {:error, :budget_exceeded}
  end

  test "resume_run/1 restores committed spend from the run's cost-entry roll-up, not zero" do
    prev_budget = Ledger.snapshot(Ledger).budget
    on_exit(fn -> Ledger.set_budget(Ledger, prev_budget) end)

    # T040: `restore_ledger/1` restores an ABSOLUTE figure — the run's own
    # cost-entry roll-up, not a delta onto whatever this (shared, per-test-file)
    # `Ledger` process already committed from an earlier test — so the
    # target is the roll-up itself, and `Ledger.restore/2`'s own
    # `max(committed, recorded)` monotonicity is what "not zero" asserts.
    target = 7.0
    :ok = Ledger.set_budget(Ledger, target + 100.0)

    layout = done_layout("001-spend")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key =
      open_run(repo, layout, [feat("001")], %RunContext{budget_usd: target + 100.0})

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("001", :specify),
        cost: %{amount_usd: 7.0, kind: :estimate}
      })

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Ledger.spent(Ledger) >= target

    assert_receive {:started, "001", n1}, 1_000
    n1.("001", :done, nil)
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001"]
  end

  # ---- 025 US1: whole-run resume dispatches at the checkpoint, not the trail

  # Reports a critical finding for `/speckit.analyze` (so an illegitimate
  # rewind to `:analyze` is loudly distinguishable from the correct resume at
  # `:implement` — `:escalated` vs `:done`), and otherwise drives the chunked
  # `:implement` loop like `chunk_runner_test.exs`'s FakeSDK: checks off the
  # scoped task-phase's own task and writes a real source file so the
  # artifact gate sees genuine implementation changes. Dispatching an
  # already-complete task-phase is a hard bug, reported as a terminal
  # (non-transient) session error rather than silently succeeding.
  defmodule CheckpointFirstFakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      cond do
        String.contains?(prompt, "/speckit.analyze") ->
          critical_finding()

        true ->
          case Regex.run(~r/Implement ONLY the tasks in "Phase (\d+):/, prompt) do
            [_, n] ->
              if n in illegal_phases() do
                error_messages("illegal redispatch of already-complete task-phase #{n}")
              else
                check_off_and_succeed(Map.get(options, :cwd), n)
              end

            nil ->
              success_messages()
          end
      end
    end

    defp illegal_phases,
      do: Application.get_env(:speckit_orchestrator, :checkpoint_first_illegal_phases, [])

    defp check_off_and_succeed(cwd, n) when is_binary(cwd) do
      case cwd |> Path.join("specs/**/tasks.md") |> Path.wildcard() |> List.first() do
        nil -> :ok
        path -> check_off(path, cwd, n)
      end

      success_messages()
    end

    defp check_off_and_succeed(_cwd, _n), do: success_messages()

    defp check_off(path, cwd, n) do
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

    defp critical_finding do
      text = ~s({"summary":"should never run","findings":[{"severity":"critical","title":"bad"}]})

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
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
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

    defp error_messages(reason) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{session_id: "s", error: reason, is_error: true, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end
  end

  defp checkpoint_first_git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # A real, scaffolded repo (`.specify`/`.claude`, required by `Worktree.create`
  # for a genuine — not faked — dispatch) with a structured, multi-task-phase
  # `tasks.md`, mirroring `resume_test.exs`'s "chunked implement resume"
  # fixtures. `complete` marks which task-phase numbers start pre-checked.
  defp checkpoint_first_chunked_repo(feature, phases, complete) do
    repo = Path.join(System.tmp_dir!(), "rr_ckpt_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")

    spec_dir = Path.join(repo, "specs/#{Feature.spec_id(feature)}-#{feature.slug}")
    File.mkdir_p!(spec_dir)

    body =
      Enum.map_join(phases, "\n", fn {n, title} ->
        mark = if n in complete, do: "X", else: " "
        "## Phase #{n}: #{title}\n\n- [#{mark}] T00#{n} #{title} task\n"
      end)

    File.write!(Path.join(spec_dir, "tasks.md"), "# Tasks\n\n" <> body)

    checkpoint_first_git!(repo, ["init", "-q", "-b", "main"])
    checkpoint_first_git!(repo, ["config", "user.email", "t@e.com"])
    checkpoint_first_git!(repo, ["config", "user.name", "T"])
    checkpoint_first_git!(repo, ["remote", "add", "origin", "git@example.com:test/ckpt.git"])
    checkpoint_first_git!(repo, ["add", "-A"])
    checkpoint_first_git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  describe "025 US1: whole-run resume dispatches at the checkpoint, not the trail" do
    setup do
      prev_sdk = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, CheckpointFirstFakeSDK)

      on_exit(fn ->
        if prev_sdk,
          do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
          else: Application.delete_env(:jido_claude, :sdk_module)

        Application.delete_env(:speckit_orchestrator, :checkpoint_first_illegal_phases)
      end)

      :ok
    end

    # SC-001 (contracts/reconcile-checkpoint-first.md §4 worked case 1): a
    # checkpoint naming `:implement` (task-phase 3) beside a trail whose
    # newest boundary commit is `:tasks` — two phases behind. Before 025,
    # `resume_run/1`'s dispatch derived the resume phase from the trail alone
    # (`phase_after(:tasks) == :analyze`), rewinding a feature interrupted
    # mid-implement and re-running `:analyze`. `CheckpointFirstFakeSDK` reports
    # a critical finding for any `:analyze` dispatch, so a regression surfaces
    # as `report.escalated == [id]` instead of `report.done == [id]`.
    test "a feature interrupted mid-implement resumes at :implement, not :analyze (the defect)" do
      # A numeric id, like every real feature id (`Backlog`/`SingleSpec`) —
      # `Feature.spec_id/1`'s auto-allocation fallback (`ensure_spec_number/3`)
      # only fires for an UNALLOCATED feature; recording the spec_number up
      # front (mirrors production's `run_fresh/6` invariant, feature 022)
      # keeps the worktree path/branch this fixture creates and the one
      # `resume_run/1`'s real dispatch resolves byte-identical.
      id = "#{System.unique_integer([:positive, :monotonic])}"
      n = String.to_integer(id)
      feature = %{feat(id, n) | spec_number: n}

      phases = [
        {"1", "Setup"},
        {"2", "Core"},
        {"3", "Widgets"},
        {"4", "Gadgets"},
        {"5", "Polish"}
      ]

      repo = checkpoint_first_chunked_repo(feature, phases, ["1", "2"])
      Application.put_env(:speckit_orchestrator, :checkpoint_first_illegal_phases, ["1", "2"])
      put_repo(repo)

      {:ok, segment} = RepoIdentity.resolve(repo)
      {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

      {:ok, wt} = Worktree.create(feature, repo: repo, worktree_root: layout.worktree_root)

      # The trail: a single boundary commit proving only :tasks completed —
      # two phases behind the checkpoint's :analyze completed-through.
      checkpoint_first_git!(wt.path, [
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        "speckit: #{id} checkpoint after tasks"
      ])

      run_key = open_run(repo, layout, [feature], %RunContext{budget_usd: 100.0})
      :ok = Writer.record_spec_number(run_key, id, n)

      :ok =
        Writer.record_checkpoint(run_key, id, %{
          phase: :implement,
          last_completed_phase: :analyze,
          status: :in_progress,
          reason: nil,
          session_id: "s1",
          implement_chunk: %{
            ordinal: 3,
            number: "3",
            title: "Widgets",
            total: 5,
            sessions_used: 0,
            ceiling: 14,
            scope: :task_phase
          }
        })

      me = self()

      fake_publisher = fn feature, _base -> {:ok, "https://example/pr/#{feature.id}"} end

      assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me, publisher: fake_publisher)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.done == [id]
      assert report.escalated == []

      {:ok, detail} = Store.run(run_key)
      phases_seen = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> Enum.map(& &1.phase)

      # A resume-triggered rewind would re-run :analyze (and land on
      # :escalated, asserted above) instead of dispatching straight to the
      # chunked implement loop.
      refute :analyze in phases_seen
      assert :implement_chunk in phases_seen
    end
  end

  # ---- a never-started feature with no target scaffold (T027, integration) --

  @tag :integration
  test "a never-started feature whose target repo lacks the .specify/.claude scaffold fails loud without crashing the rest of the run" do
    id = "rr#{System.unique_integer([:positive, :monotonic])}"

    # The repo must keep a *resolvable identity* — `read_current_run/0`
    # locates the store's slot by `RepoIdentity.partition/1`. What this test
    # breaks is the thing it is actually about: the target repo is bare of
    # the committed `.specify/`/`.claude/` scaffold `Worktree.create`
    # asserts, so the feature fails loud (no checkpoint, no branch — a
    # never-released feature reconciles to plain `:pending` and dispatches
    # through `run_fresh/6`) while the run itself drains normally.
    repo = Path.join(System.tmp_dir!(), "rr_gone_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["remote", "add", "origin", "https://example.com/acme/gone-#{id}.git"])
    on_exit(fn -> File.rm_rf(repo) end)
    put_repo(repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "pkg"})

    open_run(repo, layout, [feat(id, 1)], %RunContext{budget_usd: 100.0})

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 5_000
    assert report.failed == [id]
  end
end
