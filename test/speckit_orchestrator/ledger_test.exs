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

  test "set_budget/2 changes the budget used by subsequent reserve/breaker_tripped? calls" do
    l = start(10)
    {:ok, ref} = Ledger.reserve(l, 10)
    Ledger.record(l, ref, 10)
    assert Ledger.breaker_tripped?(l)

    assert Ledger.set_budget(l, 100) == :ok
    refute Ledger.breaker_tripped?(l)
    assert Ledger.snapshot(l).budget == 100
  end

  test "set_budget/2 preserves the committed < budget + max single reservation invariant" do
    l = start(50)
    {:ok, ref} = Ledger.reserve(l, 20)
    Ledger.record(l, ref, 20)

    assert Ledger.set_budget(l, 25) == :ok
    # committed (20) < new budget (25) + next reservation still enforced going forward
    {:ok, ref2} = Ledger.reserve(l, 5)
    Ledger.record(l, ref2, 5)
    assert Ledger.spent(l) == 25
    assert Ledger.reserve(l, 1) == {:error, :budget_exceeded}
  end

  test "restore/2 sets committed to the recorded figure on a fresh Ledger" do
    l = start(100)
    assert Ledger.restore(l, 5.0) == 5.0
    assert Ledger.spent(l) == 5.0
  end

  test "restore/2 is monotonic — never lowers an already-higher committed" do
    l = start(100)
    Ledger.restore(l, 5.0)
    assert Ledger.restore(l, 3.0) == 5.0
    assert Ledger.spent(l) == 5.0
  end

  test "restore/2 idempotent — calling twice with the same value is a no-op" do
    l = start(100)
    Ledger.restore(l, 5.0)
    assert Ledger.restore(l, 5.0) == 5.0
  end

  test "restore/2 trips the breaker when the recorded figure is at/above budget" do
    l = start(10)
    refute Ledger.breaker_tripped?(l)
    assert Ledger.restore(l, 10) == 10
    assert Ledger.breaker_tripped?(l)
    assert Ledger.reserve(l, 1) == {:error, :budget_exceeded}
  end

  test "restore/2 does not touch reservations" do
    l = start(100)
    {:ok, _ref} = Ledger.reserve(l, 20)
    Ledger.restore(l, 5.0)
    assert Ledger.snapshot(l).reserved == 20
  end

  test "server-less API targets the default-named (app-supervised) ledger" do
    # The application starts a default-named Ledger; exercise the no-server-arg
    # heads against it with a delta assertion (no absolute-spend coupling).
    before = Ledger.spent()
    {:ok, ref} = Ledger.reserve(1)
    assert Ledger.record(ref, 1) == before + 1
    assert Ledger.spent() == before + 1
    assert is_boolean(Ledger.breaker_tripped?())
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
