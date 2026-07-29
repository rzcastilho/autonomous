defmodule SpeckitOrchestrator.RecoveryQuickpollTest do
  # async: false — real-named Coordinator/Ledger + global :transcript_root/
  # :autonomous_root/:repo app env, plus the shared store (StoreCase clears
  # tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Feature, Layout, Recovery, RepoIdentity, RunContext}

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "rq_#{System.unique_integer([:positive])}")
    prev_transcript = Application.get_env(:speckit_orchestrator, :transcript_root)
    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    prev_repo = Application.get_env(:speckit_orchestrator, :repo)

    Application.put_env(:speckit_orchestrator, :transcript_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    stop_coordinator()

    on_exit(fn ->
      stop_coordinator()
      File.rm_rf(root)

      if prev_transcript,
        do: Application.put_env(:speckit_orchestrator, :transcript_root, prev_transcript),
        else: Application.delete_env(:speckit_orchestrator, :transcript_root)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)

      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    %{root: root}
  end

  defp stop_coordinator do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo do
    dir = Path.join(System.tmp_dir!(), "rq_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Tester"])
    File.write!(Path.join(dir, "README.md"), "base\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "base"])
    git!(dir, ["remote", "add", "origin", "https://example.com/quickpoll.git"])
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp commit(repo, message) do
    File.write!(Path.join(repo, "f_#{System.unique_integer([:positive])}.txt"), message)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp converge_ready, do: "Tests green, committed.\n\n## CONVERGE: READY\n"

  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || String.to_integer(id),
      slug: "core-ledger",
      path: "#{id}.md"
    }

  defp capturing_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  # ---- store fixtures (018) --------------------------------------------------

  defp open_run(repo, layout, features) do
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
        settings:
          RunContext.to_map(%RunContext{
            budget_usd: 100.0
          }),
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
      duration_ms: 42_500,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 42.5,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # Reproduces the exact quickpoll first-wave defect (SC-001): the store
  # never recorded "001" terminal (still `:pending`, so
  # `store_recorded_status/1` derives `:running`), but on disk 001 already
  # finished — branch committed, converge marker present. `report.spend`
  # comes from this same phase attempt's cost entry (T040 — the roll-up, not
  # a separately recorded scalar), so the fixture's $42.50 is carried
  # entirely by this one attempt.
  defp seed_quickpoll_state do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after specify")
    commit(repo, "speckit: 001 checkpoint after clarify")
    commit(repo, "speckit: 001 checkpoint after plan")
    commit(repo, "speckit: 001 checkpoint after tasks")
    commit(repo, "speckit: 001 checkpoint after analyze")
    commit(repo, "speckit: 001 checkpoint after implement")
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    run_key = open_run(repo, layout, [feat("001"), feat("002")])

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("001", :converge),
        cost: %{amount_usd: 42.5, kind: :estimate},
        transcript: converge_ready()
      })

    {layout, run_key}
  end

  test "reconcile_run/2 reconciles the stale 001:running to :done, releases 002, preserves spend once" do
    {layout, run_key} = seed_quickpoll_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, detail} = Store.run(run_key)

    assert {:ok, %{statuses: statuses, report: report, resume_phases: resume_phases}} =
             Recovery.reconcile_run(detail)

    assert statuses["001"] == :done
    assert statuses["002"] == :pending
    refute Map.has_key?(resume_phases, "001")

    assert report.spend == 42.5
    assert "002" in report.next_runnable
    refute "001" in report.next_runnable

    row_001 = Enum.find(report.features, &(&1.id == "001"))
    assert row_001.recorded == :running
    assert row_001.reconciled == :done
    assert row_001.corrected? == true

    # Immediately persisted — a fresh read reflects the correction (FR-009).
    {:ok, reread} = Store.run(run_key)
    assert Enum.find(reread.features, &(&1.feature_id == "001")).status == :done
    assert Enum.find(reread.features, &(&1.feature_id == "002")).status == :pending
  end

  test "resume_run/1 continues from the reconciled state: 002 dispatches, 001 never re-runs" do
    {layout, _run_key} = seed_quickpoll_state()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    me = self()

    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:started, "002", _notify}, 1_000
    refute_received {:started, "001", _}
  end
end
