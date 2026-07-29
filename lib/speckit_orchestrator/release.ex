defmodule SpeckitOrchestrator.Release do
  @moduledoc """
  Pure release policy for a stacked sequential run (contracts/release-policy.md).
  No process state, no IO, no Mnesia, no harness (Principle I) — the direct
  analogue of `Pipeline.next/3` for the run level: this is the whole decision
  surface for "what runs next".

  One feature runs at a time, in ascending numeric order (backlog), then
  ad-hoc features by creation time. There is no cap parameter — one-at-a-time
  is rule 3 of `next/3`, structural rather than configured (FR-006, R10).
  """

  alias SpeckitOrchestrator.Feature

  @doc """
  The total order: `:backlog` features first, ascending by `number`; then
  `:ad_hoc` features, ascending by `{created_at, number}`. Deterministic,
  independent of input list order (FR-027).
  """
  @spec order([Feature.t()]) :: [Feature.t()]
  def order(features) when is_list(features) do
    {backlog, ad_hoc} = Enum.split_with(features, &(&1.group == :backlog))

    Enum.sort_by(backlog, & &1.number) ++
      Enum.sort_by(ad_hoc, &{&1.created_at, &1.number})
  end

  @doc """
  Decide what happens next, given the run's `features`, a `feature_id =>
  status` map (a feature absent from the map uses its struct `status`), and
  whether the cost breaker is tripped.

  Rules, in evaluation order:

  1. breaker tripped ⇒ `:none` (Principle IV — drain, don't kill)
  2. any feature `:escalated`/`:halted`/`:failed` ⇒ `{:stopped, id, status}`
     (the lowest-ordered one, when more than one)
  3. any feature `:running` ⇒ `:none` (structural one-at-a-time)
  4. some feature `:pending` ⇒ `{:release, lowest_ordered_pending}`
  5. otherwise ⇒ `:none` (run complete)
  """
  @spec next([Feature.t()], %{String.t() => Feature.status()}, boolean()) ::
          {:release, Feature.t()}
          | :none
          | {:stopped, String.t(), Feature.status()}
  def next(features, statuses, breaker_tripped?)
      when is_list(features) and is_map(statuses) and is_boolean(breaker_tripped?) do
    ordered = order(features)

    cond do
      breaker_tripped? ->
        :none

      stopped = find_stopped(ordered, statuses) ->
        stopped

      Enum.any?(ordered, &(status_of(&1, statuses) == :running)) ->
        :none

      pending = Enum.find(ordered, &(status_of(&1, statuses) == :pending)) ->
        {:release, pending}

      true ->
        :none
    end
  end

  @non_done_terminal [:escalated, :halted, :failed]

  defp find_stopped(ordered, statuses) do
    Enum.find_value(ordered, fn feature ->
      status = status_of(feature, statuses)
      if status in @non_done_terminal, do: {:stopped, feature.id, status}
    end)
  end

  @spec status_of(Feature.t(), %{String.t() => Feature.status()}) :: Feature.status()
  defp status_of(%Feature{id: id, status: status}, statuses) do
    Map.get(statuses, id, status)
  end
end
