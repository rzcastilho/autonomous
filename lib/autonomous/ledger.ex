defmodule Autonomous.Ledger do
  @moduledoc """
  Cost accumulator as a `GenServer` (039: informational only).

  Holds one quantity, `committed` — the spend every phase attempt records via
  `record/3` (actual cost when the session reports one, the per-phase
  estimate otherwise; `Cost.for_phase/2`). It feeds the run report's `spend`,
  the console topbar and `close_run(spend_usd: …)`. Nothing reads it to
  decide anything: there is no budget, no reservation and no breaker — runs
  never stop, drain or refuse because of spend.
  """

  use GenServer

  # ---- Client API ---------------------------------------------------------

  @doc """
  Start the ledger. Options:

  * `:name` — process name (defaults to `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record spend. `ref` is ignored (kept for the actions' existing call shape —
  they always pass `nil`). Returns the new committed total.
  """
  @spec record(GenServer.server(), term(), number()) :: number()
  def record(server \\ __MODULE__, _ref, amount) when is_number(amount) and amount >= 0 do
    GenServer.call(server, {:record, amount})
  end

  @doc "Committed spend so far."
  @spec spent(GenServer.server()) :: number()
  def spent(server \\ __MODULE__), do: GenServer.call(server, :spent)

  @doc """
  Restore committed spend from a recorded figure on resume (FR-012).
  Sets `committed = max(committed, recorded)` — idempotent and monotonic
  (never lowers an already-higher live value). See
  `specs/009-crash-recovery/contracts/ledger-restore.md`.
  """
  @spec restore(GenServer.server(), number()) :: number()
  def restore(server \\ __MODULE__, recorded) when is_number(recorded) and recorded >= 0 do
    GenServer.call(server, {:restore, recorded})
  end

  @doc "Snapshot: `%{committed: number}`."
  @spec snapshot(GenServer.server()) :: %{committed: number()}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # ---- Server -------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{committed: 0}}

  @impl true
  def handle_call({:restore, recorded}, _from, state) do
    committed = max(state.committed, recorded)
    {:reply, committed, %{state | committed: committed}}
  end

  def handle_call({:record, amount}, _from, state) do
    committed = state.committed + amount
    {:reply, committed, %{state | committed: committed}}
  end

  def handle_call(:spent, _from, state), do: {:reply, state.committed, state}

  def handle_call(:snapshot, _from, state), do: {:reply, %{committed: state.committed}, state}
end
