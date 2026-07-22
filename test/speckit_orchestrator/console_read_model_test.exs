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
end
