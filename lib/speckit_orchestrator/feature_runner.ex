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
    Cost,
    Describe,
    FeatureAgent,
    InteractiveClarify,
    Ledger,
    NeedsHuman,
    PhaseResult,
    PhaseSession,
    PhaseStep,
    Pipeline,
    Remediation,
    SpecDir,
    Store,
    Worktree,
    Workers
  }

  alias SpeckitOrchestrator.InteractiveClarify.AnswerSet
  alias SpeckitOrchestrator.Remediation.Settings
  alias SpeckitOrchestrator.Store.Writer

  # The per-session wall-clock deadline (`Config.phase_timeout/0`), enforced
  # *inside* each phase action by `PhaseSession` — which is the only place a
  # runaway CLI can be shut down cleanly. Every `AgentServer.call` below waits
  # `PhaseSession.call_timeout/1` (deadline + grace), so the deadline is the
  # governing guard and the call never fires first. Implement chunks scale
  # their own deadline from this floor (`Chunking.deadline_ms/2`).

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
    * `:phase_timeout` — per-session deadline in ms (default
      `Config.phase_timeout/0`, 50 min); implement chunks scale up from it.
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
      FR-011), threaded alongside `:run_context` into checkpoint writes.
      Defaults to `nil` (tests and non-layout callers).
    * `:start_task_phase` — an explicit `TaskPhaseRef.t()` or ordinal
      (`pos_integer()`) that overrides `implement`'s recorded checkpoint
      position (checkpoint-implement-chunk.md §3); threaded straight into
      `ChunkRunner.run/1`'s `:start_task_phase`. `nil` (default) resolves
      against the checkpoint instead.
    * `:stack_base` — the git ref this feature's branch was forked from (the
      stacked workflow's resolved stack base: the previous feature's branch, or
      `Config.pr_base()`). The reference for every fork-point lookup this run
      makes: the `:done` squash, and `ChunkRunner`'s roll-up artifact gate.
      `nil` (default) resolves to `Config.pr_base()` at lookup time, which is
      correct for the bottom of the stack and for ad-hoc features.
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
    timeout = Keyword.get(opts, :phase_timeout, Config.phase_timeout())
    notify = Keyword.get(opts, :notify)
    start_phase = Keyword.get(opts, :start_phase, Pipeline.first())
    resume_prompt = Keyword.get(opts, :resume_prompt)
    remediation_prompt = Keyword.get(opts, :remediation_prompt)
    remediation_model = Keyword.get(opts, :remediation_model)
    run_context = Keyword.get(opts, :run_context)
    layout = Keyword.get(opts, :layout)
    # Resolved lazily at each fork-point lookup (`merge_base/2`, `ChunkRunner`)
    # — a dry run with no worktree never looks one up, and must not pay for a
    # `Config.pr_base()` that may not be configured at all.
    stack_base = Keyword.get(opts, :stack_base)
    # The store's `{repo_id, run_id}` for this run (018) — `nil` for a caller
    # with no store-backed run (most unit tests calling this module directly),
    # in which case every store write below is a silent no-op.
    run_key = Keyword.get(opts, :run_key)

    step_opts = %{
      start_task_phase: Keyword.get(opts, :start_task_phase),
      reset_implement_sessions: Keyword.get(opts, :reset_implement_sessions, false),
      remediation_settings: remediation_settings!(run_context),
      run_key: run_key,
      stack_base: stack_base,
      # 029: the mode's settings, resolved once per run from the run's
      # **captured** context (never live Config — see `remediation_settings!/1`
      # just above for why), and the current clarify re-run's answer block
      # (set only inside `answer_the_clarify_gate/…`, `nil` everywhere else —
      # byte-identical prompt when the mode is off or between rounds).
      interactive_clarify_settings: interactive_clarify_settings!(run_context),
      clarify_answers: nil
    }

    with {:ok, pid} <- start_agent(feature, opts) do
      record_feature_started(run_key, feature)

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
          case maybe_run_remediation(pid, feature, timeout, remediation_prompt, run_key) do
            {:error, agent} ->
              {:failed, remediation_failure_reason(agent), agent}

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
                step_opts,
                run_key,
                nil,
                0
              )
          end

        call(pid, "feature.finalize", %{status: status, reason: reason}, timeout)
        {message, pr} = commit_message_and_pr(feature, status, worktree, layout)
        handle_worktree(feature, status, reason, worktree, message, stack_base)

        if drained?(status, reason) do
          emit_drained(feature)
        else
          record_feature_terminal(run_key, feature, status, reason, pr)
          record_diversion_escalation(run_key, feature, agent, status, reason)
          emit_terminal(feature, status, reason, agent.state.cost_total)
          notify(notify, feature.id, status, reason)
        end

        stop_agent(pid)

        %{
          feature_id: feature.id,
          status: status,
          reason: reason,
          cost_total: agent.state.cost_total
        }
      catch
        kind, err ->
          handle_worktree(feature, :failed, {kind, err}, worktree, nil, stack_base)
          record_feature_terminal(run_key, feature, :failed, {kind, err}, nil)
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
  defp maybe_run_remediation(pid, feature, timeout, remediation_prompt, run_key) do
    if blank?(remediation_prompt) do
      :ok
    else
      agent =
        remediation_with_retry(pid, feature, timeout, Config.phase_max_retries(), run_key)

      if agent.state.last_outcome == :error, do: {:error, agent}, else: :ok
    end
  end

  # Same transient-retry policy as a phase (FR-006): a server/API drop is
  # retried up to Config.phase_max_retries() times before it counts as a
  # genuine failure.
  defp remediation_with_retry(pid, feature, timeout, retries, run_key) do
    agent = run_remediation(pid, feature, timeout, run_key)
    st = agent.state

    if retries > 0 and st.last_outcome == :error and PhaseResult.transient?(st.last_result) do
      Logger.warning(
        "feature #{feature.id} remediation failed transiently — retrying (#{retries} left)"
      )

      remediation_with_retry(pid, feature, timeout, retries - 1, run_key)
    else
      agent
    end
  end

  # Same [:speckit, :phase] span every phase uses (meta.phase = :remediation,
  # FR-012), recorded as this feature run's own `:remediation`-phase attempt
  # (ordinal 1 — this step runs at most once, before the phase loop starts),
  # so it precedes the target phase's own attempt in any store-sourced
  # listing.
  defp run_remediation(pid, feature, timeout, run_key) do
    meta = %{feature_id: feature.id, phase: :remediation, step: 0}
    started_at = DateTime.utc_now()

    :telemetry.span([:speckit, :phase], meta, fn ->
      {:ok, %{agent: before}} = AgentServer.state(pid)
      Workers.session_started(timeout)
      {:ok, agent} = call(pid, "remediation.run", %{}, PhaseSession.call_timeout(timeout))
      agent = PhaseStep.ensure_recorded(before, agent, :remediation)
      entry = List.first(agent.state.history) || %{}
      record_attempt(run_key, feature, :remediation, 0, 1, started_at, agent, nil, nil)

      Logger.info("feature #{feature.id} remediation -> #{inspect(Map.get(entry, :outcome))}")

      {agent,
       Map.merge(meta, %{outcome: Map.get(entry, :outcome), cost: Map.get(entry, :cost, 0.0)})}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # 027, US2: a pre-phase remediation session that drifted off the
  # orchestrator's branch names the drift explicitly (contracts/branch-guard.md
  # §3), rather than the generic `:remediation_failed`.
  defp remediation_failure_reason(%{state: %{last_signals: %{branch_drift: d}}}),
    do: {:branch_drift, :remediation, d}

  defp remediation_failure_reason(_agent), do: :remediation_failed

  # ---- loop ---------------------------------------------------------------

  defp loop(
         pid,
         feature,
         phase,
         step,
         timeout,
         ledger,
         worktree,
         run_context,
         layout,
         step_opts,
         run_key,
         mark,
         clarify_rounds_used
       ) do
    started_at = DateTime.utc_now()
    agent = run_step(pid, feature, phase, step, timeout, ledger, worktree, layout, step_opts)
    st = agent.state
    gate_sigs = gate_signals(phase, st, step_opts)

    transition = terminal_override(st) || Pipeline.next(phase, st.last_outcome, gate_sigs)
    decorated = decorate(transition, phase, st)

    # Feature 021: the exhaustion mark is decided at the :analyze boundary
    # (the only phase that can produce it) and threaded forward so the
    # eventual `{:done, :done}` reason can be decorated at :converge —
    # `mark || …` means once set it survives every later phase unchanged.
    mark = mark || exhaustion_mark(phase, gate_sigs, st)

    # Net two (empty-checkpoint): the boundary commit runs before the
    # transition is finalized, so a `:cont` reached with the phase's artifact
    # absent at start *and* nothing committed is turned into `{:failed,
    # {:empty_checkpoint, phase}}` right here — before `record_attempt/9`, so
    # the checkpoint it writes reflects the *failed* phase, not one that
    # claims the run advanced (research R7). Every other transition
    # (`:done`/`:escalated`/`:halted`/`:failed` from `Pipeline.next/3` or the
    # terminal override) is untouched — the per-phase boundary commit has
    # never applied to those; `handle_worktree/6` commits the final state
    # once the loop returns.
    decorated =
      case decorated do
        {:cont, next} ->
          commit_result =
            if worktree,
              do: Worktree.commit(worktree, "speckit: #{feature.id} checkpoint after #{phase}")

          absent? = Map.get(gate_sigs, :artifact_absent_at_start?, false)

          case Checkpoint.verdict(phase, absent?, commit_result || :ok) do
            :advance -> {:cont, next}
            {:failed, reason} -> {:failed, reason}
          end

        other ->
          other
      end

    # One store transaction per phase-attempt boundary (FR-006, R7): the
    # attempt, its cost, the checkpoint this boundary leaves (or the
    # diverted-terminal one), and the transcript — before recursing, not
    # after, so a crash mid-next-phase still finds the record for the phase
    # that already completed.
    record_attempt(
      run_key,
      feature,
      phase,
      step,
      attempt_ordinal(st),
      started_at,
      agent,
      checkpoint_for(decorated, phase, st),
      if(phase == :analyze, do: mark)
    )

    case decorated do
      {:cont, next} ->
        # Drain-don't-kill: the current phase finished; if the breaker has since
        # tripped, halt before starting the next phase rather than mid-phase.
        # A persistence failure drains the same way, at the same point
        # (FR-010, contracts/persistence-failure.md).
        cond do
          breaker_tripped?(ledger) ->
            {:halted, :breaker, agent}

          Workers.drain_requested?() ->
            {:halted, :superseded, agent}

          store_unwritable?(run_key) ->
            {:halted, {:persistence_failed, store_health_reason()}, agent}

          true ->
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
              step_opts,
              run_key,
              mark,
              clarify_rounds_used
            )
        end

      {:done, :done} ->
        {:done, done_reason(mark), agent}

      # 029: intercepted strictly after the pure `Pipeline`/`Checkpoint`
      # boundary above has already run — the standard `record_attempt/9`
      # call just below writes this exact `{:escalated, :needs_human}`
      # checkpoint regardless of what happens next (research.md R12 "checkpoint
      # at wait entry" is satisfied by that ordinary write, not a second one).
      # `InteractiveClarify.decide/3` then decides whether this loop iteration
      # ends here (today's path, byte-identical when the mode is off — FR-002)
      # or hands off to the wait.
      {:escalated, :needs_human} when phase == :clarify ->
        handle_clarify_gate(
          pid,
          feature,
          agent,
          ledger,
          worktree,
          run_context,
          layout,
          step_opts,
          run_key,
          mark,
          clarify_rounds_used,
          step,
          timeout
        )

      {:escalated, reason} ->
        {:escalated, reason, agent}

      {:halted, reason} ->
        {:halted, reason, agent}

      {:failed, reason} ->
        {:failed, reason, agent}
    end
  end

  # ---- interactive clarify (029, contracts/wait-protocol.md) ----------------
  #
  # Reached only from `loop/13`'s `{:escalated, :needs_human} when phase ==
  # :clarify` clause, strictly after the ordinary per-phase boundary
  # (`record_attempt/9`, checkpoint included) has already run — this never
  # duplicates that write (research.md R12).

  defp handle_clarify_gate(
         pid,
         feature,
         agent,
         ledger,
         worktree,
         run_context,
         layout,
         step_opts,
         run_key,
         mark,
         rounds_used,
         step,
         timeout
       ) do
    settings = Map.fetch!(step_opts, :interactive_clarify_settings)

    case InteractiveClarify.decide({:escalated, :needs_human}, settings, rounds_used) do
      :pass ->
        {:escalated, :needs_human, agent}

      # T042, data-model.md Escalation.evidence: the final unanswered
      # question block, plus the round count spent on it — exhaustion opens
      # no round of its own (research.md R5 "creates no round row"), so this
      # is the only place that evidence is ever available.
      {:escalated, {:needs_human, :rounds_exhausted} = reason} ->
        raw = questions_raw(agent.state, worktree, feature)
        {:escalated, reason, with_diversion_evidence(agent, %{questions: raw, rounds_used: rounds_used})}

      :await ->
        await_answers(%{
          pid: pid,
          feature: feature,
          agent: agent,
          ledger: ledger,
          worktree: worktree,
          run_context: run_context,
          layout: layout,
          step_opts: step_opts,
          run_key: run_key,
          mark: mark,
          rounds_used: rounds_used,
          step: step,
          timeout: timeout,
          settings: settings,
          poll_ms: Config.clarify_poll_ms()
        })
    end
  end

  # Entry (contracts/wait-protocol.md § Entry): parse the questions, open the
  # round (one transaction — sets `FeatureRun.status: :awaiting_answers` in
  # the same write, `Writer.record_feature_awaiting/3`), notify, and enter the
  # tick loop. A store failure here (no `run_key`, or the write itself erring)
  # falls back to today's plain escalation rather than waiting on a round that
  # was never durably opened.
  defp await_answers(ctx) do
    round = ctx.rounds_used + 1
    raw = questions_raw(ctx.agent.state, ctx.worktree, ctx.feature)
    questions = NeedsHuman.parse_questions(raw)

    case Writer.record_feature_awaiting(ctx.run_key, ctx.feature.id, %{
           round: round,
           max_rounds: ctx.settings.max_rounds,
           questions_raw: raw,
           questions: questions,
           answer_timeout_s: ctx.settings.answer_timeout_s
         }) do
      {:ok, seq} ->
        round_key = round_key(ctx.run_key, ctx.feature.id, seq)
        deadline_at = DateTime.add(DateTime.utc_now(), ctx.settings.answer_timeout_s, :second)

        :telemetry.execute(
          [:speckit, :clarify, :awaiting],
          %{system_time: System.system_time()},
          %{
            feature_id: ctx.feature.id,
            seq: seq,
            round: round,
            max_rounds: ctx.settings.max_rounds,
            deadline_at: deadline_at
          }
        )

        notify_coordinator({:feature_awaiting, ctx.feature.id})

        clarify_tick(Map.merge(ctx, %{round_key: round_key, seq: seq}))

      {:error, reason} ->
        Logger.error(
          "feature #{ctx.feature.id} could not open interactive-clarify round: #{inspect(reason)}"
        )

        {:escalated, :needs_human, ctx.agent}
    end
  end

  # Tick (contracts/wait-protocol.md § Tick): drain and breaker are checked
  # first, every tick, and neither starts a session or spends (FR-004,
  # FR-011). Every other branch reads the round row transactionally — the
  # runner acts on the transaction's result, never on the message that woke
  # it (research.md R3), so a lost `{:clarify_answered, _}` message costs at
  # most one `poll_ms` tick (SC-002).
  defp clarify_tick(ctx) do
    Workers.waiting(ctx.poll_ms)

    cond do
      Workers.drain_requested?() -> finish_wait(ctx, :drained, :drained)
      breaker_tripped?(ctx.ledger) -> finish_wait(ctx, :breaker, :breaker)
      true -> read_clarify_round(ctx)
    end
  end

  defp read_clarify_round(ctx) do
    case Store.Query.clarify_round(ctx.round_key) do
      {:ok, %{outcome: :answered} = round} ->
        answered(ctx, round)

      {:ok, %{outcome: :open, deadline_at: deadline_at}} ->
        if DateTime.compare(DateTime.utc_now(), deadline_at) != :lt do
          finish_wait(ctx, :timed_out, :answer_timeout)
        else
          wait_tick(ctx)
        end

      # Defensive only — this loop is the sole writer of an `:open` round; a
      # non-`:open`/`:answered` outcome here means something else already
      # closed it (e.g. a restart reconcile racing an unexpectedly still-live
      # process). Escalate on the matching reason rather than spin forever.
      {:ok, %{outcome: outcome}} ->
        {:escalated, InteractiveClarify.on_exit(exit_for(outcome)), ctx.agent}

      {:error, :absent} ->
        {:escalated, {:needs_human, :restart}, ctx.agent}
    end
  end

  defp wait_tick(ctx) do
    key = ctx.round_key

    receive do
      {:clarify_answered, ^key} -> clarify_tick(ctx)
    after
      ctx.poll_ms -> clarify_tick(ctx)
    end
  end

  # `close_round/3` is the guarded write (research.md R3): if it loses the
  # race to a just-landed answer, it returns `{:error, {:stale_round,
  # :answered}}` and the runner takes the answered path instead of
  # escalating, exactly as the contract requires.
  defp finish_wait(ctx, close_outcome, exit_reason) do
    case Writer.close_round(ctx.run_key, ctx.feature.id, %{seq: ctx.seq, outcome: close_outcome}) do
      :ok ->
        {:escalated, InteractiveClarify.on_exit(exit_reason), ctx.agent}

      {:error, {:stale_round, :answered}} ->
        {:ok, round} = Store.Query.clarify_round(ctx.round_key)
        answered(ctx, round)

      {:error, {:stale_round, other}} ->
        {:escalated, InteractiveClarify.on_exit(exit_for(other)), ctx.agent}

      {:error, reason} ->
        Logger.error(
          "feature #{ctx.feature.id} could not close interactive-clarify round: #{inspect(reason)}"
        )

        {:escalated, {:needs_human, exit_reason}, ctx.agent}
    end
  end

  defp exit_for(:timed_out), do: :answer_timeout
  defp exit_for(:breaker), do: :breaker
  defp exit_for(:drained), do: :drained
  defp exit_for(_other), do: :restart

  # Answered path (contracts/wait-protocol.md § Answered path). Step 1: a
  # breaker/drain that tripped in the gap between the answer landing and this
  # tick observing it escalates without ever starting the re-run session,
  # leaving the round `:answered` with `applied_at: nil` so a later resume can
  # still reuse it (research.md R12). Steps 2-4: resume the feature, fold the
  # answers into a fresh `:clarify` session via the ordinary `loop/13` path —
  # re-entering `Pipeline.next/3` and `decide/3` exactly as any other clarify
  # attempt would, with `rounds_used` advanced by one.
  defp answered(ctx, round) do
    cond do
      breaker_tripped?(ctx.ledger) ->
        {:escalated, InteractiveClarify.on_exit(:breaker), ctx.agent}

      Workers.drain_requested?() ->
        {:escalated, InteractiveClarify.on_exit(:drained), ctx.agent}

      true ->
        _ = Writer.record_feature_resumed(ctx.run_key, ctx.feature.id)
        _ = Writer.mark_round_applied(ctx.round_key)

        :telemetry.execute(
          [:speckit, :clarify, :answered],
          %{system_time: System.system_time()},
          %{feature_id: ctx.feature.id, seq: ctx.seq, round: round.round}
        )

        notify_coordinator({:feature_resumed, ctx.feature.id})

        rendered = AnswerSet.render(%AnswerSet{answers: round.answers}, round.round)
        step_opts = Map.put(ctx.step_opts, :clarify_answers, rendered)

        loop(
          ctx.pid,
          ctx.feature,
          :clarify,
          ctx.step,
          ctx.timeout,
          ctx.ledger,
          ctx.worktree,
          ctx.run_context,
          ctx.layout,
          step_opts,
          ctx.run_key,
          ctx.mark,
          ctx.rounds_used + 1
        )
    end
  end

  defp round_key({repo_id, run_id}, feature_id, seq),
    do: SpeckitOrchestrator.Store.Ids.ordinal_id(repo_id, run_id, feature_id, seq)

  # The final transcript usually carries the marker directly (matches the
  # clarify gate's own check, `Actions.RunFeaturePhase.classify_gate/4`); a
  # reviewer that wrote it only into `spec.md` (the gate's "or" clause) is
  # covered by falling back to the spec file itself.
  defp questions_raw(st, worktree, feature) do
    final_text = st.last_result && st.last_result.final_text

    case NeedsHuman.extract(final_text) do
      nil -> questions_raw_from_spec(worktree, feature) || ""
      block -> block
    end
  end

  defp questions_raw_from_spec(%Worktree{path: path}, feature) do
    case SpecDir.file(path, feature, "spec.md") do
      nil ->
        nil

      file ->
        case File.read(file) do
          {:ok, content} -> NeedsHuman.extract(content)
          _ -> nil
        end
    end
  end

  defp questions_raw_from_spec(_worktree, _feature), do: nil

  # 029, research.md R6: the runner reaches the Coordinator by its one
  # well-known registered name — the same lookup `guard_active_run/1` and
  # `coordinator_active_pid/0` already use in the facade — rather than
  # threading a new pid through every runner-spawning call site. At most one
  # Coordinator is ever live per node (`guard_active_run/1` enforces it), so
  # this is never ambiguous. No live Coordinator (a plain unit test calling
  # this module directly) is a silent no-op.
  defp notify_coordinator(message) do
    case Process.whereis(SpeckitOrchestrator.Coordinator) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end

  # Resolved once per feature run from the run's **captured** `RunContext`,
  # mirroring `remediation_settings!/1` just below — never from live `Config`,
  # so a mid-run config edit never reaches an in-flight run.
  defp interactive_clarify_settings!(run_context) do
    case InteractiveClarify.Settings.from_context(run_context) do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError,
              "invalid recorded interactive-clarify settings: #{inspect(reason)}"
    end
  end

  # ---- exhaustion mark (feature 021, contracts/advanced-record.md) ----------

  # `analyze_remediation` is only present once the loop actually ran; a clock
  # read for `:advanced_at` is the caller's job (keeps `Remediation.
  # exhaustion_advance/2` pure) — `Remediation` decides `:mark | :none` from
  # exactly the values the gate used, so the mark and the gate can never
  # disagree (FR-009).
  defp exhaustion_mark(:analyze, gate_sigs, st) do
    case Map.get(st, :analyze_remediation) do
      %{attempts_used: n, limit: limit} ->
        state = %{
          attempts_used: n,
          attempt_limit: limit,
          findings: Map.get(gate_sigs, :analyze_residual_findings, []),
          advanced_at: DateTime.utc_now()
        }

        case Remediation.exhaustion_advance(gate_sigs, state) do
          {:mark, record} -> record
          :none -> nil
        end

      _absent ->
        nil
    end
  end

  defp exhaustion_mark(_phase, _gate_sigs, _st), do: nil

  # Status is never changed (FR-008a) — only the reason `feature.finalize` and
  # `notify/4` report is decorated, exactly as `Remediation.terminal_reason/2`
  # already decorates a halted/escalated reason.
  defp done_reason(nil), do: :done
  defp done_reason(_mark), do: {:done, :advanced_with_unresolved_findings}

  # ---- checkpoint shape (per transition) -----------------------------------

  defp checkpoint_for({:cont, next}, phase, st) do
    %{
      phase: next,
      last_completed_phase: phase,
      status: :in_progress,
      reason: nil,
      session_id: st.session_id,
      analyze_remediation: Map.get(st, :analyze_remediation)
    }
  end

  # `:done` deletes the checkpoint (Store.Writer.record_feature_terminal/4) —
  # no checkpoint row to leave behind.
  defp checkpoint_for({:done, :done}, _phase, _st), do: nil

  defp checkpoint_for({status, reason}, phase, st)
       when status in [:escalated, :halted, :failed] do
    %{
      phase: phase,
      last_completed_phase: phase,
      status: status,
      reason: reason,
      session_id: st.session_id,
      analyze_remediation: Map.get(st, :analyze_remediation)
    }
  end

  # `:implement` (015) delegates wholesale to `ChunkRunner`, which drives its
  # own multi-session loop and absorbs per-chunk transient retries via
  # `Chunking.next/2`'s row 1 — the outer transient-retry wrapper
  # (`run_phase_with_retry/8`) would be meaningless wrapped around a call that
  # already represents N sessions, not one. Every other phase is unchanged.
  defp run_step(pid, feature, :implement, step, timeout, ledger, worktree, layout, step_opts) do
    chunk_opts =
      Map.take(step_opts, [:start_task_phase, :reset_implement_sessions, :run_key, :stack_base])

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
      settings: Map.fetch!(step_opts, :remediation_settings),
      run_key: Map.get(step_opts, :run_key)
    })
  end

  # 029: an interactive-clarify re-run carries the operator's answers,
  # `step_opts.clarify_answers` (`nil` on the first attempt and on every phase
  # but `:clarify` — a plain `PhaseStep.run/4` no-op there, byte-identical to
  # the generic clause below).
  defp run_step(pid, feature, :clarify, step, timeout, _ledger, _worktree, _layout, step_opts) do
    PhaseStep.run(pid, feature, :clarify,
      step: step,
      timeout: timeout,
      operator_answers: Map.get(step_opts, :clarify_answers)
    )
  end

  defp run_step(pid, feature, phase, step, timeout, _ledger, _worktree, _layout, _step_opts) do
    PhaseStep.run(pid, feature, phase, step: step, timeout: timeout)
  end

  # The same [:speckit, :phase] span every other phase gets, wrapping the
  # *whole* chunked step (so existing console/cost observability keeps
  # working) — a finer per-chunk span is added in Phase 5 (T031), inside
  # `ChunkRunner` itself. Only the roll-up (the whole step's own result)
  # becomes this feature run's durable `:implement` phase attempt, recorded
  # below by the caller — each intermediate chunk's own result is not
  # separately persisted (018).
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
      %{cost_total: cost_total || 0.0, system_time: System.system_time()},
      %{feature_id: feature.id, status: status, reason: reason}
    )

    Logger.info("feature #{feature.id} terminal=#{status} reason=#{inspect(reason)}")
  end

  # A drained exit (026) is deliberately not a terminal status — the feature
  # row stays `:running` for supersession to mark `:ended_by_supersession`
  # (FR-011) — so it gets its own event instead of `[:speckit, :feature,
  # :terminal]`.
  defp drained?(:halted, :superseded), do: true
  defp drained?(_status, _reason), do: false

  defp emit_drained(feature) do
    :telemetry.execute(
      [:speckit, :feature, :drained],
      %{system_time: System.system_time()},
      %{feature_id: feature.id}
    )

    Logger.info("feature #{feature.id} drained (superseded)")
  end

  # ---- start/terminal recording (018) ---------------------------------------
  #
  # The start write is what makes the record self-sufficient about a feature in
  # flight: without it a store-backed reader (run detail, `Recovery`) still
  # shows the pre-start status — `:pending`, or the *previous* terminal on a
  # resume — for as long as the feature runs. Same `run_key: nil` no-op as the
  # terminal write below.
  defp record_feature_started(nil, _feature), do: :ok

  defp record_feature_started(run_key, feature) do
    _ = Writer.record_feature_started(run_key, feature.id)
    :ok
  end

  #
  # `record_feature_terminal/4` carries `pr_description` in the same
  # transaction (replacing `Describe.write_pr/3`); a diverted (:escalated /
  # :halted) terminal also records the escalation (FR-025). No-ops when this
  # run isn't store-backed (`run_key: nil` — most unit tests calling this
  # module directly).
  defp record_feature_terminal(nil, _feature, _status, _reason, _pr), do: :ok

  defp record_feature_terminal(run_key, feature, status, reason, pr) do
    _ = Writer.record_feature_terminal(run_key, feature.id, status, reason, pr_description: pr)
    :ok
  end

  defp record_diversion_escalation(run_key, feature, agent, status, reason)
       when run_key != nil and status in [:escalated, :halted] do
    _ =
      Writer.record_escalation(run_key, %{
        feature_id: feature.id,
        kind: status,
        phase: agent.state.phase,
        reason: reason,
        evidence: diversion_evidence(agent)
      })

    :ok
  end

  defp record_diversion_escalation(_run_key, _feature, _agent, _status, _reason), do: :ok

  # 029, T042: a local-only carrier for the one diversion (rounds-exhausted)
  # that has evidence to attach — set via `with_diversion_evidence/2` right
  # before the terminal tuple is returned, never round-tripped through Jido's
  # own signal/action pipeline. `last_signals` is a free-form `:map` field in
  # `FeatureAgent`'s schema, so stuffing an extra key into it here is safe:
  # nothing re-reads or overwrites it after this point in the run.
  defp with_diversion_evidence(agent, evidence) do
    signals = Map.put(agent.state.last_signals || %{}, :diversion_evidence, evidence)
    %{agent | state: %{agent.state | last_signals: signals}}
  end

  defp diversion_evidence(agent),
    do: Map.get(agent.state.last_signals || %{}, :diversion_evidence, %{})

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: Ledger.breaker_tripped?(ledger)

  defp store_unwritable?(nil), do: false
  defp store_unwritable?(_run_key), do: Store.Health.failed?()

  defp store_health_reason do
    case Store.Health.status() do
      {:failed, reason, _at} -> reason
      :ok -> :unknown
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp call(pid, type, data, timeout) do
    AgentServer.call(pid, Signal.new!(type, data, source: "/runner"), timeout)
  end

  defp handle_worktree(_feature, _status, _reason, nil, _message, _stack_base), do: :ok

  # Commit whatever the pipeline generated onto the feature branch BEFORE the
  # worktree is torn down — otherwise a successful run's spec/plan/tasks/code is
  # discarded on removal. `message` was authored (Claude, PR workflow) or
  # templated by `commit_message_and_pr/4` before the store write, so the git
  # history and the recorded `pr_description` always agree.
  defp handle_worktree(_feature, :done, _reason, %Worktree{} = wt, message, stack_base) do
    _ = Worktree.squash(wt, merge_base(wt, stack_base), message)
    Worktree.remove(wt)
  end

  # 027, US2: a branch-drift terminal writes no further git state to either
  # branch — no commit, only `keep_for_inspection/1` for post-mortem (Principle
  # II; contracts/branch-guard.md §4-§5).
  defp handle_worktree(_feature, _status, {:branch_drift, _, _}, %Worktree{} = wt, _message, _stack_base) do
    Worktree.keep_for_inspection(wt)
  end

  defp handle_worktree(feature, status, _reason, %Worktree{} = wt, _message, _stack_base) do
    _ = Worktree.commit(wt, "speckit: feature #{feature.id} pipeline artifacts (#{status})")
    Worktree.keep_for_inspection(wt)
  end

  # The branch's fork point, for squash/3's --soft reset target: the commit
  # where the feature branch diverged from `stack_base` — the ref its worktree
  # was actually created from (the previous feature's branch in a stacked run,
  # `Config.pr_base()` at the bottom of the stack or for an ad-hoc feature).
  #
  # It must NOT be `Config.pr_base()` unconditionally. For a feature stacked on
  # an unmerged predecessor, `merge-base(feature/002, main)` is where *001*
  # forked from main, so the soft reset walks back past 001's commit entirely:
  # the squashed 002 is reparented onto `main`, carrying 001's changes in its
  # own diff. Its PR against `feature/001-…` then re-proposes 001's work and
  # conflicts with it file for file.
  #
  # Falls back to "HEAD" (a no-op reset) if the merge-base lookup itself fails.
  defp merge_base(%Worktree{} = wt, stack_base) do
    case Worktree.fork_point(wt, stack_base || Config.pr_base()) do
      {:ok, sha} -> sha
      {:error, _reason} -> "HEAD"
    end
  end

  # The commit message and `pr_description` — computed once, before the store
  # write and the worktree squash, so the recorded `feature_run.pr_description`
  # and the git history it describes always agree. Claude-authored via
  # `Describe.run/3` (019: every run publishes a PR, unconditionally). A
  # describe failure logs and falls back — never blocks.
  defp commit_message_and_pr(feature, :done, %Worktree{} = wt, layout) do
    fallback = "speckit: feature #{feature.id} pipeline artifacts (done)"

    case Describe.run(feature, wt, layout) do
      {:ok, d} ->
        message = if d.commit_message == "", do: fallback, else: d.commit_message
        {message, %{pr_title: d.pr_title, pr_body: d.pr_body}}

      {:error, reason} ->
        Logger.warning("feature #{feature.id} describe failed: #{inspect(reason)}")
        {fallback, nil}
    end
  end

  defp commit_message_and_pr(feature, status, _wt, _layout) do
    {"speckit: feature #{feature.id} pipeline artifacts (#{status})", nil}
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

  # ---- store recording (018) ------------------------------------------------
  #
  # One `Store.Writer.record_phase_attempt/2` transaction per phase-attempt
  # boundary (R7): the attempt, its cost, the checkpoint this boundary leaves,
  # and the transcript — never separately, so a reader can never see one
  # without the others (FR-006). `run_key: nil` (no store-backed run) is a
  # silent no-op — most unit tests call this module directly with no store.
  defp record_attempt(
         nil,
         _feature,
         _phase,
         _step,
         _ordinal,
         _started_at,
         _agent,
         _checkpoint,
         _mark
       ),
       do: :ok

  # `AnalyzeRunner`'s failure and breaker paths already committed the analyze
  # run, and hand back the *remediation* agent — recording that here would
  # overwrite the analyze attempt with the corrective step's outcome, cost and
  # transcript at the same `attempt_id`. Write the checkpoint alone; the
  # attempt it refers to is already durable.
  defp record_attempt(
         run_key,
         feature,
         _phase,
         _step,
         _ordinal,
         _started_at,
         %{state: %{analyze_attempt_recorded?: true}},
         checkpoint,
         _mark
       ) do
    _ = checkpoint && Writer.record_checkpoint(run_key, feature.id, checkpoint)
    :ok
  end

  defp record_attempt(run_key, feature, phase, step, ordinal, started_at, agent, checkpoint, mark) do
    st = agent.state
    result = st.last_result
    {cost_amount, cost_kind} = Cost.for_phase(phase, result || %PhaseResult{})
    ended_at = DateTime.utc_now()

    attempt = %{
      feature_id: feature.id,
      phase: phase,
      ordinal: ordinal,
      step: step,
      label: Atom.to_string(phase),
      started_at: started_at,
      ended_at: ended_at,
      duration_ms: DateTime.diff(ended_at, started_at, :millisecond),
      outcome: st.last_outcome,
      model: model_for_record(phase, st),
      cost_usd: cost_amount,
      cost_kind: cost_kind,
      session_id: st.session_id,
      error: result && result.error
    }

    _ =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt,
        cost: %{amount_usd: cost_amount, kind: cost_kind},
        checkpoint: checkpoint,
        transcript: result && result.final_text,
        advanced_with_findings: mark
      })

    :ok
  end

  # The analyze gate is governed by the run's severity threshold — the same
  # single knob that decides when auto-remediation runs (017 FR-001a, amended
  # Constitution Principle V). It is a run setting, not phase output, so it is
  # injected here rather than extracted upstream in `RunFeaturePhase`. Every
  # other phase's signals pass through untouched, and an absent setting leaves
  # `Pipeline` on its `:high` default.
  defp gate_signals(:analyze, st, step_opts) do
    signals = st.last_signals || %{}

    case Map.get(step_opts, :remediation_settings) do
      %Settings{threshold: threshold, exhaustion_policy: policy} ->
        signals
        |> Map.put(:gate_threshold, threshold)
        |> Map.put(:exhaustion_policy, policy)

      _absent ->
        signals
    end
  end

  defp gate_signals(_phase, st, _step_opts), do: st.last_signals

  # Almost every phase runs exactly once per feature run, so its attempt is
  # ordinal 1. `:analyze` is the exception: `AnalyzeRunner`'s bounded loop can
  # run it N times and reports N as `analyze_runs`, having already recorded
  # runs 1..N-1 itself. Recording the final run at N keeps every analyze run
  # individually addressable instead of collapsing them onto one key
  # (FR-012a, Constitution Principle V). Absent — every non-analyze phase, and
  # `:analyze` with the loop disabled — is ordinal 1, byte-identical to
  # pre-017 behaviour (FR-010).
  defp attempt_ordinal(st), do: Map.get(st, :analyze_runs) || 1

  # `:remediation` (013's pre-phase step) has no `Config.model_for/1` route of
  # its own (it runs under whichever model `Config.remediation_model/2`
  # resolved) — recorded from agent state instead of raising on an unrouted
  # phase.
  defp model_for_record(:remediation, st), do: Map.get(st, :remediation_model) || "unspecified"
  defp model_for_record(phase, _st), do: Config.model_for(phase)
end
