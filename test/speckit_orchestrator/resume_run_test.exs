defmodule SpeckitOrchestrator.ResumeRunTest do
  # async: false — real-named Coordinator/Ledger + global :transcript_root app
  # env, plus the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, Ledger, RepoIdentity, RunContext}

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

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "f#{id}", path: "#{id}.md", prereqs: prereqs}

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
            &%{feature_id: &1.id, slug: &1.slug, path: &1.path, prereqs: &1.prereqs}
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

  test "resume_run/1 does not re-run :done, resumes :running, releases :pending in prereq order under cap" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    features = [feat("001"), feat("002", ["001"]), feat("003", ["002"]), feat("004", ["001"])]
    context = %RunContext{pr_workflow: false, max_concurrency: 2, budget_usd: 100.0}

    run_key =
      open_run(Application.get_env(:speckit_orchestrator, :repo), layout, features, context)

    seed_converge_marker(run_key, "001")

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_received {:started, "001", _}

    assert_receive {:started, "002", n2}, 1_000
    assert_receive {:started, "004", n4}, 1_000
    refute_received {:started, "003", _}

    n2.("002", :done, nil)
    n4.("004", :done, nil)

    assert_receive {:started, "003", n3}, 1_000
    n3.("003", :done, nil)

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

    open_run(repo, layout, [feat("001")], %RunContext{
      pr_workflow: false,
      max_concurrency: 1,
      budget_usd: 100.0
    })

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

  # ---- recorded context reapply, not live Config (T025) ----------------------

  test "the resumed run re-executes under the run's recorded max_concurrency, not live Config" do
    prev_cap = Application.get_env(:speckit_orchestrator, :max_concurrency)
    Application.put_env(:speckit_orchestrator, :max_concurrency, 5)

    on_exit(fn ->
      if prev_cap,
        do: Application.put_env(:speckit_orchestrator, :max_concurrency, prev_cap),
        else: Application.delete_env(:speckit_orchestrator, :max_concurrency)
    end)

    layout = done_layout("999-cap")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    context = %RunContext{
      pr_workflow: false,
      max_concurrency: 1,
      budget_usd: 100.0,
      plan_stack: ["research", "plan"],
      pr_base: "develop",
      pr_remote: "upstream"
    }

    open_run(repo, layout, [feat("001"), feat("002"), feat("003")], context)

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
  end

  # ---- detect-only (T026) ----------------------------------------------------

  test "resumable_run/0 reports the reconciled summary and starts no Coordinator process" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    repo = Application.get_env(:speckit_orchestrator, :repo)

    run_key =
      open_run(repo, layout, [feat("001"), feat("002", ["001"])], %RunContext{
        pr_workflow: false,
        max_concurrency: 2,
        budget_usd: 100.0
      })

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
      open_run(repo, layout, [feat("001"), feat("002")], %RunContext{
        pr_workflow: false,
        max_concurrency: 2,
        budget_usd: 100.0
      })

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
      open_run(repo, layout, [feat("001")], %RunContext{
        pr_workflow: false,
        max_concurrency: 1,
        budget_usd: 5.0
      })

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
      open_run(repo, layout, [feat("001")], %RunContext{
        pr_workflow: false,
        max_concurrency: 1,
        budget_usd: target + 100.0
      })

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

    open_run(repo, layout, [feat(id)], %RunContext{
      pr_workflow: false,
      max_concurrency: 1,
      budget_usd: 100.0
    })

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 5_000
    assert report.failed == [id]
  end
end
