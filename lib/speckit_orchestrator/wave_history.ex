defmodule SpeckitOrchestrator.WaveHistory do
  @moduledoc """
  Pure resolution of which run a wave (backlog package) draws its Pipeline
  Chain history from (feature 028, contracts/wave-history.md).

  No Mnesia, `Coordinator`, `Ledger`, PubSub, or LiveView dependency — every
  input is an argument, taken verbatim from `SpeckitOrchestrator.run_history/1`
  summaries.
  """

  alias SpeckitOrchestrator.Pipeline

  @type source ::
          {:live, map()}
          | {:recorded, map()}
          | :none
          | {:unavailable, term()}

  @doc """
  Which run `slug`'s wave draws its Pipeline Chain state from.

  Rules (first match wins, contracts/wave-history.md):
  1. `{:error, reason}` history → `{:unavailable, reason}`
  2. An `:in_flight` summary scoped to `slug` → `{:live, summary}`
  3. The first (most recent) summary, any other state, scoped to `slug` →
     `{:recorded, summary}`
  4. Otherwise → `:none`

  A damaged summary (`%{damaged: true}`) or one not scoped to
  `{:breakdown, slug}` (including `:ad_hoc`) never matches.
  """
  @spec source_for(String.t(), {:ok, [map()]} | {:error, term()}) :: source()
  def source_for(_slug, {:error, reason}), do: {:unavailable, reason}

  def source_for(slug, {:ok, summaries}) do
    scoped = Enum.filter(summaries, &scoped_to?(&1, slug))

    case Enum.find(scoped, &(&1.state == :in_flight)) do
      nil ->
        case scoped do
          [summary | _] -> {:recorded, summary}
          [] -> :none
        end

      summary ->
        {:live, summary}
    end
  end

  @doc """
  Which package the Pipeline Chain selects by default on mount
  (contracts/wave-history.md).

  Rules (first match wins):
  1. `packages == []` → `nil` (legacy layout)
  2. An `:in_flight` summary scoped to a package in `packages` → that package
  3. The newest non-damaged summary scoped to a package in `packages` → that
     package
  4. Otherwise (including `{:error, _}` history) → `List.first(packages)`
  """
  @spec default_package([String.t()], {:ok, [map()]} | {:error, term()}) :: String.t() | nil
  def default_package([], _history), do: nil

  def default_package(packages, {:ok, summaries}) do
    candidates = Enum.filter(summaries, &(not damaged?(&1) and slug_of(&1) in packages))

    case Enum.find(candidates, &(&1.state == :in_flight)) do
      nil ->
        case candidates do
          [summary | _] -> slug_of(summary)
          [] -> List.first(packages)
        end

      summary ->
        slug_of(summary)
    end
  end

  def default_package(packages, {:error, _reason}), do: List.first(packages)

  defp scoped_to?(summary, slug), do: not damaged?(summary) and slug_of(summary) == slug

  defp damaged?(%{damaged: true}), do: true
  defp damaged?(_summary), do: false

  defp slug_of(%{scope: {:breakdown, slug}}), do: slug
  defp slug_of(_summary), do: nil

  @doc """
  Draws `row` as interrupted when a past (not in-flight) run left it
  `:running` (contracts/wave-history.md). Every other row/`run_state`
  combination passes through unchanged.
  """
  @spec interrupt(map(), atom()) :: map()
  def interrupt(row, :in_flight), do: row

  def interrupt(%{status: :running} = row, _run_state) do
    case open_phase(Map.get(row, :current_phase)) do
      nil -> %{row | status: :interrupted}
      phase -> %{row | status: :interrupted, phases: Map.put(row.phases, phase, %{state: :interrupted})}
    end
  end

  def interrupt(row, _run_state), do: row

  @doc "Maps `interrupt/2` over every row of a `per_feature` map."
  @spec interrupt_all(map(), atom()) :: map()
  def interrupt_all(per_feature, run_state) do
    Map.new(per_feature, fn {id, row} -> {id, interrupt(row, run_state)} end)
  end

  defp open_phase(nil), do: List.first(Pipeline.phases())

  defp open_phase(current_phase) do
    phases = Pipeline.phases()

    case Enum.find_index(phases, &(&1 == current_phase)) do
      nil -> List.first(phases)
      idx -> Enum.at(phases, idx + 1)
    end
  end
end
