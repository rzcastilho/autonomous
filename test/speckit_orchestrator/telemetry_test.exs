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

  test "events/0 and chunk_span/0 expose the chunk conventions (specs/015-implement-phase-chunking)" do
    assert [:speckit, :chunk] == Telemetry.chunk_span()
    assert [:speckit, :chunk, :start] in Telemetry.events()
    assert [:speckit, :chunk, :stop] in Telemetry.events()
    assert [:speckit, :chunk, :exception] in Telemetry.events()
    assert [:speckit, :chunk, :resolved] in Telemetry.events()
  end

  test "attach_default_logger handles every chunk event without a FunctionClauseError" do
    assert :ok = Telemetry.attach_default_logger()
    on_exit(fn -> :telemetry.detach("speckit-default-logger") end)

    capture_log(fn ->
      :telemetry.execute(
        [:speckit, :chunk, :start],
        %{system_time: 1},
        %{feature_id: "001", phase: :implement, scope: :task_phase, ordinal: 1, total: 5}
      )

      :telemetry.execute(
        [:speckit, :chunk, :stop],
        %{duration: 1},
        %{feature_id: "001", phase: :implement, scope: :task_phase, outcome: :ok, cost: 0.1}
      )

      :telemetry.execute(
        [:speckit, :chunk, :exception],
        %{duration: 1},
        %{feature_id: "001", phase: :implement, kind: :error, reason: :boom}
      )

      :telemetry.execute(
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
    end)
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

  test "events/0 exposes the scope-narrowing-refused run event (specs/016-resume-backlog-scope)" do
    assert [:speckit, :run, :scope_narrowing_refused] in Telemetry.events()
  end

  test "attach_default_logger logs the dropped ids on a scope-narrowing refusal" do
    assert :ok = Telemetry.attach_default_logger()
    on_exit(fn -> :telemetry.detach("speckit-default-logger") end)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:speckit, :run, :scope_narrowing_refused],
          %{dropped_count: 2},
          %{
            segment: "seg",
            recorded: ["001", "002", "003"],
            attempted: ["001"],
            dropped: ["002", "003"]
          }
        )
      end)

    assert log =~ "run scope narrowing refused"
    assert log =~ ~s(dropped=["002", "003"])
  end
end
