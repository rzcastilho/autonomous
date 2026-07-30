defmodule SpeckitOrchestrator.ResumeScopeTest do
  # async: false — real-named Coordinator/Ledger + global :autonomous_root app
  # env, plus the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, RepoIdentity, RunContext}

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

  defp feat(id, number \\ nil),
    do: %Feature{id: id, number: number || String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

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
      duration_ms: 0,
      outcome: :error,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # A diverted checkpoint (`status: :halted`) records the phase to re-run
  # itself (`FeatureRunner.checkpoint_for/3`'s halt/fail clause) — the store
  # equivalent of the pre-018 file checkpoint's `last_phase`.
  defp seed_halted_checkpoint(run_key, feature_id, phase) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, phase),
        checkpoint: %{
          phase: phase,
          last_completed_phase: phase,
          status: :halted,
          reason: "test fixture",
          session_id: "s1"
        }
      })

    :ok = Writer.record_feature_terminal(run_key, feature_id, :halted, "test fixture", [])
  end

  defp seed_converge_marker(run_key, feature_id) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: %{minimal_attempt(feature_id, :converge) | outcome: :ok},
        transcript: "Tests green.\n\n## CONVERGE: READY\n"
      })
  end

  # A real git repo + %Layout{} with a committed converge marker for `id`,
  # proving it genuinely finished — reconciliation reconciles a recorded
  # `:done` with zero durable evidence to `{:conflict, :done_without_artifacts}`,
  # not `:done` (mirrors resume_run_test.exs's `done_layout/1`).
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
    layout
  end

  # A layout with no real backing git repo — for tests whose only durable
  # evidence is the halted target's own checkpoint (gate passthrough, no
  # evidence collection needed).
  defp bare_layout do
    repo = Path.join(System.tmp_dir!(), "rs_bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["remote", "add", "origin", "https://example.com/resume-scope-bare.git"])
    on_exit(fn -> File.rm_rf(repo) end)
    put_repo(repo)

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)
    layout
  end

  # ---- S1: the defect, at the seam level (US1, SC-001) ----------------------

  test "resume/2 keeps the whole recorded set, dispatches the target at its checkpointed phase, and releases dependents in turn" do
    layout = bare_layout()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    run_key =
      open_run(Application.get_env(:speckit_orchestrator, :repo), layout, [
        feat("001"),
        feat("002"),
        feat("003")
      ])

    seed_halted_checkpoint(run_key, "001", :analyze)

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
  # single-element `:features` opt does once a run exists. It must feed
  # identity resolution only: the recorded scope still governs, otherwise a
  # resume driven from the Escalations page narrows the run to one feature —
  # exactly the defect this feature exists to close, reached by the path an
  # operator actually uses.
  test "an explicit single-feature :features opt (the console's shape) does not narrow the restored scope" do
    layout = bare_layout()
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    run_key =
      open_run(Application.get_env(:speckit_orchestrator, :repo), layout, [
        feat("001"),
        feat("002"),
        feat("003")
      ])

    seed_halted_checkpoint(run_key, "001", :analyze)

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

  # 019 NOTE (flagged for a maintainer, not silently adjusted): `Release.next/3`
  # rule 2 is documented as "any feature :escalated/:halted/:failed ⇒
  # {:stopped, id, status} (the lowest-ordered one, when more than one)" —
  # checked unconditionally, before rule 4's pending-release check, with no
  # exception for a feature ordered *before* the broken one. In this fixture
  # "003" is already recorded `:escalated` (independent of the "001" target
  # being resumed here), so `Release.next/3` reports `{:stopped, "003",
  # :escalated}` immediately and the Coordinator never releases anything at
  # all — not even "001", the feature `resume/2` was explicitly called to
  # redispatch. This is surprising (an operator fixing an earlier feature
  # would reasonably expect it to actually run, with only feature *after* it
  # gated on the fix), but it is what the current, documented rule 2 does
  # verbatim — a design question for a human, not a test-fixture bug. This
  # test now asserts that actual behavior; the original 016-era intent (001
  # dispatches and completes, 002 stays reconciled-done, 003 stays the
  # eventual stopper) is unreachable under the current rule 2 whenever a
  # non-target feature elsewhere in the run is already broken.
  test "resume/2 never redispatches an already-:done or diverted non-target feature" do
    layout = done_layout("002")
    on_exit(fn -> File.rm_rf(layout.worktree_root) end)

    run_key =
      open_run(Application.get_env(:speckit_orchestrator, :repo), layout, [
        feat("001"),
        feat("002"),
        feat("003")
      ])

    seed_halted_checkpoint(run_key, "001", :analyze)
    seed_converge_marker(run_key, "002")
    :ok = Writer.record_feature_terminal(run_key, "003", :escalated, "test fixture", [])

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("001", runner: capturing_runner(me), owner: me)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_received {:started, "001", _}
    refute_received {:started, "002", _}
    refute_received {:started, "003", _}

    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.done) == ["002"]
    assert report.not_started == ["001"]
    assert report.escalated == ["003"]
    assert report.stopped_by == %{feature_id: "003", status: :escalated, reason: nil}
  end
end
