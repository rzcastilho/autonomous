defmodule Autonomous.ConsoleProjection do
  @moduledoc """
  Boot-started GenServer owning the console's derived read-model
  (`specs/008-control-plane/contracts/console_projection.md`). Attaches to
  orchestrator telemetry (`Autonomous.Telemetry.events/0`), folds
  events via the pure `ConsoleReadModel`, and broadcasts diffs over
  `Phoenix.PubSub` on topic `"console:run"`.

  Never persists (FR-036) — a restart rebuilds the feed and feature slices from
  the durable run record (`ConsoleHistory`, feature 038), then folds subsequent
  telemetry. The reconcile probe runs in a `Task` off the callback
  (feature 038): a slow or dead Coordinator is a missed refresh, never a crash,
  and the last good status stays available via `last_known/1`. Never mutates orchestrator state — read/subscribe
  only.
  """

  use GenServer

  require Logger

  alias Autonomous.{
    ConsoleDelay,
    ConsoleHistory,
    ConsoleReadModel,
    Coordinator,
    CoordinatorProbe,
    Store
  }

  @topic "console:run"
  @reconcile_ms 2_000
  @probe_timeout 5_000
  # A page render probes several times (topbar, seed, counts) and mounts twice;
  # a short budget keeps a stalled Coordinator under the 3 s page-load limit.
  @page_probe_ms 250

  # ---- Client API -----------------------------------------------------

  @doc """
  Start the projection. Options:

    * `:pubsub` — `Phoenix.PubSub` server name (default `Autonomous.PubSub`).
    * `:coordinator` — `Coordinator` server name consulted on reconcile (default `Coordinator`).
    * `:probe_timeout` — Coordinator wait limit for the reconcile probe (default `5000`).
    * `:history` — zero-arity loader of the run record to rebuild from
      (`{:ok, run_detail} | :none | {:error, term}`; default: the in-flight,
      else parked, run of the served repository).
    * `:reconcile_ms` — reconcile tick interval; `0` disables it (default `2000`).
    * `:name` — process name (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current projection read-model: `%{features: ..., feed: ...}`."
  @spec read(GenServer.server()) :: ConsoleReadModel.t()
  def read(server \\ __MODULE__), do: GenServer.call(server, :read)

  @doc """
  Last status the reconcile probe saw: `%{coordinator:, delayed?:}`.
  Never blocks on the Coordinator; an absent projection yields empty values.
  """
  @spec last_known(GenServer.server()) :: %{
          coordinator: map() | nil,
          delayed?: boolean()
        }
  def last_known(server \\ __MODULE__) do
    GenServer.call(server, :last_known)
  catch
    :exit, _ -> %{coordinator: nil, delayed?: false}
  end

  @doc "Exit-safe `read/1`: an empty model when the projection is absent or unresponsive."
  @spec read_safe(GenServer.server()) :: ConsoleReadModel.t()
  def read_safe(server \\ __MODULE__) do
    read(server)
  catch
    :exit, _ -> ConsoleReadModel.new()
  end

  @doc """
  Coordinator status for console pages: a live probe (bounded by `timeout`),
  falling back to the projection's last-known status when the Coordinator is
  slow. `nil` when no Coordinator is running.
  """
  @spec coordinator_or_last_known(timeout()) :: map() | nil
  def coordinator_or_last_known(timeout \\ @page_probe_ms) do
    case CoordinatorProbe.status(Coordinator, timeout) do
      {:ok, status} -> status
      :none -> nil
      {:error, _} -> last_known().coordinator
    end
  end

  @doc "The PubSub topic every LiveView subscribes to on mount."
  @spec topic() :: String.t()
  def topic, do: @topic

  # ---- Server -----------------------------------------------------------

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, Autonomous.PubSub)
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    reconcile_ms = Keyword.get(opts, :reconcile_ms, @reconcile_ms)
    probe_timeout = Keyword.get(opts, :probe_timeout, @probe_timeout)
    handler_id = {__MODULE__, self()}

    :telemetry.attach_many(
      handler_id,
      Autonomous.Telemetry.events(),
      &__MODULE__.handle_telemetry/4,
      self()
    )

    if reconcile_ms > 0, do: :timer.send_interval(reconcile_ms, :reconcile)

    state = %{
      model: ConsoleReadModel.new(),
      pubsub: pubsub,
      coordinator: coordinator,
      probe_timeout: probe_timeout,
      last_known: %{coordinator: nil},
      probe: nil,
      misses: 0,
      warned_at: nil,
      history: Keyword.get(opts, :history, &__MODULE__.load_history/0),
      handler_id: handler_id
    }

    {:ok, state, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state) do
    {:noreply, %{state | model: rebuild_model(state.history)}}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @impl true
  def handle_call(:read, _from, state), do: {:reply, state.model, state}

  def handle_call(:last_known, _from, state),
    do: {:reply, Map.put(state.last_known, :delayed?, ConsoleDelay.delayed?(state.misses)), state}

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata}, state) do
    model = ConsoleReadModel.apply_event(state.model, event, measurements, metadata)
    broadcast_diff(state, event, model, metadata)
    {:noreply, %{state | model: model}}
  end

  # One probe in flight at a time; the Coordinator wait happens in the task,
  # so this process keeps answering `read/1` and folding telemetry.
  def handle_info(:reconcile, %{probe: nil} = state) do
    %{coordinator: coordinator, probe_timeout: timeout} = state

    task = Task.async(fn -> CoordinatorProbe.status(coordinator, timeout) end)

    {:noreply, %{state | probe: task.ref}}
  end

  def handle_info(:reconcile, state), do: {:noreply, state}

  def handle_info({ref, result}, %{probe: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_probe(%{state | probe: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{probe: ref} = state),
    do: {:noreply, %{state | probe: nil}}

  def handle_info(_stale, state), do: {:noreply, state}

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  # ---- helpers -----------------------------------------------------------

  defp broadcast_diff(state, [:speckit, :phase, kind], model, %{feature_id: id})
       when kind in [:start, :stop, :exception] do
    broadcast(
      state,
      {:console, :feature_updated, %{id: id, feature: Map.get(model.features, id)}}
    )

    broadcast_feed(state, model)
  end

  defp broadcast_diff(state, [:speckit, :feature, :terminal], model, %{feature_id: id}) do
    broadcast(
      state,
      {:console, :feature_updated, %{id: id, feature: Map.get(model.features, id)}}
    )

    broadcast_feed(state, model)
  end

  # A new run may have dropped every feature slice; open LiveViews reseed from
  # it on the next reconcile tick.
  defp broadcast_diff(state, [:speckit, :run, :start], model, _metadata),
    do: broadcast_feed(state, model)

  defp broadcast_diff(state, [:speckit, :run, :scope_narrowing_refused], model, _metadata),
    do: broadcast_feed(state, model)

  # The PR url lands on the feature slice, so the open drawer has to be told —
  # the feed entry alone would leave "View PR" unlinked until the next
  # reconcile tick.
  defp broadcast_diff(state, [:speckit, :publish, :opened], model, %{feature_id: id}) do
    broadcast(
      state,
      {:console, :feature_updated, %{id: id, feature: Map.get(model.features, id)}}
    )

    broadcast_feed(state, model)
  end

  defp broadcast_diff(state, [:speckit, :publish, :failed], model, _metadata),
    do: broadcast_feed(state, model)

  defp broadcast_diff(_state, _event, _model, _metadata), do: :ok

  defp broadcast_feed(state, %{feed: [latest | _]}),
    do: broadcast(state, {:console, :feed, latest})

  defp broadcast_feed(_state, %{feed: []}), do: :ok

  defp broadcast(state, message), do: Phoenix.PubSub.broadcast(state.pubsub, @topic, message)

  @doc false
  # Default history loader: the served repository's in-flight run, else its
  # parked run.
  @spec load_history() :: {:ok, map()} | :none | {:error, term()}
  def load_history do
    repo_id = Autonomous.RepoIdentity.partition(Autonomous.Config.repo())

    run_id =
      Autonomous.current_run_id() ||
        case Store.parked_run(repo_id) do
          {:ok, %{run_id: run_id}} -> run_id
          _ -> nil
        end

    case run_id do
      nil -> :none
      run_id -> Autonomous.run_detail(run_id)
    end
  end

  defp rebuild_model(history) do
    case history.() do
      {:ok, detail} ->
        ConsoleHistory.rebuild(detail)

      :none ->
        ConsoleReadModel.new()

      {:error, reason} ->
        Logger.warning("console history rebuild failed: #{inspect(reason)}")
        ConsoleReadModel.new()
    end
  rescue
    error ->
      Logger.warning("console history rebuild raised: #{Exception.message(error)}")
      ConsoleReadModel.new()
  catch
    :exit, reason ->
      Logger.warning("console history rebuild exited: #{inspect(reason)}")
      ConsoleReadModel.new()
  end

  defp apply_probe(state, coordinator_result) do
    misses = ConsoleDelay.step(state.misses, coordinator_result)
    now_ms = System.monotonic_time(:millisecond)
    state = log_probe(state, misses, now_ms)

    case ConsoleDelay.broadcast?(misses, coordinator_result) do
      :silent ->
        %{state | misses: misses}

      :delayed ->
        # Keep showing the last good status, flagged as delayed.
        last = state.last_known
        broadcast(state, reconciled(last.coordinator, true))
        %{state | misses: misses}

      :reconciled ->
        coordinator_status =
          case coordinator_result do
            {:ok, status} -> status
            :none -> nil
          end

        broadcast(state, reconciled(coordinator_status, false))

        %{
          state
          | misses: misses,
            model: ConsoleReadModel.clear_rebuilt(state.model),
            last_known: %{coordinator: coordinator_status}
        }
    end
  end

  defp reconciled(coordinator, delayed?),
    do: {:console, :reconciled, %{coordinator: coordinator, delayed?: delayed?}}

  defp log_probe(state, misses, now_ms) do
    case ConsoleDelay.log?(state.misses, misses, state.warned_at, now_ms) do
      :warn ->
        Logger.warning(
          "console: Coordinator.status/1 not answering (#{misses} consecutive missed refreshes); showing last known state"
        )

        %{state | warned_at: now_ms}

      :recovered ->
        Logger.info("console: Coordinator.status/1 answering again")
        %{state | warned_at: nil}

      :quiet ->
        state
    end
  end
end
