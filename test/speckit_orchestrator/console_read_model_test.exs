defmodule SpeckitOrchestrator.ConsoleReadModelTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.ConsoleReadModel

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

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)
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

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)

      assert merged.per_feature["001"].phases[:clarify] ==
               %{state: :active, outcome: :escalated, cost: nil, model: nil}
    end

    test "an in-progress crash checkpoint (feature interrupted, not diverted) marks last_phase completed, not active" do
      manifest = %{"statuses" => %{"001" => "running"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "plan", "status" => "in_progress"}}}

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)
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

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)
      entry = merged.per_feature["001"]

      assert entry.current_phase == nil
      assert entry.phases == %{}
    end

    test "an unparseable last_phase string falls back to an empty phase timeline, not a crash" do
      manifest = %{"statuses" => %{"001" => "halted"}}
      checkpoints = %{"001" => {:ok, %{"last_phase" => "not-a-real-phase", "status" => "halted"}}}

      merged = ConsoleReadModel.overlay_last_known_statuses(inactive_view(), manifest, checkpoints)
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
end
