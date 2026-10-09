defmodule Autonomous.LedgerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autonomous.Ledger

  # 039: the Ledger is an informational cost accumulator — no budget, no
  # reservations, no breaker (research R1).

  defp start, do: start_supervised!({Ledger, name: nil})

  test "record/3 commits spend and returns the new total" do
    l = start()
    assert Ledger.spent(l) == 0
    assert Ledger.record(l, nil, 25) == 25
    assert Ledger.record(l, nil, 2.5) == 27.5
    assert Ledger.spent(l) == 27.5
  end

  test "very large spend is simply accumulated (nothing trips)" do
    l = start()
    Ledger.record(l, nil, 10_000.0)
    Ledger.record(l, nil, 10_000.0)
    assert Ledger.spent(l) == 20_000.0
  end

  test "snapshot/1 reports committed only" do
    l = start()
    Ledger.record(l, nil, 7)
    assert Ledger.snapshot(l) == %{committed: 7}
  end

  test "restore/2 sets committed to the recorded figure on a fresh Ledger" do
    l = start()
    assert Ledger.restore(l, 5.0) == 5.0
    assert Ledger.spent(l) == 5.0
  end

  test "restore/2 is monotonic — never lowers an already-higher committed" do
    l = start()
    Ledger.restore(l, 5.0)
    assert Ledger.restore(l, 3.0) == 5.0
    assert Ledger.spent(l) == 5.0
  end

  test "restore/2 idempotent — calling twice with the same value is a no-op" do
    l = start()
    Ledger.restore(l, 5.0)
    assert Ledger.restore(l, 5.0) == 5.0
  end

  test "the budget/reservation/breaker API is gone" do
    Code.ensure_loaded!(Ledger)
    refute function_exported?(Ledger, :reserve, 2)
    refute function_exported?(Ledger, :set_budget, 2)
    refute function_exported?(Ledger, :breaker_tripped?, 1)
  end

  test "server-less API targets the default-named (app-supervised) ledger" do
    # The application starts a default-named Ledger; exercise the no-server-arg
    # heads against it with a delta assertion (no absolute-spend coupling).
    before = Ledger.spent()
    assert Ledger.record(nil, 1) == before + 1
    assert Ledger.spent() == before + 1
    assert Ledger.snapshot().committed == before + 1
  end

  property "committed spend is exactly the sum of recorded amounts" do
    check all(amounts <- list_of(integer(0..1_000), max_length: 60)) do
      {:ok, l} = Ledger.start_link(name: nil)
      Enum.each(amounts, &Ledger.record(l, nil, &1))
      assert Ledger.spent(l) == Enum.sum(amounts)
      GenServer.stop(l)
    end
  end
end
