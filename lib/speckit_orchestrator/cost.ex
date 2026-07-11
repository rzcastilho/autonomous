defmodule SpeckitOrchestrator.Cost do
  @moduledoc """
  Resolve the cost to charge the `Ledger` for a completed phase.

  Prefers the **actual** `cost_usd` folded from the adapter's `:usage` event
  (the CLI's `total_cost_usd`); falls back to the conservative per-phase
  **estimate** from config when the run surfaced no cost (Phase 0 flagged
  `capabilities.usage? == false`, so the estimate path must exist).
  """

  alias SpeckitOrchestrator.{Config, PhaseResult}

  @doc "Return `{amount_usd, :actual | :estimate}` for `phase`'s result."
  @spec for_phase(atom(), PhaseResult.t()) :: {number(), :actual | :estimate}
  def for_phase(_phase, %PhaseResult{cost_usd: cost}) when is_number(cost) and cost > 0 do
    {cost, :actual}
  end

  def for_phase(phase, %PhaseResult{}) do
    {Config.cost_estimate(phase), :estimate}
  end
end
