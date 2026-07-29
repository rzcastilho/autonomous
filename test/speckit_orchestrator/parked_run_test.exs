defmodule SpeckitOrchestrator.ParkedRunTest do
  @moduledoc """
  US4 — park / continue / end lifecycle (T061,
  specs/019-stacked-sequential-only/contracts/parked-run.md). Drives real
  `run/1`/`resolve/2`/`continue_run/1`/`end_run/1` against the real store
  (`StoreCase`), with an injected `:runner` that fakes what `FeatureRunner`
  would have written (terminal status, and — for the stopping feature — a
  checkpoint) so `continue_run/1`'s checkpoint-based resume has something
  real to resolve against, without any actual git/worktree/harness.

  One synthetic-test artifact worth naming: a feature this file marks
  `:done` via the fake runner has no real git branch behind it, so
  `Recovery.reconcile_run/2`'s clause 3 ("done requires corroboration") does
  not reconfirm it as `:done` on a later `continue_run/1` — a real run would
  have the branch and pass. This never affects the assertions below, which
  only check the *stopping* feature's behavior (a `:halted`/`:escalated`/
  `:failed` status is a gate passthrough, clause 1/2 — no evidence needed).
  """

  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Config, Feature, RepoIdentity}

  defp feat(id, number),
    do: %Feature{id: id, number: number, slug: "f#{id}", path: "#{id}.md"}

  defp repo_id, do: RepoIdentity.partition(Config.repo())

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
      session_id: "s1",
      error: nil
    }
  end

  # Fakes what `FeatureRunner` would have durably recorded, so the store
  # stays internally consistent for a later `continue_run/1`: a `:done`
  # outcome records the terminal status; a stop outcome additionally records
  # a checkpoint (`resume/2`'s `resolve_start_phase/2` requires one).
  defp fake_runner(test_pid, outcomes) do
    fn feature, notify ->
      run_key = {repo_id(), SpeckitOrchestrator.current_run_id()}

      case Map.fetch!(outcomes, feature.id) do
        :done ->
          Writer.record_feature_terminal(run_key, feature.id, :done, nil)
          notify.(feature.id, :done, nil)

        {status, reason} ->
          Writer.record_phase_attempt(run_key, %{
            attempt: minimal_attempt(feature.id, :implement),
            checkpoint: %{
              phase: :implement,
              last_completed_phase: :tasks,
              status: status,
              reason: reason,
              session_id: "s1"
            }
          })

          Writer.record_feature_terminal(run_key, feature.id, status, reason)
          notify.(feature.id, status, reason)
      end

      send(test_pid, {:ran, feature.id})
      :ok
    end
  end

  defp stop_coordinator do
    case Process.whereis(SpeckitOrchestrator.Coordinator) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  setup do
    on_exit(&stop_coordinator/0)
    :ok
  end

  defp start_run!(features, outcomes) do
    me = self()
    {:ok, pid} = SpeckitOrchestrator.run(features: features, runner: fake_runner(me, outcomes), owner: me)
    pid
  end

  test "a broken link parks the run and refuses every new start until resolved" do
    features = [feat("001", 1), feat("002", 2), feat("003", 3)]
    outcomes = %{"001" => :done, "002" => {:halted, :critical_finding}, "003" => :done}

    start_run!(features, outcomes)

    assert_receive {:ran, "001"}, 2_000
    assert_receive {:ran, "002"}, 2_000
    refute_receive {:ran, "003"}, 200

    assert_receive {:run_complete, report}, 2_000
    assert report.stopped_by == %{feature_id: "002", status: :halted, reason: :critical_finding}

    repo_id = repo_id()
    assert {:ok, %{state: :parked, run_id: run_id}} = Store.parked_run(repo_id)

    assert SpeckitOrchestrator.run(features: features, runner: fake_runner(self(), outcomes)) ==
             {:error, {:parked_run, run_id, [:continue, :end]}}

    assert SpeckitOrchestrator.run_spec("a new ad-hoc idea", runner: fake_runner(self(), %{})) ==
             {:error, {:parked_run, run_id, [:continue, :end]}}

    # The operator's choice is never made for them.
    assert SpeckitOrchestrator.resolve("002") == {:error, :decision_required}
    assert SpeckitOrchestrator.resolve("002", decision: :bogus) == {:error, {:invalid_decision, :bogus}}
    assert {:ok, %{state: :parked}} = Store.parked_run(repo_id)
  end

  test "resolve(id, decision: :end) closes the run out — never-started features recorded, stopped_by/stopped_reason retained, new work unblocked" do
    features = [feat("001", 1), feat("002", 2), feat("003", 3)]
    outcomes = %{"001" => :done, "002" => {:escalated, :needs_human}, "003" => :done}

    start_run!(features, outcomes)
    assert_receive {:run_complete, _report}, 2_000

    repo_id = repo_id()
    assert {:ok, %{run_id: run_id}} = Store.parked_run(repo_id)

    assert {:ok, run_summary} =
             SpeckitOrchestrator.resolve("002", decision: :end, features: features)

    assert run_summary.state == :completed
    assert run_summary.outcome == :ended_by_operator
    assert run_summary.stopped_by == "002"
    assert run_summary.stopped_reason == :needs_human

    {:ok, detail} = Store.run({repo_id, run_id})
    feature_003 = Enum.find(detail.features, &(&1.feature_id == "003"))
    assert feature_003.status == :never_started

    # Ending unblocks new work — no parked run left to refuse it.
    assert Store.parked_run(repo_id) == :none
  end

  test "resolve(id, decision: :continue) re-runs the stopping feature under the same run_id and the chain proceeds" do
    features = [feat("001", 1), feat("002", 2)]
    outcomes = %{"001" => :done, "002" => {:halted, :critical_finding}}

    start_run!(features, outcomes)
    assert_receive {:run_complete, _report}, 2_000

    repo_id = repo_id()
    assert {:ok, %{run_id: run_id}} = Store.parked_run(repo_id)

    me = self()

    assert {:ok, pid2} =
             SpeckitOrchestrator.resolve("002",
               decision: :continue,
               features: features,
               runner: fake_runner(me, %{"002" => :done}),
               owner: me
             )

    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    assert_receive {:ran, "002"}, 2_000
    assert_receive {:run_complete, report2}, 2_000
    assert "002" in report2.done

    # Same run_id continues — no new run was opened, and the store's own
    # per-feature row (independent of this test's synthetic reconciliation,
    # which has no real git branch to reconfirm "001" against) shows both
    # features terminal.
    assert {:ok, %{run: %{run_id: ^run_id}, features: features}} = Store.run({repo_id, run_id})
    assert Enum.find(features, &(&1.feature_id == "002")).status == :done
    assert Store.parked_run(repo_id) == :none
  end

  test "continuing a run whose stopping feature breaks again parks it a second time with the new reason recorded distinctly" do
    features = [feat("001", 1), feat("002", 2)]
    outcomes = %{"001" => :done, "002" => {:halted, :first_failure}}

    start_run!(features, outcomes)
    assert_receive {:run_complete, _report}, 2_000

    repo_id = repo_id()
    assert {:ok, %{run_id: run_id, stopped_reason: :first_failure}} = Store.parked_run(repo_id)

    me = self()

    assert {:ok, pid2} =
             SpeckitOrchestrator.continue_run(
               features: features,
               runner: fake_runner(me, %{"002" => {:failed, :second_failure}}),
               owner: me
             )

    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    assert_receive {:ran, "002"}, 2_000
    assert_receive {:run_complete, report2}, 2_000
    assert report2.stopped_by == %{feature_id: "002", status: :failed, reason: :second_failure}

    assert {:ok, %{run_id: ^run_id, state: :parked, stopped_reason: :second_failure}} =
             Store.parked_run(repo_id)
  end
end
