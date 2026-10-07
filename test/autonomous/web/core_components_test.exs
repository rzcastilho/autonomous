defmodule Autonomous.Web.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Autonomous.Pipeline
  alias Autonomous.Web.CoreComponents

  @phases Pipeline.phases()
  @total length(@phases)

  defp cells(states), do: Map.new(states, fn {phase, state} -> {phase, %{state: state}} end)

  describe "phase_position/1" do
    test "the active cell wins" do
      [p1, p2, p3 | _] = @phases
      phases = cells([{p1, :completed}, {p2, :active}, {p3, :pending}])

      assert CoreComponents.phase_position(phases) == {p2, 2, @total}
    end

    test "without an active cell, the last completed one" do
      [p1, p2, p3 | _] = @phases
      phases = cells([{p1, :completed}, {p2, :completed}, {p3, :pending}])

      assert CoreComponents.phase_position(phases) == {p2, 2, @total}
    end

    test "with nothing started, the first phase at n = 1" do
      [first | _] = @phases

      assert CoreComponents.phase_position(%{}) == {first, 1, @total}
      assert CoreComponents.phase_position(nil) == {first, 1, @total}
    end

    test "total tracks Pipeline.phases/0" do
      assert {_, _, total} = CoreComponents.phase_position(%{})
      assert total == length(Pipeline.phases())
    end
  end

  test "cost_gauge renders `$committed + $reserved / $budget` with no breaker word and clamps the bar" do
    html =
      render_component(&CoreComponents.cost_gauge/1,
        committed: 12.5,
        reserved: 2.0,
        budget: 10.0,
        tripped?: true
      )

    assert html =~ "$12.50 + $2.00 / $10.00"
    refute html =~ "armed"
    refute html =~ "tripped)"
    assert html =~ ~s(data-band="tripped")
    assert html =~ "width: 100.0%"
  end
end
