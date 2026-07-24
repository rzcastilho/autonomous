defmodule SpeckitOrchestrator.ResumeRunTest do
  # async: false — real-named Coordinator/Ledger + global :transcript_root app
  # env (mirrors coordinator_test.exs / resume_test.exs conventions).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{
    Checkpoint,
    Config,
    Coordinator,
    Feature,
    Layout,
    Ledger,
    RepoIdentity,
    RunContext,
    RunManifest
  }

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "rr_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    # RunManifest now lives under Config.autonomous_root/0 (012, resolves I2),
    # not :transcript_root — isolate it too so this file's manifest state
    # never leaks across tests (globally shared :autonomous_root otherwise).
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

  defp write_manifest(overrides) do
    :ok =
      RunManifest.write(
        Map.merge(
          %{
            features: [],
            statuses: %{},
            context: %RunContext{pr_workflow: false, max_concurrency: 2, budget_usd: 100.0},
            spend: 1.0,
            updated_at: 1
          },
          overrides
        )
      )
  end

  # ---- 014-recovery-reconciliation: durable evidence for a recorded `:done`
  # feature -------------------------------------------------------------------
  #
  # resume_run/1 now reconciles against repository ground truth
  # (`Recovery.reconcile_run/2`) before dispatching, so a feature recorded
  # `:done` in these fixtures needs a real committed branch + converge marker
  # to corroborate — a bare `:done` status with zero durable evidence
  # reconciles to `{:conflict, :done_without_artifacts}` (US3), same as a real
  # crash-recovery run would. `resume_run/1`'s own preflight also requires a
  # real `origin` remote, so the fixture resolves a real repo-identity segment
  # and `%Layout{}` (mirrors `recovery_test.exs`'s `base_repo`/seed helpers) —
  # the converge marker is written under that layout's `transcript_root` and
  # the same `%Layout{}` is threaded into `write_manifest/1` so the persisted
  # manifest's segment/scope matches exactly what was written to disk.
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

  # Builds a real git repo + `%Layout{}`, commits a boundary + converge
  # marker for `id` proving it finished, and points `Config.repo/0` at it.
  # Returns the `%Layout{}` for `write_manifest/1`'s `:layout` override.
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

    dir = Path.join(layout.transcript_root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "07-converge.md"), "Tests green.\n\n## CONVERGE: READY\n")

    layout
  end

  # ---- mixed-state resume (T022) --------------------------------------------

  test "resume_run/1 does not re-run :done, resumes :running, releases :pending in prereq order under cap" do
    layout = done_layout("001")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"]), feat("003", ["002"]), feat("004", ["001"])],
      statuses: %{"001" => :done, "002" => :running, "003" => :pending, "004" => :pending},
      context: %RunContext{pr_workflow: false, max_concurrency: 2, budget_usd: 100.0},
      layout: layout
    })

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

  # ---- fail-loud: missing/corrupt manifest (T023) ---------------------------

  test "resume_run/1 with no manifest on disk returns {:error, :no_manifest} and starts no Coordinator" do
    assert {:error, :no_manifest} = SpeckitOrchestrator.resume_run()
    assert Process.whereis(@coordinator) == nil
  end

  test "resume_run/1 with a corrupt manifest returns {:error, :corrupt_manifest} and starts no Coordinator",
       %{
         root: root
       } do
    # Written to the current repo's segment-scoped slot — the path resume_run/1
    # actually reads (RunManifest partitions by repo identity).
    path = manifest_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not valid json{")

    assert {:error, :corrupt_manifest} = SpeckitOrchestrator.resume_run()
    assert Process.whereis(@coordinator) == nil
  end

  # Mirrors RunManifest's own segment resolution (Config.repo() → origin
  # segment, nil → the legacy flat bucket) so this file writes/reads the same
  # slot the module does, regardless of the ambient origin.
  defp manifest_path(root) do
    case RepoIdentity.resolve(Config.repo()) do
      {:ok, segment} -> Path.join([root, "transcripts", segment, "run.json"])
      {:error, _} -> Path.join([root, "transcripts", "run.json"])
    end
  end

  # ---- active-run guard (T024) -----------------------------------------------

  test "a live unfinished Coordinator already running refuses resume_run/1 without :force, and :force proceeds" do
    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :pending}
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

  test "the resumed run re-executes under the manifest's recorded max_concurrency, not live Config" do
    prev_cap = Application.get_env(:speckit_orchestrator, :max_concurrency)
    Application.put_env(:speckit_orchestrator, :max_concurrency, 5)

    on_exit(fn ->
      if prev_cap,
        do: Application.put_env(:speckit_orchestrator, :max_concurrency, prev_cap),
        else: Application.delete_env(:speckit_orchestrator, :max_concurrency)
    end)

    write_manifest(%{
      features: [feat("001"), feat("002"), feat("003")],
      statuses: %{"001" => :pending, "002" => :pending, "003" => :pending},
      context: %RunContext{
        pr_workflow: false,
        max_concurrency: 1,
        budget_usd: 100.0,
        plan_stack: ["research", "plan"],
        pr_base: "develop",
        pr_remote: "upstream"
      }
    })

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

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"])],
      statuses: %{"001" => :done, "002" => :running},
      layout: layout
    })

    # 014-recovery-reconciliation: resumable_run/0 now returns
    # Recovery.reconcile_run/2's reconciled picture (atom statuses), not the
    # raw manifest dump. `001` corroborates via the fixture's committed branch
    # + converge marker (US3 clause 3 — a recorded `:done` with zero durable
    # evidence would otherwise reconcile to a conflict). `002` has no
    # durable evidence at all (no git branch/checkpoint), so it reconciles to
    # :pending — same "never actually progressed" conclusion the pre-014
    # crash-recovery mapping reached, now derived from repository evidence
    # instead of assumed from the status string alone.
    assert {:ok, summary} = SpeckitOrchestrator.resumable_run()
    assert summary.statuses == %{"001" => :done, "002" => :pending}
    assert Process.whereis(@coordinator) == nil
  end

  test "resumable_run/0 returns :none when every feature is terminal/diverted" do
    write_manifest(%{
      features: [feat("001"), feat("002")],
      statuses: %{"001" => :done, "002" => :escalated}
    })

    assert :none = SpeckitOrchestrator.resumable_run()
    assert Process.whereis(@coordinator) == nil
  end

  test "resumable_run/0 returns {:error, :no_manifest} when the slot is absent" do
    assert {:error, :no_manifest} = SpeckitOrchestrator.resumable_run()
  end

  # ---- cost continuity across a crash (T036-T037, US3, FR-012/013) -----------

  test "resume_run/1 with recorded spend >= budget trips the breaker and releases zero new features" do
    prev_budget = Ledger.snapshot(Ledger).budget
    on_exit(fn -> Ledger.set_budget(Ledger, prev_budget) end)

    :ok = Ledger.set_budget(Ledger, 5.0)

    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :pending},
      spend: 5.0,
      context: %RunContext{pr_workflow: false, max_concurrency: 1, budget_usd: 5.0}
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

  test "resume_run/1 restores committed spend from the manifest's recorded figure, not zero" do
    prev_budget = Ledger.snapshot(Ledger).budget
    on_exit(fn -> Ledger.set_budget(Ledger, prev_budget) end)

    baseline = Ledger.spent(Ledger)
    target = baseline + 7.0
    :ok = Ledger.set_budget(Ledger, target + 100.0)

    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :pending},
      spend: target,
      context: %RunContext{pr_workflow: false, max_concurrency: 1, budget_usd: target + 100.0}
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

  # ---- checkpointed feature with a missing branch/worktree (T027, integration) --

  @tag :integration
  test "a checkpointed feature whose branch/worktree is missing fails loud without crashing the rest of the run",
       %{root: root} do
    id = "rr#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      Checkpoint.write(%{
        feature_id: id,
        last_phase: :plan,
        status: :in_progress,
        reason: nil,
        session_id: "s1"
      })

    on_exit(fn -> File.rm_rf(Path.join(Config.transcript_root(), id)) end)

    # A recorded layout (012, T033) lets resume_run/1 skip re-resolving repo
    # identity — exactly the point of this test: the repo itself has since
    # become unreachable, but the crash-recovery resume must not need it to
    # exist just to locate the checkpoint; only the feature's own worktree
    # lookup (against the now-broken :repo) should fail.
    layout = %Layout{
      worktree_root: Path.join(root, "worktrees"),
      transcript_root: root,
      in_repo_rel: "specs/autonomous/ad-hoc"
    }

    write_manifest(%{
      features: [feat(id)],
      statuses: %{id => :running},
      context: %RunContext{pr_workflow: false, max_concurrency: 1, budget_usd: 100.0},
      layout: layout
    })

    prev_repo = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, "/nonexistent/repo-#{id}")

    on_exit(fn ->
      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    me = self()
    assert {:ok, pid} = SpeckitOrchestrator.resume_run(owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 5_000
    assert report.failed == [id]
  end
end
