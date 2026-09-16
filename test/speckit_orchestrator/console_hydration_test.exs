defmodule SpeckitOrchestrator.ConsoleHydrationTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{ConsoleHydration, Pipeline}

  @now ~U[2026-09-15 12:00:00Z]

  defp attempt(feature_id, phase, opts) do
    %{
      attempt_id: {"repo", "run", feature_id, phase, Keyword.get(opts, :ordinal, 1)},
      feature_id: feature_id,
      phase: phase,
      outcome: Keyword.get(opts, :outcome, :ok),
      model: Keyword.get(opts, :model, "sonnet"),
      cost_usd: Keyword.get(opts, :cost_usd, 1.0)
    }
  end

  defp cost_entry(attempt_id, amount), do: %{id: attempt_id, amount_usd: amount}

  defp feature(id, opts) do
    %{
      feature_id: id,
      status: Keyword.get(opts, :status, :done),
      slug: Keyword.get(opts, :slug),
      group: Keyword.get(opts, :group),
      spec_number: Keyword.get(opts, :spec_number),
      started_at: Keyword.get(opts, :started_at),
      ended_at: Keyword.get(opts, :ended_at),
      pr_url: Keyword.get(opts, :pr_url),
      checkpoint: Keyword.get(opts, :checkpoint),
      phase_attempts: Keyword.get(opts, :phase_attempts, [])
    }
  end

  describe "from_record/3" do
    test "a :done feature recorded through all seven phases yields seven completed cells, correct spend, and elapsed = ended_at - started_at (US1-1)" do
      phases = Pipeline.phases()
      attempts = Enum.map(phases, &attempt("f1", &1, cost_usd: 2.0))
      cost_entries = Enum.map(attempts, &cost_entry(&1.attempt_id, 2.0))

      started_at = ~U[2026-01-01 00:00:00Z]
      ended_at = ~U[2026-01-01 00:10:00Z]

      f =
        feature("f1",
          status: :done,
          phase_attempts: attempts,
          started_at: started_at,
          ended_at: ended_at
        )

      slice = ConsoleHydration.from_record(f, cost_entries, @now)

      assert map_size(slice.phases) == 7

      for phase <- phases do
        assert slice.phases[phase].state == :completed
      end

      assert slice.spend == 14.0
      assert slice.elapsed_ms == 600_000
      assert slice.current_phase == nil
    end

    test "non-phase attempts (:remediation, :implement_chunk, :auto_remediation) never produce a cell and add no spend without a matching cost entry (FR-003/FR-005)" do
      non_phase_attempts = [
        attempt("f2", :remediation, cost_usd: 5.0),
        attempt("f2", :implement_chunk, cost_usd: 5.0),
        attempt("f2", :auto_remediation, cost_usd: 5.0)
      ]

      specify_attempt = attempt("f2", :specify, cost_usd: 1.0)
      attempts = non_phase_attempts ++ [specify_attempt]

      # Mirrors real recorded behavior: only the :specify attempt has a
      # matching cost entry (an :implement_chunk session never gets one —
      # the wrapping :implement roll-up carries the summed cost instead).
      cost_entries = [cost_entry(specify_attempt.attempt_id, 1.0)]

      f = feature("f2", status: :running, phase_attempts: attempts, checkpoint: nil)

      slice = ConsoleHydration.from_record(f, cost_entries, @now)

      assert Map.keys(slice.phases) == [:specify]
      assert slice.spend == 1.0
    end

    test "a phase with multiple attempts uses the last attempt's own outcome/cost/model (clarification 2)" do
      attempts = [
        attempt("f3", :plan, ordinal: 1, cost_usd: 1.0, outcome: :error, model: "sonnet"),
        attempt("f3", :plan, ordinal: 2, cost_usd: 3.0, outcome: :ok, model: "opus")
      ]

      cost_entries = Enum.map(attempts, &cost_entry(&1.attempt_id, &1.cost_usd))

      f =
        feature("f3",
          status: :running,
          phase_attempts: attempts,
          checkpoint: %{last_completed_phase: :plan}
        )

      slice = ConsoleHydration.from_record(f, cost_entries, @now)

      assert slice.phases[:plan] == %{state: :completed, outcome: :ok, cost: 3.0, model: "opus"}
      assert slice.spend == 4.0
    end

    test "a diverted feature's checkpoint phase becomes active with the status marker and that phase's own attempt cost/model (FR-004)" do
      attempts = [attempt("f4", :analyze, cost_usd: 2.5, model: "opus")]
      cost_entries = Enum.map(attempts, &cost_entry(&1.attempt_id, &1.cost_usd))

      f =
        feature("f4",
          status: :halted,
          phase_attempts: attempts,
          checkpoint: %{last_completed_phase: :analyze}
        )

      slice = ConsoleHydration.from_record(f, cost_entries, @now)

      assert slice.phases[:analyze] == %{
               state: :active,
               outcome: :halted,
               cost: 2.5,
               model: "opus"
             }
    end

    test "a diverted feature with no attempt at its checkpoint phase degrades to cost: nil, model: nil (FR-004, US3-1)" do
      f =
        feature("f4b",
          status: :halted,
          phase_attempts: [],
          checkpoint: %{last_completed_phase: :analyze}
        )

      slice = ConsoleHydration.from_record(f, [], @now)

      assert slice.phases[:analyze] == %{
               state: :active,
               outcome: :halted,
               cost: nil,
               model: nil
             }
    end

    test "a feature resumed from an earlier phase renders later recorded attempts as pending, not completed (edge case, US2-5)" do
      attempts = [
        attempt("f6", :specify, cost_usd: 1.0),
        attempt("f6", :clarify, cost_usd: 1.0),
        attempt("f6", :plan, cost_usd: 1.0),
        attempt("f6", :tasks, cost_usd: 1.0),
        attempt("f6", :analyze, cost_usd: 1.0)
      ]

      cost_entries = Enum.map(attempts, &cost_entry(&1.attempt_id, &1.cost_usd))

      f =
        feature("f6",
          status: :running,
          phase_attempts: attempts,
          checkpoint: %{last_completed_phase: :plan}
        )

      slice = ConsoleHydration.from_record(f, cost_entries, @now)

      assert Map.keys(slice.phases) |> Enum.sort() == [:clarify, :plan, :specify]
      assert slice.phases[:plan] == %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"}
      refute Map.has_key?(slice.phases, :tasks)
      refute Map.has_key?(slice.phases, :analyze)
      assert slice.current_phase == :plan
      assert slice.spend == 5.0
    end

    test "tolerates a record missing every optional field (FR-013)" do
      slice = ConsoleHydration.from_record(%{feature_id: "f5"}, nil, @now)

      assert slice.phases == %{}
      assert slice.spend == 0.0
      assert slice.elapsed_ms == nil
      assert slice.current_phase == nil
      assert slice.chunk == nil
    end
  end

  describe "layer/2 (contracts/console-hydration.md §2-3)" do
    defp recorded_slice do
      %{
        status: :done,
        slug: "slug-x",
        group: :backlog,
        spec_number: 1,
        current_phase: nil,
        phases: %{
          specify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
          clarify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"}
        },
        spend: 2.0,
        elapsed_ms: 5_000,
        chunk: nil,
        remediation: nil,
        pr_url: "https://example.com/pr/1"
      }
    end

    test "is idempotent: layer(r, layer(r, l)) == layer(r, l)" do
      r = recorded_slice()

      l = %{
        status: :running,
        phases: %{plan: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}},
        spend: 3.0
      }

      once = ConsoleHydration.layer(r, l)
      twice = ConsoleHydration.layer(r, once)

      assert twice == once
    end

    test "spend is the max of record and live" do
      r = %{recorded_slice() | spend: 5.0}
      l = %{spend: 2.0}

      assert ConsoleHydration.layer(r, l).spend == 5.0
      assert ConsoleHydration.layer(%{r | spend: 1.0}, %{spend: 9.0}).spend == 9.0
    end

    test "live wins per phase it observed, and cells after a live active phase are trimmed" do
      r = %{
        recorded_slice()
        | current_phase: :converge,
          phases: %{
            specify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
            clarify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
            plan: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
            converge: %{state: :active, outcome: nil, cost: nil, model: "opus"}
          }
      }

      l = %{
        phases: %{
          plan: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}
        }
      }

      row = ConsoleHydration.layer(r, l)

      assert row.phases[:plan] == l.phases.plan
      assert row.phases[:specify] == r.phases.specify
      assert row.phases[:clarify] == r.phases.clarify
      refute Map.has_key?(row.phases, :converge)
      assert row.current_phase == :plan
    end

    test "a known pr_url is never blanked by a live slice that carries nil" do
      r = recorded_slice()
      l = %{pr_url: nil}

      assert ConsoleHydration.layer(r, l).pr_url == r.pr_url
    end

    test "handles either argument being nil" do
      r = recorded_slice()

      assert ConsoleHydration.layer(r, nil).pr_url == r.pr_url
      assert ConsoleHydration.layer(nil, %{status: :running}).status == :running
      assert ConsoleHydration.layer(nil, nil) == ConsoleHydration.layer(%{}, %{})
    end
  end

  describe "apply_update/2 (contracts/console-hydration.md §3-4)" do
    defp row do
      %{
        status: :running,
        slug: "slug-y",
        current_phase: :tasks,
        phases: %{
          specify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
          clarify: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
          plan: %{state: :completed, outcome: :ok, cost: 1.0, model: "sonnet"},
          tasks: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}
        },
        spend: 3.0,
        elapsed_ms: 10_000,
        chunk: nil,
        remediation: nil,
        pr_url: "https://example.com/pr/2"
      }
    end

    test "update == nil returns row unchanged" do
      assert ConsoleHydration.apply_update(row(), nil) == row()
    end

    test "a missing row starts from the documented default shape" do
      update = %{
        status: :running,
        phases: %{specify: %{state: :active, outcome: nil, cost: nil, model: nil}}
      }

      result = ConsoleHydration.apply_update(nil, update)

      assert result.status == :running
      assert result.slug == nil
      assert result.spend == 0.0
      assert result.phases == update.phases
    end

    test "spend never decreases" do
      assert ConsoleHydration.apply_update(row(), %{spend: 1.0}).spend == 3.0
      assert ConsoleHydration.apply_update(row(), %{spend: 9.0}).spend == 9.0
    end

    test "no blanking: an untouched pre-restart completed cell survives an update that only carries a later phase" do
      update = %{phases: %{analyze: %{state: :active, outcome: nil, cost: nil, model: "opus"}}}

      result = ConsoleHydration.apply_update(row(), update)

      assert result.phases[:specify] == row().phases.specify
      assert result.phases[:clarify] == row().phases.clarify
      assert result.phases[:plan] == row().phases.plan
      assert result.phases[:tasks] == row().phases.tasks
      assert result.phases[:analyze] == update.phases.analyze
    end

    test "live wins per phase: every phase in the update overwrites the row's own cell" do
      update = %{
        phases: %{tasks: %{state: :active, outcome: :error, cost: 2.0, model: "opus"}}
      }

      result = ConsoleHydration.apply_update(row(), update)

      assert result.phases[:tasks] == update.phases.tasks
    end

    test "an update whose active phase is earlier than a recorded cell renders the later recorded cells pending (resume from an earlier phase)" do
      update = %{phases: %{clarify: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}}}

      result = ConsoleHydration.apply_update(row(), update)

      assert result.phases[:specify] == row().phases.specify
      assert result.phases[:clarify] == update.phases.clarify
      refute Map.has_key?(result.phases, :plan)
      refute Map.has_key?(result.phases, :tasks)
    end

    test "a known pr_url survives an update carrying pr_url: nil" do
      assert ConsoleHydration.apply_update(row(), %{pr_url: nil}).pr_url == row().pr_url
    end

    test "chunk/remediation/current_phase are replaced by the update, including nil to clear" do
      result =
        ConsoleHydration.apply_update(row(), %{chunk: %{ordinal: 1}, current_phase: :analyze})

      assert result.chunk == %{ordinal: 1}
      assert result.current_phase == :analyze

      cleared = ConsoleHydration.apply_update(result, %{chunk: nil})
      assert cleared.chunk == nil
    end

    test "is idempotent: reapplying an already-reflected update yields the same row" do
      update = %{phases: %{analyze: %{state: :active, outcome: nil, cost: nil, model: "opus"}}}

      once = ConsoleHydration.apply_update(row(), update)
      twice = ConsoleHydration.apply_update(once, update)

      assert twice == once
    end
  end
end
