defmodule Autonomous.CostTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Cost, PhaseResult}

  test "prefers the actual cost from the usage event" do
    pr = %PhaseResult{cost_usd: 1.23}
    assert Cost.for_phase(:implement, pr) == {1.23, :actual}
  end

  test "falls back to the per-phase config estimate when no cost surfaced" do
    assert Cost.for_phase(:implement, %PhaseResult{cost_usd: nil}) == {7.88, :estimate}
    assert Cost.for_phase(:specify, %PhaseResult{}) == {0.63, :estimate}
  end

  test "zero cost is treated as no cost (estimate)" do
    assert {_amount, :estimate} = Cost.for_phase(:analyze, %PhaseResult{cost_usd: 0})
  end

  test "a session that never started is charged an actual $0 (034)" do
    pr = %PhaseResult{error: {:session_died, :start_failed, "boom"}}
    assert Cost.for_phase(:specify, pr) == {0.0, :actual}
  end

  test "a session that ended early keeps the estimate fallback (034)" do
    pr = %PhaseResult{error: {:session_died, :ended_early, "boom"}}
    assert {amount, :estimate} = Cost.for_phase(:specify, pr)
    assert amount > 0
  end

  test "an ended-early session with an actual cost reports it (034)" do
    pr = %PhaseResult{cost_usd: 0.4, error: {:session_died, :ended_early, "boom"}}
    assert Cost.for_phase(:specify, pr) == {0.4, :actual}
  end
end
