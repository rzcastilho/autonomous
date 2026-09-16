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

  alias SpeckitOrchestrator.ConsoleHydration

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

  @type remediation_cell :: %{
          attempt: pos_integer(),
          limit: pos_integer(),
          threshold: atom(),
          findings: non_neg_integer(),
          outcome: :ok | :error | nil
        }

  @type feature_slice :: %{
          current_phase: atom() | nil,
          phases: %{atom() => phase_cell()},
          spend: number(),
          chunk: chunk_cell() | nil,
          remediation: remediation_cell() | nil,
          pr_url: String.t() | nil
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
  :terminal]`, `[:speckit, :chunk, :start/:stop/:exception/:resolved]`,
  `[:speckit, :remediation, :start/:stop/:exception]`,
  `[:speckit, :run, :scope_narrowing_refused]`, and
  `[:speckit, :publish, :opened/:failed]`. Any other event passes through
  unchanged.
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
    feature = %{feature | spend: max(feature.spend, cost_total), chunk: nil, remediation: nil}

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

  # ---- auto-remediation events (specs/017-analyze-auto-remediation) ---------
  # `AnalyzeRunner`'s per-attempt `[:speckit, :remediation]` span
  # (contracts/telemetry-console.md §2): folds the current attempt into the
  # feature slice and emits one feed entry per attempt boundary. The slice is
  # the analyze-step analogue of `chunk` — same shape of concept, so
  # `phase_strip` renders it through the same sub-label slot.
  #
  # No double counting: the remediation span and the analyze phase span never
  # describe the same harness run, so cost is added plainly here and plainly in
  # `[:speckit, :phase, :stop]` — no `chunk_cost_seen`-style guard is needed.

  def apply_event(
        model,
        [:speckit, :remediation, :start],
        _measurements,
        %{feature_id: id} = meta
      ) do
    feature = feature_slice(model, id)
    feature = %{feature | remediation: remediation_from_start_meta(meta)}

    text =
      "auto-remediation attempt #{meta[:attempt]}/#{meta[:limit]} — " <>
        "#{meta[:findings_count]} findings ≥ #{meta[:threshold]}"

    model
    |> put_feature(id, feature)
    |> push_feed(entry(id, :analyze, :info, text))
  end

  def apply_event(
        model,
        [:speckit, :remediation, :stop],
        _measurements,
        %{feature_id: id} = meta
      ) do
    feature = feature_slice(model, id)
    outcome = meta[:outcome]
    cost = meta[:cost] || 0.0

    remediation = feature.remediation && Map.put(feature.remediation, :outcome, outcome)
    feature = %{feature | spend: feature.spend + cost, remediation: remediation}

    text = "auto-remediation attempt #{meta[:attempt]}/#{meta[:limit]} → #{outcome}"

    model
    |> put_feature(id, feature)
    |> push_feed(entry(id, :analyze, severity_for_outcome(outcome), text))
  end

  def apply_event(
        model,
        [:speckit, :remediation, :exception],
        _measurements,
        %{feature_id: id} = meta
      ) do
    feature = feature_slice(model, id)
    remediation = feature.remediation && Map.put(feature.remediation, :outcome, :error)
    feature = %{feature | remediation: remediation}

    model
    |> put_feature(id, feature)
    |> push_feed(
      entry(id, :analyze, :error, "auto-remediation exception: #{inspect(meta[:reason])}")
    )
  end

  # ---- run-level guard refusal (specs/016-resume-backlog-scope) -------------

  def apply_event(
        model,
        [:speckit, :run, :scope_narrowing_refused],
        _measurements,
        %{dropped: dropped}
      ) do
    push_feed(
      model,
      entry(nil, nil, :warn, "scope narrowing refused — would drop #{Enum.join(dropped, ", ")}")
    )
  end

  # ---- publish (019, FR-018) -------------------------------------------------
  # A completed feature's PR publish can fail without failing the run — the
  # local branch still becomes the next base regardless — but the failure
  # must never be merely swallowed: it shows up here on the live feed. The
  # success carries the URL so the drawer can link straight to the PR while
  # the run is still live, without a store read.

  def apply_event(
        model,
        [:speckit, :publish, :opened],
        _measurements,
        %{feature_id: id, url: url}
      ) do
    model
    |> put_feature(id, %{feature_slice(model, id) | pr_url: url})
    |> push_feed(entry(id, nil, :info, "PR opened: #{url}"))
  end

  def apply_event(
        model,
        [:speckit, :publish, :failed],
        _measurements,
        %{feature_id: id, reason: reason}
      ) do
    push_feed(model, entry(id, nil, :warn, "PR publish failed: #{inspect(reason)}"))
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
      observed: features,
      totals: (coordinator_status && coordinator_status[:totals]) || %{},
      inflight: (coordinator_status && coordinator_status[:inflight]) || [],
      finished?: (coordinator_status && coordinator_status[:finished?]) || false,
      report: coordinator_status && coordinator_status[:report],
      ledger: ledger_snapshot,
      feed: feed
    }
  end

  @doc """
  Hydrate `view.per_feature` from a durable run record (023,
  contracts/console-hydration.md §5) — in **both** modes, replacing the old
  `overlay_last_known_statuses/2` (which was a no-op the moment a live
  `Coordinator` existed). `ConsoleProjection` never persists (FR-036,
  `specs/008-control-plane`), and neither the Coordinator nor the projection
  remembers a finished feature's full phase history across a restart — only
  the record does.

  With a live `Coordinator` (`view.active? == true`), only the feature ids
  already in `view.per_feature` are hydrated (a feature present in the record
  but not released by this Coordinator is never added, FR-008); each row is
  `ConsoleHydration.layer(from_record(...), live_row)`. Without one, rows are
  built from the record via `Map.put_new` (never overwriting an existing
  entry) and then still pass through `overlay_observed/1`. `run_detail ==
  nil`, or a `run_detail` whose `:features` is not a list, leaves the view
  unchanged (aside from `overlay_observed/1` in the inactive case).
  """
  @spec hydrate(map(), map() | nil, DateTime.t()) :: map()
  def hydrate(view, run_detail, now)

  def hydrate(%{active?: true} = view, run_detail, now) do
    features_by_id = Map.new(run_detail_features(run_detail), &{&1.feature_id, &1})
    cost_entries = run_detail_cost_entries(run_detail)

    per_feature =
      Map.new(view.per_feature, fn {id, live_row} ->
        recorded =
          case Map.get(features_by_id, id) do
            nil -> nil
            feature -> ConsoleHydration.from_record(feature, cost_entries, now)
          end

        {id, ConsoleHydration.layer(recorded, live_row)}
      end)

    %{view | per_feature: per_feature}
  end

  def hydrate(view, run_detail, now) do
    case run_detail_features(run_detail) do
      [] ->
        overlay_observed(view)

      features ->
        cost_entries = run_detail_cost_entries(run_detail)

        per_feature =
          Enum.reduce(features, view.per_feature, fn f, acc ->
            row = ConsoleHydration.layer(ConsoleHydration.from_record(f, cost_entries, now), nil)
            Map.put_new(acc, f.feature_id, row)
          end)

        overlay_observed(%{view | per_feature: per_feature})
    end
  end

  defp run_detail_features(%{features: features}) when is_list(features), do: features
  defp run_detail_features(_run_detail), do: []

  defp run_detail_cost_entries(%{cost_entries: entries}) when is_list(entries), do: entries
  defp run_detail_cost_entries(_run_detail), do: []

  @doc """
  Let live telemetry outrank a stale recorded status when there is no
  `Coordinator` to ask.

  The store's status is the *last recorded* one, which is only the truth while
  nothing is running. A feature's `FeatureRunner` is a `RunnerSup` task with a
  life of its own — by design, so a Coordinator going away drains rather than
  kills — so phases can genuinely be running with no Coordinator to report
  them. `merge/3` had nothing to put in `per_feature` in that case and the
  overlay filled it from the record, so the console showed a feature's last
  terminal status (`:failed`) while its telemetry streamed successful phases.

  Only claims `:running`, and only for a feature whose newest phase cell is
  actually `:active` — a projection that merely remembers finished phases from
  earlier in the session never resurrects a terminal feature. Everything the
  projection knows better than the record (phase timeline, spend, chunk,
  remediation, PR url) is merged over the recorded entry.
  """
  @spec overlay_observed(map()) :: map()
  def overlay_observed(%{active?: true} = view), do: view

  def overlay_observed(%{observed: observed} = view) when is_map(observed) do
    per_feature =
      Enum.reduce(observed, view.per_feature, fn {id, slice}, acc ->
        if phase_in_flight?(slice) do
          recorded = Map.get(acc, id, %{})

          layered =
            recorded |> ConsoleHydration.layer(known(slice)) |> Map.put(:status, :running)

          Map.put(acc, id, layered)
        else
          acc
        end
      end)

    %{view | per_feature: per_feature}
  end

  def overlay_observed(view), do: view

  defp phase_in_flight?(%{phases: phases}) when is_map(phases),
    do: Enum.any?(phases, fn {_phase, cell} -> cell[:state] == :active end)

  defp phase_in_flight?(_slice), do: false

  # A `nil` in the projection means "never saw one", not "there isn't one" —
  # letting it win would blank a `pr_url` the record does know. `chunk_cost_seen`
  # is the fold's own bookkeeping and has no business in a rendered slice.
  defp known(slice) do
    slice
    |> Map.drop([:chunk_cost_seen])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The parked-run projection (019, contracts/parked-run.md § 6): `state`,
  `stopped_by`, `stopped_reason` from a `SpeckitOrchestrator.run_detail/1`
  (or `current_run_detail`-shaped) map. Sourced from the store directly
  (`run.state`/`stopped_by`/`stopped_reason`, already present on every run
  summary) rather than gated on `active?` — a `:parked` run's Coordinator
  process is normally still alive (it parks on drain, it does not exit), but
  this must also read correctly after a cold boot with no live Coordinator
  at all, so callers compute it unconditionally alongside (not inside)
  `merge/3`/`overlay_last_known_statuses/2`.
  """
  @spec run_state(map() | nil) :: %{
          state: atom() | nil,
          stopped_by: String.t() | nil,
          stopped_reason: term()
        }
  def run_state(nil), do: %{state: nil, stopped_by: nil, stopped_reason: nil}

  def run_state(%{run: run}) do
    %{state: run.state, stopped_by: run.stopped_by, stopped_reason: run.stopped_reason}
  end

  defp merge_per_feature(coordinator_per_feature, projection_features) do
    Map.new(coordinator_per_feature, fn {id, status_slice} ->
      projected =
        Map.get(projection_features, id, %{
          current_phase: nil,
          phases: %{},
          spend: 0.0,
          chunk: nil,
          remediation: nil,
          pr_url: nil
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
        chunk_cost_seen: 0.0,
        remediation: nil,
        pr_url: nil
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

  # ---- remediation fold helpers (contracts/telemetry-console.md §2) ---------

  defp remediation_from_start_meta(meta) do
    %{
      attempt: meta[:attempt],
      limit: meta[:limit],
      threshold: meta[:threshold],
      findings: meta[:findings_count],
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
