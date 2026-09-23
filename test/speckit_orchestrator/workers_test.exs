defmodule SpeckitOrchestrator.WorkersTest do
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Workers

  # Every test picks its own repo_id so workers from one test can never be
  # seen by another (FR-007 exercised for free).
  defp fresh_repo, do: "repo-#{System.unique_integer([:positive])}"

  defp spawn_stub(run_key, feature_id, behavior) do
    parent = self()
    {:ok, pid} = Workers.spawn(run_key, feature_id, fn -> behavior.(parent) end)
    pid
  end

  # Polls the boundary predicate like a real phase/chunk/remediation site
  # would, and exits as soon as a drain is requested.
  defp drain_aware_loop(parent) do
    if Workers.drain_requested?() do
      send(parent, :drained)
    else
      Process.sleep(10)
      drain_aware_loop(parent)
    end
  end

  # A stub that never checks drain_requested?/0 — forces a drain timeout.
  # Publishes a session deadline of 1ms so it has already elapsed by the time
  # the test calls drain/2 with a zero grace/margin.
  defp ignores_drain(parent) do
    Workers.session_started(1)
    Process.sleep(5)
    send(parent, :running)
    Process.sleep(:infinity)
  end

  describe "registration scoping (FR-007)" do
    test "a worker registers only under its own repo_id" do
      repo_a = fresh_repo()
      repo_b = fresh_repo()
      run_key = {repo_a, "run-1"}
      pid = spawn_stub(run_key, "001", &ignores_drain/1)
      assert_receive :running

      assert [%{pid: ^pid, feature_id: "001", run_id: "run-1"}] = Workers.in_flight(repo_a)
      assert Workers.in_flight(repo_b) == []

      Process.exit(pid, :kill)
    end

    test "spawn/3 with run_key: nil registers nothing" do
      repo = fresh_repo()
      {:ok, pid} = Workers.spawn(nil, "001", fn -> Process.sleep(:infinity) end)

      assert Workers.in_flight(repo) == []
      Process.exit(pid, :kill)
    end
  end

  describe "drain/2" do
    test "empty registry returns :ok immediately, with no wait (FR-012)" do
      repo = fresh_repo()
      {elapsed_us, result} = :timer.tc(fn -> Workers.drain(repo) end)

      assert result == :ok
      assert elapsed_us < 50_000
    end

    test "waits for a drain_requested?/0-observing stub to exit and returns :ok" do
      repo = fresh_repo()
      run_key = {repo, "run-1"}
      pid = spawn_stub(run_key, "001", &drain_aware_loop/1)

      task = Task.async(fn -> Workers.drain(repo) end)
      assert_receive :drained, 1_000
      assert Task.await(task, 2_000) == :ok
      refute Process.alive?(pid)
    end

    test "times out on a stub that ignores the drain past its bound, naming the stuck feature/run" do
      repo = fresh_repo()
      run_key = {repo, "run-1"}
      pid = spawn_stub(run_key, "002", &ignores_drain/1)
      assert_receive :running

      assert {:error, {:drain_timeout, stuck}} =
               Workers.drain(repo, call_grace_ms: 0, finalize_margin_ms: 0)

      assert stuck == [%{feature_id: "002", run_id: "run-1"}]
      # the request latch is cleared even on timeout
      refute Workers.drain_requested?()

      Process.exit(pid, :kill)
    end

    test "no-ops on a worker already dead before drain/2 is called" do
      repo = fresh_repo()
      run_key = {repo, "run-1"}
      pid = spawn_stub(run_key, "003", fn _parent -> :ok end)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      # `Registry` removes a dead process's entry only after it processes the
      # `:DOWN` itself — a race against this test's own monitor, not
      # something `drain/2` needs to wait out (a dead pid yields an
      # immediate `:DOWN` to `drain/2`'s own monitor too).
      assert Workers.drain(repo) == :ok
    end
  end

  describe "session_started/1" do
    test "updates deadline_at for the calling (owner) process only" do
      repo = fresh_repo()
      run_key = {repo, "run-1"}

      pid =
        spawn_stub(run_key, "001", fn parent ->
          Workers.session_started(60_000)
          send(parent, :published)
          Process.sleep(:infinity)
        end)

      assert_receive :published

      assert [%{pid: ^pid, deadline_at: %DateTime{} = deadline_at}] = Workers.in_flight(repo)
      assert DateTime.diff(deadline_at, DateTime.utc_now(), :millisecond) > 0

      # Calling from an unregistered process (this test) never touches the
      # worker's entry — owner-only (Registry.update_value/3 semantics).
      assert Workers.session_started(1_000) == :ok
      assert [%{pid: ^pid, deadline_at: ^deadline_at}] = Workers.in_flight(repo)

      Process.exit(pid, :kill)
    end

    test "no-ops when the caller is not a registered worker" do
      assert Workers.session_started(1_000) == :ok
    end
  end
end
