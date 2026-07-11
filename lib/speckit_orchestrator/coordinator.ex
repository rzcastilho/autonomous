defmodule SpeckitOrchestrator.Coordinator do
  @moduledoc """
  Run-level control plane. Holds the backlog and per-feature statuses, releases
  features in dependency-and-cap-respecting waves, reacts to each feature's
  terminal notification, and emits a final report when the run drains.

  ## Design note (deviation from the plan's "Jido agent + actions")

  The Coordinator is a plain `GenServer`, not a Jido agent. It is the supervisor
  of Task-based `FeatureRunner`s reacting to asynchronous `{:finished, ...}`
  notifications — a textbook GenServer. Modelling it as a Jido agent would push
  process-spawning into action bodies, which the plan itself flags as a purity
  hazard. Jido remains the substrate for the autonomous units (`FeatureAgent`).

  The runner-spawning is an injected seam (`:runner`) so the wave/DAG/breaker
  logic is fully unit-testable without a CLI, worktrees, or agents. The facade
  (`SpeckitOrchestrator.run/0`) supplies the real runner.

  ## Breaker

  A tripped `Ledger` breaker releases **no new** features; in-flight features
  drain (finish their current phase, then halt — enforced in `FeatureRunner`).
  When the in-flight set empties with nothing releasable, the run finalizes;
  undelivered `:pending` features are reported as `blocked` or `not_started`.
  """

  use GenServer

  alias SpeckitOrchestrator.{Feature, Ledger, Release}

  @type status :: Feature.status()

  defstruct features: %{},
            statuses: %{},
            inflight: MapSet.new(),
            cap: 2,
            ledger: nil,
            runner: nil,
            owner: nil,
            self_pid: nil,
            finished?: false,
            report: nil

  # ---- Client API ---------------------------------------------------------

  @doc """
  Start a run. Options:

    * `:features` — list of `%Feature{}` (the validated backlog). Required.
    * `:max_concurrency` — cap (default `Config.max_concurrency/0`).
    * `:ledger` — `Ledger` server for the breaker (optional; no breaker if nil).
    * `:runner` — `fun (feature, notify)` that starts the feature's work and
      arranges for `notify.(id, status, reason)` on terminal. Required.
    * `:owner` — pid to receive `{:run_complete, report}` (optional).
    * `:name` — process name (optional).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Current run snapshot: statuses, in-flight ids, spend, finished?/report."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Notify the coordinator a feature reached a terminal status."
  @spec notify(GenServer.server(), String.t(), status(), term()) :: :ok
  def notify(server, id, status, reason), do: GenServer.cast(server, {:finished, id, status, reason})

  # ---- Server -------------------------------------------------------------

  @impl true
  def init(opts) do
    features = Keyword.fetch!(opts, :features)
    runner = Keyword.fetch!(opts, :runner)

    state = %__MODULE__{
      features: Map.new(features, &{&1.id, &1}),
      statuses: Map.new(features, &{&1.id, :pending}),
      cap: Keyword.get(opts, :max_concurrency, default_cap()),
      ledger: Keyword.get(opts, :ledger),
      runner: runner,
      owner: Keyword.get(opts, :owner),
      self_pid: self()
    }

    {:ok, state, {:continue, :release}}
  end

  @impl true
  def handle_continue(:release, state), do: {:noreply, advance(state)}

  @impl true
  def handle_cast({:finished, id, status, _reason}, state) do
    state = %{
      state
      | statuses: Map.put(state.statuses, id, status),
        inflight: MapSet.delete(state.inflight, id)
    }

    {:noreply, advance(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, snapshot(state), state}
  end

  # ---- orchestration ------------------------------------------------------

  # Release everything the DAG + cap + breaker allow, then check for completion.
  defp advance(%__MODULE__{finished?: true} = state), do: state

  defp advance(state) do
    wave = Release.next_wave(feature_list(state), state.statuses, state.cap, breaker_tripped?(state))
    state = Enum.reduce(wave, state, &spawn_feature/2)
    maybe_finish(state)
  end

  defp spawn_feature(%Feature{id: id} = feature, state) do
    notify = fn fid, status, reason -> notify(state.self_pid, fid, status, reason) end
    state.runner.(feature, notify)

    %{
      state
      | statuses: Map.put(state.statuses, id, :running),
        inflight: MapSet.put(state.inflight, id)
    }
  end

  # The run ends when nothing is in flight and nothing more can be released
  # (all remaining pending features are blocked, or the breaker drained them).
  defp maybe_finish(state) do
    releasable = Release.next_wave(feature_list(state), state.statuses, state.cap, breaker_tripped?(state))

    if MapSet.size(state.inflight) == 0 and releasable == [] do
      report = build_report(state)
      if state.owner, do: send(state.owner, {:run_complete, report})
      %{state | finished?: true, report: report}
    else
      state
    end
  end

  # ---- report -------------------------------------------------------------

  defp build_report(state) do
    grouped = Enum.group_by(state.statuses, fn {_id, status} -> classify(state, status) end, fn {id, _} -> id end)

    %{
      done: ids(grouped, :done),
      escalated: ids(grouped, :escalated),
      halted: ids(grouped, :halted),
      failed: ids(grouped, :failed),
      blocked: blocked_ids(state),
      not_started: not_started_ids(state),
      spend: spend(state),
      breaker_tripped: breaker_tripped?(state)
    }
  end

  # A pending feature is `:blocked` when a prereq ended non-done, else it simply
  # never got released (breaker drain / cap exhaustion at finalize).
  defp classify(_state, status) when status in [:done, :escalated, :halted, :failed], do: status
  defp classify(_state, _pending), do: :pending

  defp blocked_ids(state) do
    for {id, :pending} <- state.statuses,
        Release.blocked?(state.features[id], state.statuses),
        do: id
  end

  defp not_started_ids(state) do
    for {id, :pending} <- state.statuses,
        not Release.blocked?(state.features[id], state.statuses),
        do: id
  end

  defp ids(grouped, key), do: grouped |> Map.get(key, []) |> Enum.sort()

  # ---- helpers ------------------------------------------------------------

  defp snapshot(state) do
    %{
      statuses: state.statuses,
      inflight: MapSet.to_list(state.inflight),
      spend: spend(state),
      breaker_tripped: breaker_tripped?(state),
      finished?: state.finished?,
      report: state.report
    }
  end

  defp feature_list(state), do: Map.values(state.features)

  defp breaker_tripped?(%__MODULE__{ledger: nil}), do: false
  defp breaker_tripped?(%__MODULE__{ledger: ledger}), do: Ledger.breaker_tripped?(ledger)

  defp spend(%__MODULE__{ledger: nil}), do: 0.0
  defp spend(%__MODULE__{ledger: ledger}), do: Ledger.spent(ledger)

  defp default_cap, do: SpeckitOrchestrator.Config.max_concurrency()
end
