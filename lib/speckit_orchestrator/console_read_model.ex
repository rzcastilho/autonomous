defmodule SpeckitOrchestrator.ConsoleReadModel do
  @moduledoc """
  Pure read-model fold + snapshot merge for the console projection
  (`specs/008-control-plane/contracts/console_projection.md`). No
  Phoenix/GenServer/telemetry dependency — unit-tested with synthetic events
  (Constitution I: Pure Core, Isolated Contracts).

  `ConsoleProjection` (the GenServer) is a thin owner: fold via `apply_event/4`
  → store → broadcast diff. `merge/3` combines this projection's state with
  `Coordinator.status/0` and `Ledger.snapshot/1` for both seed-on-mount and
  reconcile.
  """

  @feed_limit 200

  @type event_entry :: %{
          feature_id: String.t() | nil,
          phase: atom() | nil,
          text: String.t(),
          severity: :info | :warn | :error,
          at: DateTime.t()
        }

  @type phase_cell :: %{
          state: :active | :completed,
          outcome: term(),
          cost: number() | nil,
          model: String.t() | nil
        }

  @type feature_slice :: %{
          current_phase: atom() | nil,
          phases: %{atom() => phase_cell()},
          spend: number()
        }

  @type t :: %{features: %{String.t() => feature_slice()}, feed: [event_entry()]}

  @doc "An empty console read-model."
  @spec new() :: t()
  def new, do: %{features: %{}, feed: []}

  @doc """
  Fold one telemetry event into the model. Pure — no side effects, no
  dependency on `:telemetry` being loaded.

  Recognized events (see the projection contract's telemetry table):
  `[:speckit, :phase, :start/:stop/:exception]`, `[:speckit, :feature,
  :terminal]`. Any other event passes through unchanged.
  """
  @spec apply_event(t(), [atom()], map(), map()) :: t()
  def apply_event(model, event_name, measurements, metadata)

  def apply_event(
        model,
        [:speckit, :phase, :start],
        _measurements,
        %{feature_id: id, phase: phase} = meta
      ) do
    feature = feature_slice(model, id)

    cell = %{state: :active, outcome: nil, cost: nil, model: meta[:model]}
    phases = Map.update(feature.phases, phase, cell, &%{&1 | state: :active, model: meta[:model]})

    feature = %{feature | current_phase: phase, phases: phases}

    model
    |> put_feature(id, feature)
    |> push_feed(entry(id, phase, :info, "phase #{phase} started"))
  end

  def apply_event(
        model,
        [:speckit, :phase, :stop],
        _measurements,
        %{feature_id: id, phase: phase} = meta
      ) do
    feature = feature_slice(model, id)
    outcome = meta[:outcome]
    cost = meta[:cost] || 0.0

    cell = %{state: :completed, outcome: outcome, cost: cost, model: meta[:model]}
    phases = Map.put(feature.phases, phase, cell)

    feature = %{feature | phases: phases, spend: feature.spend + cost}

    model
    |> put_feature(id, feature)
    |> push_feed(
      entry(id, phase, severity_for_outcome(outcome), "phase #{phase} -> #{inspect(outcome)}")
    )
  end

  def apply_event(
        model,
        [:speckit, :phase, :exception],
        _measurements,
        %{feature_id: id, phase: phase} = meta
      ) do
    feature = feature_slice(model, id)

    default_cell = %{state: :active, outcome: :error, cost: nil, model: meta[:model]}
    phases = Map.update(feature.phases, phase, default_cell, &%{&1 | outcome: :error})

    feature = %{feature | phases: phases}

    model
    |> put_feature(id, feature)
    |> push_feed(entry(id, phase, :error, "phase #{phase} raised #{inspect(meta[:reason])}"))
  end

  def apply_event(
        model,
        [:speckit, :feature, :terminal],
        measurements,
        %{feature_id: id, status: status} = meta
      ) do
    feature = feature_slice(model, id)
    cost_total = measurements[:cost_total] || 0.0
    feature = %{feature | spend: max(feature.spend, cost_total)}

    model
    |> put_feature(id, feature)
    |> push_feed(
      entry(
        id,
        nil,
        severity_for_status(status),
        "feature terminal #{status} (#{inspect(meta[:reason])})"
      )
    )
  end

  def apply_event(model, _event_name, _measurements, _metadata), do: model

  @doc """
  Pure merge of `Coordinator.status/0` (or `nil` when no run is active) +
  `Ledger.snapshot/1` + this projection's own state into the full console
  view state. Shared by seed-on-mount and the reconcile tick.
  """
  @spec merge(map() | nil, map() | nil, t()) :: map()
  def merge(coordinator_status, ledger_snapshot, %{features: features, feed: feed}) do
    per_feature =
      case coordinator_status do
        nil -> %{}
        %{per_feature: per_feature} -> merge_per_feature(per_feature, features)
      end

    %{
      active?: coordinator_status != nil,
      per_feature: per_feature,
      totals: (coordinator_status && coordinator_status[:totals]) || %{},
      inflight: (coordinator_status && coordinator_status[:inflight]) || [],
      finished?: (coordinator_status && coordinator_status[:finished?]) || false,
      report: coordinator_status && coordinator_status[:report],
      ledger: ledger_snapshot,
      feed: feed
    }
  end

  defp merge_per_feature(coordinator_per_feature, projection_features) do
    Map.new(coordinator_per_feature, fn {id, status_slice} ->
      projected = Map.get(projection_features, id, %{current_phase: nil, phases: %{}, spend: 0.0})
      {id, Map.merge(status_slice, projected)}
    end)
  end

  # ---- helpers --------------------------------------------------------

  defp feature_slice(model, id),
    do: Map.get(model.features, id, %{current_phase: nil, phases: %{}, spend: 0.0})

  defp put_feature(model, id, feature),
    do: %{model | features: Map.put(model.features, id, feature)}

  defp push_feed(model, entry), do: %{model | feed: Enum.take([entry | model.feed], @feed_limit)}

  defp entry(feature_id, phase, severity, text) do
    %{
      feature_id: feature_id,
      phase: phase,
      severity: severity,
      text: text,
      at: DateTime.utc_now()
    }
  end

  defp severity_for_outcome(:error), do: :error
  defp severity_for_outcome(_), do: :info

  defp severity_for_status(status) when status in [:escalated, :halted], do: :warn
  defp severity_for_status(:failed), do: :error
  defp severity_for_status(_), do: :info
end
