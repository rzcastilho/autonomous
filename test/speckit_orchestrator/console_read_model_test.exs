defmodule SpeckitOrchestrator.ConsoleReadModelTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.ConsoleReadModel

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
      assert merged.per_feature["001"].elapsed_ms == 1000
      assert merged.per_feature["001"].current_phase == :specify
      assert merged.ledger == ledger_snapshot
    end
  end

  describe "overlay_last_known_statuses/2 (specs/009-crash-recovery)" do
    defp inactive_view, do: ConsoleReadModel.merge(nil, nil, ConsoleReadModel.new())

    test "is a no-op when the view is active — live Coordinator state always wins" do
      active_view =
        ConsoleReadModel.merge(
          %{per_feature: %{"001" => %{status: :running}}, finished?: false},
          nil,
          ConsoleReadModel.new()
        )

      manifest = %{"statuses" => %{"001" => "done"}}

      assert ConsoleReadModel.overlay_last_known_statuses(active_view, manifest) == active_view
    end

    test "is a no-op when there is no manifest record" do
      view = inactive_view()
      assert ConsoleReadModel.overlay_last_known_statuses(view, nil) == view
    end

    test "populates per_feature from the manifest's last-known statuses, converting the vocabulary safely" do
      manifest = %{
        "statuses" => %{
          "001" => "halted",
          "002" => "pending",
          "003" => "running",
          "004" => "weird-unrecognized-value"
        }
      }

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest)

      assert merged.per_feature["001"].status == :halted
      assert merged.per_feature["002"].status == :pending
      assert merged.per_feature["003"].status == :running
      # fail-safe default for anything outside the known vocabulary
      assert merged.per_feature["004"].status == :pending
    end

    test "populated entries carry the full per-feature slice shape (no missing-key crash downstream)" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest)

      entry = merged.per_feature["001"]
      assert entry.status == :halted
      assert entry.elapsed_ms == nil
      assert entry.slug == nil
      assert entry.prereqs == []
      assert entry.current_phase == nil
      assert entry.phases == %{}
      assert entry.spend == 0.0
    end

    test "never overwrites an existing per_feature entry" do
      view = %{inactive_view() | per_feature: %{"001" => %{status: :done}}}
      manifest = %{"statuses" => %{"001" => "halted"}}

      merged = ConsoleReadModel.overlay_last_known_statuses(view, manifest)

      assert merged.per_feature["001"] == %{status: :done}
    end
  end

  describe "overlay_last_known_statuses/3 with checkpoints — phase timeline (specs/009-crash-recovery)" do
    test "a halted feature's checkpoint marks every phase before last_phase completed, and last_phase active-halted" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "analyze", "status" => "halted"}}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      entry = merged.per_feature["001"]

      assert entry.current_phase == :analyze

      for phase <- [:specify, :clarify, :plan, :tasks] do
        assert entry.phases[phase] == %{state: :completed, outcome: nil, cost: nil, model: nil}
      end

      assert entry.phases[:analyze] == %{state: :active, outcome: :halted, cost: nil, model: nil}
      refute Map.has_key?(entry.phases, :implement)
      refute Map.has_key?(entry.phases, :converge)
    end

    test "an escalated feature's checkpoint colors last_phase active-escalated" do
      manifest = %{"statuses" => %{"001" => "escalated"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "clarify", "status" => "escalated"}}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      assert merged.per_feature["001"].phases[:clarify] ==
               %{state: :active, outcome: :escalated, cost: nil, model: nil}
    end

    test "an in-progress crash checkpoint (feature interrupted, not diverted) marks last_phase completed, not active" do
      manifest = %{"statuses" => %{"001" => "running"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "plan", "status" => "in_progress"}}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      entry = merged.per_feature["001"]

      assert entry.current_phase == :plan
      assert entry.phases[:plan] == %{state: :completed, outcome: nil, cost: nil, model: nil}
      assert entry.phases[:specify] == %{state: :completed, outcome: nil, cost: nil, model: nil}
      refute Map.has_key?(entry.phases, :tasks)
    end

    test "a feature absent from checkpoints (never released) gets an empty phase timeline" do
      manifest = %{"statuses" => %{"001" => "pending"}}

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, %{})
      entry = merged.per_feature["001"]

      assert entry.current_phase == nil
      assert entry.phases == %{}
    end

    test "a corrupt/missing checkpoint entry for an id falls back to an empty phase timeline, not a crash" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      checkpoints = %{"001" => {:error, :corrupt}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      entry = merged.per_feature["001"]

      assert entry.current_phase == nil
      assert entry.phases == %{}
    end

    test "an unparseable last_phase string falls back to an empty phase timeline, not a crash" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "not-a-real-phase", "status" => "halted"}}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      entry = merged.per_feature["001"]

      assert entry.current_phase == nil
      assert entry.phases == %{}
    end

    test "checkpoints defaults to %{} when omitted" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest)

      assert merged.per_feature["001"].phases == %{}
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

  describe "overlay_last_known_statuses/3 — implement_chunk seeding (contracts/checkpoint-implement-chunk.md)" do
    test "seeds chunk from the checkpoint's implement_chunk when present" do
      manifest = %{"statuses" => %{"001" => "halted"}}

      checkpoints = %{
        "001" =>
          {:ok,
           %{
             "last_phase" => "implement",
             "status" => "halted",
             "implement_chunk" => %{
               "ordinal" => 3,
               "number" => "3",
               "title" => "User Story 1",
               "total" => 5,
               "sessions_used" => 7,
               "ceiling" => 14,
               "scope" => "task_phase"
             }
           }}
      }

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

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
      manifest = %{"statuses" => %{"001" => "halted"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "analyze", "status" => "halted"}}}

      merged =
        ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      assert merged.per_feature["001"].chunk == nil
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
