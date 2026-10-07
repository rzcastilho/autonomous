defmodule Autonomous.Web.RunStateView do
  @moduledoc """
  Pure mapping from a run's state/outcome to the console's status vocabulary
  (033, research R7, data-model §2). Total: an unknown term maps to `pending`,
  never raises.
  """

  alias Autonomous.Web.CoreComponents

  @doc "Contract status name (one of `CoreComponents.statuses/0`) for a run state or outcome."
  @spec status(term()) :: String.t()
  def status(:in_flight), do: "running"
  def status(:completed), do: "done"
  def status(:parked), do: "escalated"
  def status(:superseded), do: "blocked"
  def status(:interrupted), do: "blocked"
  def status(:ended_by_operator), do: "pending"
  def status(term) when is_atom(term), do: CoreComponents.status_class(term)
  def status(_other), do: "pending"

  @doc "The real identifier text for a chip, e.g. `:in_flight`; `—` when absent."
  @spec label(term()) :: String.t()
  def label(nil), do: "—"
  def label(term) when is_atom(term), do: ":" <> Atom.to_string(term)
  def label(term) when is_binary(term), do: term
  def label(_other), do: "—"

  @doc "`[{status_name, count}]` over `%{id => status}`, zero counts omitted, in `statuses/0` order."
  @spec status_counts(map() | nil) :: [{String.t(), pos_integer()}]
  def status_counts(feature_statuses) when is_map(feature_statuses) do
    counts =
      feature_statuses |> Map.values() |> Enum.frequencies_by(&CoreComponents.status_class/1)

    for name <- CoreComponents.statuses(), count = Map.get(counts, name, 0), count > 0 do
      {name, count}
    end
  end

  def status_counts(_other), do: []
end
