defmodule SpeckitOrchestrator.ConsoleReadModelTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{ConsoleReadModel, ExecutionTime}

  defp remediation_meta(opts) do
    %{
      feature_id: "001",
      phase: :analyze,
      attempt: opts[:attempt] || 1,
      limit: opts[:limit] || 2,
      threshold: opts[:threshold] || :high,
      findings_count: opts[:findings_count] || 1,
      max_severity: opts[:max_severity] || :high,
      model: "sonnet"
    }
  end

  defp chunk_start_meta(opts) do
    %{
      feature_id: "001",
      phase: :implement,
      scope: :task_phase,
      ordinal: opts[:ordinal],
      total: opts[:total],
      number: to_string(opts[:ordinal]),
      title: opts[:title],
      attempt: opts[:attempt],
      sessions_used: opts[:sessions_used] || 1,
      ceiling: 14,
      remaining: nil,
      model: "sonnet"
    }
  end

  describe "apply_event/4 — [:speckit, :phase, :start]" do
    test "sets current_phase, marks the phase cell active, records the model" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )

      feature = model.features["001"]
      assert feature.current_phase == :specify

      assert feature.phases[:specify] == %{
               state: :active,
               outcome: nil,
               cost: nil,
               model: "sonnet"
             }

      assert [%{feature_id: "001", phase: :specify, severity: :info}] = model.feed
    end
  end

  describe "apply_event/4 — [:speckit, :phase, :stop]" do
    test "marks the phase completed, records outcome/cost, and adds cost to spend" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 100},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
        )

      feature = model.features["001"]

      assert feature.phases[:specify] == %{
               state: :completed,
               outcome: :ok,
               cost: 0.5,
               model: "sonnet"
             }

      assert feature.spend == 0.5
      assert [%{severity: :info} | _] = model.feed
    end

    test "an errored outcome pushes an :error severity feed entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 100},
          %{
            feature_id: "001",
            phase: :implement,
            model: "sonnet",
            step: 6,
            outcome: :error,
            cost: 0.0
          }
        )

      assert [%{severity: :error}] = model.feed
    end

    test "stop without a prior start still fills the cell (default state)" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{feature_id: "002", phase: :plan, model: "opus", step: 3, outcome: :ok, cost: 1.2}
        )

      assert model.features["002"].phases[:plan].state == :completed
      assert model.features["002"].spend == 1.2
    end
  end

  describe "apply_event/4 — [:speckit, :phase, :exception]" do
    test "marks the active phase errored and pushes an :error feed entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "001", phase: :analyze, model: "opus", step: 5}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :exception],
          %{duration: 50},
          %{
            feature_id: "001",
            phase: :analyze,
            model: "opus",
            step: 5,
            kind: :error,
            reason: :boom
          }
        )

      feature = model.features["001"]
      assert feature.phases[:analyze].outcome == :error
      assert [%{severity: :error, text: text} | _] = model.feed
      assert text =~ "boom"
    end
  end

  describe "apply_event/4 — [:speckit, :feature, :terminal]" do
    test "spend rises to cost_total when it is higher than the folded per-phase sum" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 3.0},
          %{feature_id: "001", status: :done, reason: nil}
        )

      assert model.features["001"].spend == 3.0
    end

    test "spend never regresses below the folded per-phase sum" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 5.0}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 1.0},
          %{feature_id: "001", status: :done, reason: nil}
        )

      assert model.features["001"].spend == 5.0
    end

    test "severity is warn for escalated/halted and error for failed" do
      escalated =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :feature, :terminal],
          %{cost_total: 0.0},
          %{feature_id: "001", status: :escalated, reason: :needs_human}
        )

      failed =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :feature, :terminal],
          %{cost_total: 0.0},
          %{feature_id: "001", status: :failed, reason: :error}
        )

      assert [%{severity: :warn}] = escalated.feed
      assert [%{severity: :error}] = failed.feed
    end

    test "clears a chunked feature's chunk field on terminal" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 1.0},
          %{feature_id: "001", status: :done, reason: nil}
        )

      assert model.features["001"].chunk == nil
    end
  end

  describe "apply_event/4 — windows fold (contracts/execution-time.md §3, US2)" do
    test "[:speckit, :phase, :start] opens a window from native_to_ms(system_time)" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :start],
          %{system_time: 1_000_000_000},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )

      assert [%{key: {:phase, :specify}, from: from, to: nil}] = model.features["001"].windows
      assert from == ExecutionTime.native_to_ms(1_000_000_000)
    end

    test "[:speckit, :phase, :stop] closes the window at from + native_to_ms(duration)" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 0},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 5_000_000},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
        )

      assert [%{key: {:phase, :specify}, from: 0, to: to}] = model.features["001"].windows
      assert to == ExecutionTime.native_to_ms(5_000_000)
    end

    test "[:speckit, :phase, :exception] closes the window the same way as :stop" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 0},
          %{feature_id: "001", phase: :analyze, model: "opus", step: 5}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :exception],
          %{duration: 2_000_000},
          %{feature_id: "001", phase: :analyze, model: "opus", step: 5, kind: :error, reason: :boom}
        )

      assert [%{key: {:phase, :analyze}, from: 0, to: to}] = model.features["001"].windows
      assert to == ExecutionTime.native_to_ms(2_000_000)
    end

    test "a :stop/:exception with no matching open window leaves windows unchanged" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{feature_id: "001", phase: :plan, model: "opus", step: 3, outcome: :ok, cost: 1.2}
        )

      assert model.features["001"].windows == []
    end

    test "a :start missing system_time leaves windows unchanged" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :start],
          %{},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )

      assert model.features["001"].windows == []
    end

    test "[:speckit, :remediation, :start/:stop] open/close a {:remediation, phase} window" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{system_time: 0},
          remediation_meta(attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :stop],
          %{duration: 3_000_000},
          Map.merge(remediation_meta(attempt: 1), %{outcome: :ok, cost: 0.5})
        )

      assert [%{key: {:remediation, :analyze}, from: 0, to: to}] = model.features["001"].windows
      assert to == ExecutionTime.native_to_ms(3_000_000)
    end

    test "[:speckit, :chunk, :start/:stop] open/close a {:chunk, phase} window" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{system_time: 0},
          chunk_start_meta(ordinal: 1, total: 3, title: "US1", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :stop],
          %{duration: 4_000_000},
          Map.merge(chunk_start_meta(ordinal: 1, total: 3, title: "US1", attempt: 1), %{
            outcome: :ok,
            cost: 0.5,
            completed_before: 0,
            completed_after: 1
          })
        )

      assert [%{key: {:chunk, :implement}, from: 0, to: to}] = model.features["001"].windows
      assert to == ExecutionTime.native_to_ms(4_000_000)
    end

    test "[:speckit, :feature, :terminal] with system_time closes every open window" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 0},
          %{feature_id: "001", phase: :converge, model: "opus", step: 7}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 1.0, system_time: 6_000_000},
          %{feature_id: "001", status: :done, reason: nil}
        )

      assert [%{key: {:phase, :converge}, from: 0, to: to}] = model.features["001"].windows
      assert to == ExecutionTime.native_to_ms(6_000_000)
    end

    test "[:speckit, :feature, :terminal] without system_time leaves open windows open" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 0},
          %{feature_id: "001", phase: :converge, model: "opus", step: 7}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 1.0},
          %{feature_id: "001", status: :done, reason: nil}
        )

      assert [%{key: {:phase, :converge}, from: 0, to: nil}] = model.features["001"].windows
    end
  end

  describe "apply_event/4 — [:speckit, :run, :scope_narrowing_refused] (specs/016-resume-backlog-scope)" do
    test "pushes one :warn feed entry with feature_id nil naming the dropped ids, and leaves features untouched" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :run, :scope_narrowing_refused],
          %{dropped_count: 2},
          %{
            segment: "seg",
            recorded: ["001", "002", "003"],
            attempted: ["001"],
            dropped: ["002", "003"]
          }
        )

      assert [%{feature_id: nil, phase: nil, severity: :warn, text: text} | _] = model.feed
      assert text =~ "002"
      assert text =~ "003"
      assert map_size(model.features) == 1
    end
  end

  describe "apply_event/4 — [:speckit, :publish, :opened] (019, FR-018)" do
    test "records the PR url on the feature slice and feeds it, so the drawer can link mid-run" do
      url = "https://github.com/acme/ledgerlite/pull/3"

      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :publish, :opened],
          %{},
          %{feature_id: "001", url: url}
        )

      assert model.features["001"].pr_url == url
      assert [%{feature_id: "001", severity: :info, text: text} | _] = model.feed
      assert text =~ url
    end

    test "a feature with no publish event keeps a nil pr_url" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "002", phase: :specify, model: "sonnet", step: 1}
        )

      assert model.features["002"].pr_url == nil
    end
  end

  describe "apply_event/4 — unknown events" do
    test "passes the model through unchanged" do
      model = ConsoleReadModel.new()
      assert ConsoleReadModel.apply_event(model, [:some, :other, :event], %{}, %{}) == model
    end
  end

  describe "feed" do
    test "is newest-first and bounded to 200 entries" do
      model =
        Enum.reduce(1..250, ConsoleReadModel.new(), fn i, acc ->
          ConsoleReadModel.apply_event(
            acc,
            [:speckit, :phase, :start],
            %{system_time: i},
            %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
          )
        end)

      assert length(model.feed) == 200
    end
  end

  describe "merge/3" do
    test "active? is false and per_feature is empty with no coordinator status" do
      merged =
        ConsoleReadModel.merge(
          nil,
          %{budget: 10, committed: 0, reserved: 0, tripped?: false},
          ConsoleReadModel.new()
        )

      refute merged.active?
      assert merged.per_feature == %{}
      assert merged.finished? == false
    end

    test "merges coordinator per_feature status with this projection's phase/spend data" do
      projection =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :start],
          %{system_time: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1}
        )

      coordinator_status = %{
        per_feature: %{"001" => %{status: :running, elapsed_ms: 1000}},
        totals: %{running: 1},
        inflight: ["001"],
        finished?: false,
        report: nil
      }

      ledger_snapshot = %{budget: 10.0, committed: 0.0, reserved: 0.0, tripped?: false}

      merged = ConsoleReadModel.merge(coordinator_status, ledger_snapshot, projection)

      assert merged.active?
      assert merged.per_feature["001"].status == :running
      refute Map.has_key?(merged.per_feature["001"], :elapsed_ms)
      assert merged.per_feature["001"].current_phase == :specify
      assert merged.ledger == ledger_snapshot
    end
  end

  describe "hydrate/3 (023, contracts/console-hydration.md §5)" do
    defp inactive_view, do: ConsoleReadModel.merge(nil, nil, ConsoleReadModel.new())
    defp now, do: ~U[2026-09-15 12:00:00Z]

    defp run_detail(features, cost_entries \\ []),
      do: %{features: features, cost_entries: cost_entries}

    defp feature_detail(id, status, opts \\ []) do
      %{
        feature_id: id,
        status: status,
        slug: Keyword.get(opts, :slug),
        group: Keyword.get(opts, :group, :backlog),
        spec_number: Keyword.get(opts, :spec_number),
        checkpoint: Keyword.get(opts, :checkpoint),
        pr_url: Keyword.get(opts, :pr_url),
        started_at: Keyword.get(opts, :started_at),
        ended_at: Keyword.get(opts, :ended_at),
        phase_attempts: Keyword.get(opts, :phase_attempts, [])
      }
    end

    defp checkpoint(last_completed_phase, status),
      do: %{last_completed_phase: last_completed_phase, status: status, implement_chunk: nil}

    defp attempt(feature_id, phase, opts) do
      %{
        attempt_id: {"repo", "run", feature_id, phase, Keyword.get(opts, :ordinal, 1)},
        phase: phase,
        ordinal: Keyword.get(opts, :ordinal, 1),
        outcome: Keyword.get(opts, :outcome, :ok),
        model: Keyword.get(opts, :model, "sonnet"),
        cost_usd: Keyword.get(opts, :cost_usd, 1.0),
        started_at: Keyword.get(opts, :started_at),
        ended_at: Keyword.get(opts, :ended_at)
      }
    end

    defp cost_entry(attempt_id, amount), do: %{id: attempt_id, amount_usd: amount}

    defp active_view(per_feature),
      do:
        ConsoleReadModel.merge(
          %{per_feature: per_feature, finished?: false},
          nil,
          ConsoleReadModel.new()
        )

    test "live mode fills every coordinator-listed row from the record and ignores a record-only feature (FR-008)" do
      view = active_view(%{"001" => %{status: :running, elapsed_ms: 1000}})
      detail = run_detail([feature_detail("001", :running), feature_detail("record-only", :done)])

      merged = ConsoleReadModel.hydrate(view, detail, now())

      assert Map.has_key?(merged.per_feature, "001")
      refute Map.has_key?(merged.per_feature, "record-only")
    end

    test "live mode layers the record's execution-time elapsed/spend under the live row" do
      attempts = [
        attempt("001", :specify,
          cost_usd: 3.0,
          started_at: ~U[2026-09-15 11:00:00Z],
          ended_at: ~U[2026-09-15 12:00:00Z]
        )
      ]

      cost_entries = [cost_entry(hd(attempts).attempt_id, 3.0)]

      detail =
        run_detail(
          [
            feature_detail("001", :running,
              started_at: ~U[2026-09-15 11:00:00Z],
              phase_attempts: attempts
            )
          ],
          cost_entries
        )

      view = active_view(%{"001" => %{status: :running, elapsed_ms: 42}})

      merged = ConsoleReadModel.hydrate(view, detail, now())
      entry = merged.per_feature["001"]

      assert entry.elapsed_ms == 3_600_000
      assert entry.spend == 3.0
    end

    test "cold mode populates per_feature from the run's record" do
      detail =
        run_detail([
          feature_detail("001", :halted),
          feature_detail("002", :pending),
          feature_detail("003", :running)
        ])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      assert merged.per_feature["001"].status == :halted
      assert merged.per_feature["002"].status == :pending
      assert merged.per_feature["003"].status == :running
    end

    test "cold-mode entries carry the full per-feature row shape (no missing-key crash downstream)" do
      detail =
        run_detail([feature_detail("001", :halted, slug: "core-ledger", group: :ad_hoc)])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      entry = merged.per_feature["001"]
      assert entry.status == :halted
      assert entry.elapsed_ms == nil
      assert entry.slug == "core-ledger"
      assert entry.group == :ad_hoc
      assert entry.current_phase == nil
      assert entry.phases == %{}
      assert entry.spend == 0.0
      assert entry.pr_url == nil
    end

    test "carries a stored pr_url through, so a cold boot still links to a done feature's PR" do
      url = "https://github.com/acme/ledgerlite/pull/9"
      detail = run_detail([feature_detail("001", :done, pr_url: url)])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      assert merged.per_feature["001"].pr_url == url
    end

    test "tolerates a run detail whose features predate the pr_url/phase_attempts fields" do
      detail =
        run_detail([
          %{feature_id: "001", status: :done, slug: "x", group: :backlog, checkpoint: nil}
        ])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      assert merged.per_feature["001"].pr_url == nil
      assert merged.per_feature["001"].phases == %{}
    end

    test "never overwrites an existing per_feature entry in cold mode" do
      view = %{inactive_view() | per_feature: %{"001" => %{status: :done}}}
      detail = run_detail([feature_detail("001", :halted)])

      merged = ConsoleReadModel.hydrate(view, detail, now())

      assert merged.per_feature["001"] == %{status: :done}
    end

    test "is unchanged (aside from overlay_observed/1) when there is no run detail" do
      view = inactive_view()
      assert ConsoleReadModel.hydrate(view, nil, now()) == view
    end

    test "a feature's checkpoint plus its recorded attempts renders completed cells before it and an active-diverted cell at it" do
      attempts = [
        attempt("001", :specify, cost_usd: 1.0),
        attempt("001", :clarify, cost_usd: 1.0),
        attempt("001", :plan, cost_usd: 1.0),
        attempt("001", :tasks, cost_usd: 1.0),
        attempt("001", :analyze, cost_usd: 2.0, model: "opus")
      ]

      detail =
        run_detail([
          feature_detail("001", :halted,
            checkpoint: checkpoint(:analyze, :halted),
            phase_attempts: attempts
          )
        ])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())
      entry = merged.per_feature["001"]

      assert entry.current_phase == :analyze

      for phase <- [:specify, :clarify, :plan, :tasks] do
        assert entry.phases[phase].state == :completed
      end

      assert entry.phases[:analyze] == %{
               state: :active,
               outcome: :halted,
               cost: 2.0,
               model: "opus"
             }

      refute Map.has_key?(entry.phases, :implement)
      refute Map.has_key?(entry.phases, :converge)
    end

    test "a feature with no checkpoint (never released) gets an empty phase timeline" do
      detail = run_detail([feature_detail("001", :pending)])
      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())
      entry = merged.per_feature["001"]

      assert entry.current_phase == nil
      assert entry.phases == %{}
    end

    test "seeds chunk from the checkpoint's implement_chunk when present" do
      checkpoint = %{
        last_completed_phase: :implement,
        status: :halted,
        implement_chunk: %{
          ordinal: 3,
          number: "3",
          title: "User Story 1",
          total: 5,
          sessions_used: 7,
          ceiling: 14,
          scope: :task_phase
        }
      }

      detail = run_detail([feature_detail("001", :halted, checkpoint: checkpoint)])
      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      assert merged.per_feature["001"].chunk == %{
               ordinal: 3,
               total: 5,
               title: "User Story 1",
               attempt: 1,
               scope: :task_phase,
               sessions_used: 7,
               ceiling: 14,
               remaining: nil,
               outcome: nil
             }
    end

    test "absent implement_chunk seeds chunk: nil (FR-018)" do
      detail =
        run_detail([feature_detail("001", :halted, checkpoint: checkpoint(:analyze, :halted))])

      merged = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      assert merged.per_feature["001"].chunk == nil
    end

    test "overlay_observed/1 still promotes a feature on a live active phase, without blanking its hydrated record cells" do
      attempts = [attempt("001", :specify, cost_usd: 1.0)]

      detail =
        run_detail([
          feature_detail("001", :running,
            checkpoint: checkpoint(:specify, :in_progress),
            phase_attempts: attempts
          )
        ])

      hydrated = ConsoleReadModel.hydrate(inactive_view(), detail, now())

      observed_view = %{
        hydrated
        | observed: %{
            "001" => %{
              current_phase: :clarify,
              phases: %{clarify: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}},
              spend: 1.0,
              chunk: nil,
              remediation: nil,
              pr_url: nil
            }
          }
      }

      merged = ConsoleReadModel.overlay_observed(observed_view, now())
      entry = merged.per_feature["001"]

      assert entry.status == :running
      assert entry.phases[:specify].state == :completed
      assert entry.phases[:clarify].state == :active
    end
  end

  describe "apply_event/4 — [:speckit, :chunk, :start] (specs/015-implement-phase-chunking)" do
    test "task-phase attempt 1 with no previous chunk sets chunk and emits a started boundary entry" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :start],
          %{system_time: 1},
          chunk_start_meta(ordinal: 1, total: 5, title: "Setup", attempt: 1)
        )

      feature = model.features["001"]

      assert feature.chunk == %{
               ordinal: 1,
               total: 5,
               title: "Setup",
               attempt: 1,
               scope: :task_phase,
               sessions_used: 1,
               ceiling: 14,
               remaining: nil,
               outcome: nil
             }

      assert [%{severity: :info, text: "task-phase 1/5 \"Setup\" started"}] = model.feed
    end

    test "task-phase attempt 1 with a previous completed chunk emits a transition boundary entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 2, total: 5, title: "Foundational", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1)
        )

      assert [%{severity: :info, text: text} | _] = model.feed
      assert text == "task-phase 2/5 \"Foundational\" complete → 3/5 \"User Story 1\""
    end

    test "attempt > 1 emits a :warn continuation entry naming the attempt" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 2)
        )

      assert [%{severity: :warn, text: text}] = model.feed
      assert text == "task-phase 3/5 \"User Story 1\" continuing (attempt 2)"
    end

    test "sweep start sets chunk scope :sweep and emits a :warn feed entry naming the remaining count" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :start],
          %{},
          %{
            feature_id: "001",
            phase: :implement,
            scope: :sweep,
            ordinal: nil,
            total: nil,
            number: nil,
            title: nil,
            attempt: 1,
            sessions_used: 6,
            ceiling: 14,
            remaining: 2,
            model: "sonnet"
          }
        )

      assert model.features["001"].chunk.scope == :sweep
      assert [%{severity: :warn, text: "sweep session over 2 remaining tasks"}] = model.feed
    end

    test "whole_list start sets chunk (rendering treats it as absent) but feeds :info \"implement started\"" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :start],
          %{},
          %{
            feature_id: "001",
            phase: :implement,
            scope: :whole_list,
            ordinal: nil,
            total: nil,
            number: nil,
            title: nil,
            attempt: 1,
            sessions_used: 1,
            ceiling: 14,
            remaining: nil,
            model: "sonnet"
          }
        )

      assert model.features["001"].chunk.scope == :whole_list
      assert [%{severity: :info, text: "implement started"}] = model.feed
    end
  end

  describe "apply_event/4 — [:speckit, :chunk, :stop] (specs/015-implement-phase-chunking)" do
    test "an :ok task-phase stop adds its cost to spend and emits an info transition-outcome entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :stop],
          %{duration: 1},
          Map.merge(chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1), %{
            outcome: :ok,
            cost: 0.3,
            completed_before: 11,
            completed_after: 14
          })
        )

      feature = model.features["001"]
      assert feature.spend == 0.3

      assert [%{severity: :info, text: text} | _] = model.feed
      assert text == "task-phase 3/5 \"User Story 1\" → ok (11→14 tasks)"
    end

    test "an :exhausted stop is :warn severity regardless of progress" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :stop],
          %{duration: 1},
          Map.merge(chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1), %{
            outcome: :exhausted,
            cost: 0.1,
            completed_before: 11,
            completed_after: 11
          })
        )

      assert [%{severity: :warn} | _] = model.feed
    end
  end

  describe "apply_event/4 — [:speckit, :chunk, :exception] (specs/015-implement-phase-chunking)" do
    test "sets chunk.outcome to :error and pushes an :error feed entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :start],
          %{},
          chunk_start_meta(ordinal: 3, total: 5, title: "User Story 1", attempt: 1)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :exception],
          %{duration: 1},
          %{feature_id: "001", kind: :error, reason: :boom}
        )

      assert model.features["001"].chunk.outcome == :error
      assert [%{severity: :error, text: text} | _] = model.feed
      assert text =~ "boom"
    end
  end

  describe "apply_event/4 — [:speckit, :chunk, :resolved] (specs/015-implement-phase-chunking)" do
    test "match_kind :number is a no-op — no feed entry (the common, unremarkable case)" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :resolved],
          %{},
          %{
            feature_id: "001",
            match_kind: :number,
            ordinal: 3,
            number: "3",
            title: "US1",
            requested: nil
          }
        )

      assert model.feed == []
    end

    test "match_kind :title pushes a :warn feed entry naming the renumbering (FR-025a)" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :resolved],
          %{},
          %{
            feature_id: "001",
            match_kind: :title,
            ordinal: 3,
            number: "3",
            title: "US1",
            requested: nil
          }
        )

      assert [%{severity: :warn, text: text}] = model.feed
      assert text =~ "title"
    end

    test "match_kind :fallback pushes a :warn feed entry" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :chunk, :resolved],
          %{},
          %{
            feature_id: "001",
            match_kind: :fallback,
            ordinal: 1,
            number: nil,
            title: "Setup",
            requested: nil
          }
        )

      assert [%{severity: :warn}] = model.feed
    end
  end

  describe "double-count avoidance — chunked implement phase-stop cost (contracts/telemetry-chunk.md §2)" do
    test "the wrapping phase-stop event adds only the not-yet-counted remainder" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :stop],
          %{},
          %{feature_id: "001", outcome: :ok, cost: 0.4}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :chunk, :stop],
          %{},
          %{feature_id: "001", outcome: :ok, cost: 0.6}
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{
            feature_id: "001",
            phase: :implement,
            model: "sonnet",
            step: 6,
            outcome: :ok,
            cost: 1.0
          }
        )

      assert_in_delta model.features["001"].spend, 1.0, 0.0001
    end

    test "a non-implement phase-stop still adds its full cost (unchanged behaviour)" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{feature_id: "001", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
        )

      assert model.features["001"].spend == 0.5
    end
  end

  # ---- 017-analyze-auto-remediation (contracts/telemetry-console.md §2) -------

  describe "apply_event/4 — [:speckit, :remediation, :start]" do
    test "sets the feature's remediation slice and pushes an attempt feed entry" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :remediation, :start],
          %{system_time: 1},
          remediation_meta(attempt: 1, limit: 2, findings_count: 3)
        )

      assert model.features["001"].remediation == %{
               attempt: 1,
               limit: 2,
               threshold: :high,
               findings: 3,
               outcome: nil
             }

      assert [%{feature_id: "001", phase: :analyze, severity: :info, text: text}] = model.feed
      assert text == "auto-remediation attempt 1/2 — 3 findings ≥ high"
    end

    test "a later attempt replaces the slice rather than accumulating" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{},
          remediation_meta(attempt: 1, limit: 2)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{},
          remediation_meta(attempt: 2, limit: 2, findings_count: 2)
        )

      assert model.features["001"].remediation.attempt == 2
      assert model.features["001"].remediation.findings == 2
    end
  end

  describe "apply_event/4 — [:speckit, :remediation, :stop]" do
    test "adds the attempt's cost to spend, records the outcome, pushes a feed entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{},
          remediation_meta(attempt: 1, limit: 2)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :stop],
          %{duration: 1},
          remediation_meta(attempt: 1, limit: 2) |> Map.merge(%{outcome: :ok, cost: 1.26})
        )

      feature = model.features["001"]
      assert_in_delta feature.spend, 1.26, 0.0001
      assert feature.remediation.outcome == :ok

      assert [%{severity: :info, text: text} | _] = model.feed
      assert text == "auto-remediation attempt 1/2 → ok"
    end

    test "an :error outcome pushes an :error feed entry" do
      model =
        ConsoleReadModel.apply_event(
          ConsoleReadModel.new(),
          [:speckit, :remediation, :stop],
          %{duration: 1},
          remediation_meta(attempt: 2, limit: 2) |> Map.merge(%{outcome: :error, cost: 0.0})
        )

      assert [%{severity: :error, text: "auto-remediation attempt 2/2 → error"}] = model.feed
    end
  end

  describe "apply_event/4 — [:speckit, :remediation, :exception]" do
    test "marks the slice's outcome :error and pushes an :error feed entry" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{},
          remediation_meta(attempt: 1, limit: 2)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :exception],
          %{duration: 1},
          remediation_meta(attempt: 1, limit: 2)
          |> Map.merge(%{kind: :error, reason: %RuntimeError{message: "boom"}})
        )

      assert model.features["001"].remediation.outcome == :error
      assert [%{severity: :error, phase: :analyze, text: text} | _] = model.feed
      assert text =~ "auto-remediation exception"
    end
  end

  describe "remediation cost is never double-counted against the analyze phase" do
    test "a remediation stop plus the wrapping analyze phase stop sum, they do not overlap" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :stop],
          %{},
          remediation_meta(attempt: 1, limit: 2) |> Map.merge(%{outcome: :ok, cost: 1.26})
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :phase, :stop],
          %{duration: 1},
          %{
            feature_id: "001",
            phase: :analyze,
            model: "sonnet",
            step: 5,
            outcome: :ok,
            cost: 0.4
          }
        )

      # The two events describe different harness runs — the analyze phase span
      # never wraps the remediation span's cost, so no `chunk_cost_seen`-style
      # guard applies and the total is the plain sum.
      assert_in_delta model.features["001"].spend, 1.66, 0.0001
    end
  end

  describe "apply_event/4 — [:speckit, :feature, :terminal] clears the remediation slice" do
    test "remediation is reset to nil alongside chunk" do
      model =
        ConsoleReadModel.new()
        |> ConsoleReadModel.apply_event(
          [:speckit, :remediation, :start],
          %{},
          remediation_meta(attempt: 1, limit: 2)
        )
        |> ConsoleReadModel.apply_event(
          [:speckit, :feature, :terminal],
          %{cost_total: 2.0},
          %{
            feature_id: "001",
            status: :escalated,
            reason: {:high_findings, :auto_remediation_exhausted}
          }
        )

      assert model.features["001"].remediation == nil
    end
  end
end
