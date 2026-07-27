defmodule SpeckitOrchestrator.RecordRecoveryTest do
  # async: false — real-named Coordinator/Ledger + global :speckit_orchestrator
  # app env (mirrors recovery_quickpoll_test.exs / resume_scope_test.exs
  # conventions).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, RepoIdentity, RunContext, RunManifest}

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "rr_#{System.unique_integer([:positive])}")
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

    :ok
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
    repo = Path.join(System.tmp_dir!(), "rr_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "Tester"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    git!(repo, ["remote", "add", "origin", "https://example.com/quickpoll.git"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp commit(repo, message) do
    File.write!(Path.join(repo, "f_#{System.unique_integer([:positive])}.txt"), message)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

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

  defp breakdown_file(dir, id, prereqs_line) do
    File.write!(
      Path.join(dir, "#{id}-core-ledger.md"),
      "# #{id} — Core Ledger\n\n## Prerequisites\n\n#{prereqs_line}\n"
    )
  end

  # The `../quickpoll`-shaped fixture from contracts/record-recovery.md
  # "Worked example": record narrowed to `001: done` only, backlog on disk
  # `001 → 002 → 003`, evidence corroborating `001` (committed branch +
  # `pr.json`) and none for `002`/`003`.
  defp seed_worked_example do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core-ledger"})

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    pr_dir = Path.join(layout.transcript_root, "001")
    File.mkdir_p!(pr_dir)
    File.write!(Path.join(pr_dir, "pr.json"), Jason.encode!(%{pr_title: "t", pr_body: "b"}))

    File.mkdir_p!(layout.breakdown_root)
    breakdown_file(layout.breakdown_root, "001", "None")
    breakdown_file(layout.breakdown_root, "002", "- 001 Core Ledger")
    breakdown_file(layout.breakdown_root, "003", "- 002 Core Ledger")

    write_manifest(%{
      features: [feat("001")],
      statuses: %{"001" => :done},
      layout: layout
    })

    layout
  end

  # ---- S5.1: preview has no durable effect (FR-019a) -------------------------

  test "recover_record/1 preview names all three features and leaves the manifest byte-identical" do
    layout = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    manifest_path = Path.join([layout.transcript_root |> Path.dirname(), "run.json"])
    before = File.read!(manifest_path)

    assert {:ok, proposal} = SpeckitOrchestrator.recover_record()

    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]
    assert proposal.statuses == %{"001" => :done, "002" => :pending, "003" => :pending}

    assert Enum.sort(for(d <- proposal.discrepancies, do: {d.kind, d.id})) == [
             {:absent_from_record, "002"},
             {:absent_from_record, "003"}
           ]

    after_read = File.read!(manifest_path)
    assert after_read == before
  end

  # ---- S5.2: confirm writes; a subsequent resume_run/1 dispatches the gap ----

  test "recover_record(confirm: true) writes the rebuilt record; resume_run/1 then releases 002/003 but never re-dispatches 001" do
    layout = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    assert {:ok, :written, proposal} = SpeckitOrchestrator.recover_record(confirm: true)
    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]

    {:ok, reread} = RunManifest.read()
    assert Enum.map(reread["features"], & &1["id"]) == ["001", "002", "003"]
    assert reread["statuses"] == %{"001" => "done", "002" => "pending", "003" => "pending"}

    me = self()

    assert {:ok, pid} = SpeckitOrchestrator.resume_run(runner: capturing_runner(me), owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Enum.sort(Map.keys(Coordinator.status(pid).per_feature)) == ["001", "002", "003"]

    refute_received {:started, "001", _}
    assert_receive {:started, "002", n2}, 1_000
    refute_received {:started, "003", _}

    n2.("002", :done, nil)

    assert_receive {:started, "003", n3}, 1_000
    n3.("003", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002", "003"]
  end

  # ---- S5.3: an unloadable backlog refuses with no write ---------------------

  test "recover_record/1 refuses with {:backlog, _} and writes nothing when the backlog has a dangling prereq" do
    layout = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    # Corrupt the on-disk backlog after the manifest was written: 003 now
    # names a prereq no breakdown file defines.
    breakdown_file(layout.breakdown_root, "003", "- 999 Missing")

    manifest_path = Path.join([layout.transcript_root |> Path.dirname(), "run.json"])
    before = File.read!(manifest_path)

    assert {:error, {:backlog, _reason}} = SpeckitOrchestrator.recover_record()

    assert File.read!(manifest_path) == before
  end

  # ---- S5.4: a prereq-missing proposal refuses with no write (FR-020) --------

  test "recover_record/1 refuses with {:inconsistent, _} and writes nothing when the union has a missing prereq" do
    layout = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    # `Backlog.load!/1` itself already fails loud on a dangling prereq
    # *within* the backlog files, so `propose/3`'s own union guard (FR-020)
    # is only reachable through a record-only feature (absent from the
    # backlog on disk, so never validated by `Backlog.load!/1`) naming a
    # prereq nowhere in the union.
    write_manifest(%{
      features: [feat("001"), feat("004", ["999"])],
      statuses: %{"001" => :done, "004" => :pending},
      layout: layout
    })

    manifest_path = Path.join([layout.transcript_root |> Path.dirname(), "run.json"])
    before = File.read!(manifest_path)

    assert {:error, {:inconsistent, discrepancies}} = SpeckitOrchestrator.recover_record()
    assert [%{kind: :prereq_missing, id: "004", detail: "999"}] = discrepancies

    assert File.read!(manifest_path) == before
  end

  # ---- no record at all -------------------------------------------------------

  test "recover_record/1 returns {:error, :no_manifest} when nothing is recorded" do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    assert {:error, :no_manifest} = SpeckitOrchestrator.recover_record()
  end
end
