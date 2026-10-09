defmodule Autonomous.CoordinatorTest do
  use ExUnit.Case, async: true

  alias Autonomous.{Coordinator, Feature, Ledger}

  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || String.to_integer(id),
      slug: "f#{id}",
      path: "#{id}.md"
    }

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

  test "init emits [:speckit, :run, :start] carrying the run_key" do
    test_pid = self()
    handler_id = {__MODULE__, :run_start, make_ref()}

    :telemetry.attach(
      handler_id,
      [:speckit, :run, :start],
      fn _event, _meas, meta, _cfg -> send(test_pid, {:run_start, self(), meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    pid = start([])
    assert_receive {:run_start, ^pid, %{run_key: nil}}, 1_000
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

      assert report.stopped_by == %{
               feature_id: "002",
               status: unquote(status),
               reason: unquote(Macro.escape(reason))
             }

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

  # ---- cost is informational (039, SC-001, FR-001) -----------------------------

  test "large spend never halts: every feature reaches :done and spend is the sum" do
    {:ok, ledger} = Ledger.start_link(name: nil)
    test_pid = self()

    # A stub runner that records a very large cost per feature, then finishes
    # it :done — the Coordinator must keep releasing regardless of spend.
    runner = fn feature, notify ->
      Ledger.record(ledger, nil, 10_000.0)
      send(test_pid, {:ran, feature.id})
      notify.(feature.id, :done, nil)
    end

    features = [feat("001"), feat("002"), feat("003"), feat("004")]

    {:ok, pid} =
      Coordinator.start_link(features: features, runner: runner, owner: self(), ledger: ledger)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002", "003", "004"]
    assert report.not_started == []
    assert report.stopped_by == nil
    assert report.spend == 40_000.0
    refute Map.has_key?(report, :breaker_tripped)
    refute Map.has_key?(Coordinator.status(pid), :breaker_tripped)
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

  # ---- interactive clarify (029, research.md R6) -----------------------------

  test "{:feature_awaiting, id} updates statuses without ending the run or releasing another feature" do
    features = [feat("001"), feat("002")]
    pid = start(features)

    await_started("001")
    send(pid, {:feature_awaiting, "001"})

    assert Coordinator.status(pid).statuses["001"] == :awaiting_answers
    refute_received {:started, "002", _}
    refute_received {:run_complete, _}
  end

  test "{:feature_resumed, id} sets the feature back to :running, still without releasing another feature" do
    features = [feat("001"), feat("002")]
    pid = start(features)

    await_started("001")
    send(pid, {:feature_awaiting, "001"})
    send(pid, {:feature_resumed, "001"})

    assert Coordinator.status(pid).statuses["001"] == :running
    refute_received {:started, "002", _}
    refute_received {:run_complete, _}
  end

  test "a feature that goes through awaiting/resumed still finishes the run normally" do
    features = [feat("001"), feat("002")]
    pid = start(features)

    n1 = await_started("001")
    send(pid, {:feature_awaiting, "001"})
    send(pid, {:feature_resumed, "001"})
    n1.("001", :done, nil)

    n2 = await_started("002")
    n2.("002", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
  end

  # ---- 039: no containment profile on any surface ---------------------------

  test "final report and status snapshot never carry containment_profile — even from a legacy context" do
    pid = start([feat("001")], context: %{containment_profile: "permissive"})

    refute Map.has_key?(Coordinator.status(pid), :containment_profile)

    n1 = await_started("001")
    n1.("001", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    refute Map.has_key?(report, :containment_profile)
  end
end
