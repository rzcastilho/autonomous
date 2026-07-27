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
    AnalyzeRunner,
    Checkpoint,
    ChunkRunner,
    Config,
    Describe,
    FeatureAgent,
    PhaseResult,
    PhaseStep,
    Pipeline,
    Remediation,
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
    * `:start_task_phase` — an explicit `TaskPhaseRef.t()` or ordinal
      (`pos_integer()`) that overrides `implement`'s recorded checkpoint
      position (checkpoint-implement-chunk.md §3); threaded straight into
      `ChunkRunner.run/1`'s `:start_task_phase`. `nil` (default) resolves
      against the checkpoint instead.
    * `:reset_implement_sessions` — `true` clears the carried
      `implement_chunk.sessions_used` to `0` before the chunk loop starts
      (FR-013b — an explicit grant of more session budget). Default `false`
      preserves whatever the checkpoint recorded, for the crash-recovery
      continuation path.
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

    step_opts = %{
      start_task_phase: Keyword.get(opts, :start_task_phase),
      reset_implement_sessions: Keyword.get(opts, :reset_implement_sessions, false),
      remediation_settings: remediation_settings!(run_context)
    }

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
                layout,
                step_opts
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
        remediation_with_retry(
          pid,
          feature,
          timeout,
          worktree,
          layout,
          Config.phase_max_retries()
        )

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

      Logger.info("feature #{feature.id} remediation -> #{inspect(Map.get(entry, :outcome))}")

      {agent,
       Map.merge(meta, %{outcome: Map.get(entry, :outcome), cost: Map.get(entry, :cost, 0.0)})}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # ---- loop ---------------------------------------------------------------

  defp loop(pid, feature, phase, step, timeout, ledger, worktree, run_context, layout, step_opts) do
    agent =
      run_step(pid, feature, phase, step, timeout, ledger, worktree, layout, step_opts)

    st = agent.state

    transition =
      terminal_override(st) || Pipeline.next(phase, st.last_outcome, st.last_signals)

    case decorate(transition, phase, st) do
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
          layout: layout,
          analyze_remediation: Map.get(st, :analyze_remediation)
        })

        if worktree,
          do: Worktree.commit(worktree, "speckit: #{feature.id} checkpoint after #{phase}")

        # Drain-don't-kill: the current phase finished; if the breaker has since
        # tripped, halt before starting the next phase rather than mid-phase.
        if breaker_tripped?(ledger),
          do: {:halted, :breaker, agent},
          else:
            loop(
              pid,
              feature,
              next,
              step + 1,
              timeout,
              ledger,
              worktree,
              run_context,
              layout,
              step_opts
            )

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

  # `:implement` (015) delegates wholesale to `ChunkRunner`, which drives its
  # own multi-session loop and absorbs per-chunk transient retries via
  # `Chunking.next/2`'s row 1 — the outer transient-retry wrapper
  # (`run_phase_with_retry/8`) would be meaningless wrapped around a call that
  # already represents N sessions, not one. Every other phase is unchanged.
  defp run_step(pid, feature, :implement, step, timeout, ledger, worktree, layout, step_opts) do
    chunk_opts = Map.take(step_opts, [:start_task_phase, :reset_implement_sessions])
    run_chunked_phase(pid, feature, step, timeout, ledger, worktree, layout, chunk_opts)
  end

  # `:analyze` (017) delegates to `AnalyzeRunner`, which drives the bounded
  # auto-remediation loop *below* the analyze gate and returns the **final**
  # analyze run's outcome/signals — so `Pipeline.next/3` below still sees
  # exactly one `:analyze` outcome, exactly once (FR-007). With the loop
  # disabled the runner short-circuits to the same `PhaseStep.run/4` call the
  # generic clause makes.
  defp run_step(pid, feature, :analyze, step, timeout, ledger, worktree, layout, step_opts) do
    AnalyzeRunner.run(%{
      pid: pid,
      feature: feature,
      worktree: worktree,
      layout: layout,
      timeout: timeout,
      step: step,
      ledger: ledger,
      settings: Map.fetch!(step_opts, :remediation_settings)
    })
  end

  defp run_step(pid, feature, phase, step, timeout, _ledger, worktree, layout, _step_opts) do
    PhaseStep.run(pid, feature, phase,
      step: step,
      timeout: timeout,
      worktree: worktree,
      layout: layout
    )
  end

  # The same [:speckit, :phase] span every other phase gets, wrapping the
  # *whole* chunked step (so existing console/cost observability keeps
  # working) — a finer per-chunk span is added in Phase 5 (T031), inside
  # `ChunkRunner` itself. `ChunkRunner` writes its own per-chunk + roll-up
  # transcripts (contracts/chunk_session.md §5), so the generic
  # `Transcripts.write/5` call `run_phase/7` makes below is skipped here to
  # avoid clobbering the roll-up with just the last chunk's raw result.
  defp run_chunked_phase(pid, feature, step, timeout, ledger, worktree, layout, chunk_opts) do
    meta = %{
      feature_id: feature.id,
      phase: :implement,
      model: Config.model_for(:implement),
      step: step
    }

    cost_before = current_cost_total(pid)

    :telemetry.span([:speckit, :phase], meta, fn ->
      agent =
        ChunkRunner.run(
          Map.merge(chunk_opts, %{
            pid: pid,
            feature: feature,
            worktree: worktree,
            layout: layout,
            timeout: timeout,
            step: step,
            ledger: ledger
          })
        )

      cost = (agent.state.cost_total || 0.0) - cost_before
      Logger.info("feature #{feature.id} phase implement -> #{inspect(agent.state.last_outcome)}")

      {agent, Map.merge(meta, %{outcome: agent.state.last_outcome, cost: cost})}
    end)
  end

  defp current_cost_total(pid) do
    {:ok, %{agent: agent}} = AgentServer.state(pid)
    agent.state.cost_total || 0.0
  end

  # An edge module that drives its own sub-loop (`ChunkRunner` for `:implement`,
  # `AnalyzeRunner` for `:analyze`) resolves halt/failure reasons
  # `Pipeline.next/3` has no vocabulary for — a chunked implement's SC-002
  # reasons and breaker halt, the analyze loop's `:remediation_failed` and its
  # own breaker halt — below `Pipeline.next/3`'s single generic `{phase,
  # :error}`. `Pipeline.next/3` itself stays untouched. `terminal_reason` is
  # the existing `FeatureAgent` field (added in 013 for post-finalize
  # bookkeeping) reused as the seam both edge modules share, so the specific
  # reason reaches the checkpoint/console instead of that generic tuple.
  defp terminal_override(%{terminal_reason: {:halted, _} = t}), do: t
  defp terminal_override(%{terminal_reason: {:failed, _} = t}), do: t
  defp terminal_override(_st), do: nil

  # Exhausted auto-remediation names itself in the gate's reason (FR-006,
  # research R11) without the gate itself changing: `Pipeline.next/3` already
  # produced the identical transition, and a loop that never ran (or succeeded)
  # leaves it byte-identical to pre-017 (SC-007a).
  defp decorate(transition, :analyze, %{analyze_remediation: %{attempts_used: n}}) when n > 0 do
    Remediation.terminal_reason(transition, %{attempts_used: n})
  end

  defp decorate(transition, _phase, _st), do: transition

  # Resolved once per feature run from the run's **captured** `RunContext`,
  # never from live `Config` (FR-010b) — a mid-run config edit must not reach an
  # in-flight run. A recorded-but-invalid setting is a corrupt manifest, not an
  # operator mistake (`run/1`'s preflight rejects those at launch), so it fails
  # loud here rather than silently falling back to a default.
  defp remediation_settings!(run_context) do
    case Remediation.Settings.from_context(run_context) do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError,
              "invalid recorded auto-remediation settings: #{inspect(reason)}"
    end
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
      layout: layout,
      analyze_remediation: Map.get(agent.state, :analyze_remediation)
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
