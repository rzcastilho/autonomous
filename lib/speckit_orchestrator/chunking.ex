defmodule SpeckitOrchestrator.ChunkScope do
  @moduledoc """
  The unit dispatched to one chunk session (data-model.md §4): a single
  task-phase, the end-of-run sweep of leftover tasks, or the unstructured-plan
  fallback that hands the whole list to one bare `/speckit.implement` session.
  """

  alias SpeckitOrchestrator.TaskPlan.{Task, TaskPhase}

  @type t :: {:task_phase, TaskPhase.t()} | {:sweep, [Task.t()]} | :whole_list
end

defmodule SpeckitOrchestrator.ChunkAttempt do
  @moduledoc """
  One dispatched chunk session (data-model.md §6) — the spec's *Chunk Attempt*
  entity. Carried through the loop by the caller (`ChunkRunner`) and rendered
  into transcripts, telemetry, and the roll-up. `Chunking.next/2` itself does
  not append to a `ChunkState`'s history; that bookkeeping belongs to the edge
  module that actually runs sessions.
  """

  alias SpeckitOrchestrator.ChunkScope

  defstruct scope: nil,
            attempt: 1,
            outcome: nil,
            completed_before: 0,
            completed_after: 0,
            cost: 0.0,
            transcript: nil

  @type t :: %__MODULE__{
          scope: ChunkScope.t(),
          attempt: pos_integer(),
          outcome: :ok | :exhausted | :error | nil,
          completed_before: non_neg_integer(),
          completed_after: non_neg_integer(),
          cost: float(),
          transcript: String.t() | nil
        }

  @doc "True when the attempt completed at least one task — the FR-011 vs FR-012 discriminator."
  @spec progress?(t()) :: boolean()
  def progress?(%__MODULE__{completed_before: before, completed_after: aft}), do: aft > before
end

defmodule SpeckitOrchestrator.ChunkState do
  @moduledoc """
  `Chunking.next/2`'s whole loop state (data-model.md §7). Holds no process
  state and no IO handles — `plan` is re-read and threaded back in via
  `signals.plan` before every decision (FR-006), never trusted stale.
  """

  alias SpeckitOrchestrator.{ChunkAttempt, TaskPlan}

  defstruct plan: nil,
            cursor: 1,
            attempt: 1,
            no_progress: 0,
            sessions_used: 0,
            ceiling: 0,
            swept?: false,
            history: []

  @type t :: %__MODULE__{
          plan: TaskPlan.t(),
          cursor: pos_integer(),
          attempt: pos_integer(),
          no_progress: non_neg_integer(),
          sessions_used: non_neg_integer(),
          ceiling: non_neg_integer(),
          swept?: boolean(),
          history: [ChunkAttempt.t()]
        }
end

