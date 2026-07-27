defmodule SpeckitOrchestrator.ResumeScopeTest do
  # async: false — real-named Coordinator/Ledger + global :autonomous_root app
  # env (mirrors resume_run_test.exs's conventions, which this file's fixtures
  # are modelled on).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{
    Checkpoint,
    Coordinator,
    Feature,
    Layout,
    RepoIdentity,
    RunContext,
    RunManifest
  }

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    root = Path.join(System.tmp_dir!(), "rs_#{System.unique_integer([:positive])}")
    prev_transcript = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
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

  defp write_checkpoint(id, last_phase, status, layout) do
    :ok =
      Checkpoint.write(%{
        feature_id: id,
        last_phase: last_phase,
        status: status,
        reason: "test fixture",
        session_id: "s1",
        slug: "f#{id}",
        path: "#{id}.md",
        layout: layout
      })
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

  # A real git repo + %Layout{} with a committed converge marker for `id`,
  # proving it genuinely finished — Recovery.reconcile_run/2 (014) reconciles
  # a recorded `:done` with zero durable evidence to `{:conflict,
  # :done_without_artifacts}`, not `:done` (mirrors resume_run_test.exs's
  # `done_layout/1`).
  defp done_layout(id) do
    repo = Path.join(System.tmp_dir!(), "rs_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "Tester"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    git!(repo, ["remote", "add", "origin", "https://example.com/resume-scope.git"])
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

  # ---- S1: the defect, at the seam level (US1, SC-001) ----------------------

  test "resume/2 keeps the whole recorded set, dispatches the target at its checkpointed phase, and releases dependents in turn" do
    write_checkpoint("001", :analyze, :halted, nil)

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"]), feat("003", ["002"])],
      statuses: %{"001" => :halted, "002" => :pending, "003" => :pending}
    })

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("001", runner: capturing_runner(me), owner: me)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Enum.sort(Map.keys(Coordinator.status(pid).per_feature)) == ["001", "002", "003"]

    assert_receive {:started, "001", n1}, 1_000
    refute_received {:started, "002", _}
    refute_received {:started, "003", _}

    n1.("001", :done, nil)

    assert_receive {:started, "002", n2}, 1_000
    refute_received {:started, "003", _}
    n2.("002", :done, nil)

    assert_receive {:started, "003", n3}, 1_000
    n3.("003", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002", "003"]
  end

  # ---- the console's own call shape -----------------------------------------

  # `EscalationsLive`'s resume handler always passes `features: [identity]` —
  # it supplies the target's slug/path, not the run's scope. Every other test
  # here calls `resume/2` without `:features`, so nothing pinned down what a
  # single-element `:features` opt does once a manifest exists. It must feed
  # identity resolution only: the recorded scope still governs, otherwise a
  # resume driven from the Escalations page narrows the run to one feature —
  # exactly the defect this feature exists to close, reached by the path an
  # operator actually uses.
  test "an explicit single-feature :features opt (the console's shape) does not narrow the restored scope" do
    write_checkpoint("001", :analyze, :halted, nil)

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"]), feat("003", ["002"])],
      statuses: %{"001" => :halted, "002" => :pending, "003" => :pending}
    })

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("001",
               features: [feat("001")],
               remediation_prompt: "Fix the money-type Critical.",
               runner: capturing_runner(me),
               owner: me
             )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert Enum.sort(Map.keys(Coordinator.status(pid).per_feature)) == ["001", "002", "003"]

    assert_receive {:started, "001", n1}, 1_000
    n1.("001", :done, nil)

    assert_receive {:started, "002", n2}, 1_000
    n2.("002", :done, nil)

    assert_receive {:started, "003", n3}, 1_000
    n3.("003", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002", "003"]
  end

  # ---- S2: nothing else is disturbed (US1, FR-002/005/006) -------------------

  test "resume/2 never redispatches an already-:done or diverted non-target feature" do
    layout = done_layout("002")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)
    write_checkpoint("001", :analyze, :halted, layout)

    write_manifest(%{
      features: [feat("001"), feat("002", ["001"]), feat("003", ["002"])],
      statuses: %{"001" => :halted, "002" => :done, "003" => :escalated},
      layout: layout
    })

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("001", runner: capturing_runner(me), owner: me)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:started, "001", n1}, 1_000
    refute_received {:started, "002", _}
    refute_received {:started, "003", _}

    n1.("001", :done, nil)

    refute_received {:started, "002", _}
    refute_received {:started, "003", _}

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["001", "002"]
    assert report.escalated == ["003"]
  end
end
