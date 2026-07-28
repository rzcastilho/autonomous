defmodule SpeckitOrchestrator.AnalyzeRunner do
  @moduledoc """
  Edge module that drives the `:analyze` step's auto-remediation loop (017).

  Wraps `Remediation.next/2` (the pure decision surface) and dispatches one
  harness call per step — an analyze run through `PhaseStep`, a corrective step
  through the `"auto_remediation.run"` signal — so the per-action timeout,
  telemetry span shape, and per-step transcript/cost accounting all keep their
  meaning. Not a process: called synchronously from the same supervised `Task`
  `FeatureRunner` already runs in, exactly as `ChunkRunner` is for `:implement`.

  The loop sits strictly **below** the analyze gate: `FeatureRunner` still calls
  `Pipeline.next(:analyze, last_outcome, last_signals)` exactly once, against
  the **final** analyze run, so a gate diversion is structurally never retried
  (FR-007). With the loop disabled, `run/1` short-circuits to a single
  `PhaseStep` call with today's label, meta and cost — byte-identical to pre-017
  (FR-010, SC-004, SC-007a).

  See `specs/017-analyze-auto-remediation/contracts/analyze_loop.md`.
  """

  require Logger

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.{
    AnalyzeResult,
    Config,
    Cost,
    Ledger,
    PhaseResult,
    PhaseStep,
    Prompts,
    Remediation,
    Severity,
    Telemetry
  }

  alias SpeckitOrchestrator.Store.Writer

  alias SpeckitOrchestrator.Remediation.Settings

  @type opts :: %{
          required(:pid) => pid(),
          required(:feature) => SpeckitOrchestrator.Feature.t(),
          required(:worktree) => SpeckitOrchestrator.Worktree.t() | nil,
          required(:layout) => SpeckitOrchestrator.Layout.t() | nil,
          required(:timeout) => timeout(),
          required(:step) => pos_integer(),
          required(:ledger) => pid() | atom() | nil,
          required(:settings) => Settings.t(),
          optional(:run_key) => {binary(), binary()} | nil
        }

  @doc """
  Drive the analyze step to completion for one feature, returning the
  `AgentServer`-shaped `agent` `FeatureRunner` expects — the same shape a
  normal phase call returns, plus `state.terminal_reason` when the loop ended
  in a remediation-specific failure/halt `Pipeline.next/3` has no vocabulary
  for, and `state.analyze_remediation` carrying the attempt provenance for the
  checkpoint (contracts/analyze_loop.md §3).

  `last_outcome`/`last_signals` always come from the **final** analyze run
  (FR-005), so the gate decides from the most recent evidence and from nothing
  else.
  """
  @spec run(opts()) :: struct()

  # Disabled short-circuit (FR-010, SC-004): one analyze run, plain `analyze`
  # label, no extra span meta, no `Remediation.next/2` call, no extra
  # transcript, no cost beyond that one run.
  def run(%{settings: %Settings{enabled?: false}} = ctx) do
    PhaseStep.run(ctx.pid, ctx.feature, :analyze, step: ctx.step, timeout: ctx.timeout)
  end

  def run(%{settings: %Settings{} = settings} = ctx) do
    state = %{
      settings: settings,
      attempts_used: 0,
      analyze_runs: 0,
      analyze_started_at: nil,
      last_result: nil,
      last_outcome: nil
    }

    {agent, state} = analyze(ctx, state)
    loop(ctx, state, agent)
  end

  # ---- loop -----------------------------------------------------------------

  defp loop(ctx, state, agent) do
    signals = %{
      step: :analyze,
      outcome: agent.state.last_outcome,
      result: parsed_result(agent),
      breaker?: breaker_tripped?(ctx.ledger)
    }

    case Remediation.next(state, signals) do
      {:gate, state1} ->
        finish(ctx, state1, agent, nil)

      {:gate, {:exhausted, n}, state1} ->
        finish(ctx, state1, agent, n)

      {:halted, :breaker, state1} ->
        halt(ctx, state1, agent)

      {:remediate, findings, state1} ->
        # This analyze run is not the final one — the loop is about to run a
        # corrective step and re-analyze — so record it here, at its own
        # ordinal. The final run is recorded by `FeatureRunner` at the phase
        # boundary, together with the checkpoint it leaves (FR-012a,
        # Constitution Principle V: every analyze re-run individually
        # recorded).
        record_analyze_run(ctx, state1, agent)
        remediate_then_reanalyze(ctx, state1, findings)
    end
  end

  defp remediate_then_reanalyze(ctx, state, findings) do
    {agent, outcome} = remediate(ctx, state, findings)

    # The remediation step's own outcome goes back through the pure table so
    # rows 3 (remediation failed) and 4 (breaker) — and their documented
    # 3-before-4 order — are decided in one place. Any other row is the
    # table's findings-based tail evaluated against the *stale* analyze result
    # and is deliberately ignored: only a fresh analyze run may consume the
    # next attempt, so the loop continues from `state` unchanged.
    case Remediation.next(state, %{
           step: :remediation,
           outcome: outcome,
           breaker?: breaker_tripped?(ctx.ledger)
         }) do
      {:failed, :remediation_failed, state1} ->
        fail(ctx, state1, agent)

      {:halted, :breaker, state1} ->
        halt(ctx, state1, agent)

      _continue ->
        {agent1, state1} = analyze(ctx, state)
        loop(ctx, state1, agent1)
    end
  end

  # ---- one analyze run --------------------------------------------------------

  # Every analyze run is durably recorded as its own attempt-numbered
  # `:analyze` phase attempt, and no run overwrites an earlier one (FR-012a,
  # Constitution Principle V). Runs that the loop supersedes are recorded here
  # in `loop/3`'s `{:remediate, ...}` branch; the **final** run is recorded by
  # `FeatureRunner` at the phase boundary — at ordinal `analyze_runs`, carried
  # up through the agent state — so it lands in the same transaction as the
  # checkpoint that boundary leaves (FR-006). Each remediation attempt's own
  # findings/outcome/cost stay individually durable via
  # `record_remediation_attempt/8` below.
  defp analyze(ctx, state) do
    k = state.analyze_runs + 1
    started_at = DateTime.utc_now()

    agent =
      PhaseStep.run(ctx.pid, ctx.feature, :analyze,
        step: ctx.step,
        timeout: ctx.timeout,
        span_meta: %{attempt: k, limit: state.settings.attempt_limit}
      )

    {agent, %{state | analyze_runs: k, analyze_started_at: started_at}}
  end

  # One superseded analyze run, at its own ordinal. No checkpoint: an
  # intermediate run is not a phase boundary, so the only durable resume
  # pointer stays the one the final run writes.
  defp record_analyze_run(%{run_key: run_key} = ctx, state, agent) when not is_nil(run_key) do
    result = agent.state.last_result
    ended_at = DateTime.utc_now()
    {cost_amount, cost_kind} = Cost.for_phase(:analyze, result || %PhaseResult{})

    attempt = %{
      feature_id: ctx.feature.id,
      phase: :analyze,
      ordinal: state.analyze_runs,
      step: ctx.step,
      label: "analyze-a#{state.analyze_runs}",
      started_at: state.analyze_started_at,
      ended_at: ended_at,
      duration_ms: DateTime.diff(ended_at, state.analyze_started_at, :millisecond),
      outcome: agent.state.last_outcome,
      model: Config.model_for(:analyze),
      cost_usd: cost_amount,
      cost_kind: cost_kind,
      session_id: agent.state.session_id,
      error: result && result.error
    }

    _ =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt,
        cost: %{amount_usd: cost_amount, kind: cost_kind},
        transcript: result && result.final_text
      })

    :ok
  end

  defp record_analyze_run(_ctx, _state, _agent), do: :ok

  # `RunFeaturePhase` extracts only the gate booleans; the loop needs the
  # findings themselves, so the transcript is re-parsed here (pure, cheap). A
  # transcript that does not parse is already an `:error` outcome upstream, and
  # row 2 of the decision table gates on that before any finding is read.
  defp parsed_result(agent) do
    case agent.state.last_result do
      %PhaseResult{final_text: text} when is_binary(text) ->
        case AnalyzeResult.parse(text) do
          {:ok, parsed} -> parsed
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  # ---- one remediation attempt ------------------------------------------------

  defp remediate(ctx, state, findings) do
    attempt = state.attempts_used
    limit = state.settings.attempt_limit
    threshold = state.settings.threshold

    instruction =
      Remediation.instruction(findings, attempt: attempt, limit: limit, threshold: threshold)

    prompt = Prompts.load("analyze_remediation") <> "\n\n---\n" <> instruction
    meta = remediation_meta(ctx, state, findings)
    started_at = DateTime.utc_now()

    Telemetry.remediation_span()
    |> :telemetry.span(meta, fn ->
      signal =
        Signal.new!(
          "auto_remediation.run",
          %{prompt: prompt, model: state.settings.model, attempt: attempt},
          source: "/analyze_runner"
        )

      {:ok, agent} = AgentServer.call(ctx.pid, signal, ctx.timeout)
      entry = List.first(agent.state.history) || %{}
      outcome = Map.get(entry, :outcome, agent.state.last_outcome)
      cost = Map.get(entry, :cost, 0.0)

      record_remediation_attempt(ctx, state, findings, attempt, outcome, started_at, agent)

      Logger.info(
        "feature #{ctx.feature.id} auto-remediation attempt #{attempt}/#{limit} -> " <>
          inspect(outcome)
      )

      {{agent, outcome}, Map.merge(meta, %{outcome: outcome, cost: cost})}
    end)
  end

  defp remediation_meta(ctx, state, findings) do
    %{
      feature_id: ctx.feature.id,
      phase: :analyze,
      attempt: state.attempts_used,
      limit: state.settings.attempt_limit,
      threshold: state.settings.threshold,
      findings_count: length(findings),
      max_severity: findings |> Enum.map(&Severity.parse_finding/1) |> Severity.max(),
      model: state.settings.model
    }
  end

  # ---- records (FR-012, FR-012a, contracts/analyze_loop.md §4) ----------------
  #
  # One `Store.Writer.record_remediation_attempt/2` transaction per attempt
  # (018): the corrective step's own `phase_attempt` (`phase: :remediation`),
  # the `remediation_attempt` row (findings/outcome/cost/limit/threshold
  # verbatim), and its transcript — a no-op when this run isn't store-backed.
  defp record_remediation_attempt(ctx, state, findings, attempt, outcome, started_at, agent) do
    case Map.get(ctx, :run_key) do
      nil ->
        :ok

      run_key ->
        do_record_remediation_attempt(
          run_key,
          ctx,
          state,
          findings,
          attempt,
          outcome,
          started_at,
          agent
        )
    end
  end

  defp do_record_remediation_attempt(
         run_key,
         ctx,
         state,
         findings,
         attempt,
         outcome,
         started_at,
         agent
       ) do
    result = agent.state.last_result
    ended_at = DateTime.utc_now()
    {cost_amount, cost_kind} = Cost.for_phase(:auto_remediation, result || %PhaseResult{})

    max_severity = findings |> Enum.map(&Severity.parse_finding/1) |> Severity.max()

    phase_attempt = %{
      step: ctx.step,
      label: "remediation-a#{attempt}",
      started_at: started_at,
      ended_at: ended_at,
      duration_ms: DateTime.diff(ended_at, started_at, :millisecond),
      outcome: outcome,
      model: state.settings.model,
      cost_usd: cost_amount,
      cost_kind: cost_kind,
      session_id: agent.state.session_id,
      error: result && result.error
    }

    remediation = %{
      feature_id: ctx.feature.id,
      ordinal: attempt,
      findings: findings,
      max_severity: max_severity,
      outcome: outcome,
      cost_usd: cost_amount,
      attempt_limit: state.settings.attempt_limit,
      threshold: state.settings.threshold,
      model: state.settings.model
    }

    _ =
      Writer.record_remediation_attempt(run_key, %{
        remediation: remediation,
        phase_attempt: phase_attempt,
        cost: %{amount_usd: cost_amount, kind: cost_kind},
        transcript: result && result.final_text
      })

    :ok
  end

  # ---- terminal handling -------------------------------------------------------

  # Converged / below threshold / exhausted: the final analyze run governs, and
  # `Pipeline.next/3` evaluates it exactly as it would an un-looped run. Only the
  # *reason* is later decorated, by `Remediation.terminal_reason/2`.
  defp finish(_ctx, state, agent, exhausted) do
    patch(agent,
      last_signals: exhaustion_signals(agent.state.last_signals || %{}, state, exhausted),
      terminal_reason: nil,
      analyze_remediation: provenance(state),
      analyze_runs: state.analyze_runs
    )
  end

  defp exhaustion_signals(signals, _state, nil), do: signals

  defp exhaustion_signals(signals, state, attempts) do
    Map.put(signals, :remediation, %{
      attempts: attempts,
      limit: state.settings.attempt_limit,
      exhausted?: true
    })
  end

  # A halt/failure below has no `Pipeline.next/3` vocabulary of its own
  # (`Pipeline` stays untouched) — `terminal_reason` is the existing seam
  # `FeatureRunner` reads to short-circuit straight to the specific reason,
  # shared with `ChunkRunner`.
  defp halt(ctx, state, agent) do
    Logger.info("feature #{ctx.feature.id} analyze auto-remediation halted — breaker tripped")

    patch(agent,
      last_outcome: :error,
      last_signals: %{},
      terminal_reason: {:halted, :breaker},
      analyze_remediation: provenance(state),
      analyze_runs: state.analyze_runs
    )
  end

  defp fail(ctx, state, agent) do
    Logger.warning(
      "feature #{ctx.feature.id} analyze auto-remediation failed — remediation step errored " <>
        "on attempt #{state.attempts_used}/#{state.settings.attempt_limit}"
    )

    patch(agent,
      last_outcome: :error,
      last_signals: %{},
      terminal_reason: {:failed, :remediation_failed},
      analyze_remediation: provenance(state),
      analyze_runs: state.analyze_runs
    )
  end

  # Provenance, never budget (FR-015): recorded so an operator can see what was
  # already tried. Absent when the loop made no attempt.
  defp provenance(%{attempts_used: 0}), do: nil

  defp provenance(state) do
    %{
      attempts_used: state.attempts_used,
      limit: state.settings.attempt_limit,
      threshold: Atom.to_string(state.settings.threshold),
      enabled: true
    }
  end

  defp patch(agent, kvs), do: %{agent | state: Map.merge(agent.state, Map.new(kvs))}

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: Ledger.breaker_tripped?(ledger)
end
