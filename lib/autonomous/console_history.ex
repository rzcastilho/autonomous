defmodule Autonomous.ConsoleHistory do
  @moduledoc """
  Pure rebuild of the console read-model from one durable run record
  (`specs/038-console-projection-resilience/contracts/console-projection-resilience.md` §4).

  A restarted `ConsoleProjection` starts empty; this folds the recorded facts
  (run start, phase attempts, terminal status, PR url) back into the same feed
  texts the live fold writes, so the feed and the per-feature slices survive
  the restart. Only recorded facts are used — a record missing a timestamp
  yields no entry, never one stamped "now". No Mnesia, Phoenix, Coordinator,
  or `:telemetry` dependency.
  """

  alias Autonomous.{ConsoleHydration, ConsoleReadModel, Pipeline}

  @slice_keys [:current_phase, :phases, :spend, :windows, :chunk, :remediation, :pr_url]
  @terminal [:done, :escalated, :halted, :failed]

  @doc "Rebuild the read-model from `run_detail` (`nil` → an empty model)."
  @spec rebuild(map() | nil) :: ConsoleReadModel.t()
  @spec rebuild(map() | nil, DateTime.t()) :: ConsoleReadModel.t()
  def rebuild(run_detail, now \\ DateTime.utc_now())

  def rebuild(%{run: run, features: [_ | _] = features} = detail, now) do
    cost_entries = Map.get(detail, :cost_entries) || []

    entries =
      (run_entries(run) ++ Enum.flat_map(features, &feature_entries/1))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.take(-ConsoleReadModel.feed_limit())
      |> Enum.map(&elem(&1, 1))

    %{
      ConsoleReadModel.new()
      | features: Map.new(features, &{&1.feature_id, slice(&1, cost_entries, now)}),
        feed: Enum.reverse(entries),
        run_key: run.key,
        rebuilt_keys: MapSet.new(entries, &{&1.feature_id, &1.phase, &1.text})
    }
  end

  def rebuild(_detail, _now), do: ConsoleReadModel.new()

  defp slice(feature, cost_entries, now) do
    feature
    |> ConsoleHydration.from_record(cost_entries, now)
    |> Map.take(@slice_keys)
    |> Map.put(:chunk_cost_seen, 0.0)
  end

  # ---- entries: {{at, rank, feature_id}, entry} -------------------------------

  defp run_entries(%{started_at: %DateTime{} = at}),
    do: [tag(at, 0, entry(nil, nil, :info, "run started", at))]

  defp run_entries(_run), do: []

  defp feature_entries(feature) do
    id = feature.feature_id
    attempts = Map.get(feature, :phase_attempts) || []
    phases = MapSet.new(Pipeline.phases())

    attempt_entries =
      attempts
      |> Enum.filter(&MapSet.member?(phases, Map.get(&1, :phase)))
      |> Enum.flat_map(&attempt_entries(id, &1))

    attempt_entries ++ terminal_entries(id, feature)
  end

  defp attempt_entries(id, attempt) do
    phase = attempt.phase
    outcome = Map.get(attempt, :outcome)

    started =
      case Map.get(attempt, :started_at) do
        %DateTime{} = at ->
          [tag(at, 1, entry(id, phase, :info, "phase #{phase} started", at), id)]

        _ ->
          []
      end

    stopped =
      case Map.get(attempt, :ended_at) do
        %DateTime{} = at when not is_nil(outcome) ->
          severity = ConsoleReadModel.severity_for_outcome(outcome)

          [
            tag(
              at,
              2,
              entry(id, phase, severity, "phase #{phase} -> #{inspect(outcome)}", at),
              id
            )
          ]

        _ ->
          []
      end

    started ++ stopped
  end

  defp terminal_entries(id, %{status: status, ended_at: %DateTime{} = at} = feature)
       when status in @terminal do
    text = "feature terminal #{status} (#{inspect(Map.get(feature, :terminal_reason))})"
    severity = ConsoleReadModel.severity_for_status(status)

    terminal = [tag(at, 3, entry(id, nil, severity, text, at), id)]

    case Map.get(feature, :pr_url) do
      url when is_binary(url) ->
        terminal ++ [tag(at, 4, entry(id, nil, :info, "PR opened: #{url}", at), id)]

      _ ->
        terminal
    end
  end

  defp terminal_entries(_id, _feature), do: []

  defp entry(feature_id, phase, severity, text, at),
    do: %{feature_id: feature_id, phase: phase, severity: severity, text: text, at: at}

  defp tag(at, rank, entry, id \\ ""), do: {{DateTime.to_unix(at, :microsecond), rank, id}, entry}

  defp sort_key({key, _entry}), do: key
end
