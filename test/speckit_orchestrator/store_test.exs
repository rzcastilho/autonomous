defmodule SpeckitOrchestrator.StoreTest do
  @moduledoc """
  `SpeckitOrchestrator.Store` is a thin delegating facade over
  `Store.Writer`/`Store.Query` (018) — the individual behaviours are already
  covered exhaustively in `store/writer_test.exs` and `store/query_test.exs`.
  This exercises every delegate at least once so the facade itself is proven
  wired correctly end to end.
  """

  use SpeckitOrchestrator.StoreCase, async: false

  @repo "o:store-facade-test"

  test "every delegate reaches the underlying Writer/Query implementation" do
    {:ok, run_id} =
      Store.open_run(@repo, %{
        features: [%{feature_id: "001", slug: "f", path: "specs/001", prereqs: []}],
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    run_key = {@repo, run_id}

    assert :ok =
             Store.record_phase_attempt(run_key, %{
               attempt: %{
                 feature_id: "001",
                 phase: :specify,
                 ordinal: 1,
                 step: 1,
                 label: "specify",
                 started_at: DateTime.utc_now(),
                 ended_at: DateTime.utc_now(),
                 duration_ms: 1,
                 outcome: :ok,
                 model: "sonnet",
                 cost_usd: 0.0,
                 cost_kind: :estimate
               },
               checkpoint: %{
                 phase: :clarify,
                 last_completed_phase: :specify,
                 status: :in_progress
               },
               transcript: "hello"
             })

    assert :ok =
             Store.record_remediation_attempt(run_key, %{
               remediation: %{
                 feature_id: "001",
                 ordinal: 1,
                 findings: [],
                 max_severity: :high,
                 outcome: :ok,
                 cost_usd: 0.1,
                 attempt_limit: 2,
                 threshold: :high,
                 model: "opus"
               },
               phase_attempt: %{
                 step: 2,
                 label: "remediation",
                 started_at: DateTime.utc_now(),
                 ended_at: DateTime.utc_now(),
                 duration_ms: 1,
                 outcome: :ok,
                 model: "opus",
                 cost_usd: 0.1,
                 cost_kind: :actual
               }
             })

    assert :ok =
             Store.record_escalation(run_key, %{
               feature_id: "001",
               kind: :escalated,
               phase: :analyze,
               reason: "r",
               evidence: %{}
             })

    escalation_id = {@repo, run_id, "001", 1}

    assert :ok =
             Store.resolve_escalation(escalation_id, %{
               resolved_at: DateTime.utc_now(),
               note: "ok"
             })

    assert :ok = Store.record_settings_amendment(run_key, %{max_concurrency: [2, 3]}, nil)
    assert :ok = Store.record_feature_terminal(run_key, "001", :done, nil)

    assert {:ok, [_ | _]} = Store.runs(@repo)
    assert {:ok, %{run: %{run_id: ^run_id}}} = Store.run(run_key)
    assert {:error, :absent} = Store.checkpoint(run_key, "001")
    assert {:ok, %{body: "hello"}} = Store.transcript({@repo, run_id, "001", :specify, 1})
    assert Store.in_flight_run(@repo) != :none

    assert :ok = Store.close_run(run_key, :all_done, [])
    assert :ok = Store.flag_record_incomplete(run_key, {:persistence_failed, :x})

    capacity = Store.capacity()
    assert capacity.used_bytes >= 0
  end
end