defmodule SpeckitOrchestrator.Chunking do
  @moduledoc """
  Pure decision surface for the implement step's chunk loop — the
  `Pipeline.next/3` analogue for one feature's task-phases. No IO, no process
  state, no `:telemetry` (Constitution I). See
  `specs/015-implement-phase-chunking/contracts/chunking.md` for the full
  decision table and failure-reason vocabulary this module implements.
  """

  alias SpeckitOrchestrator.ChunkState
  alias SpeckitOrchestrator.Config
  alias SpeckitOrchestrator.TaskPhaseRef
  alias SpeckitOrchestrator.TaskPlan
  alias SpeckitOrchestrator.TaskPlan.{Task, TaskPhase}

  @type outcome :: :ok | :exhausted | :error

  @type signals :: %{
          optional(:outcome) => outcome(),
          optional(:progress?) => boolean(),
          optional(:plan) => TaskPlan.t(),
          optional(:breaker?) => boolean(),
          optional(:transient?) => boolean(),
          # Not part of the documented contract signal set — plumbed through so
          # row 2's `{:session_error, term()}` reason carries the real failure,
          # rather than `nil`.
          optional(:error) => term()
        }

  @type reason ::
          {:stuck_task_phase, TaskPhaseRef.t(), non_neg_integer()}
          | {:session_ceiling, pos_integer()}
          | {:unchecked_tasks, [String.t()]}
          | {:session_error, term()}

  @type decision ::
          {:dispatch, SpeckitOrchestrator.ChunkScope.t(), ChunkState.t()}
          | {:skip, TaskPhase.t(), ChunkState.t()}
          | {:done, ChunkState.t()}
          | {:halted, :breaker, ChunkState.t()}
          | {:failed, reason(), ChunkState.t()}

  @doc """
  Freeze the session ceiling (research R8) and build the initial loop state.

  `ceiling = per_task_phase * max(task_phase_count, 1) + headroom`, resolved
  once here and never recomputed — a session that appends task-phases must not
  raise its own budget.

  Options:
    * `:from_ordinal` — resume cursor (FR-021), default `1`.
    * `:sessions_used` — carried session count; `0` on operator resume (FR-013b).
  """
  @spec start(TaskPlan.t(), keyword()) :: ChunkState.t()
  def start(%TaskPlan{} = plan, opts \\ []) do
    task_phase_count = max(TaskPlan.task_phase_count(plan), 1)

    ceiling =
      Config.implement_sessions_per_task_phase() * task_phase_count +
        Config.implement_sessions_headroom()

    %ChunkState{
      plan: plan,
      cursor: Keyword.get(opts, :from_ordinal, 1),
      attempt: 1,
      no_progress: 0,
      sessions_used: Keyword.get(opts, :sessions_used, 0),
      ceiling: ceiling,
      swept?: false,
      history: []
    }
  end

  @doc """
  Decide the next thing to do given the loop `state` and the just-folded
  `signals` (empty on the very first call, before any session has run). See
  contracts/chunking.md §2 for the full table; row precedence is documented
  inline below where this implementation's evaluation order departs from the
  table's literal numbering.
  """
  @spec next(ChunkState.t(), signals()) :: decision()
  def next(%ChunkState{} = state, signals \\ %{}) do
    state = %{state | plan: Map.get(signals, :plan, state.plan)}
    outcome = Map.get(signals, :outcome)
    progress? = Map.get(signals, :progress?, false)
    breaker? = Map.get(signals, :breaker?, false)
    transient? = Map.get(signals, :transient?, false)
    limit = Config.implement_no_progress_limit()

    cond do
      # Row 2 — a genuine (non-transient) session error always fails.
      outcome == :error and not transient? ->
        {:failed, {:session_error, Map.get(signals, :error)}, state}

      # Row 4 — checked ahead of the general exhaustion-continuation rows
      # (3/5) so a no-progress streak that just reached the limit fails as
      # stuck rather than continuing once more.
      outcome == :exhausted and not progress? and state.no_progress + 1 >= limit ->
        {:failed, {:stuck_task_phase, current_ref(state), limit}, state}

      # Rows 1/3/5 — redispatch the same scope: a transient error retry, an
      # exhausted-with-progress continuation, or an exhausted-without-progress
      # continuation (not yet at the limit). The session ceiling (row 6) is
      # checked here too, ahead of the redispatch itself — the contract's note
      # "the ceiling can never be exceeded, only reached" only holds if a
      # continuation streak stops being re-dispatched once `sessions_used`
      # reaches it, which the literal top-down table order alone would not
      # guarantee.
      continuing?(outcome, transient?) ->
        continue(state, outcome, progress?)

      # Every other outcome (:ok, or no outcome yet on the very first call)
      # is a boundary: the just-folded scope (if any) is done with its one
      # normal-budget session, whether or not it finished every task inside
      # it — leftovers past this point are reconciled by the sweep (rows
      # 12/13), not by re-dispatching the same task-phase.
      true ->
        state |> advance_cursor_on_success(outcome) |> decide_next(outcome, breaker?)
    end
  end

  @doc """
  Operator-facing sentence for a terminal failure `reason()` (SC-002,
  contracts/chunking.md §3). The four reasons are exhaustive by construction —
  `reason()`'s union has no other member, so there is no catch-all clause here
  (Constitution II: fail loud rather than paper over a fifth shape with a
  generic message).
  """
  @spec failure_sentence(reason()) :: String.t()
  def failure_sentence({:stuck_task_phase, %TaskPhaseRef{} = ref, limit}) do
    ~s(task-phase #{ref.number || ref.ordinal} "#{ref.title}" made no progress in #{limit} consecutive sessions)
  end

  def failure_sentence({:session_ceiling, n}) do
    "feature exhausted its implement session budget (#{n} sessions)"
  end

  def failure_sentence({:unchecked_tasks, ids}) do
    "tasks still unchecked after the sweep: #{Enum.join(ids, ", ")}"
  end

  def failure_sentence({:session_error, r}) do
    "implement session failed: #{inspect(r)}"
  end

  # ---- continuation folding -------------------------------------------------

  defp continuing?(:error, true), do: true
  defp continuing?(:exhausted, _progress?), do: true
  defp continuing?(_outcome, _transient?), do: false

  defp continue(state, :exhausted, true), do: continue_dispatch(%{state | no_progress: 0})

  defp continue(state, :exhausted, false),
    do: continue_dispatch(%{state | no_progress: state.no_progress + 1})

  defp continue(state, :error, _progress?), do: continue_dispatch(state)

  defp continue_dispatch(state) do
    if state.sessions_used >= state.ceiling do
      {:failed, {:session_ceiling, state.ceiling}, state}
    else
      dispatch_same(state, current_scope(state))
    end
  end

  # ---- boundary advance + next-scope selection ------------------------------

  # A task-phase's cursor only ever moves forward on its own successful
  # (`:ok`) completion — never at dispatch time, or a continuation fold (rows
  # 1/3/5 above) would compute `current_scope/1` against the *next* task-phase
  # instead of the one actually being retried. A sweep/`:whole_list` boundary
  # needs no cursor (there is none to advance); `decide_next/3` below reaches
  # `:done` or the unchecked-tasks failure for those directly.
  defp advance_cursor_on_success(state, :ok) do
    case current_scope(state) do
      {:task_phase, tp} -> %{state | cursor: tp.ordinal + 1, attempt: 1, no_progress: 0}
      _ -> state
    end
  end

  defp advance_cursor_on_success(state, _outcome), do: state

  defp decide_next(state, outcome, breaker?) do
    cond do
      # Row 6 — ceiling reached with no continuation in play (a fresh
      # task-phase/sweep/fallback dispatch would exceed it).
      state.sessions_used >= state.ceiling ->
        {:failed, {:session_ceiling, state.ceiling}, state}

      # Row 7 — breaker checked only at a boundary (the just-folded session
      # succeeded), never mid-scope (mid-scope continuations return above).
      breaker? and outcome == :ok ->
        {:halted, :breaker, state}

      # Row 8 — FR-004 fallback: unstructured plan, nothing dispatched yet.
      not state.plan.structured? and state.sessions_used == 0 ->
        dispatch_new(state, :whole_list)

      # Row 9 — pre-complete task-phase (e.g. an out-of-scope completion, or
      # never touched this run at all): skip without dispatching.
      state.cursor <= TaskPlan.task_phase_count(state.plan) and
          task_phase_complete_at_cursor?(state.plan, state.cursor) ->
        {:ok, tp} = TaskPlan.at(state.plan, state.cursor)
        {:skip, tp, %{state | cursor: state.cursor + 1, attempt: 1, no_progress: 0}}

      # Row 10 — normal task-phase dispatch.
      state.cursor <= TaskPlan.task_phase_count(state.plan) ->
        {:ok, tp} = TaskPlan.at(state.plan, state.cursor)
        dispatch_new(state, {:task_phase, tp})

      # Row 11 — every task-phase dispatched/skipped and the whole list is
      # checked off: done, before ever considering a sweep.
      TaskPlan.complete?(state.plan) ->
        {:done, state}

      # Row 12 — the one-time sweep of whatever is still unchecked.
      not state.swept? ->
        dispatch_new(%{state | swept?: true}, {:sweep, TaskPlan.incomplete(state.plan)})

      # Row 13 — swept already, still unchecked tasks remain: fail by name.
      true ->
        {:failed, {:unchecked_tasks, Enum.map(TaskPlan.incomplete(state.plan), &task_name/1)},
         state}
    end
  end

  # ---- scope derivation ------------------------------------------------------

  defp current_scope(%ChunkState{plan: %TaskPlan{structured?: false}}), do: :whole_list

  defp current_scope(%ChunkState{swept?: true} = state),
    do: {:sweep, TaskPlan.incomplete(state.plan)}

  defp current_scope(%ChunkState{cursor: cursor, plan: plan}) do
    case TaskPlan.at(plan, cursor) do
      {:ok, tp} -> {:task_phase, tp}
      :error -> :whole_list
    end
  end

  # The stuck-task-phase reason (row 4) needs a `TaskPhaseRef` identity even
  # when the exhausted scope is the sweep or the unstructured fallback, neither
  # of which is a real numbered task-phase — synthesize a sentinel ref so the
  # operator sentence (contracts/chunking.md §3) still names *something*.
  defp current_ref(state) do
    case current_scope(state) do
      {:task_phase, tp} -> TaskPlan.ref(tp)
      {:sweep, _tasks} -> sweep_ref(state)
      :whole_list -> whole_list_ref()
    end
  end

  defp sweep_ref(state) do
    %TaskPhaseRef{
      ordinal: TaskPlan.task_phase_count(state.plan) + 1,
      number: "sweep",
      title: "final sweep"
    }
  end

  defp whole_list_ref, do: %TaskPhaseRef{ordinal: 1, number: nil, title: "tasks.md"}

  # ---- dispatch helpers --------------------------------------------------

  defp dispatch_new(state, scope) do
    {:dispatch, scope, %{state | attempt: 1, sessions_used: state.sessions_used + 1}}
  end

  defp dispatch_same(state, scope) do
    {:dispatch, scope,
     %{state | attempt: state.attempt + 1, sessions_used: state.sessions_used + 1}}
  end

  # ---- misc ----------------------------------------------------------------

  defp task_phase_complete_at_cursor?(plan, cursor) do
    case TaskPlan.at(plan, cursor) do
      {:ok, tp} -> TaskPhase.complete?(tp)
      :error -> false
    end
  end

  defp task_name(%Task{id: id}) when is_binary(id), do: id
  defp task_name(%Task{line: line, text: text}), do: "line #{line}: #{String.slice(text, 0, 60)}"
end
