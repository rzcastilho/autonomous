# Contract: `SpeckitOrchestrator.Chunking`

**Kind**: pure decision surface (Constitution I) — the `Pipeline.next/3` of the
implement step. No IO, no process state, no `:telemetry`.
**File**: `lib/speckit_orchestrator/chunking.ex`
**Satisfies**: FR-002, FR-003, FR-007, FR-007a, FR-007b, FR-009, FR-011, FR-012,
FR-013, FR-013a

---

## 1. API

```elixir
@spec start(TaskPlan.t(), keyword()) :: ChunkState.t()
@spec next(ChunkState.t(), signals()) :: decision()

@type signals :: %{
        optional(:outcome)      => :ok | :exhausted | :error,
        optional(:progress?)    => boolean(),
        optional(:plan)         => TaskPlan.t(),   # freshly re-read (FR-006)
        optional(:breaker?)     => boolean(),
        optional(:transient?)   => boolean()
      }

@type decision ::
        {:dispatch, ChunkScope.t(), ChunkState.t()}
      | {:skip, TaskPhase.t(), ChunkState.t()}
      | {:done, ChunkState.t()}
      | {:halted, :breaker, ChunkState.t()}
      | {:failed, reason(), ChunkState.t()}

@type reason ::
        {:stuck_task_phase, TaskPhaseRef.t(), non_neg_integer()}
      | {:session_ceiling, pos_integer()}
      | {:unchecked_tasks, [String.t()]}
      | {:session_error, term()}
```

`start/2` freezes the ceiling (research R8):
`ceiling = per_task_phase * max(task_phase_count, 1) + headroom`, defaults `2`
and `4` from `Config`. It accepts `:from_ordinal` (resume, FR-021) and
`:sessions_used` (0 on operator resume, FR-013b).

`next/2` is called twice per iteration by the caller: once with an **empty**
signal map to obtain the next thing to do, and once with the completed session's
signals to fold the outcome in. Both are the same pure function over
`ChunkState`; the caller never mutates state itself.

---

## 2. Decision table

Evaluated top-down; first match wins.

| # | Condition | Decision | FR |
|---|---|---|---|
| 1 | `signals.outcome == :error` and `signals.transient?` | `{:dispatch, same_scope, …}` (attempt+1, no `no_progress` change) | FR-014 — existing transient ladder, unchanged |
| 2 | `signals.outcome == :error` | `{:failed, {:session_error, reason}, …}` | FR-014 |
| 3 | `signals.outcome == :exhausted` and `progress?` | `{:dispatch, same_scope, …}` (attempt+1, `no_progress = 0`) | FR-011 |
| 4 | `signals.outcome == :exhausted` and not `progress?` and `no_progress + 1 >= limit` | `{:failed, {:stuck_task_phase, ref, limit}, …}` | FR-013 |
| 5 | `signals.outcome == :exhausted` and not `progress?` | `{:dispatch, same_scope, …}` (attempt+1, `no_progress + 1`) | FR-012 |
| 6 | `sessions_used >= ceiling` | `{:failed, {:session_ceiling, ceiling}, …}` | FR-013a |
| 7 | `signals.breaker?` and a task-phase boundary was just crossed | `{:halted, :breaker, …}` | FR-009 |
| 8 | `plan.structured? == false` and no session yet dispatched | `{:dispatch, :whole_list, …}` | FR-004 |
| 9 | `cursor <= task_phase_count` and `TaskPhase.complete?(at(cursor))` | `{:skip, tp, …}` (cursor+1, attempt reset) | FR-003 |
| 10 | `cursor <= task_phase_count` | `{:dispatch, {:task_phase, tp}, …}` | FR-002 |
| 11 | `TaskPlan.complete?(plan)` | `{:done, …}` | FR-007a |
| 12 | not `swept?` | `{:dispatch, {:sweep, TaskPlan.incomplete(plan)}, …}` (`swept? = true`) | FR-007, FR-007b |
| 13 | otherwise | `{:failed, {:unchecked_tasks, names}, …}` | FR-007a |

