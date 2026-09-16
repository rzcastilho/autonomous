defmodule SpeckitOrchestrator.ConsoleHydration do
  @moduledoc """
  Pure hydration of one console row from a durable run record
  (`specs/023-console-restart-hydration/contracts/console-hydration.md`). No
  Mnesia, Phoenix, Coordinator, or `:telemetry` dependency — `now` is always
  an injected parameter (Principle I, FR-012).

  `from_record/3` turns one recorded feature + the run's cost entries into a
  `recorded_slice()`; `layer/2` combines that with a live slice (Coordinator
  status ∪ `ConsoleReadModel` projection, or `nil`) under the seed/reconcile
  precedence table (§3); `apply_update/2` applies the same table's update
  column to an already-hydrated row for a `:feature_updated` broadcast — the
  one that must never blank a hydrated row (FR-011, SC-004).
  """

  alias SpeckitOrchestrator.Pipeline

  @type phase_cell :: %{
          state: :active | :completed,
          outcome: term(),
          cost: number() | nil,
          model: String.t() | nil
        }

  @type chunk_cell :: map()

  @type recorded_slice :: %{
          status: atom(),
          slug: String.t() | nil,
          group: atom() | nil,
          spec_number: pos_integer() | nil,
          current_phase: atom() | nil,
          phases: %{atom() => phase_cell()},
          spend: float(),
          elapsed_ms: non_neg_integer() | nil,
          chunk: chunk_cell() | nil,
          remediation: nil,
          pr_url: String.t() | nil
        }

  @type row :: map()

  @diverted [:escalated, :halted, :failed]

  @default_row %{
    status: :pending,
    elapsed_ms: nil,
    slug: nil,
    group: nil,
    spec_number: nil,
    current_phase: nil,
    phases: %{},
    spend: 0.0,
    chunk: nil,
    remediation: nil,
    pr_url: nil
  }

  # ---- 1. from_record/3 -----------------------------------------------------

  @doc """
  Builds one feature's recorded contribution to a console row
  (contracts/console-hydration.md §1). `recorded_feature` is one element of
  `SpeckitOrchestrator.run_detail/1`'s `:features` list; `cost_entries` is
  that run detail's `:cost_entries`. Every field is read with `Map.get` —
  a record missing any of them never raises (FR-013).
  """
  @spec from_record(map(), [map()], DateTime.t()) :: recorded_slice()
  def from_record(recorded_feature, cost_entries, now) do
    phase_attempts = Map.get(recorded_feature, :phase_attempts) || []
    checkpoint = Map.get(recorded_feature, :checkpoint)
    status = Map.get(recorded_feature, :status)
    current_phase = checkpoint_phase(checkpoint)

    phases =
      phase_attempts
      |> last_attempt_per_phase()
      |> trim_after_phase(current_phase)
      |> mark_diverted(status, current_phase)

    %{
      status: status,
      slug: Map.get(recorded_feature, :slug),
      group: Map.get(recorded_feature, :group),
      spec_number: Map.get(recorded_feature, :spec_number),
      current_phase: current_phase,
      phases: phases,
      spend: spend_for(phase_attempts, cost_entries || []),
      elapsed_ms: elapsed_for(recorded_feature, now),
      chunk: checkpoint_chunk(checkpoint),
      remediation: nil,
      pr_url: Map.get(recorded_feature, :pr_url)
    }
  end

  defp last_attempt_per_phase(phase_attempts) do
    ordered = MapSet.new(Pipeline.phases())

    Enum.reduce(phase_attempts, %{}, fn attempt, acc ->
      phase = Map.get(attempt, :phase)

      if MapSet.member?(ordered, phase) do
        Map.put(acc, phase, %{
          state: :completed,
          outcome: Map.get(attempt, :outcome),
          cost: Map.get(attempt, :cost_usd),
          model: Map.get(attempt, :model)
        })
      else
        acc
      end
    end)
  end

  defp trim_after_phase(phases, nil), do: phases
  defp trim_after_phase(phases, current_phase), do: Map.drop(phases, later_phases(current_phase))

  defp mark_diverted(phases, status, current_phase)
       when status in @diverted and not is_nil(current_phase) do
    existing = Map.get(phases, current_phase, %{})

    Map.put(phases, current_phase, %{
      state: :active,
      outcome: status,
      cost: Map.get(existing, :cost),
      model: Map.get(existing, :model)
    })
  end

  defp mark_diverted(phases, _status, _current_phase), do: phases

  defp spend_for(phase_attempts, cost_entries) do
    attempt_ids = MapSet.new(phase_attempts, &Map.get(&1, :attempt_id))

    cost_entries
    |> Enum.filter(&MapSet.member?(attempt_ids, Map.get(&1, :id)))
    |> Enum.reduce(0.0, &(Map.get(&1, :amount_usd) + &2))
  end

  defp elapsed_for(recorded_feature, now) do
    case Map.get(recorded_feature, :started_at) do
      nil ->
        nil

      started_at ->
        ended_at = Map.get(recorded_feature, :ended_at) || now
        DateTime.diff(ended_at, started_at, :millisecond)
    end
  end

  defp checkpoint_phase(nil), do: nil
  defp checkpoint_phase(checkpoint), do: Map.get(checkpoint, :last_completed_phase)

  # Attempt fixed at 1: not part of the durable record (meaningless at rest
  # between sessions), so no "(attempt N)" suffix on a resumed/dead run.
  defp checkpoint_chunk(%{implement_chunk: %{} = chunk}) do
    %{
      ordinal: Map.get(chunk, :ordinal),
      total: Map.get(chunk, :total),
      title: Map.get(chunk, :title),
      attempt: 1,
      scope: Map.get(chunk, :scope),
      sessions_used: Map.get(chunk, :sessions_used),
      ceiling: Map.get(chunk, :ceiling),
      remaining: nil,
      outcome: nil
    }
  end

  defp checkpoint_chunk(_checkpoint), do: nil

  # ---- 2-3. layer/2 + precedence table --------------------------------------

  @doc """
  Layers a live slice (a Coordinator/projection row, or `nil`) over a
  recorded slice (`from_record/3`'s output, or `nil`), per the seed/reconcile
  column of contracts/console-hydration.md §3. At least one argument is
  expected non-`nil`; either may be `nil` without raising.
  """
  @spec layer(recorded_slice() | nil, map() | nil) :: row()
  def layer(recorded, live) do
    recorded = recorded || %{}
    live = live || %{}

    live_phases = Map.get(live, :phases) || %{}
    record_phases = Map.get(recorded, :phases) || %{}
    merged_phases = trim_after_active(Map.merge(record_phases, live_phases), live_phases)

    current_phase =
      active_phase_in(live_phases) || Map.get(live, :current_phase) ||
        Map.get(recorded, :current_phase)

    %{
      status: Map.get(live, :status) || Map.get(recorded, :status),
      slug: not_nil_or(Map.get(live, :slug), Map.get(recorded, :slug)),
      group: not_nil_or(Map.get(live, :group), Map.get(recorded, :group)),
      spec_number: not_nil_or(Map.get(live, :spec_number), Map.get(recorded, :spec_number)),
      current_phase: current_phase,
      phases: merged_phases,
      spend: max(Map.get(recorded, :spend) || 0.0, Map.get(live, :spend) || 0.0),
      elapsed_ms: Map.get(recorded, :elapsed_ms) || Map.get(live, :elapsed_ms),
      pr_url: not_nil_or(Map.get(live, :pr_url), Map.get(recorded, :pr_url)),
      chunk: not_nil_or(Map.get(live, :chunk), Map.get(recorded, :chunk)),
      remediation: Map.get(live, :remediation)
    }
  end

  # ---- 4. apply_update/2 -----------------------------------------------------

  @doc """
  Applies a `:feature_updated` live slice to an already-hydrated row, per the
  update column of contracts/console-hydration.md §3-4. `update == nil`
  returns `row` unchanged; a `nil` row (a feature id not seen yet) starts
  from the documented default shape.
  """
  @spec apply_update(row() | nil, map() | nil) :: row()
  def apply_update(row, nil), do: row

  def apply_update(nil, update), do: apply_update(@default_row, update)

  def apply_update(row, update) do
    update_phases = Map.get(update, :phases) || %{}
    row_phases = Map.get(row, :phases) || %{}
    merged_phases = trim_after_active(Map.merge(row_phases, update_phases), update_phases)

    Map.merge(row, %{
      status: Map.get(update, :status, Map.get(row, :status)),
      phases: merged_phases,
      current_phase: pick_present(update, :current_phase, row),
      spend: max(Map.get(row, :spend) || 0.0, Map.get(update, :spend) || 0.0),
      pr_url: not_nil_or(Map.get(update, :pr_url), Map.get(row, :pr_url)),
      chunk: pick_present(update, :chunk, row),
      remediation: pick_present(update, :remediation, row)
    })
  end

  # ---- shared helpers ---------------------------------------------------

  defp pick_present(map, key, fallback_map) do
    if Map.has_key?(map, key), do: Map.get(map, key), else: Map.get(fallback_map, key)
  end

  defp not_nil_or(nil, fallback), do: fallback
  defp not_nil_or(value, _fallback), do: value

  defp trim_after_active(phases, source_phases) do
    case active_phase_in(source_phases) do
      nil -> phases
      active -> Map.drop(phases, later_phases(active))
    end
  end

  defp active_phase_in(phases) do
    Enum.find_value(phases, fn {phase, cell} -> if cell[:state] == :active, do: phase end)
  end

  defp later_phases(phase) do
    ordered = Pipeline.phases()

    case Enum.find_index(ordered, &(&1 == phase)) do
      nil -> []
      idx -> Enum.drop(ordered, idx + 1)
    end
  end
end
