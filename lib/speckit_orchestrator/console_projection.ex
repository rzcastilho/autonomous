defmodule SpeckitOrchestrator.ConsoleProjection do
  @moduledoc """
  Boot-started GenServer owning the console's derived read-model
  (`specs/008-control-plane/contracts/console_projection.md`). Attaches to
  orchestrator telemetry (`SpeckitOrchestrator.Telemetry.events/0`), folds
  events via the pure `ConsoleReadModel`, and broadcasts diffs over
  `Phoenix.PubSub` on topic `"console:run"`.

  Never persists (FR-036) — a restart rebuilds from `Coordinator.status/0` +
  subsequent telemetry. Never mutates orchestrator state — read/subscribe
  only.
  """

  use GenServer

  alias SpeckitOrchestrator.{ConsoleReadModel, Coordinator, Ledger}

  @topic "console:run"
  @reconcile_ms 2_000

  # ---- Client API -----------------------------------------------------

  @doc """
  Start the projection. Options:

    * `:pubsub` — `Phoenix.PubSub` server name (default `SpeckitOrchestrator.PubSub`).
    * `:coordinator` — `Coordinator` server name consulted on reconcile (default `Coordinator`).
    * `:ledger` — `Ledger` server name consulted on reconcile (default `Ledger`).
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

  @doc "The PubSub topic every LiveView subscribes to on mount."
  @spec topic() :: String.t()
  def topic, do: @topic

  # ---- Server -----------------------------------------------------------

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, SpeckitOrchestrator.PubSub)
    coordinator = Keyword.get(opts, :coordinator, Coordinator)
    ledger = Keyword.get(opts, :ledger, Ledger)
    reconcile_ms = Keyword.get(opts, :reconcile_ms, @reconcile_ms)
    handler_id = {__MODULE__, self()}

    :telemetry.attach_many(
      handler_id,
      SpeckitOrchestrator.Telemetry.events(),
      &__MODULE__.handle_telemetry/4,
      self()
    )

    if reconcile_ms > 0, do: :timer.send_interval(reconcile_ms, :reconcile)

    state = %{
      model: ConsoleReadModel.new(),
      pubsub: pubsub,
      coordinator: coordinator,
      ledger: ledger,
      handler_id: handler_id
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  @impl true
  def handle_call(:read, _from, state), do: {:reply, state.model, state}

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata}, state) do
    model = ConsoleReadModel.apply_event(state.model, event, measurements, metadata)
    broadcast_diff(state, event, model, metadata)
    {:noreply, %{state | model: model}}
  end

  def handle_info(:reconcile, state) do
    coordinator_status = coordinator_status(state.coordinator)
    ledger_snapshot = Ledger.snapshot(state.ledger)

    broadcast(
      state,
      {:console, :reconciled, %{coordinator: coordinator_status, ledger: ledger_snapshot}}
    )

    {:noreply, state}
  end

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

  defp broadcast_diff(_state, _event, _model, _metadata), do: :ok

  defp broadcast_feed(state, %{feed: [latest | _]}),
    do: broadcast(state, {:console, :feed, latest})

  defp broadcast_feed(_state, %{feed: []}), do: :ok

  defp broadcast(state, message), do: Phoenix.PubSub.broadcast(state.pubsub, @topic, message)

  defp coordinator_status(coordinator) when is_atom(coordinator) do
    if Process.whereis(coordinator), do: Coordinator.status(coordinator)
  end

  defp coordinator_status(coordinator), do: Coordinator.status(coordinator)
end
