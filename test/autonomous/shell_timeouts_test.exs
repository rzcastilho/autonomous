defmodule Autonomous.ShellTimeoutsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autonomous.ShellTimeouts

  defp pair(d) do
    t = ShellTimeouts.for_deadline(d)
    {String.to_integer(t["BASH_DEFAULT_TIMEOUT_MS"]), String.to_integer(t["BASH_MAX_TIMEOUT_MS"])}
  end

  test "contract table" do
    # {deadline, default, max}
    for {d, default, max} <- [
          {3_000_000, 1_800_000, 2_700_000},
          {1_200_000, 900_000, 900_000},
          {900_000, 600_000, 600_000},
          {600_001, 300_001, 300_001},
          {600_000, 120_000, 600_000},
          {60_000, 120_000, 600_000},
          {14_400_000, 1_800_000, 2_700_000}
        ] do
      assert pair(d) == {default, max}, "deadline #{d}"
    end
  end

  test "values are decimal strings under the two env names" do
    assert ShellTimeouts.for_deadline(3_000_000) == %{
             "BASH_DEFAULT_TIMEOUT_MS" => "1800000",
             "BASH_MAX_TIMEOUT_MS" => "2700000"
           }
  end

  property "d > 10 min: max <= d - 5 min and default <= max (SC-003)" do
    check all(d <- integer(600_001..20_000_000)) do
      {default, max} = pair(d)
      assert max <= d - 300_000
      assert default <= max
    end
  end
end
