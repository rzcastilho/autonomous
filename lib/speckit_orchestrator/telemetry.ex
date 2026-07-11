defmodule SpeckitOrchestrator.Telemetry do
  @moduledoc """
  Telemetry event names and an optional default logging handler.

  Events (emitted by `FeatureRunner`):

    * `[:speckit, :phase, :start]` — measurements `%{system_time}`, metadata
      `%{feature_id, phase, model, step}`.
    * `[:speckit, :phase, :stop]` — measurements `%{duration}`, metadata adds
      `%{outcome, cost}`.
    * `[:speckit, :phase, :exception]` — measurements `%{duration}`, metadata
      adds `%{kind, reason}`. (Emitted via `:telemetry.span/3`.)
    * `[:speckit, :feature, :terminal]` — measurements `%{cost_total}`, metadata
      `%{feature_id, status, reason}`.

  Call `attach_default_logger/0` from `iex` to log every event.
  """

  require Logger

  @phase [:speckit, :phase]
  @events [
    [:speckit, :phase, :start],
    [:speckit, :phase, :stop],
    [:speckit, :phase, :exception],
    [:speckit, :feature, :terminal]
  ]

  @doc "The `:telemetry.span/3` prefix for phase events."
  @spec phase_span() :: [atom()]
  def phase_span, do: @phase

  @doc "All emitted event names."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Attach a handler that logs every orchestrator event. Idempotent-ish."
  @spec attach_default_logger() :: :ok | {:error, :already_exists}
  def attach_default_logger do
    :telemetry.attach_many("speckit-default-logger", @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:speckit, :phase, :stop], %{duration: dur}, meta, _cfg) do
    Logger.info(
      "phase #{meta.phase} feature=#{meta.feature_id} outcome=#{inspect(meta[:outcome])} " <>
        "cost=#{inspect(meta[:cost])} #{ms(dur)}ms model=#{meta.model}"
    )
  end

  def handle_event([:speckit, :feature, :terminal], meas, meta, _cfg) do
    Logger.info(
      "feature #{meta.feature_id} terminal=#{meta.status} reason=#{inspect(meta.reason)} " <>
        "cost_total=#{inspect(meas.cost_total)}"
    )
  end

  def handle_event(_event, _meas, _meta, _cfg), do: :ok

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
