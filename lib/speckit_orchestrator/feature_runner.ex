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

  require Logger

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.{
    Checkpoint,
    Config,
    Describe,
    FeatureAgent,
    PhaseResult,
    Pipeline,
    Transcripts,
    Worktree
  }

  # Kept strictly larger than the jido_action `:default_timeout` (config.exs, 45
  # min) so the *action* execution timeout is the governing guard, not this outer
  # AgentServer.call — otherwise the call fires first and the phase is marked
  # :failed while the action is still legitimately running.
  @default_phase_timeout :timer.minutes(50)

  @type terminal :: :done | :escalated | :halted | :failed
  @type result :: %{
          feature_id: String.t(),
          status: terminal(),
          reason: term(),
          cost_total: number() | nil
        }

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
          call(
            pid,
            "feature.init",
            %{feature: feature, worktree: worktree, ledger: ledger},
            timeout
          )

        {status, reason, agent} =
          loop(pid, feature, Pipeline.first(), 1, timeout, ledger, worktree)

        call(pid, "feature.finalize", %{status: status, reason: reason}, timeout)
        checkpoint(feature, status, reason, agent)
        handle_worktree(feature, status, worktree)
        emit_terminal(feature, status, reason, agent.state.cost_total)
        notify(notify, feature.id, status, reason)
        stop_agent(pid)

        %{
          feature_id: feature.id,
          status: status,
          reason: reason,
          cost_total: agent.state.cost_total
        }
      catch
        kind, err ->
          handle_worktree(feature, :failed, worktree)
          notify(notify, feature.id, :failed, {kind, err})
          stop_agent(pid)
          %{feature_id: feature.id, status: :failed, reason: {kind, err}, cost_total: nil}
      end
    end
  end

  # ---- loop ---------------------------------------------------------------

  defp loop(pid, feature, phase, step, timeout, ledger, worktree) do
    agent =
      run_phase_with_retry(
        pid,
        feature,
        phase,
        step,
        timeout,
        worktree,
        Config.phase_max_retries()
      )

    st = agent.state

    case Pipeline.next(phase, st.last_outcome, st.last_signals) do
      {:cont, next} ->
        # Drain-don't-kill: the current phase finished; if the breaker has since
        # tripped, halt before starting the next phase rather than mid-phase.
        if breaker_tripped?(ledger),
          do: {:halted, :breaker, agent},
          else: loop(pid, feature, next, step + 1, timeout, ledger, worktree)

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

  # Re-run a phase that failed transiently (a server/API drop, not a real error)
  # up to `retries` times before giving up — a single dropped stream should not
  # fail an expensive feature. Real errors and the gate outcomes (`:escalated` /
  # `:halted`, which are signals, not `:error`) fall straight through.
  defp run_phase_with_retry(pid, feature, phase, step, timeout, worktree, retries) do
    agent = run_phase(pid, feature, phase, step, timeout, worktree)
    st = agent.state

    if retries > 0 and st.last_outcome == :error and PhaseResult.transient?(st.last_result) do
      Logger.warning(
        "feature #{feature.id} phase #{phase} failed transiently — retrying (#{retries} left)"
      )

      run_phase_with_retry(pid, feature, phase, step, timeout, worktree, retries - 1)
    else
      agent
    end
  end

  # Run one phase inside a telemetry span, write its transcript, and log the
  # transition.
  defp run_phase(pid, feature, phase, step, timeout, worktree) do
    meta = %{feature_id: feature.id, phase: phase, model: Config.model_for(phase), step: step}

    :telemetry.span([:speckit, :phase], meta, fn ->
      {:ok, agent} = call(pid, "phase.run", %{phase: phase}, timeout)
      entry = List.first(agent.state.history) || %{}
      Transcripts.write(worktree, step, phase, agent.state.last_result)
      Logger.info("feature #{feature.id} phase #{phase} -> #{inspect(Map.get(entry, :outcome))}")

      {agent,
       Map.merge(meta, %{outcome: Map.get(entry, :outcome), cost: Map.get(entry, :cost, 0.0)})}
    end)
  end

  defp emit_terminal(feature, status, reason, cost_total) do
    :telemetry.execute(
      [:speckit, :feature, :terminal],
      %{cost_total: cost_total || 0.0},
      %{feature_id: feature.id, status: status, reason: reason}
    )

    Logger.info("feature #{feature.id} terminal=#{status} reason=#{inspect(reason)}")
  end

  # Best-effort resume pointer for a diverted terminal (FR-010). Delete-on-:done
  # (US2) is wired separately once Checkpoint.delete/1 is implemented.
  defp checkpoint(feature, :done, _reason, _agent), do: Checkpoint.delete(feature.id)

  defp checkpoint(feature, status, reason, agent) do
    Checkpoint.write(%{
      feature_id: feature.id,
      last_phase: agent.state.phase,
      status: status,
      reason: reason,
      session_id: agent.state.session_id
    })
  end

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: SpeckitOrchestrator.Ledger.breaker_tripped?(ledger)

  # ---- helpers ------------------------------------------------------------

  defp call(pid, type, data, timeout) do
    AgentServer.call(pid, Signal.new!(type, data, source: "/runner"), timeout)
  end

  defp handle_worktree(_feature, _status, nil), do: :ok

  # Commit whatever the pipeline generated onto the feature branch BEFORE the
  # worktree is torn down — otherwise a successful run's spec/plan/tasks/code is
  # discarded on removal. On :done under the PR workflow, ask Claude to author the
  # commit message + PR text from the real diff first (best-effort; falls back to
  # the template). Commit on kept terminals too, so a later `resolve/1` (which
  # removes the worktree) doesn't lose them either.
  defp handle_worktree(feature, :done, %Worktree{feature_id: id} = wt) do
    {message, pr} = authored_or_template(feature, wt)
    _ = Worktree.commit(wt, message)
    if pr, do: Describe.write_pr(id, pr)
    Worktree.remove(wt)
  end

  defp handle_worktree(feature, status, %Worktree{} = wt) do
    _ = Worktree.commit(wt, "speckit: feature #{feature.id} pipeline artifacts (#{status})")
    Worktree.keep_for_inspection(wt)
  end

  # Claude-authored commit message + PR text when the PR workflow is on; else the
  # mechanical template. A describe failure logs and falls back — never blocks.
  defp authored_or_template(feature, wt) do
    fallback = "speckit: feature #{feature.id} pipeline artifacts (done)"

    if Config.pr_workflow?() do
      case Describe.run(feature, wt) do
        {:ok, d} ->
          message = if d.commit_message == "", do: fallback, else: d.commit_message
          {message, %{pr_title: d.pr_title, pr_body: d.pr_body}}

        {:error, reason} ->
          Logger.warning("feature #{feature.id} describe failed: #{inspect(reason)}")
          {fallback, nil}
      end
    else
      {fallback, nil}
    end
  end

  defp start_agent(feature, opts) do
    id =
      Keyword.get(opts, :agent_id, "feature-#{feature.id}-#{System.unique_integer([:positive])}")

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
