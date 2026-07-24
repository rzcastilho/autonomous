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
    * `:start_phase` — phase to begin the loop at (default `Pipeline.first()`),
      for resuming a halted/escalated feature at its stopped phase.
    * `:resume_prompt` — optional operator note carried into agent state
      alongside the fixed `resume_phase` anchor; does not alter any phase
      request in this feature.
    * `:remediation_prompt` — optional operator correction instruction (feature
      013). Non-blank ⇒ a single remediation step runs once, before
      `start_phase`, and a genuine post-retry failure stops the run (`:failed`,
      worktree kept) without entering the phase loop. Blank/absent ⇒ no step,
      byte-identical to a resume with no remediation.
    * `:remediation_model` — model alias override for the remediation step
      only (`nil` ⇒ `Config.model_for(start_phase)`).
    * `:run_context` — a `RunContext.t()` captured by the facade for this run;
      threaded into a diverted-terminal checkpoint write so a resume reapplies
      the original run shape. Defaults to `nil` (tests and non-context callers).
    * `:layout` — the run's resolved `%Layout{}` (`RepoIdentity` + `Layout`,
      FR-011), threaded alongside `:run_context` into checkpoint writes for
      scope-partitioned lookup once `Checkpoint` reads it (Phase 4). Defaults
      to `nil` (tests and non-layout callers).
  """
  @spec run(SpeckitOrchestrator.Feature.t(), keyword()) :: result() | {:error, term()}
  def run(feature, opts \\ []) do
    worktree = Keyword.get(opts, :worktree)
    ledger = Keyword.get(opts, :ledger)
    timeout = Keyword.get(opts, :phase_timeout, @default_phase_timeout)
    notify = Keyword.get(opts, :notify)
    start_phase = Keyword.get(opts, :start_phase, Pipeline.first())
    resume_prompt = Keyword.get(opts, :resume_prompt)
    remediation_prompt = Keyword.get(opts, :remediation_prompt)
    remediation_model = Keyword.get(opts, :remediation_model)
    run_context = Keyword.get(opts, :run_context)
    layout = Keyword.get(opts, :layout)

    with {:ok, pid} <- start_agent(feature, opts) do
      try do
        {:ok, _} =
          call(
            pid,
            "feature.init",
            %{
              feature: feature,
              worktree: worktree,
              ledger: ledger,
              layout: layout,
              phase: start_phase,
              resume_prompt: resume_prompt,
              remediation_prompt: remediation_prompt,
              remediation_model: remediation_model
            },
            timeout
          )

        {status, reason, agent} =
          case maybe_run_remediation(pid, feature, worktree, layout, timeout, remediation_prompt) do
            {:error, agent} ->
              {:failed, :remediation_failed, agent}

            :ok ->
              loop(
                pid,
                feature,
                start_phase,
                Pipeline.step_of(start_phase),
                timeout,
                ledger,
                worktree,
                run_context,
                layout
              )
          end

        call(pid, "feature.finalize", %{status: status, reason: reason}, timeout)
        checkpoint(feature, status, reason, agent, run_context, layout)
        handle_worktree(feature, status, worktree, layout)
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
          handle_worktree(feature, :failed, worktree, layout)
          notify(notify, feature.id, :failed, {kind, err})
          stop_agent(pid)
          %{feature_id: feature.id, status: :failed, reason: {kind, err}, cost_total: nil}
      end
    end
  end

  # ---- pre-phase remediation (feature 013) ---------------------------------

  # Runs once, outside `loop/…`, before the phase loop begins — structurally
  # guarantees "at most once, before the target phase only" (FR-005/SC-003).
  # Blank prompt = zero overhead (FR-004/SC-002): no signal, no telemetry span,
  # no cost.
  defp maybe_run_remediation(pid, feature, worktree, layout, timeout, remediation_prompt) do
    if blank?(remediation_prompt) do
      :ok
    else
      agent =
        remediation_with_retry(pid, feature, timeout, worktree, layout, Config.phase_max_retries())

      if agent.state.last_outcome == :error, do: {:error, agent}, else: :ok
    end
  end

  # Same transient-retry policy as a phase (FR-006): a server/API drop is
  # retried up to Config.phase_max_retries() times before it counts as a
  # genuine failure.
  defp remediation_with_retry(pid, feature, timeout, worktree, layout, retries) do
    agent = run_remediation(pid, feature, timeout, worktree, layout)
    st = agent.state

    if retries > 0 and st.last_outcome == :error and PhaseResult.transient?(st.last_result) do
      Logger.warning(
        "feature #{feature.id} remediation failed transiently — retrying (#{retries} left)"
      )

      remediation_with_retry(pid, feature, timeout, worktree, layout, retries - 1)
    else
      agent
    end
  end

  # Same [:speckit, :phase] span every phase uses (meta.phase = :remediation,
  # FR-012) and the same durable-transcript machinery at step 0
  # (00-remediation.md), so it precedes the target phase's 01-<phase>.md in
  # any listing.
  defp run_remediation(pid, feature, timeout, worktree, layout) do
    meta = %{feature_id: feature.id, phase: :remediation, step: 0}

    :telemetry.span([:speckit, :phase], meta, fn ->
      {:ok, agent} = call(pid, "remediation.run", %{}, timeout)
      entry = List.first(agent.state.history) || %{}
      Transcripts.write(worktree, layout, 0, :remediation, agent.state.last_result)

      Logger.info(
        "feature #{feature.id} remediation -> #{inspect(Map.get(entry, :outcome))}"
      )

      {agent,
       Map.merge(meta, %{outcome: Map.get(entry, :outcome), cost: Map.get(entry, :cost, 0.0)})}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # ---- loop ---------------------------------------------------------------

  defp loop(pid, feature, phase, step, timeout, ledger, worktree, run_context, layout) do
    agent =
      run_phase_with_retry(
        pid,
        feature,
        phase,
        step,
        timeout,
        worktree,
        layout,
        Config.phase_max_retries()
      )

    st = agent.state

    case Pipeline.next(phase, st.last_outcome, st.last_signals) do
      {:cont, next} ->
        # Durable resume pointer for this boundary (FR-001) — before recursing,
        # not after, so a crash mid-next-phase still finds the checkpoint/commit
        # for the phase that already completed.
        Checkpoint.write(%{
          feature_id: feature.id,
          last_phase: phase,
          status: :in_progress,
          reason: nil,
          session_id: st.session_id,
          slug: feature.slug,
          path: feature.path,
          run_context: run_context,
          layout: layout
        })

        if worktree,
          do: Worktree.commit(worktree, "speckit: #{feature.id} checkpoint after #{phase}")

        # Drain-don't-kill: the current phase finished; if the breaker has since
        # tripped, halt before starting the next phase rather than mid-phase.
        if breaker_tripped?(ledger),
          do: {:halted, :breaker, agent},
          else:
            loop(pid, feature, next, step + 1, timeout, ledger, worktree, run_context, layout)

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
  defp run_phase_with_retry(pid, feature, phase, step, timeout, worktree, layout, retries) do
    agent = run_phase(pid, feature, phase, step, timeout, worktree, layout)
    st = agent.state

    if retries > 0 and st.last_outcome == :error and PhaseResult.transient?(st.last_result) do
      Logger.warning(
        "feature #{feature.id} phase #{phase} failed transiently — retrying (#{retries} left)"
      )

      run_phase_with_retry(pid, feature, phase, step, timeout, worktree, layout, retries - 1)
    else
      agent
    end
  end

  # Run one phase inside a telemetry span, write its transcript, and log the
  # transition.
  defp run_phase(pid, feature, phase, step, timeout, worktree, layout) do
    meta = %{feature_id: feature.id, phase: phase, model: Config.model_for(phase), step: step}

    :telemetry.span([:speckit, :phase], meta, fn ->
      {:ok, agent} = call(pid, "phase.run", %{phase: phase}, timeout)
      entry = List.first(agent.state.history) || %{}
      Transcripts.write(worktree, layout, step, phase, agent.state.last_result)
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
  defp checkpoint(feature, :done, _reason, _agent, _run_context, layout),
    do: Checkpoint.delete(feature.id, layout)

  defp checkpoint(feature, status, reason, agent, run_context, layout) do
    Checkpoint.write(%{
      feature_id: feature.id,
      last_phase: agent.state.phase,
      status: status,
      reason: reason,
      session_id: agent.state.session_id,
      slug: feature.slug,
      path: feature.path,
      run_context: run_context,
      layout: layout
    })
  end

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: SpeckitOrchestrator.Ledger.breaker_tripped?(ledger)

  # ---- helpers ------------------------------------------------------------

  defp call(pid, type, data, timeout) do
    AgentServer.call(pid, Signal.new!(type, data, source: "/runner"), timeout)
  end

  defp handle_worktree(_feature, _status, nil, _layout), do: :ok

  # Commit whatever the pipeline generated onto the feature branch BEFORE the
  # worktree is torn down — otherwise a successful run's spec/plan/tasks/code is
  # discarded on removal. On :done under the PR workflow, ask Claude to author the
  # commit message + PR text from the real diff first (best-effort; falls back to
  # the template). Commit on kept terminals too, so a later `resolve/1` (which
  # removes the worktree) doesn't lose them either.
  defp handle_worktree(
         feature,
         :done,
         %Worktree{feature_id: id, repo: repo, branch: branch} = wt,
         layout
       ) do
    {message, pr} = authored_or_template(feature, wt, layout)
    _ = Worktree.squash(wt, merge_base(repo, branch), message)
    if pr, do: Describe.write_pr(id, pr, layout)
    Worktree.remove(wt)
  end

  defp handle_worktree(feature, status, %Worktree{} = wt, _layout) do
    _ = Worktree.commit(wt, "speckit: feature #{feature.id} pipeline artifacts (#{status})")
    Worktree.keep_for_inspection(wt)
  end

  # The branch's fork point, for squash/3's --soft reset target: the commit
  # where the feature branch diverged from Config.pr_base() (the plain
  # workflow's implicit base — its worktree is created from "HEAD" of the
  # currently checked-out branch, which is pr_base by default — and the
  # stacked workflow's explicit stack-base). Falls back to "HEAD" (a no-op
  # reset) if the merge-base lookup itself fails.
  defp merge_base(repo, branch) do
    case System.cmd("git", ["-C", repo, "merge-base", branch, Config.pr_base()],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_, _} -> "HEAD"
    end
  end

  # Claude-authored commit message + PR text when the PR workflow is on; else the
  # mechanical template. A describe failure logs and falls back — never blocks.
  defp authored_or_template(feature, wt, layout) do
    fallback = "speckit: feature #{feature.id} pipeline artifacts (done)"

    if Config.pr_workflow?() do
      case Describe.run(feature, wt, layout) do
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
