defmodule SpeckitOrchestrator.RecoveryQuickpollTest do
  # async: false — real-named Coordinator/Ledger + global :transcript_root/
  # :autonomous_root/:repo app env (mirrors resume_run_test.exs conventions).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, Layout, Recovery, RepoIdentity, RunContext, RunManifest}

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

  defp write_durable(root, id, filename, content) do
    dir = Path.join(root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
  end

  defp pr_json, do: Jason.encode!(%{pr_title: "core ledger", pr_body: "b"})
  defp converge_ready, do: "Tests green, committed.\n\n## CONVERGE: READY\n"

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "core-ledger", path: "#{id}.md", prereqs: prereqs}

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
            spend: 42.5,
            updated_at: 1
          },
          overrides
        )
      )
  end

  # Reproduces the exact quickpoll first-wave defect (SC-001): manifest says
  # `001: running`, but on disk 001 already finished — branch committed,
  # `pr.json` present, converge marker present. The fixture repo carries an
  # `origin` remote so `RepoIdentity.resolve/1` yields the same segment
  # `RunManifest.read/0`/`write/1` and `run/1`'s own preflight resolve — the
  # self-built `%Layout{}` here is built from that same segment so
  # `Recovery.reconcile_run/2`'s `RunManifest.rebuild_layout/2` lands on
  # exactly the same durable paths this seed wrote.
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

    write_durable(layout.transcript_root, "001", "pr.json", pr_json())
    write_durable(layout.transcript_root, "001", "07-converge.md", converge_ready())

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"])],
      statuses: %{"001" => :running, "002" => :pending},
      layout: layout
    })

    layout
  end

  test "reconcile_run/2 reconciles the stale 001:running to :done, releases 002, preserves spend once" do
    seed_quickpoll_state()

    {:ok, record} = RunManifest.read()
    assert {:ok, %{statuses: statuses, report: report, resume_phases: resume_phases}} =
             Recovery.reconcile_run(record)

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
    {:ok, reread} = RunManifest.read()
    assert reread["statuses"]["001"] == "done"
    assert reread["statuses"]["002"] == "pending"
    assert reread["spend"] == 42.5
  end

  test "resume_run/1 continues from the reconciled state: 002 dispatches, 001 never re-runs" do
    seed_quickpoll_state()

    me = self()

    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:started, "002", _notify}, 1_000
    refute_received {:started, "001", _}
  end
end
