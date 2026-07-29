defmodule SpeckitOrchestrator.Store.Health do
  @moduledoc """
  Persistence breaker (018, research R9, contracts/persistence-failure.md) —
  a thin `GenServer` mirroring `Ledger`'s shape exactly: holds
  `:ok | {:failed, reason, DateTime.t()}`, nothing more. The two call sites
  (`Coordinator.advance/1` releasing nothing new, `FeatureRunner`'s
  inter-phase drain point) decide what a failure means; this module only
  holds the flag. Every `Store.Writer` function reports an aborted
  transaction here before returning `{:error, reason}` — no writer raises
  into the run (FR-010).
  """

  use GenServer

  @doc """
  Start the health server. Options:

  * `:name` — process name (defaults to `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Record a write failure."
  @spec record_failure(GenServer.server(), term()) :: :ok
  def record_failure(server \\ __MODULE__, reason) do
    GenServer.call(server, {:record_failure, reason})
  end

  @doc "True once a failure has been recorded and not yet cleared."
  @spec failed?(GenServer.server()) :: boolean()
  def failed?(server \\ __MODULE__), do: GenServer.call(server, :failed?)

  @doc "`:ok`, or `{:failed, reason, recorded_at}`."
  @spec status(GenServer.server()) :: :ok | {:failed, term(), DateTime.t()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Operator action only — clears a recorded failure once the store is writable again."
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @impl true
  def init(_opts), do: {:ok, :ok}

  @impl true
  def handle_call({:record_failure, reason}, _from, _state) do
    {:reply, :ok, {:failed, reason, DateTime.utc_now()}}
  end

  def handle_call(:failed?, _from, state),
    do: {:reply, match?({:failed, _reason, _at}, state), state}

  def handle_call(:status, _from, state), do: {:reply, state, state}
  def handle_call(:clear, _from, _state), do: {:reply, :ok, :ok}
end
