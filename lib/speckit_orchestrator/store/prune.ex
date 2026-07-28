defmodule SpeckitOrchestrator.Store.Prune do
  @moduledoc """
  Pure prune policy (018, contracts/capacity-and-prune.md § Prune, R18). No
  IO, no `:mnesia` reference — a protected run (in-flight, or resumable via a
  live checkpoint) is never removable regardless of boundary, and is reported
  retained **with its reason** rather than silently skipped (FR-031).
  """

  @type run_summary :: %{
          run_id: binary(),
          state: :in_flight | :completed | :superseded,
          ended_at: DateTime.t() | nil,
          bytes: non_neg_integer()
        }

  @type removable :: %{run_id: binary(), ended_at: DateTime.t() | nil, bytes: non_neg_integer()}
  @type retained :: %{run_id: binary(), reason: :in_flight | :resumable | :after_boundary}

  @type plan :: %{
          removable: [removable()],
          retained: [retained()],
          bytes_reclaimable: non_neg_integer()
        }

  @doc """
  `(run_summaries, boundary, protected_run_ids) -> plan`. A run is removable
  only if it is not `:in_flight`, its `run_id` is not in `protected_run_ids`
  (every run the store reports as resumable — a live checkpoint with a
  non-`:done` status), and its `ended_at` is at or before `boundary`.
  """
  @spec plan([run_summary()], DateTime.t(), Enumerable.t()) :: plan()
  def plan(run_summaries, %DateTime{} = boundary, protected_run_ids) do
    protected = MapSet.new(protected_run_ids)

    {removable, retained} =
      Enum.reduce(run_summaries, {[], []}, fn run, {removable, retained} ->
        classify(run, boundary, protected, removable, retained)
      end)

    removable = Enum.reverse(removable)

    %{
      removable: removable,
      retained: Enum.reverse(retained),
      bytes_reclaimable: Enum.reduce(removable, 0, &(&1.bytes + &2))
    }
  end

  defp classify(%{state: :in_flight} = run, _boundary, _protected, removable, retained) do
    {removable, [%{run_id: run.run_id, reason: :in_flight} | retained]}
  end

  defp classify(run, boundary, protected, removable, retained) do
    cond do
      MapSet.member?(protected, run.run_id) ->
        {removable, [%{run_id: run.run_id, reason: :resumable} | retained]}

      not before_or_at?(run.ended_at, boundary) ->
        {removable, [%{run_id: run.run_id, reason: :after_boundary} | retained]}

      true ->
        {[%{run_id: run.run_id, ended_at: run.ended_at, bytes: run.bytes} | removable], retained}
    end
  end

  defp before_or_at?(nil, _boundary), do: false
  defp before_or_at?(ended_at, boundary), do: DateTime.compare(ended_at, boundary) != :gt
end
