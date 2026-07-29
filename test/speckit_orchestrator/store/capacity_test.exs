defmodule SpeckitOrchestrator.Store.CapacityTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Capacity

  describe "check/1" do
    test ":ok when used + headroom fits exactly at the capacity boundary" do
      assert Capacity.check(%{
               used_bytes: 850,
               capacity_bytes: 1000,
               headroom_bytes: 150,
               reclaimable_bytes: 0
             }) == :ok
    end

    test ":ok with headroom to spare" do
      assert Capacity.check(%{
               used_bytes: 100,
               capacity_bytes: 1000,
               headroom_bytes: 150,
               reclaimable_bytes: 0
             }) == :ok
    end

    test "{:refuse, ...} one byte past the boundary, naming the shortfall" do
      assert {:refuse, refusal} =
               Capacity.check(%{
                 used_bytes: 851,
                 capacity_bytes: 1000,
                 headroom_bytes: 150,
                 reclaimable_bytes: 42
               })

      assert refusal == %{
               shortfall_bytes: 1,
               used_bytes: 851,
               capacity_bytes: 1000,
               headroom_bytes: 150,
               reclaimable_bytes: 42
             }
    end

    test "reclaimable_bytes defaults to 0 when absent from the measurement" do
      assert {:refuse, %{reclaimable_bytes: 0}} =
               Capacity.check(%{used_bytes: 2000, capacity_bytes: 1000, headroom_bytes: 150})
    end

    test "zero headroom still refuses once used exceeds capacity" do
      assert {:refuse, %{shortfall_bytes: 1}} =
               Capacity.check(%{
                 used_bytes: 1001,
                 capacity_bytes: 1000,
                 headroom_bytes: 0,
                 reclaimable_bytes: 0
               })
    end
  end
end
