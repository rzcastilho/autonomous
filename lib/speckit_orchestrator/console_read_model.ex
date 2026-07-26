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

  alias SpeckitOrchestrator.Pipeline

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

  @type chunk_cell :: %{
          ordinal: pos_integer() | nil,
          total: pos_integer() | nil,
          title: String.t() | nil,
          attempt: pos_integer(),
          scope: :task_phase | :sweep | :whole_list,
          sessions_used: non_neg_integer() | nil,
          ceiling: pos_integer() | nil,
          remaining: non_neg_integer() | nil,
          outcome: atom() | nil
        }

  @type feature_slice :: %{
          current_phase: atom() | nil,
          phases: %{atom() => phase_cell()},
          spend: number(),
          chunk: chunk_cell() | nil
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
    raw_cost = meta[:cost] || 0.0
    cost = phase_stop_cost(phase, raw_cost, feature)

    cell = %{state: :completed, outcome: outcome, cost: raw_cost, model: meta[:model]}
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
    feature = %{feature | spend: max(feature.spend, cost_total), chunk: nil}

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

  # ---- chunk events (specs/015-implement-phase-chunking) --------------------
  # `ChunkRunner`'s per-chunk `[:speckit, :chunk]` span
  # (contracts/telemetry-chunk.md §2-3): folds the current task-phase/sweep
  # position into the feature slice and emits one feed entry per boundary.

  def apply_event(
        model,
        [:speckit, :chunk, :start],
        _measurements,
        %{feature_id: id} = meta
      ) do
    feature = feature_slice(model, id)
    previous = feature.chunk
    feature = %{feature | chunk: chunk_from_start_meta(meta)}

    model
    |> put_feature(id, feature)
    |> push_feed(start_feed_entry(id, previous, meta))
  end

  def apply_event(
        model,
        [:speckit, :chunk, :stop],
        _measurements,
        %{feature_id: id, outcome: outcome} = meta
      ) do
    feature = feature_slice(model, id)
    cost = meta[:cost] || 0.0

    feature = %{
      feature
      | spend: feature.spend + cost,
        chunk_cost_seen: feature.chunk_cost_seen + cost
    }

    model
    |> put_feature(id, feature)
    |> push_feed(stop_feed_entry(id, feature.chunk, meta, outcome))
  end

  def apply_event(
        model,
        [:speckit, :chunk, :exception],
        _measurements,
        %{feature_id: id} = meta
      ) do
    feature = feature_slice(model, id)
    chunk = feature.chunk && Map.put(feature.chunk, :outcome, :error)
    feature = %{feature | chunk: chunk}

    model
    |> put_feature(id, feature)
    |> push_feed(entry(id, :implement, :error, "chunk exception: #{inspect(meta[:reason])}"))
  end

  def apply_event(model, [:speckit, :chunk, :resolved], _measurements, %{match_kind: :number}),
    do: model

  def apply_event(
        model,
        [:speckit, :chunk, :resolved],
        _measurements,
        %{feature_id: id, match_kind: match_kind}
      ) do
    push_feed(model, entry(id, :implement, :warn, resolved_feed_text(match_kind)))
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

  @doc """
  Overlay a durable run manifest's last-known per-feature statuses (and, where
  available, each feature's checkpointed phase progress) onto an
  otherwise-empty `per_feature` (no live `Coordinator` — fresh boot, crash not
  yet resumed). `ConsoleProjection` never persists (FR-036,
  `specs/008-control-plane`), so without this a restarted node's Mission
  Control/Pipeline DAG would default every feature to `:pending`, silently
  hiding e.g. a feature that halted before the crash — and, even once the
  status is shown, its phase timeline would render as if nothing had run at
  all. A no-op when the view is `active?` (a live `Coordinator` always wins)
  or `manifest_record` is `nil`/missing `"statuses"` (no manifest, or a
  corrupt one — the caller already logged/handled that).

  `checkpoints` maps `feature_id => Checkpoint.read/1`'s result (or is simply
  omitted/absent for an id — e.g. a `:pending` feature never released has no
  checkpoint). Its `"last_phase"` becomes the boundary between `:completed`
  cells (every phase before it) and the current one: `:active` colored by the
  diverted status when the checkpoint's own `"status"` is
  `:escalated`/`:halted`/`:failed` (mirrors `FeatureDrawerComponent`'s/
  `phase_strip`'s existing status-coloring rule), or `:completed` when the
  checkpoint is an in-progress crash pointer (`last_phase` is the phase that
  had just *finished*, per `Checkpoint`'s write-timing contract). See
  `specs/009-crash-recovery`.
  """
  @spec overlay_last_known_statuses(map(), map() | nil, %{String.t() => term()}) :: map()
  def overlay_last_known_statuses(view, manifest_record, checkpoints \\ %{})

  def overlay_last_known_statuses(%{active?: true} = view, _manifest_record, _checkpoints),
    do: view

  def overlay_last_known_statuses(view, %{"statuses" => statuses}, checkpoints)
      when is_map(statuses) do
    per_feature =
      Enum.reduce(statuses, view.per_feature, fn {id, status}, acc ->
        last_known_status = last_known_status(status)

        Map.put_new(acc, id, %{
          status: last_known_status,
          elapsed_ms: nil,
          slug: nil,
          prereqs: [],
          current_phase: checkpoint_phase(checkpoints, id),
          phases: checkpoint_phases(checkpoints, id, last_known_status),
          spend: 0.0,
          chunk: checkpoint_chunk(checkpoints, id)
        })
      end)

    %{view | per_feature: per_feature}
  end

  def overlay_last_known_statuses(view, _manifest_record, _checkpoints), do: view

  defp checkpoint_phase(checkpoints, id) do
    with {:ok, record} <- Map.get(checkpoints, id),
         {:ok, phase} <- Pipeline.parse(record["last_phase"]) do
      phase
    else
      _ -> nil
    end
  end

  defp checkpoint_phases(checkpoints, id, status) do
    case checkpoint_phase(checkpoints, id) do
      nil ->
        %{}

      last_phase ->
        {before, [_ | _after]} = Enum.split_while(Pipeline.phases(), &(&1 != last_phase))

        completed =
          Map.new(before, &{&1, %{state: :completed, outcome: nil, cost: nil, model: nil}})

        Map.put(completed, last_phase, last_phase_cell(status))
    end
  end

  # Seeds `chunk` for an inactive run's implement cell from the checkpoint's
  # `implement_chunk` (contracts/checkpoint-implement-chunk.md). `attempt`
  # isn't part of that durable record (it's meaningless at rest between
  # sessions), so it's fixed at `1` — no "(attempt N)" suffix on a dead run.
  defp checkpoint_chunk(checkpoints, id) do
    with {:ok, record} <- Map.get(checkpoints, id),
         %{"implement_chunk" => %{} = chunk} <- record do
      %{
        ordinal: Map.get(chunk, "ordinal"),
        total: Map.get(chunk, "total"),
        title: Map.get(chunk, "title"),
        attempt: 1,
        scope: chunk_scope_atom(Map.get(chunk, "scope")),
        sessions_used: Map.get(chunk, "sessions_used"),
        ceiling: Map.get(chunk, "ceiling"),
        remaining: nil,
        outcome: nil
      }
    else
      _ -> nil
    end
  end

  defp chunk_scope_atom("task_phase"), do: :task_phase
  defp chunk_scope_atom("sweep"), do: :sweep
  defp chunk_scope_atom("whole_list"), do: :whole_list
  defp chunk_scope_atom(_other), do: nil

  defp last_phase_cell(status) when status in [:escalated, :halted, :failed],
    do: %{state: :active, outcome: status, cost: nil, model: nil}

  defp last_phase_cell(_status), do: %{state: :completed, outcome: nil, cost: nil, model: nil}

  # Explicit mapping over the fixed, known status vocabulary — never
  # `String.to_atom/1` on file-sourced content (atom-table safety; mirrors
  # `RunManifest.reconstruct/1`'s guard), but unlike `reconstruct/1` this is
  # display-only, so "running"/"pending" are shown as-is rather than reset.
  defp last_known_status("pending"), do: :pending
  defp last_known_status("running"), do: :running
  defp last_known_status("done"), do: :done
  defp last_known_status("escalated"), do: :escalated
  defp last_known_status("halted"), do: :halted
  defp last_known_status("failed"), do: :failed
  defp last_known_status("blocked"), do: :blocked
  defp last_known_status(_other), do: :pending

  defp merge_per_feature(coordinator_per_feature, projection_features) do
    Map.new(coordinator_per_feature, fn {id, status_slice} ->
      projected =
        Map.get(projection_features, id, %{
          current_phase: nil,
          phases: %{},
          spend: 0.0,
          chunk: nil
        })

      {id, Map.merge(status_slice, projected)}
    end)
  end

  # ---- helpers --------------------------------------------------------

  defp feature_slice(model, id),
    do:
      Map.get(model.features, id, %{
        current_phase: nil,
        phases: %{},
        spend: 0.0,
        chunk: nil,
        chunk_cost_seen: 0.0
      })

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

  # A chunked implement step's own [:speckit, :chunk, :stop] events already
  # added each chunk's cost to `spend` — the wrapping [:speckit, :phase,
  # :stop] for :implement must add only what those chunks haven't accounted
  # for yet, or the console would double-count (contracts/telemetry-chunk.md
  # §2).
  defp phase_stop_cost(:implement, raw_cost, feature),
    do: max(0.0, raw_cost - feature.chunk_cost_seen)

  defp phase_stop_cost(_phase, raw_cost, _feature), do: raw_cost

  defp severity_for_outcome(:error), do: :error
  defp severity_for_outcome(_), do: :info

  defp severity_for_status(status) when status in [:escalated, :halted], do: :warn
  defp severity_for_status(:failed), do: :error
  defp severity_for_status(_), do: :info

  # ---- chunk fold helpers (contracts/telemetry-chunk.md §2-3) ---------------

  # `:whole_list` still sets `chunk` (so `overlay`/drawer callers can tell a
  # feature is mid-implement), but `phase_strip` treats it identically to
  # `nil` — FR-019's "no empty or misleading task-phase indicator" is a
  # rendering rule, not an absence-of-data rule.
  defp chunk_from_start_meta(meta) do
    %{
      ordinal: meta[:ordinal],
      total: meta[:total],
      title: meta[:title],
      attempt: meta[:attempt],
      scope: meta[:scope],
      sessions_used: meta[:sessions_used],
      ceiling: meta[:ceiling],
      remaining: meta[:remaining],
      outcome: nil
    }
  end

  defp start_feed_entry(id, previous, %{scope: :task_phase, attempt: 1} = meta) do
    text =
      case previous do
        %{scope: :task_phase} = prev ->
          "task-phase #{prev.ordinal}/#{prev.total} #{qtitle(prev.title)} complete → " <>
            "#{meta.ordinal}/#{meta.total} #{qtitle(meta.title)}"

        _ ->
          "task-phase #{meta.ordinal}/#{meta.total} #{qtitle(meta.title)} started"
      end

    entry(id, :implement, :info, text)
  end

  defp start_feed_entry(id, _previous, %{scope: :task_phase, attempt: attempt} = meta) do
    text =
      "task-phase #{meta.ordinal}/#{meta.total} #{qtitle(meta.title)} continuing " <>
        "(attempt #{attempt})"

    entry(id, :implement, :warn, text)
  end

  defp start_feed_entry(id, _previous, %{scope: :sweep} = meta) do
    entry(id, :implement, :warn, "sweep session over #{meta[:remaining]} remaining tasks")
  end

  defp start_feed_entry(id, _previous, %{scope: :whole_list}) do
    entry(id, :implement, :info, "implement started")
  end

  defp stop_feed_entry(id, %{scope: :task_phase} = chunk, meta, outcome) do
    text =
      "task-phase #{chunk.ordinal}/#{chunk.total} #{qtitle(chunk.title)} → #{outcome} " <>
        "(#{meta[:completed_before]}→#{meta[:completed_after]} tasks)"

    entry(id, :implement, chunk_stop_severity(outcome), text)
  end

  defp stop_feed_entry(id, %{scope: :sweep}, meta, outcome) do
    text = "sweep → #{outcome} (#{meta[:completed_before]}→#{meta[:completed_after]} tasks)"
    entry(id, :implement, chunk_stop_severity(outcome), text)
  end

  defp stop_feed_entry(id, _chunk, meta, outcome) do
    text = "implement → #{outcome} (#{meta[:completed_before]}→#{meta[:completed_after]} tasks)"
    entry(id, :implement, chunk_stop_severity(outcome), text)
  end

  defp chunk_stop_severity(:exhausted), do: :warn
  defp chunk_stop_severity(outcome), do: severity_for_outcome(outcome)

  defp resolved_feed_text(:title),
    do: "resumed task-phase located by title — task list was renumbered"

  defp resolved_feed_text(:ordinal),
    do: "resumed task-phase located by ordinal — task list was renumbered"

  defp resolved_feed_text(:fallback),
    do: "resumed task-phase located by fallback — recorded task-phase not found"

  defp qtitle(title), do: "\"#{title}\""
end
