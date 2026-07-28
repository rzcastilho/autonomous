defmodule SpeckitOrchestrator.Recovery.RebuildTest do
  # async: false — the shared store (StoreCase clears tables per test); :git
  # is always injected, so no real git/worktree I/O beyond the store.
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.Feature
  alias SpeckitOrchestrator.Recovery.Rebuild

  @repo_id "o:rebuild-test"

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "core-ledger", path: "#{id}.md", prereqs: prereqs}

  # No evidence of any kind, for any feature — a hermetic default matching
  # `Evidence.default_git/1`'s "no branch" shape without touching git.
  defp no_evidence(_feature), do: %{branch_committed?: false, last_boundary_phase: nil}

  # ---- store fixtures (018) --------------------------------------------------

  defp open_record(features) do
    {:ok, run_id} =
      Writer.open_run(@repo_id, %{
        features:
          Enum.map(
            features,
            &%{feature_id: &1.id, slug: &1.slug, path: &1.path, prereqs: &1.prereqs}
          ),
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {@repo_id, run_id}
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

  defp seed_terminal(run_key, feature_id, status) do
    :ok = Writer.record_feature_terminal(run_key, feature_id, status, :test_fixture, [])
  end

  defp seed_running(run_key, feature_id) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, :plan),
        checkpoint: %{
          phase: :tasks,
          last_completed_phase: :plan,
          status: :in_progress,
          reason: nil,
          session_id: nil
        }
      })
  end

  defp seed_converge_marker(run_key, feature_id) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, :converge),
        transcript: "Tests green.\n\n## CONVERGE: READY\n"
      })
  end

  defp record(run_key), do: Store.run(run_key) |> elem(1)

  # ---- union rule + status mapping table (T027) ------------------------------

  test "propose/3: union order, both-present-clean, and absent_from_record" do
    run_key = open_record([feat("001")])
    seed_terminal(run_key, "001", :done)
    seed_converge_marker(run_key, "001")

    git = fn
      %{id: "001"} -> %{branch_committed?: true, last_boundary_phase: :converge}
      _ -> no_evidence(nil)
    end

    backlog = [feat("001"), feat("002", ["001"]), feat("003", ["002"])]

    assert {:ok, proposal} = Rebuild.propose(record(run_key), backlog, git: git)

    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]
    assert proposal.statuses == %{"001" => :done, "002" => :pending, "003" => :pending}
    refute Map.has_key?(proposal.resume_phases, "001")

    assert Enum.sort(for(d <- proposal.discrepancies, do: {d.kind, d.id})) == [
             {:absent_from_record, "002"},
             {:absent_from_record, "003"}
           ]

    assert proposal.source == %{
             record_ids: ["001"],
             backlog_ids: ["001", "002", "003"],
             backlog_root: nil
           }

    row_001 = Enum.find(proposal.report.features, &(&1.id == "001"))
    assert row_001.reconciled == :done
    assert row_001.corrected? == false
  end

  test "propose/3: both-present conflict reconciles to :blocked and reports :unreconcilable" do
    run_key = open_record([feat("001")])
    seed_terminal(run_key, "001", :done)
    # No corroborating evidence at all for "001" despite a recorded :done.

    backlog = [feat("001")]

    assert {:ok, proposal} = Rebuild.propose(record(run_key), backlog, git: &no_evidence/1)

    assert proposal.statuses["001"] == :blocked

    assert [%{kind: :unreconcilable, id: "001", detail: :done_without_artifacts}] =
             proposal.discrepancies

    assert %{id: "001", reason: :done_without_artifacts} in proposal.report.conflicts
  end

  test "propose/3: record-only feature (absent_from_backlog) is kept verbatim, unreconciled" do
    run_key = open_record([feat("001"), feat("002")])
    seed_terminal(run_key, "001", :done)
    seed_converge_marker(run_key, "001")
    seed_running(run_key, "002")

    git = fn
      %{id: "001"} -> %{branch_committed?: true, last_boundary_phase: :converge}
      _ -> no_evidence(nil)
    end

    backlog = [feat("001")]

    assert {:ok, proposal} = Rebuild.propose(record(run_key), backlog, git: git)

    assert Enum.map(proposal.features, & &1.id) == ["001", "002"]
    assert proposal.statuses["002"] == :running
    refute Map.has_key?(proposal.resume_phases, "002")
    assert [%{kind: :absent_from_backlog, id: "002", detail: :running}] = proposal.discrepancies

    row_002 = Enum.find(proposal.report.features, &(&1.id == "002"))
    assert row_002.recorded == :running
    assert row_002.reconciled == :running
    assert row_002.corrected? == false
  end

  test "propose/3: a prereq missing from the union refuses without collecting evidence" do
    # Backlog names 001 with a prereq the record never mentions and the
    # backlog never defines — evidence must never be collected once this is
    # found (asserted via a :git seam that raises if invoked).
    exploding_git = fn _ -> raise "evidence must not be collected for a refused proposal" end

    run_key = open_record([feat("001", ["999"])])
    backlog = [feat("001", ["999"])]

    assert {:error, {:inconsistent, discrepancies}} =
             Rebuild.propose(record(run_key), backlog, git: exploding_git)

    assert discrepancies == [%{kind: :prereq_missing, id: "001", detail: "999"}]
  end
end
