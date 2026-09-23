defmodule SpeckitOrchestrator.SupersessionDrainTest do
  @moduledoc """
  US1 (026, MVP): a fresh `run/1` drains every worker still registered for
  the repository before it supersedes the prior run's record and releases
  any feature — closing the two-sessions-one-working-copy defect
  (incident `r000002`). No real `claude` session, no spend: the "worker" is a
  stub process registered through `Workers.spawn/3` exactly as a real
  executor would.
  """

  # async: false — the facade run uses a fixed Coordinator name, and workers
  # are scoped by the shared default `Config.repo()`.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Config, Feature, RepoIdentity, Store, Workers}

  defp feat(id, slug),
    do: %Feature{id: id, number: String.to_integer(id), slug: slug, path: "#{id}.md"}

  defp repo_id, do: RepoIdentity.partition(Config.repo())

  # Polls the same boundary predicate a real phase/chunk/remediation site
  # would, and reports back once it notices — never killed from outside.
  defp drain_aware_worker(me) do
    send(me, {:worker_pid, self()})
    send(me, :worker_running)
    wait_for_drain(me)
  end

  defp wait_for_drain(me) do
    if Workers.drain_requested?() do
      send(me, :worker_drained)
    else
      Process.sleep(20)
      wait_for_drain(me)
    end
  end

  test "start-while-worker-in-flight blocks the new run until the stub drains, and the superseded outcome is byte-identical (AS1, AS2, AS4)" do
    me = self()

    # Run 1: a single feature whose "executor" is a registered stub worker
    # that never finishes on its own — simulating a session mid-flight when a
    # second run starts (the r000002 shape).
    run1_executor = fn feature, _base, _notify ->
      run_key = Store.current_run_key(repo_id())
      Workers.spawn(run_key, feature.id, fn -> drain_aware_worker(me) end)
      :ok
    end

    {:ok, pid1} =
      SpeckitOrchestrator.run(
        features: [feat("001", "core")],
        executor: run1_executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        owner: me
      )

    assert_receive {:worker_pid, worker_pid}, 2_000
    assert_receive :worker_running, 2_000
    run_id_1 = elem(Store.current_run_key(repo_id()), 1)
    assert Workers.in_flight(repo_id()) != []

    # Run 2: a fresh run for the same repo. Its own executor must not fire
    # until the stub has been asked to drain and has exited (AS1) — proven by
    # mailbox order, not by timing.
    run2_executor = fn feature, _base, notify ->
      send(me, {:run2_executor_called, feature.id})
      notify.(feature.id, :done, nil)
      :ok
    end

    {:ok, pid2} =
      SpeckitOrchestrator.run(
        features: [feat("002", "vote")],
        executor: run2_executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    ordered = for _ <- 1..2, do: receive(do: (msg -> msg))
    assert ordered == [:worker_drained, {:run2_executor_called, "002"}]

    refute Process.alive?(pid1)
    refute Process.alive?(worker_pid)

    {:ok, runs} = Store.runs(repo_id())
    run_1_summary = Enum.find(runs, &(&1.run_id == run_id_1))

    assert run_1_summary.state == :superseded
    assert is_binary(run_1_summary.superseded_by)
    assert run_1_summary.feature_statuses["001"] == :ended_by_supersession
  end

  test "no-worker start has no added delay (AS3, SC-005)" do
    me = self()

    executor = fn feature, _base, notify ->
      send(me, {:built, feature.id})
      notify.(feature.id, :done, nil)
      :ok
    end

    {elapsed_us, {:ok, pid}} =
      :timer.tc(fn ->
        SpeckitOrchestrator.run(
          features: [feat("003", "solo")],
          executor: executor,
          publisher: fn _f, _b -> {:ok, "u"} end,
          owner: me
        )
      end)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert elapsed_us < 1_000_000
    assert_receive {:built, "003"}, 2_000
  end
end
