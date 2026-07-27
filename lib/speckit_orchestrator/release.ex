defmodule SpeckitOrchestrator.Release do
  @moduledoc """
  Pure release policy: given the backlog, current per-feature statuses, the
  concurrency cap, and the breaker state, decide which `:pending` features may
  start next.

  Rules:

  * A tripped breaker releases **nothing** — in-flight features drain and no new
    work starts. (The drain-don't-kill mechanics live in the Coordinator; here
    the breaker simply yields an empty wave.)
  * A feature is *releasable* when it is `:pending` and **every** prereq is
    `:done`.
  * A feature is *blocked* when any prereq is in a non-done terminal state
    (`:escalated`, `:halted`, `:failed`) or is itself blocked — it is not
    releasable and never will be until the prereq is resolved. It is simply not
    returned (status bookkeeping is the Coordinator's job).
  * The wave size is capped: `max(0, cap - in_flight)` features, where
    `in_flight` counts `:running` features. Ties broken by ascending feature id.
  """

  alias SpeckitOrchestrator.Feature

  @blocking_statuses [:escalated, :halted, :failed, :blocked]

  @doc """
  Return the next wave of features to start.

  `statuses` is a map of `feature_id => status`. A feature id absent from the
  map is treated as its struct `status` (normally `:pending`).
  """
  @spec next_wave([Feature.t()], %{String.t() => Feature.status()}, pos_integer(), boolean()) ::
          [Feature.t()]
  def next_wave(features, statuses, cap, breaker_tripped?)
      when is_list(features) and is_map(statuses) and is_integer(cap) do
    if breaker_tripped? do
      []
    else
      slots = max(0, cap - in_flight(features, statuses))

      features
      |> Enum.filter(&releasable?(&1, statuses))
      |> Enum.sort_by(& &1.id)
      |> Enum.take(slots)
    end
  end

  @doc """
  The order a **cap-1** run releases `features` in, as a list of ids.

  At cap 1 the run is strictly sequential, so this projection is exact rather
  than an estimate: replaying `next_wave/4` with `cap: 1`, marking each
  released feature `:done`, reproduces the very policy the Coordinator runs,
  and so can never drift from it.

  Deliberately cap-1 only. At cap > 1 the Coordinator releases as each
  individual feature finishes, not in synchronized batches, so which features
  overlap depends on phase durations that are unknowable up front — any
  "wave N" projection there would be a guess presented as fact.

  Features that can never be released (a prereq stuck in a blocking state)
  are simply absent from the result; the walk stops when nothing more is
  releasable, so it always terminates.
  """
  @spec sequential_order([Feature.t()]) :: [String.t()]
  def sequential_order(features) when is_list(features) do
    sequential_order(features, %{}, [])
  end

  defp sequential_order(features, statuses, acc) do
    case next_wave(features, statuses, 1, false) do
      [] ->
        Enum.reverse(acc)

      [%Feature{id: id}] ->
        sequential_order(features, Map.put(statuses, id, :done), [id | acc])
    end
  end

  @doc "True when `feature` is `:pending` and all prereqs are `:done`."
  @spec releasable?(Feature.t(), %{String.t() => Feature.status()}) :: boolean()
  def releasable?(%Feature{} = feature, statuses) do
    status_of(feature, statuses) == :pending and
      Enum.all?(feature.prereqs, fn id -> Map.get(statuses, id) == :done end)
  end

  @doc """
  True when `feature` can never be released as-is because a prereq is in a
  non-done terminal/blocked state.
  """
  @spec blocked?(Feature.t(), %{String.t() => Feature.status()}) :: boolean()
  def blocked?(%Feature{} = feature, statuses) do
    Enum.any?(feature.prereqs, fn id -> Map.get(statuses, id) in @blocking_statuses end)
  end

  @spec in_flight([Feature.t()], %{String.t() => Feature.status()}) :: non_neg_integer()
  defp in_flight(features, statuses) do
    Enum.count(features, fn f -> status_of(f, statuses) == :running end)
  end

  @spec status_of(Feature.t(), %{String.t() => Feature.status()}) :: Feature.status()
  defp status_of(%Feature{id: id, status: status}, statuses) do
    Map.get(statuses, id, status)
  end
end