**Notes on precedence**

- Rows 1–5 fold the *just-finished* session; rows 6–13 choose the *next* one.
  Rows 3/5 re-dispatch the **same** scope, which is what makes continuation work
  identically for `{:task_phase, _}`, `{:sweep, _}` and `:whole_list` (FR-004's
  final sentence, FR-007b's "no second sweep").
- Row 6 is checked before any new dispatch, so the ceiling can never be exceeded
  — only reached.
- Row 7 fires only at a boundary (a scope completing), never mid-scope: drain,
  don't kill (Constitution IV, FR-009).
- Row 11 before row 12: a run that finished everything never dispatches a sweep.
- Row 13's `names` are `TaskPlan.Task` ids, or `"line <n>: <text…>"` when the
  task carries none (data-model §3).

**Counter rules**

- Every `{:dispatch, …}` increments `sessions_used` (FR-013a).
- `{:skip, …}` increments `cursor` only — it dispatches nothing and costs
  nothing (FR-003).
- Advancing `cursor` resets `attempt` to `1` and `no_progress` to `0`.
- `no_progress` is per-scope and consecutive: any attempt with `progress?`
  resets it to `0` (FR-013's explicit "an attempt that completes at least one
  task MUST reset that count").

---

## 3. Failure-reason vocabulary (SC-002)

Every implement failure carries exactly one of four reasons, and each maps to a
distinct operator-facing sentence:

| Reason | Sentence |
|---|---|
| `{:stuck_task_phase, ref, limit}` | `task-phase <n> "<title>" made no progress in <limit> consecutive sessions` |
| `{:session_ceiling, n}` | `feature exhausted its implement session budget (<n> sessions)` |
| `{:unchecked_tasks, ids}` | `tasks still unchecked after the sweep: T007, T012` |
| `{:session_error, r}` | `implement session failed: <r>` (the pre-existing class) |

These four are exhaustive by construction — the decision table has no other
`{:failed, _}` producer. This is the SC-002 guarantee, and a test asserts the
mapping is total.

---

## 4. Test obligations

Pure unit tests, table-driven, zero IO — the same style as `pipeline_test.exs`
and `release_test.exs`:

- 5 task-phases / 18 tasks / all complete in one attempt each ⇒ exactly 5
  dispatches, `{:done, _}` (SC-001, FR-002).
- Task-phases 1–2 pre-complete ⇒ 2 `{:skip, _}`, dispatch starts at 3 (FR-003,
  SC-004).
- `:exhausted` + progress, ten times over ⇒ ten dispatches, no failure until the
  ceiling (FR-011, FR-013's "steadily progressing task-phase is not killed").
- `:exhausted` + no progress ×`limit` ⇒ `{:failed, {:stuck_task_phase, …}}`;
  one no-progress attempt alone never fails (FR-012, FR-013).
- Alternating progress / no-progress ⇒ never reaches the no-progress bound
  (FR-013 reset rule).
- Ceiling reached mid-task-phase ⇒ `{:failed, {:session_ceiling, _}}`, distinct
  from stuck (FR-013a, SC-002).
- Unstructured plan ⇒ one `:whole_list` dispatch; exhaustion+progress ⇒ a second
  (FR-004, US1 scenario 5).
- All task-phases dispatched, 2 tasks unchecked ⇒ one `{:sweep, [_, _]}`; sweep
  exhausts ⇒ continuation, **never** a second sweep (FR-007, FR-007b).
- Sweep leaves one unchecked ⇒ `{:failed, {:unchecked_tasks, ["T012"]}}`
  (FR-007a).
- Out-of-scope completion (task-phase 5 completed by task-phase 3's session) ⇒
  task-phase 5 is later `{:skip, _}`ped ("Out-of-scope completions" edge case).
- `breaker? == true` at a boundary ⇒ `{:halted, :breaker, _}`; mid-scope it does
  not fire (FR-009).
