defmodule Autonomous.Cost do
  @moduledoc """
  Resolve the cost to record in the `Ledger` for a completed phase
  (informational — 039: cost never gates work).

  Prefers the **actual** `cost_usd` folded from the adapter's `:usage` event
  (the CLI's `total_cost_usd`); falls back to the conservative per-phase
  **estimate** from config when the run surfaced no cost (Phase 0 flagged
  `capabilities.usage? == false`, so the estimate path must exist).
  """

  alias Autonomous.{Config, PhaseResult}

  @doc """
  Return `{amount_usd, :actual | :estimate}` for `phase`'s result.

  A session that never started (034) spent nothing — charged an actual `0.0`,
  not the estimate. One that ended early may have spent tokens it never
  reported, so it keeps the estimate fallback.
  """
  @spec for_phase(atom(), PhaseResult.t()) :: {number(), :actual | :estimate}
  def for_phase(_phase, %PhaseResult{error: {:session_died, :start_failed, _}}),
    do: {0.0, :actual}

  def for_phase(_phase, %PhaseResult{cost_usd: cost}) when is_number(cost) and cost > 0 do
    {cost, :actual}
  end

  def for_phase(phase, %PhaseResult{}) do
    {Config.cost_estimate(phase), :estimate}
  end
end
