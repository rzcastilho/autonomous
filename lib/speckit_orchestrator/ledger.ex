defmodule SpeckitOrchestrator.Ledger do
  @moduledoc """
  Cost circuit-breaker as a `GenServer`.

  Two quantities: `committed` (recorded actual spend) and outstanding
  `reservations` (estimated spend for in-flight phases). A run reserves before a
  phase, records the actual (estimated) cost after, and consults the breaker
  before starting new work.

  ## Reservation rule & invariant

  `reserve/2` is rejected once `committed + reserved_total >= budget` — i.e.
  once committed-plus-reserved fills the budget, no further reservation is
  granted. Combined with `record/3` recording no more than the reserved amount,
  this guarantees:

      committed < budget + max_single_reservation

  at all times. The breaker (`breaker_tripped?/1`) trips at `committed >= budget`.

  Note (Phase 0 finding): the Claude adapter does not surface usage/cost events
  (`capabilities.usage? == false`), so recorded amounts are config-derived
  per-phase estimates, not measured spend. See `docs/harness-contract.md`.
  """

  use GenServer

  @type ref :: reference()

  # ---- Client API ---------------------------------------------------------

  @doc """
  Start the ledger. Options:

  * `:budget` — run budget in the same unit as reserve/record amounts
    (defaults to `Config.budget_usd/0`).
  * `:name` — process name (defaults to `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reserve `amount` for an in-flight phase. Returns `{:ok, ref}` or
  `{:error, :budget_exceeded}` when there is no headroom.
  """
  @spec reserve(GenServer.server(), number()) :: {:ok, ref()} | {:error, :budget_exceeded}
  def reserve(server \\ __MODULE__, amount) when is_number(amount) and amount >= 0 do
    GenServer.call(server, {:reserve, amount})
  end

  @doc """
  Record actual spend for a previously reserved `ref`, releasing the
  reservation. If `ref` is unknown (e.g. spend without a reservation) the amount
  is still committed. Returns the new committed total.
  """
  @spec record(GenServer.server(), ref() | nil, number()) :: number()
  def record(server \\ __MODULE__, ref, amount) when is_number(amount) and amount >= 0 do
    GenServer.call(server, {:record, ref, amount})
  end

  @doc "True once committed spend has reached or exceeded the budget."
  @spec breaker_tripped?(GenServer.server()) :: boolean()
  def breaker_tripped?(server \\ __MODULE__) do
    GenServer.call(server, :breaker_tripped?)
  end

  @doc "Committed spend so far."
  @spec spent(GenServer.server()) :: number()
  def spent(server \\ __MODULE__), do: GenServer.call(server, :spent)

  @doc """
  Restore committed spend from a recorded figure on resume (FR-012).
  Sets `committed = max(committed, recorded)` — idempotent and monotonic
  (never lowers an already-higher live value); does not touch `reservations`
  or `budget`. See `specs/009-crash-recovery/contracts/ledger-restore.md`.
  """
  @spec restore(GenServer.server(), number()) :: number()
  def restore(server \\ __MODULE__, recorded) when is_number(recorded) and recorded >= 0 do
    GenServer.call(server, {:restore, recorded})
  end

  @doc """
  Live-config apply (`contracts/live_config.md`): update the run budget.
  Forward-only — breaker decisions (`reserve/2`, `breaker_tripped?/1`) read
  the new budget starting with the next call; never retroactively alters
  already-committed/reserved amounts.
  """
  @spec set_budget(GenServer.server(), number()) :: :ok
  def set_budget(server \\ __MODULE__, amount) when is_number(amount) and amount >= 0 do
    GenServer.call(server, {:set_budget, amount})
  end

  @doc "Full snapshot: `%{budget, committed, reserved, tripped?}`."
  @spec snapshot(GenServer.server()) :: %{
          budget: number(),
          committed: number(),
          reserved: number(),
          tripped?: boolean()
        }
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  # ---- Server -------------------------------------------------------------

  @impl true
  def init(opts) do
    budget = Keyword.get_lazy(opts, :budget, &default_budget/0)

    {:ok, %{budget: budget, committed: 0, reservations: %{}}}
  end

  @impl true
  def handle_call({:reserve, amount}, _from, state) do
    if state.committed + reserved_total(state) >= state.budget do
      {:reply, {:error, :budget_exceeded}, state}
    else
      ref = make_ref()
      {:reply, {:ok, ref}, put_in(state.reservations[ref], amount)}
    end
  end

  def handle_call({:restore, recorded}, _from, state) do
    committed = max(state.committed, recorded)
    {:reply, committed, %{state | committed: committed}}
  end

  def handle_call({:record, ref, amount}, _from, state) do
    committed = state.committed + amount
    reservations = if ref, do: Map.delete(state.reservations, ref), else: state.reservations
    state = %{state | committed: committed, reservations: reservations}
    {:reply, committed, state}
  end

  def handle_call(:breaker_tripped?, _from, state) do
    {:reply, tripped?(state), state}
  end

  def handle_call(:spent, _from, state) do
    {:reply, state.committed, state}
  end

  def handle_call({:set_budget, amount}, _from, state) do
    {:reply, :ok, %{state | budget: amount}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       budget: state.budget,
       committed: state.committed,
       reserved: reserved_total(state),
       tripped?: tripped?(state)
     }, state}
  end

  # ---- Helpers ------------------------------------------------------------

  defp tripped?(state), do: state.committed >= state.budget

  defp reserved_total(state), do: state.reservations |> Map.values() |> Enum.sum()

  defp default_budget do
    SpeckitOrchestrator.Config.budget_usd()
  end
end
