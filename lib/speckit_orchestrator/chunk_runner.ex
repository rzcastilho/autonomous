defmodule SpeckitOrchestrator.ChunkRunner do
  @moduledoc """
  Edge module that drives the `:implement` step's chunk loop.

  Wraps `Chunking.next/2` (the pure decision surface) and dispatches one
  `"phase.run"` signal per chunk — one harness session per task-phase/sweep
  attempt — so the existing per-action timeout, telemetry span shape, and
  per-session transcript/cost accounting all keep their meaning (research R3).
  Not a process: called synchronously from the same supervised `Task`
  `FeatureRunner` already runs in.

  See `specs/015-implement-phase-chunking/contracts/chunk_session.md` §2-4, §6
  and `specs/015-implement-phase-chunking/contracts/checkpoint-implement-chunk.md`
  §3 for the resume resolution this module performs at step start.
  """

  require Logger

  alias Jido.{AgentServer, Signal}

  alias SpeckitOrchestrator.Actions.RunFeaturePhase

  alias SpeckitOrchestrator.{
    Chunking,
    Config,
    Ledger,
    PhaseResult,
    Store,
    TaskPhaseRef,
    TaskPlan,
    Telemetry,
    Worktree
  }

  @type opts :: %{
          required(:pid) => pid(),
          required(:feature) => SpeckitOrchestrator.Feature.t(),
          required(:worktree) => Worktree.t() | nil,
          required(:layout) => SpeckitOrchestrator.Layout.t() | nil,
          required(:timeout) => timeout(),
          required(:step) => pos_integer(),
          required(:ledger) => pid() | nil,
          optional(:start_task_phase) => TaskPhaseRef.t() | pos_integer() | nil,
          optional(:reset_implement_sessions) => boolean()
        }

  @doc """
  Drive the implement step to completion for one feature, returning the
  `AgentServer`-shaped `agent` `FeatureRunner` expects — the same shape a
  normal (non-chunked) phase call returns, plus `state.terminal_reason` set
  when the step ended in a chunking-specific halt/failure that `Pipeline.next/3`
  has no vocabulary for (contracts/chunk_session.md §6).

  Resolves the loop's starting position (checkpoint-implement-chunk.md §3):
  an explicit `:start_task_phase` (an operator override, threaded down from
  `SpeckitOrchestrator.resume/2`) wins over the checkpoint's own recorded
  `implement_chunk`, which wins over the FR-025 fallback (first incomplete
  task-phase). `sessions_used` carries over from the checkpoint unless
  `:reset_implement_sessions` is true (FR-013b — an explicit grant of more
  budget). A match weaker than `:number` is reported once, before the first
  dispatch (FR-025a).
  """
  @spec run(opts()) :: struct()
  def run(%{pid: pid, worktree: worktree, feature: feature, layout: layout} = ctx) do
    plan = TaskPlan.load(worktree_path(worktree))
    record = checkpoint_record(Map.get(ctx, :run_key), feature, layout)

    {ref, override?} = start_ref(ctx, record)
    sessions_used = start_sessions_used(ctx, record)

    {from_ordinal, resolution} = resolve_position(plan, ref)
    report_resolution(feature, resolution, ref, override?)

    state = Chunking.start(plan, from_ordinal: from_ordinal, sessions_used: sessions_used)
    {:ok, %{agent: agent}} = AgentServer.state(pid)

    ctx =
      ctx
      |> Map.put(:start_ref, git_head(worktree))
      |> Map.put(:baseline_sessions_used, sessions_used)

    loop(ctx, state, %{}, agent)
  end

  # ---- resume resolution (checkpoint-implement-chunk.md §3) ------------------

  # `nil` for a caller with no store-backed run (a unit test calling this
  # module directly) — resolves as "no checkpoint", same as a genuine miss.
  defp checkpoint_record(nil, _feature, _layout), do: nil

  defp checkpoint_record(run_key, feature, _layout) do
    case Store.checkpoint(run_key, feature.id) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp start_ref(ctx, record) do
    case Map.get(ctx, :start_task_phase) do
      nil -> {ref_from_record(record), false}
      %TaskPhaseRef{} = ref -> {ref, true}
      ordinal when is_integer(ordinal) -> {%TaskPhaseRef{ordinal: ordinal}, true}
    end
  end

  defp ref_from_record(%{implement_chunk: %{} = chunk}) do
    %TaskPhaseRef{
      ordinal: Map.get(chunk, :ordinal),
      number: Map.get(chunk, :number),
      title: Map.get(chunk, :title)
    }
  end

  defp ref_from_record(_record), do: nil

  defp start_sessions_used(ctx, record) do
    if Map.get(ctx, :reset_implement_sessions, false) do
      0
    else
      case record do
        %{implement_chunk: %{sessions_used: n}} when is_integer(n) -> n
        _ -> 0
      end
    end
  end

  defp resolve_position(plan, ref) do
    case TaskPlan.locate(plan, ref) do
      {:ok, tp, match_kind} -> {tp.ordinal, {tp, match_kind}}
      {:error, :unstructured} -> {1, nil}
    end
  end

  defp report_resolution(_feature, nil, _ref, _override?), do: :ok
  defp report_resolution(_feature, {_tp, :number}, _ref, _override?), do: :ok

  defp report_resolution(feature, {tp, match_kind}, ref, override?) do
    Logger.info(
      "feature #{feature.id} implement resume: task-phase located by #{match_kind}" <>
        if(override?, do: " (explicit override)", else: "")
    )

    :telemetry.execute(
      [:speckit, :chunk, :resolved],
      %{},
      %{
        feature_id: feature.id,
        match_kind: match_kind,
        ordinal: tp.ordinal,
        number: tp.number,
        title: tp.title,
        requested: ref
      }
    )
  end

  # ---- loop -----------------------------------------------------------------

  defp loop(ctx, state, signals, agent) do
    case Chunking.next(state, signals) do
      {:dispatch, scope, state1} ->
        {agent1, next_signals} = dispatch(ctx, state1, scope)
        loop(ctx, state1, next_signals, agent1)

      {:skip, _tp, state1} ->
        loop(ctx, state1, %{}, agent)

      {:done, _state1} ->
        finish(ctx, agent)

      {:halted, :breaker, _state1} ->
        halt(ctx, agent)

      {:failed, reason, _state1} ->
        fail(ctx, agent, reason)
    end
  end

  # ---- one chunk session ------------------------------------------------------

  defp dispatch(ctx, state1, scope) do
    before_count = TaskPlan.completed_tasks(state1.plan)
    first_chunk? = state1.sessions_used == ctx.baseline_sessions_used + 1
    meta = chunk_meta(ctx, state1, scope)

    Telemetry.chunk_span()
    |> :telemetry.span(meta, fn ->
      signal =
        Signal.new!(
          "phase.run",
          %{phase: :implement, scope: scope, first_chunk: first_chunk?},
          source: "/chunk_runner"
        )

      {:ok, agent1} = AgentServer.call(ctx.pid, signal, ctx.timeout)
      result = agent1.state.last_result

      {outcome, transient?} = classify_outcome(result)
      after_plan = TaskPlan.load(worktree_path(ctx.worktree))
      after_count = TaskPlan.completed_tasks(after_plan)
      progress? = after_count > before_count

      maybe_commit_boundary(ctx, scope, outcome, after_plan)

      signals = %{
        outcome: outcome,
        progress?: progress?,
        plan: after_plan,
        breaker?: breaker_tripped?(ctx.ledger),
        transient?: transient?,
        error: result && result.error
      }

      stop_meta =
        Map.merge(meta, %{
          outcome: outcome,
          cost: (result && result.cost_usd) || 0.0,
          completed_before: before_count,
          completed_after: after_count
        })

      {{agent1, signals}, stop_meta}
    end)
  end

  # Telemetry start metadata (contracts/telemetry-chunk.md §1). `ordinal`/
  # `total`/`number`/`title` are `nil` for `:sweep`/`:whole_list`; `remaining`
  # (not part of the documented table) carries the sweep's leftover-task count
  # so the feed/strip can render "sweep · N left" without re-deriving it from
  # the plan at fold time.
  defp chunk_meta(ctx, state1, scope) do
    {scope_atom, ordinal, total, number, title, remaining} = scope_fields(scope, state1.plan)

    %{
      feature_id: ctx.feature.id,
      phase: :implement,
      scope: scope_atom,
      ordinal: ordinal,
      total: total,
      number: number,
      title: title,
      attempt: state1.attempt,
      sessions_used: state1.sessions_used,
      ceiling: state1.ceiling,
      remaining: remaining,
      model: Config.model_for(:implement)
    }
  end

  defp scope_fields({:task_phase, tp}, plan),
    do: {:task_phase, tp.ordinal, TaskPlan.task_phase_count(plan), tp.number, tp.title, nil}

  defp scope_fields({:sweep, tasks}, _plan), do: {:sweep, nil, nil, nil, nil, length(tasks)}
  defp scope_fields(:whole_list, _plan), do: {:whole_list, nil, nil, nil, nil, nil}

  # Fixed classification order (contracts/chunk_session.md §3): exhaustion is
  # checked before the transient-vs-terminal split, so a max-turns result is
  # never mistaken for a server/API drop or folded into a flat "error".
  @spec classify_outcome(PhaseResult.t() | nil) :: {Chunking.outcome(), boolean()}
  defp classify_outcome(result) do
    cond do
      PhaseResult.exhausted?(result) -> {:exhausted, false}
      match?(%PhaseResult{status: :ok}, result) -> {:ok, false}
      PhaseResult.transient?(result) -> {:error, true}
      true -> {:error, false}
    end
  end

  # ---- per-task-phase boundary commit (FR-023a) ------------------------------

  defp maybe_commit_boundary(%{worktree: nil}, _scope, _outcome, _after_plan), do: :ok

  defp maybe_commit_boundary(ctx, {:task_phase, tp}, :ok, after_plan) do
    total = TaskPlan.task_phase_count(after_plan)
    message = "speckit: #{ctx.feature.id} implement task-phase #{tp.ordinal}/#{total} #{tp.title}"
    Worktree.commit(ctx.worktree, message)
  end

  defp maybe_commit_boundary(_ctx, _scope, _outcome, _after_plan), do: :ok

  # ---- terminal handling -------------------------------------------------------

  # The artifact gate (research R10) is evaluated exactly once here, on the
  # roll-up — never per chunk — so `Pipeline.next/3` still sees exactly the
  # `:implement` signal map it understands today (FR-008).
  defp finish(ctx, agent) do
    artifact =
      RunFeaturePhase.missing_implement_artifact(ctx.worktree, since: ctx[:start_ref])

    signals = if artifact, do: %{missing_artifact: artifact}, else: %{}
    result = rollup(:ok, signals, nil)

    patch(agent,
      last_outcome: :ok,
      last_signals: signals,
      last_result: result,
      terminal_reason: nil
    )
  end

  # A halt/failure below has no `Pipeline.next/3` vocabulary of its own
  # (FR-008: `Pipeline.next/3` stays untouched) — `terminal_reason` is the
  # existing `FeatureAgent` field the runner reads to short-circuit straight
  # to the specific SC-002 reason (or the breaker halt) instead of the
  # generic `{:implement, :error}` `Pipeline.next/3` would otherwise produce.
  defp halt(_ctx, agent) do
    result = rollup(:halted, %{}, :breaker)

    patch(agent,
      last_outcome: :error,
      last_result: result,
      terminal_reason: {:halted, :breaker}
    )
  end

  defp fail(_ctx, agent, reason) do
    result = rollup(:error, %{}, reason)

    patch(agent,
      last_outcome: :error,
      last_result: result,
      terminal_reason: {:failed, reason}
    )
  end

  defp patch(agent, kvs), do: %{agent | state: Map.merge(agent.state, Map.new(kvs))}

  # The roll-up becomes this feature run's durable `:implement` phase attempt
  # (018) — the caller (`FeatureRunner`) persists `agent.state.last_result`
  # via `Store.Writer.record_phase_attempt/2`. Each intermediate chunk's own
  # result is not separately persisted (018 — only the roll-up matters to the
  # pipeline; per-chunk transcripts were a pre-018 worktree-only convenience).
  defp rollup(status, signals, reason) do
    %PhaseResult{status: status, final_text: rollup_text(status, signals, reason), error: reason}
  end

  defp rollup_text(:ok, %{missing_artifact: artifact}, _reason),
    do: "implement step complete, but missing: #{artifact}"

  defp rollup_text(:ok, _signals, _reason),
    do: "implement step complete — every task-phase dispatched"

  defp rollup_text(:halted, _signals, :breaker),
    do: "implement step halted — cost breaker tripped at a task-phase boundary"

  defp rollup_text(:error, _signals, reason), do: "implement step failed: #{inspect(reason)}"

  # ---- misc -------------------------------------------------------------------

  defp worktree_path(%Worktree{path: path}), do: path
  defp worktree_path(_), do: SpeckitOrchestrator.Config.repo()

  # Captured once at implement-step start so the roll-up's artifact-gate check
  # can see changes already committed at task-phase boundaries (FR-023a), not
  # just what's still dirty in the tree.
  defp git_head(%Worktree{path: path}) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp git_head(_worktree), do: nil

  defp breaker_tripped?(nil), do: false
  defp breaker_tripped?(ledger), do: Ledger.breaker_tripped?(ledger)
end
