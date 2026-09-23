defmodule SpeckitOrchestrator.Workers do
  @moduledoc """
  Makes every `RunnerSup` worker findable and drainable (026,
  `contracts/workers.md`).

  A worker is a `Task.Supervisor` child spawned through `spawn/3`, which
  registers it — as the *first* act, before the caller's function runs — in
  `SpeckitOrchestrator.WorkerRegistry` (`Registry`, `keys: :duplicate`), keyed
  by `repo_id`. The worker itself publishes its current session's deadline via
  `session_started/1`; `drain_requested?/0` is the boundary predicate every
  session-driving site (phase, chunk, remediation) consults immediately after
  the breaker check, at exactly the point where the preceding session's
  attempt/checkpoint/transcript are already recorded.

  A registered worker's mutable deadline lives in a public ETS table keyed by
  pid, not in the `Registry` value — `Registry.update_value/3` is unsupported
  for `:duplicate` registries, since a shared key admits no single "the value
  for this key+pid" to update in place. `in_flight/1` joins the two. This
  process also monitors every registered pid solely to clear that table when
  the worker exits, so no entry can ever outlive the process it describes.

  `drain/1` never kills a worker — it sets a request the worker observes at
  its own boundary, and waits up to that worker's own deadline (`Workers.
  Bound.wait_ms/3`) for it to exit on its own.
  """

  use GenServer

  alias SpeckitOrchestrator.Workers.Bound

  @registry SpeckitOrchestrator.WorkerRegistry
  @requests_table __MODULE__.DrainRequests
  @deadlines_table __MODULE__.Deadlines

  @type entry :: %{
          pid: pid(),
          feature_id: String.t(),
          run_id: binary(),
          deadline_at: DateTime.t() | nil
        }

  # ---- Client API -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start `fun` as a `RunnerSup` child, registering it under `elem(run_key, 0)`
  (the repository) before `fun` runs. `run_key == nil` starts the same child
  with no registration (test seam / dry runs). Never links the child to the
  caller or the Coordinator (FR-009).
  """
  @spec spawn(SpeckitOrchestrator.Store.run_key() | nil, String.t(), (-> any())) ::
          {:ok, pid()} | {:error, term()}
  def spawn(run_key, feature_id, fun) when is_function(fun, 0) do
    result =
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        register(run_key, feature_id)
        fun.()
      end)

    case {result, run_key} do
      {{:ok, pid}, {_repo_id, _run_id}} -> GenServer.cast(__MODULE__, {:monitor, pid})
      _ -> :ok
    end

    result
  end

  @doc """
  Called by the worker (owner-only), immediately before each session-driving
  `AgentServer.call`, with that session's deadline in ms from now. No-op when
  the calling process is not a registered worker.
  """
  @spec session_started(pos_integer()) :: :ok
  def session_started(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0 do
    if registered?() do
      deadline_at = DateTime.add(DateTime.utc_now(), deadline_ms, :millisecond)
      :ets.insert(@deadlines_table, {self(), deadline_at})
    end

    :ok
  end

  @doc """
  The boundary predicate: `true` iff a drain request is currently latched
  against the calling process. Pure read — never consumes the latch.
  """
  @spec drain_requested?() :: boolean()
  def drain_requested?, do: :ets.member(@requests_table, self())

  @doc "Registered workers for `repo_id`, read-only. Other repositories never appear (FR-007)."
  @spec in_flight(binary()) :: [entry()]
  def in_flight(repo_id) do
    @registry
    |> Registry.lookup(repo_id)
    |> Enum.map(fn {pid, value} ->
      value
      |> Map.put(:pid, pid)
      |> Map.put(:deadline_at, deadline_for(pid))
    end)
  end

  @doc """
  Requests every worker registered for `repo_id` to stop at its next boundary
  and waits for it, bounded by each worker's own `Bound.wait_ms/3`. An empty
  registry returns `:ok` immediately, with no wait (FR-012, SC-005). Never
  calls `Process.exit/2` on a worker, nor stops its agent — including on
  timeout.

  `bound_opts` is forwarded to `Bound.wait_ms/3` — production callers never
  pass it; tests use it to shrink the fixed grace/margin so a deliberate
  timeout doesn't cost real minutes.
  """
  @spec drain(binary(), keyword()) ::
          :ok | {:error, {:drain_timeout, [%{feature_id: String.t(), run_id: binary()}]}}
  def drain(repo_id, bound_opts \\ []) do
    case in_flight(repo_id) do
      [] ->
        :ok

      entries ->
        run_drain(repo_id, entries, bound_opts)
    end
  end

  # ---- Server -----------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@requests_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@deadlines_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@deadlines_table, pid)
    :ets.delete(@requests_table, pid)
    {:noreply, state}
  end

  # ---- registration -----------------------------------------------------

  defp register(nil, _feature_id), do: :ok

  defp register({repo_id, run_id}, feature_id) do
    Registry.register(@registry, repo_id, %{feature_id: feature_id, run_id: run_id})
    :ok
  end

  defp registered?, do: Registry.keys(@registry, self()) != []

  defp deadline_for(pid) do
    case :ets.lookup(@deadlines_table, pid) do
      [{^pid, deadline_at}] -> deadline_at
      [] -> nil
    end
  end

  # ---- drain --------------------------------------------------------------

  defp run_drain(repo_id, entries, bound_opts) do
    now = DateTime.utc_now()
    feature_ids = Enum.map(entries, & &1.feature_id)

    :telemetry.execute(
      [:speckit, :drain, :start],
      %{},
      %{repo_id: repo_id, feature_ids: feature_ids}
    )

    watched =
      Enum.map(entries, fn entry ->
        insert_request(entry.pid)

        %{
          ref: Process.monitor(entry.pid),
          pid: entry.pid,
          feature_id: entry.feature_id,
          run_id: entry.run_id,
          wait_ms: Bound.wait_ms(entry.deadline_at, now, bound_opts)
        }
      end)

    deadline_ms =
      System.monotonic_time(:millisecond) + (watched |> Enum.map(& &1.wait_ms) |> Enum.max())

    stuck = await_all_down(watched, deadline_ms)

    Enum.each(watched, fn %{pid: pid} -> delete_request(pid) end)
    Enum.each(stuck, fn %{ref: ref} -> Process.demonitor(ref, [:flush]) end)

    result = if stuck == [], do: :ok, else: :timeout

    :telemetry.execute(
      [:speckit, :drain, :stop],
      %{},
      %{repo_id: repo_id, feature_ids: feature_ids, result: result}
    )

    case stuck do
      [] -> :ok
      stuck -> {:error, {:drain_timeout, Enum.map(stuck, &Map.take(&1, [:feature_id, :run_id]))}}
    end
  end

  defp await_all_down([], _deadline_ms), do: []

  defp await_all_down(pending, deadline_ms) do
    timeout = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        case Enum.split_with(pending, &(&1.ref == ref)) do
          {[_done], rest} -> await_all_down(rest, deadline_ms)
          {[], _rest} -> await_all_down(pending, deadline_ms)
        end
    after
      timeout -> pending
    end
  end

  defp insert_request(pid), do: :ets.insert(@requests_table, {pid, DateTime.utc_now()})
  defp delete_request(pid), do: :ets.delete(@requests_table, pid)
end
