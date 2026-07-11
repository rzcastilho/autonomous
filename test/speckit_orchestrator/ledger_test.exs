defmodule SpeckitOrchestrator.LedgerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SpeckitOrchestrator.Ledger

  defp start(budget) do
    pid = start_supervised!({Ledger, budget: budget, name: nil})
    pid
  end

  test "reserve then record commits spend" do
    l = start(100)
    {:ok, ref} = Ledger.reserve(l, 30)
    assert Ledger.spent(l) == 0
    assert Ledger.record(l, ref, 25) == 25
    assert Ledger.spent(l) == 25
  end

  test "breaker trips at committed >= budget" do
    l = start(50)
    refute Ledger.breaker_tripped?(l)
    {:ok, ref} = Ledger.reserve(l, 50)
    Ledger.record(l, ref, 50)
    assert Ledger.breaker_tripped?(l)
  end

  test "reserve rejected once committed + reserved fills the budget" do
    l = start(10)
    {:ok, _} = Ledger.reserve(l, 8)
    # committed 0 + reserved 8 < 10 -> still room
    {:ok, _} = Ledger.reserve(l, 5)
    # committed 0 + reserved 13 >= 10 -> no headroom
    assert Ledger.reserve(l, 1) == {:error, :budget_exceeded}
  end

  test "record with nil ref still commits (spend without a reservation)" do
    l = start(100)
    assert Ledger.record(l, nil, 40) == 40
    assert Ledger.spent(l) == 40
  end

  test "defaults budget to Config.budget_usd/0 when unset" do
    {:ok, l} = Ledger.start_link(name: nil)
    on_exit(fn -> if Process.alive?(l), do: GenServer.stop(l) end)
    assert Ledger.snapshot(l).budget == SpeckitOrchestrator.Config.budget_usd()
  end

  test "snapshot reports budget/committed/reserved/tripped?" do
    l = start(100)
    {:ok, _ref} = Ledger.reserve(l, 20)
    snap = Ledger.snapshot(l)
    assert snap.budget == 100
    assert snap.committed == 0
    assert snap.reserved == 20
    refute snap.tripped?
  end

  test "default-named server: no-arg start_link and server-less API" do
    {:ok, pid} = Ledger.start_link()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, ref} = Ledger.reserve(10)
    assert Ledger.record(ref, 10) == 10
    assert Ledger.spent() == 10
    refute Ledger.breaker_tripped?()
  end

  property "committed spend never exceeds budget + one in-flight reservation" do
    check all(
            budget <- integer(1..500),
            ops <- list_of(op_gen(), max_length: 60)
          ) do
      {:ok, l} = Ledger.start_link(budget: budget, name: nil)

      max_res =
        Enum.reduce(ops, 0, fn {res_amt, rec_amt}, max_res ->
          case Ledger.reserve(l, res_amt) do
            {:ok, ref} -> Ledger.record(l, ref, rec_amt)
            {:error, :budget_exceeded} -> :ok
          end

          max(max_res, res_amt)
        end)

      assert Ledger.spent(l) < budget + max(max_res, 1)
      GenServer.stop(l)
    end
  end

  # Each op reserves `res_amt` and (if granted) records `rec_amt <= res_amt`,
  # matching real usage: record the actual, which never exceeds the estimate.
  defp op_gen do
    gen all(
          res_amt <- integer(0..100),
          rec_amt <- integer(0..max(res_amt, 0))
        ) do
      {res_amt, rec_amt}
    end
  end
end
