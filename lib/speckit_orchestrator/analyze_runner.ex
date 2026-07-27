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
    Ledger,
    PhaseResult,
    PhaseStep,
    Prompts,
    Remediation,
    Severity,
    Telemetry,
    Transcripts
  }

  alias SpeckitOrchestrator.Remediation.Settings

  @type opts :: %{
          required(:pid) => pid(),
          required(:feature) => SpeckitOrchestrator.Feature.t(),
          required(:worktree) => SpeckitOrchestrator.Worktree.t() | nil,
          required(:layout) => SpeckitOrchestrator.Layout.t() | nil,
          required(:timeout) => timeout(),
          required(:step) => pos_integer(),
          required(:ledger) => pid() | atom() | nil,
          required(:settings) => Settings.t()
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
    PhaseStep.run(ctx.pid, ctx.feature, :analyze,
      step: ctx.step,
      timeout: ctx.timeout,
      worktree: ctx.worktree,
      layout: ctx.layout
    )
  end

  def run(%{settings: %Settings{} = settings} = ctx) do
    state = %{
      settings: settings,
      attempts_used: 0,
      analyze_runs: 0,
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
        write_attempt_record(ctx, state1, agent)
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

  # Always written under the plain `analyze` label, so `NN-analyze.md` is the
  # final run's transcript at every point in the loop and `Recovery.Evidence` /
  # `TranscriptsLive` keep working untouched. The per-attempt `-a<k>` copies are
  # written separately (research R9, contracts/analyze_loop.md §4).
  defp analyze(ctx, state) do
    k = state.analyze_runs + 1

    agent =
      PhaseStep.run(ctx.pid, ctx.feature, :analyze,
        step: ctx.step,
        timeout: ctx.timeout,
        worktree: ctx.worktree,
        layout: ctx.layout,
        span_meta: %{attempt: k, limit: state.settings.attempt_limit}
      )

    {agent, %{state | analyze_runs: k}}
  end

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

      write_remediation_record(ctx, attempt, instruction, agent.state.last_result)

      Logger.info(
        "feature #{ctx.feature.id} auto-remediation attempt #{attempt}/#{limit} -> " <>
          inspect(outcome)
      )

      {{agent, outcome}, Map.merge(meta, %{outcome: outcome, cost: Map.get(entry, :cost, 0.0)})}
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

  defp write_attempt_record(ctx, state, agent) do
    write_analyze_copy(ctx, state.analyze_runs, agent.state.last_result)
  end

  defp write_analyze_copy(ctx, k, %PhaseResult{} = result) do
    Transcripts.write_labelled(
      ctx.worktree,
      ctx.layout,
      ctx.step,
      "analyze-a#{k}",
      :analyze,
      result
    )
  end

  defp write_analyze_copy(_ctx, _k, _result), do: :ok

  # The triggering findings, the instruction issued, the outcome and the cost
  # are all recoverable from this one file (FR-012).
  defp write_remediation_record(ctx, attempt, instruction, %PhaseResult{} = result) do
    body = %{
      result
      | final_text:
          "### instruction\n\n" <>
            instruction <> "\n\n### step output\n\n" <> (result.final_text || "")
    }

    Transcripts.write_labelled(
      ctx.worktree,
      ctx.layout,
      ctx.step,
      "remediation-a#{attempt}",
      :auto_remediation,
      body
    )
  end

  defp write_remediation_record(_ctx, _attempt, _instruction, _result), do: :ok

  # ---- terminal handling -------------------------------------------------------

  # Converged / below threshold / exhausted: the final analyze run governs, and
  # `Pipeline.next/3` evaluates it exactly as it would an un-looped run. Only the
  # *reason* is later decorated, by `Remediation.terminal_reason/2`.
  defp finish(ctx, state, agent, exhausted) do
    if state.attempts_used > 0,
      do: write_analyze_copy(ctx, state.analyze_runs, agent.state.last_result)

    patch(agent,
      last_signals: exhaustion_signals(agent.state.last_signals || %{}, state, exhausted),
      terminal_reason: nil,
      analyze_remediation: provenance(state)
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
      analyze_remediation: provenance(state)
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
      analyze_remediation: provenance(state)
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
