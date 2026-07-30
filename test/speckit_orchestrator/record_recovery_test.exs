defmodule SpeckitOrchestrator.RecordRecoveryTest do
  # async: false — real-named Coordinator/Ledger + global :speckit_orchestrator
  # app env, plus the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, RepoIdentity, RunContext}

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

  defp breakdown_file(dir, id, prereqs_line) do
    File.write!(
      Path.join(dir, "#{id}-core-ledger.md"),
      "# #{id} — Core Ledger\n\n## Prerequisites\n\n#{prereqs_line}\n"
    )
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
        scope: {:breakdown, "core-ledger"},
        layout: layout
      })

    {repo_id, run_id}
  end

  # The `../quickpoll`-shaped fixture from contracts/record-recovery.md
  # "Worked example": record narrowed to `001: done` only, backlog on disk
  # `001 → 002 → 003`, evidence corroborating `001` (committed branch + a
  # recorded PR description) and none for `002`/`003`.
  defp seed_worked_example do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core-ledger"})

    git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
    commit(repo, "speckit: 001 checkpoint after converge")
    git!(repo, ["checkout", "-q", "main"])

    File.mkdir_p!(layout.breakdown_root)
    breakdown_file(layout.breakdown_root, "001", "None")
    breakdown_file(layout.breakdown_root, "002", "- 001 Core Ledger")
    breakdown_file(layout.breakdown_root, "003", "- 002 Core Ledger")

    run_key = open_run(repo, layout, [feat("001")])

    :ok =
      Writer.record_feature_terminal(run_key, "001", :done, :ok,
        pr_description: %{pr_title: "t", pr_body: "b"}
      )

    {layout, run_key}
  end

  # ---- S5.1: preview has no durable effect (FR-019a) -------------------------

  test "recover_record/1 preview names all three features and changes nothing in the store" do
    {layout, run_key} = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    {:ok, before} = Store.run(run_key)

    assert {:ok, proposal} = SpeckitOrchestrator.recover_record()

    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]
    assert proposal.statuses == %{"001" => :done, "002" => :pending, "003" => :pending}

    assert Enum.sort(for(d <- proposal.discrepancies, do: {d.kind, d.id})) == [
             {:absent_from_record, "002"},
             {:absent_from_record, "003"}
           ]

    {:ok, after_read} = Store.run(run_key)

    assert Enum.map(after_read.features, & &1.feature_id) ==
             Enum.map(before.features, & &1.feature_id)
  end

  # ---- S5.2: confirm writes; a subsequent resume_run/1 dispatches the gap ----

  test "recover_record(confirm: true) adds 002/003 to the store; resume_run/1 then releases them but never re-dispatches 001" do
    {layout, run_key} = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    assert {:ok, :written, proposal} = SpeckitOrchestrator.recover_record(confirm: true)
    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]

    {:ok, reread} = Store.run(run_key)
    assert Enum.map(reread.features, & &1.feature_id) |> Enum.sort() == ["001", "002", "003"]

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
  #
  # 019 dropped `Backlog`'s prereq/cycle validation entirely — a
  # `## Prerequisites` section is now inert prose, never read (see
  # `backlog.ex` moduledoc). The one way left to make `Backlog.load!/1` raise
  # is `DuplicateNumberError` — two files whose numeric ids collide (FR-012).

  test "recover_record/1 refuses with {:backlog, _} and writes nothing when the backlog has duplicate feature numbers" do
    {layout, run_key} = seed_worked_example()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    # Corrupt the on-disk backlog after the run was opened: a second file
    # numerically collides with "003" (`"0003"` == `3`, same as `"003"`).
    breakdown_file(layout.breakdown_root, "0003", "None")

    {:ok, before} = Store.run(run_key)

    assert {:error, {:backlog, _reason}} = SpeckitOrchestrator.recover_record()

    {:ok, after_read} = Store.run(run_key)

    assert Enum.map(after_read.features, & &1.feature_id) ==
             Enum.map(before.features, & &1.feature_id)
  end

  # 019 removed `Recovery.Rebuild.propose/3`'s union prereq-consistency guard
  # along with `Feature.prereqs` itself — there is no `:prereq_missing`
  # discrepancy kind and no `{:error, {:inconsistent, _}}` return left to
  # trigger (see `recovery/rebuild_test.exs`'s matching note), so the old
  # "S5.4: a prereq-missing proposal refuses with no write" test has no
  # new-model equivalent to rewrite into.

  # ---- no record at all -------------------------------------------------------

  test "recover_record/1 returns {:error, :no_manifest} when nothing is recorded" do
    repo = base_repo()
    Application.put_env(:speckit_orchestrator, :repo, repo)

    assert {:error, :no_manifest} = SpeckitOrchestrator.recover_record()
  end
end
