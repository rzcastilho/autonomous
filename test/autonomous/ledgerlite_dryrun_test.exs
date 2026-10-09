defmodule Autonomous.LedgerLiteDryRunTest do
  @moduledoc """
  Phase 7 dry-run regression guard. Drives the Coordinator against the real
  LedgerLite 7-feature backlog (the committed `test/fixtures/breakdown/` DAG,
  same files that seed the live run) with a controllable fake runner — no CLI,
  no worktrees, no spend. Proves the orchestration wiring the live validation
  run depends on: strict ascending-numeric-order release (one feature at a
  time — 019 retired both `prereqs` and the cap/wave shape, see
  `Release.next/3`) and the spend drill (039: spend accumulates past any
  former budget, never stops the run, and tallies correctly).

  Deterministic: the runner hands each feature's `notify` to the test, so the
  test controls exactly when features finish. No timers.
  """
  use ExUnit.Case, async: true

  alias Autonomous.{Backlog, Coordinator, Ledger}

  @fixtures "test/fixtures/breakdown"

  setup do
    features = Backlog.load!(@fixtures)
    %{features: features}
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

  test "the LedgerLite backlog loads as an ascending-ordered 7-feature backlog", %{
    features: features
  } do
    assert Enum.map(features, & &1.id) == ~w(001 002 003 004 005 006 007)
    assert Enum.all?(features, &(&1.group == :backlog))
  end

  test "features release strictly one at a time, in ascending numeric order", %{
    features: features
  } do
    start(features, [])

    order = drive_serial([])

    assert order == ~w(001 002 003 004 005 006 007)
  end

  test "spend drill: spend accumulates through the whole backlog and never stops it", %{
    features: features
  } do
    cost = 4.70
    {:ok, ledger} = Ledger.start_link(name: nil)

    start(features, ledger: ledger)

    report = drive_serial_spending(ledger, cost)

    # $4.70 * 7 = $32.90 — well past the former $12 drill budget; nothing trips.
    refute Map.has_key?(report, :breaker_tripped)
    assert Enum.sort(report.done) == ~w(001 002 003 004 005 006 007)
    assert report.not_started == []
    assert report.halted == []
    assert report.escalated == []
    assert report.failed == []

    # Every feature accounted for.
    accounted =
      report.done ++
        report.halted ++
        report.escalated ++
        report.failed ++ report.not_started

    assert Enum.sort(accounted) == ~w(001 002 003 004 005 006 007)

    assert_in_delta report.spend, 7 * cost, 1.0e-9
  end

  # ---- drivers ------------------------------------------------------------

  # One-at-a-time drive: complete each feature as it starts, before the next
  # one is even released (Release.next/3 rule 3 — 019, no cap left to
  # configure). Returns the release order, which must be strictly ascending.
  defp drive_serial(done) do
    receive do
      {:started, id, notify} ->
        notify.(id, :done, nil)
        drive_serial([id | done])

      {:run_complete, _report} ->
        Enum.reverse(done)
    after
      2_000 -> flunk("run stalled")
    end
  end

  # Serial drive that records `cost` against the ledger for each started feature
  # before completing it.
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
end
