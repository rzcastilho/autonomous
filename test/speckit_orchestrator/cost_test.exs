defmodule SpeckitOrchestrator.CostTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Cost, PhaseResult}

  test "prefers the actual cost from the usage event" do
    pr = %PhaseResult{cost_usd: 1.23}
    assert Cost.for_phase(:implement, pr) == {1.23, :actual}
  end

  test "falls back to the per-phase config estimate when no cost surfaced" do
    assert Cost.for_phase(:implement, %PhaseResult{cost_usd: nil}) == {2.50, :estimate}
    assert Cost.for_phase(:specify, %PhaseResult{}) == {0.20, :estimate}
  end

  test "zero cost is treated as no cost (estimate)" do
    assert {_amount, :estimate} = Cost.for_phase(:analyze, %PhaseResult{cost_usd: 0})
  end
end
