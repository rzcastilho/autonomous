defmodule SpeckitOrchestrator.CoordinatorTest do
  # async: false — the set_cap/2 tests mutate global Config app env (mirrored
  # by Coordinator.set_cap/2), same convention as run_context_test.exs.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, Ledger}

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "f#{id}", path: "#{id}.md", prereqs: prereqs}

  # A runner that reports each started feature (with its notify fn) to the test,
  # so the test controls when and how each feature finishes.
  defp controllable_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  defp start(features, opts) do
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

  test "diamond DAG releases wave by wave and completes" do
    features = [
      feat("001"),
      feat("002", ["001"]),
      feat("003", ["001"]),
      feat("004", ["002", "003"])
    ]

    start(features, max_concurrency: 4)

    n1 = await_started("001")
    refute_received {:started, "002", _}
    n1.("001", :done, nil)

    n2 = await_started("002")
    n3 = await_started("003")
    n2.("002", :done, nil)
    n3.("003", :done, nil)

    n4 = await_started("004")
    n4.("004", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002", "003", "004"]
  end

  test "concurrency cap limits in-flight features" do
    features = [feat("001"), feat("002"), feat("003")]
    start(features, max_concurrency: 2)

    _n1 = await_started("001")
    n2 = await_started("002")
    # third must wait behind the cap
    refute_received {:started, "003", _}

    n2.("002", :done, nil)
    _n3 = await_started("003")
  end

  test "a dependent of an escalated prereq is reported blocked" do
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2)

    n1 = await_started("001")
    n1.("001", :escalated, :needs_human)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.escalated == ["001"]
    assert report.blocked == ["002"]
  end

  test "a tripped breaker releases nothing (pre-tripped ledger)" do
    {:ok, ledger} = Ledger.start_link(budget: 0.0, name: nil)
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2, ledger: ledger)

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert report.breaker_tripped
    assert Enum.sort(report.not_started) == ["001", "002"]
    assert report.done == []
  end

  test "breaker tripping mid-run drains in-flight then releases no more" do
    {:ok, ledger} = Ledger.start_link(budget: 100.0, name: nil)
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2, ledger: ledger)

    n1 = await_started("001")
    # trip the breaker while 001 is in flight
    Ledger.record(ledger, nil, 150.0)
    n1.("001", :done, nil)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001"]
    assert report.not_started == ["002"]
    assert report.breaker_tripped
  end

  test "empty backlog finishes immediately" do
    start([], max_concurrency: 2)
    assert_receive {:run_complete, report}, 1_000
    assert report.done == []
  end

  # set_cap/2 mirrors to app env (a global, not per-process, side effect) —
  # every test that calls it must restore the prior value on exit so it
  # cannot bleed into other test files (e.g. config_test.exs).
  defp with_restored_max_concurrency(test) do
    prior = Application.get_env(:speckit_orchestrator, :max_concurrency)
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :max_concurrency, prior) end)
    test.()
  end

  test "set_cap/2 raises the wave cap so a previously-waiting feature releases on the next advance" do
    with_restored_max_concurrency(fn ->
      features = [feat("001"), feat("002"), feat("003")]
      pid = start(features, max_concurrency: 2)

      _n1 = await_started("001")
      n2 = await_started("002")
      refute_received {:started, "003", _}

      assert Coordinator.set_cap(pid, 3) == :ok
      # cap alone doesn't spawn work; the next advance (triggered by a finish) sees it.
      refute_received {:started, "003", _}

      n2.("002", :done, nil)
      _n3 = await_started("003")
    end)
  end

  test "set_cap/2 mirrors the new cap to app env" do
    with_restored_max_concurrency(fn ->
      features = [feat("001")]
      pid = start(features, max_concurrency: 2)
      _n1 = await_started("001")

      assert Coordinator.set_cap(pid, 5) == :ok
      assert Application.get_env(:speckit_orchestrator, :max_concurrency) == 5
    end)
  end
end
