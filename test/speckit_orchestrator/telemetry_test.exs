defmodule SpeckitOrchestrator.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias SpeckitOrchestrator.Telemetry

  setup do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)
    :ok
  end

  test "events/0 and phase_span/0 expose the conventions" do
    assert [:speckit, :phase] == Telemetry.phase_span()
    assert [:speckit, :phase, :stop] in Telemetry.events()
    assert [:speckit, :feature, :terminal] in Telemetry.events()
  end

  test "attach_default_logger logs phase-stop and feature-terminal events" do
    assert :ok = Telemetry.attach_default_logger()
    on_exit(fn -> :telemetry.detach("speckit-default-logger") end)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:speckit, :phase, :stop],
          %{duration: System.convert_time_unit(12, :millisecond, :native)},
          %{phase: :specify, feature_id: "001", model: "sonnet", outcome: :ok, cost: 0.1}
        )

        :telemetry.execute(
          [:speckit, :feature, :terminal],
          %{cost_total: 0.5},
          %{feature_id: "001", status: :done, reason: :done}
        )
      end)

    assert log =~ "phase specify feature=001"
    assert log =~ "12ms"
    assert log =~ "feature 001 terminal=done"
  end

  test "unknown events are ignored by the handler" do
    assert :ok = Telemetry.handle_event([:speckit, :phase, :start], %{}, %{}, nil)
  end
end
