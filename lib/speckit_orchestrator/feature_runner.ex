defmodule SpeckitOrchestrator.FeatureRunner do
  @moduledoc """
  Drives one `FeatureAgent` through the whole pipeline synchronously.

  Started as a supervised `Task` under `RunnerSup` (wired in Phase 4). The loop:
  seed the agent (`feature.init`), then repeatedly `call` the `"phase.run"`
  signal, read the returned agent's `last_outcome`/`last_signals`, and apply
  `Pipeline.next/3` to decide continue / escalate / halt / fail / done. On a
  terminal state it finalizes the agent's status, keeps the worktree on any
  non-`:done` outcome (for post-mortem) or removes it on `:done`, and notifies
  the caller/coordinator.

  Crash semantics: a phase `call` that dies (timeout, agent crash) is caught and
  the feature is marked `:failed` — never retried silently. Implement phases are
  long, so `:phase_timeout` defaults generously.
  """

  alias Jido.{AgentServer, Signal}
  alias SpeckitOrchestrator.{FeatureAgent, Pipeline, Worktree}

  @default_phase_timeout :timer.minutes(45)

  @type terminal :: :done | :escalated | :halted | :failed
  @type result :: %{feature_id: String.t(), status: terminal(), reason: term(), cost_total: number() | nil}

  @doc """
  Run `feature` to a terminal state. Options:

    * `:worktree` — the `%Worktree{}` to run in (removed on `:done`, kept
      otherwise). `nil` runs in the base repo (tests / dry runs).
    * `:ledger` — `Ledger` server for cost recording.
    * `:notify` — an arity-3 fun `(id, status, reason)` or a pid (sent
      `{:feature_finished, id, status, reason}`).
    * `:phase_timeout` — per-phase `call` timeout (default 45 min).
    * `:agent_id` — override the agent id.
  """
  @spec run(SpeckitOrchestrator.Feature.t(), keyword()) :: result() | {:error, term()}
  def run(feature, opts \\ []) do
    worktree = Keyword.get(opts, :worktree)
    ledger = Keyword.get(opts, :ledger)
    timeout = Keyword.get(opts, :phase_timeout, @default_phase_timeout)
    notify = Keyword.get(opts, :notify)

    with {:ok, pid} <- start_agent(feature, opts) do
      try do
        {:ok, _} =
          call(pid, "feature.init", %{feature: feature, worktree: worktree, ledger: ledger}, timeout)

        {status, reason, agent} = loop(pid, Pipeline.first(), timeout, ledger)
        call(pid, "feature.finalize", %{status: status, reason: reason}, timeout)
        handle_worktree(status, worktree)
        notify(notify, feature.id, status, reason)
        stop_agent(pid)

        %{feature_id: feature.id, status: status, reason: reason, cost_total: agent.state.cost_total}
      catch
        kind, err ->
          handle_worktree(:failed, worktree)
          notify(notify, feature.id, :failed, {kind, err})
          stop_agent(pid)
          %{feature_id: feature.id, status: :failed, reason: {kind, err}, cost_total: nil}
      end
    end
  end

  # ---- loop ---------------------------------------------------------------

  defp loop(pid, phase, timeout, ledger) do
    {:ok, agent} = call(pid, "phase.run", %{phase: phase}, timeout)
    st = agent.state

    case Pipeline.next(phase, st.last_outcome, st.last_signals) do
      {:cont, next} ->
        # Drain-don't-kill: the current phase finished; if the breaker has since
        # tripped, halt before starting the next phase rather than mid-phase.
        if breaker_tripped?(ledger),
          do: {:halted, :breaker, agent},
          else: loop(pid, next, timeout, ledger)

      {:done, :done} ->
        {:done, :done, agent}

      {:escalated, reason} ->
        {:escalated, reason, agent}

      {:halted, reason} ->
        {:halted, reason, agent}

      {:failed, reason} ->
        {:failed, reason, agent}
    end
  end

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: SpeckitOrchestrator.Ledger.breaker_tripped?(ledger)

  # ---- helpers ------------------------------------------------------------

  defp call(pid, type, data, timeout) do
    AgentServer.call(pid, Signal.new!(type, data, source: "/runner"), timeout)
  end

  defp handle_worktree(_status, nil), do: :ok
  defp handle_worktree(:done, %Worktree{} = wt), do: Worktree.remove(wt)
  defp handle_worktree(_terminal, %Worktree{} = wt), do: Worktree.keep_for_inspection(wt)

  defp start_agent(feature, opts) do
    id = Keyword.get(opts, :agent_id, "feature-#{feature.id}-#{System.unique_integer([:positive])}")
    # register_global: false — standalone agent addressed by pid; no global
    # Jido.Registry needed until the app runs under its Jido instance (Phase 4).
    AgentServer.start_link(agent: FeatureAgent, id: id, register_global: false)
  end

  defp stop_agent(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  end

  defp notify(nil, _id, _status, _reason), do: :ok
  defp notify(fun, id, status, reason) when is_function(fun, 3), do: fun.(id, status, reason)

  defp notify(pid, id, status, reason) when is_pid(pid),
    do: send(pid, {:feature_finished, id, status, reason})
end
