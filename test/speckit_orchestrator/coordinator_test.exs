defmodule SpeckitOrchestrator.CoordinatorTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Coordinator, Feature, Ledger}

  defp feat(id, number \\ nil),
    do: %Feature{id: id, number: number || String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

  # A runner that reports each started feature (with its notify fn) to the test,
  # so the test controls when and how each feature finishes.
  defp controllable_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  defp start(features, opts \\ []) do
    {:ok, pid} =
      Coordinator.start_link(
        [features: features, runner: controllable_runner(self()), owner: self()] ++ opts
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp await_started(id) do
    assert_receive {:started, ^id, notify}, 1_000
    notify
  end

  test "releases one feature at a time in ascending numeric order and completes" do
    features = [feat("003"), feat("001"), feat("002")]
    start(features)

    n1 = await_started("001")
    refute_received {:started, "002", _}
    refute_received {:started, "003", _}
    n1.("001", :done, nil)

    n2 = await_started("002")
    refute_received {:started, "003", _}
    n2.("002", :done, nil)

    n3 = await_started("003")
    n3.("003", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002", "003"]
    assert report.stopped_by == nil
    refute Map.has_key?(report, :blocked)
  end

  test "empty backlog finishes immediately with no stopped_by" do
    start([])
    assert_receive {:run_complete, report}, 1_000
    assert report.done == []
    assert report.stopped_by == nil
  end

  # ---- stop-on-first-broken-link (US3, FR-014/FR-015) ------------------------

  for {status, reason} <- [
        {:escalated, :needs_human},
        {:halted, :critical_finding},
        {:failed, {:phase_error, :boom}}
      ] do
    test "stop on #{status}: later features are never started and the report names the stopper" do
      features = for n <- 1..7, do: feat(String.pad_leading("#{n}", 3, "0"), n)
      start(features)

      n1 = await_started("001")
      n1.("001", :done, nil)

      n2 = await_started("002")
      n2.("002", unquote(status), unquote(Macro.escape(reason)))

      refute_received {:started, "003", _}
      assert_receive {:run_complete, report}, 1_000

      assert report.done == ["001"]
      assert Map.get(report, unquote(status)) == ["002"]
      assert report.not_started == ~w(003 004 005 006 007)
      assert report.stopped_by == %{feature_id: "002", status: unquote(status), reason: unquote(Macro.escape(reason))}
      refute Map.has_key?(report, :blocked)
    end
  end

  test "when more than one non-done terminal exists on a seeded run, the lowest-ordered is the stopper" do
    features = [feat("001"), feat("002"), feat("003")]

    start(features, statuses: %{"001" => :halted, "002" => :failed, "003" => :pending})

    refute_received {:started, "003", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.stopped_by == %{feature_id: "001", status: :halted, reason: nil}
  end

  # ---- breaker (drain, don't kill; Principle IV) ------------------------------

  test "a tripped breaker releases nothing (pre-tripped ledger)" do
    {:ok, ledger} = Ledger.start_link(budget: 0.0, name: nil)
    features = [feat("001"), feat("002")]
    start(features, ledger: ledger)

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert report.breaker_tripped
    assert Enum.sort(report.not_started) == ["001", "002"]
    assert report.done == []
    assert report.stopped_by == nil
  end

  test "breaker tripping mid-chain drains the in-flight feature then releases no more, and the report names it as the stopper" do
    {:ok, ledger} = Ledger.start_link(budget: 100.0, name: nil)
    features = [feat("001"), feat("002")]
    start(features, ledger: ledger)

    n1 = await_started("001")
    # trip the breaker while 001 is in flight
    Ledger.record(ledger, nil, 150.0)
    # the breaker-driven drain halts 001 between phases (FeatureRunner's job;
    # simulated here via the controllable runner's notify).
    n1.("001", :halted, :breaker_drain)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.halted == ["001"]
    assert report.not_started == ["002"]
    assert report.breaker_tripped
    # Reported even though the breaker masks `Release.next/3`'s own return
    # (rule 1 always wins once tripped) — the Coordinator computes it
    # independently so the operator can still see what broke (FR-017).
    assert report.stopped_by == %{feature_id: "001", status: :halted, reason: :breaker_drain}
  end

  # ---- report/state shape (019: no cap, no blocked) ---------------------------

  test "status/0 exposes no cap field" do
    pid = start([feat("001")])
    _n1 = await_started("001")

    refute Map.has_key?(Coordinator.status(pid), :cap)
  end

  # ---- feature 021: advanced_with_findings ⊆ done ----------------------------

  test "a feature that reached :done with the decorated reason lands in advanced_with_findings, a subset of done" do
    features = [feat("001"), feat("002")]
    start(features)

    n1 = await_started("001")
    n1.("001", :done, {:done, :advanced_with_unresolved_findings})

    n2 = await_started("002")
    n2.("002", :done, :done)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
    assert report.advanced_with_findings == ["001"]
    assert MapSet.subset?(MapSet.new(report.advanced_with_findings), MapSet.new(report.done))
  end

  test "no feature marked leaves advanced_with_findings empty (SC-002 — :escalate path unaffected)" do
    features = [feat("001")]
    start(features)

    n1 = await_started("001")
    n1.("001", :done, :done)

    assert_receive {:run_complete, report}, 1_000
    assert report.advanced_with_findings == []
  end

  # ---- :statuses init option (crash recovery) --------------------------------

  test "a supplied :statuses init option seeds state.statuses instead of the all-:pending default" do
    features = [feat("001"), feat("002")]
    start(features, statuses: %{"001" => :done, "002" => :done})

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
  end

  test "a feature seeded :pending in :statuses releases normally" do
    features = [feat("001"), feat("002")]
    start(features, statuses: %{"001" => :done, "002" => :pending})

    n2 = await_started("002")
    n2.("002", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
  end
end
