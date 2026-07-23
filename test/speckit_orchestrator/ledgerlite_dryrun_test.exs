defmodule SpeckitOrchestrator.LedgerLiteDryRunTest do
  @moduledoc """
  Phase 7 dry-run regression guard. Drives the Coordinator against the real
  LedgerLite 7-feature backlog (the committed `test/fixtures/breakdown/` DAG,
  same files that seed the live run) with a controllable fake runner — no CLI,
  no worktrees, no spend. Proves the orchestration wiring the live validation
  run depends on: DAG-ordered release, the cap-2 wave shape from plan §7.2, and
  the breaker drill (trip → drain → correct tally, bounded spend).

  Deterministic: the runner hands each feature's `notify` to the test, so the
  test controls exactly when features finish. No timers.
  """
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Backlog, Coordinator, Ledger}

  @fixtures "test/fixtures/breakdown"

  setup do
    features = Backlog.load!(@fixtures)
    prereqs = Map.new(features, &{&1.id, &1.prereqs})
    %{features: features, prereqs: prereqs}
  end

  # Reports each started feature (with its notify fn) to the test.
  defp controllable_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  # These tests don't exercise manifest behavior; a no-op keeps them from
  # racing on the shared default transcript_root path under `async: true`.
  defmodule NullManifest do
    def write(_payload), do: :ok
  end

  defp start(features, opts) do
    {:ok, pid} =
      Coordinator.start_link(
        [
          features: features,
          runner: controllable_runner(self()),
          owner: self(),
          manifest: NullManifest
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp await_started(id) do
    assert_receive {:started, ^id, notify}, 1_000
    notify
  end

  test "the LedgerLite backlog loads as the expected 7-feature DAG", %{prereqs: prereqs} do
    assert Enum.sort(Map.keys(prereqs)) ==
             ~w(001 002 003 004 005 006 007)

    assert prereqs["001"] == []
    assert prereqs["002"] == ["001"]
    assert prereqs["005"] == ["001"]
    assert prereqs["007"] == ["001"]
    assert prereqs["003"] == ["002"]
    assert prereqs["004"] == ["002"]
    assert prereqs["006"] == ["002"]
  end

  test "cap=1 serializes the whole DAG, every feature after its prereqs", %{
    features: features,
    prereqs: prereqs
  } do
    start(features, max_concurrency: 1)

    order = drive_serial(prereqs, [])

    assert Enum.sort(order) == ~w(001 002 003 004 005 006 007)
    assert length(order) == 7
  end

  test "cap=2 wave shape: 001 solo, then 002+005 parallel while 007 waits", %{features: features} do
    start(features, max_concurrency: 2)

    # Wave 1 — 001 alone (no prereqs); nothing else may start yet.
    n1 = await_started("001")
    refute_received {:started, "002", _}
    refute_received {:started, "005", _}
    n1.("001", :done, nil)

    # Wave 2 — 002 and 005 run in parallel (both prereq 001); 007 also depends
    # only on 001 but must wait behind the cap of 2.
    n2 = await_started("002")
    n5 = await_started("005")
    refute_received {:started, "007", _}

    # Drain the rest to completion; assert nothing ever exceeds the cap.
    n2.("002", :done, nil)
    n5.("005", :done, nil)
    {report, max_in_flight} = drain_to_done([{"002", n2}, {"005", n5}] |> length())

    assert max_in_flight <= 2
    assert Enum.sort(report.done) == ~w(001 002 003 004 005 006 007)
    assert report.blocked == []
  end

  test "breaker drill: spend trips the breaker mid-run, drains, tallies correctly", %{
    features: features
  } do
    cost = 4.70
    budget = 12.0
    {:ok, ledger} = Ledger.start_link(budget: budget, name: nil)

    start(features, max_concurrency: 1, ledger: ledger)

    report = drive_serial_spending(ledger, cost)

    # $4.70 * 3 = $14.10 >= $12 budget → trips after the third feature.
    assert report.breaker_tripped
    assert Enum.sort(report.done) == ~w(001 002 003)
    assert Enum.sort(report.not_started) == ~w(004 005 006 007)
    assert report.halted == []
    assert report.escalated == []
    assert report.failed == []

    # Every feature accounted for.
    accounted =
      report.done ++ report.halted ++ report.escalated ++
        report.failed ++ report.not_started ++ report.blocked

    assert Enum.sort(accounted) == ~w(001 002 003 004 005 006 007)

    # Spend is bounded by budget + one reservation (the breaker invariant).
    assert report.spend < budget + cost
    assert report.spend == 3 * cost
  end

  # ---- drivers ------------------------------------------------------------

  # Serial (cap=1) drive: complete each feature as it starts, asserting its
  # prereqs already finished. Returns the release order.
  defp drive_serial(prereqs, done) do
    receive do
      {:started, id, notify} ->
        assert Enum.all?(prereqs[id], &(&1 in done)),
               "#{id} started before prereqs #{inspect(prereqs[id])} (done: #{inspect(done)})"

        notify.(id, :done, nil)
        drive_serial(prereqs, [id | done])

      {:run_complete, _report} ->
        Enum.reverse(done)
    after
      2_000 -> flunk("run stalled")
    end
  end

  # Serial drive that records `cost` against the ledger for each started feature
  # before completing it, so committed spend crosses the budget mid-run.
  defp drive_serial_spending(ledger, cost) do
    receive do
      {:started, id, notify} ->
        Ledger.record(ledger, nil, cost)
        notify.(id, :done, nil)
        drive_serial_spending(ledger, cost)

      {:run_complete, report} ->
        report
    after
      2_000 -> flunk("run stalled")
    end
  end

  # Greedily collect each wave of concurrently-started features, complete them,
  # and track the largest wave seen. `initial` seeds the count already in flight.
  defp drain_to_done(initial, max_seen \\ 0) do
    wave = collect_wave([])

    case wave do
      [] ->
        assert_receive {:run_complete, report}, 1_000
        {report, max(max_seen, initial)}

      _ ->
        Enum.each(wave, fn {id, notify} -> notify.(id, :done, nil) end)
        drain_to_done(0, max(max_seen, max(initial, length(wave))))
    end
  end

  defp collect_wave(acc) do
    receive do
      {:started, id, notify} -> collect_wave([{id, notify} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
