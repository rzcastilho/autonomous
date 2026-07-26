# Contract: checkpoint extension + chunk-level resume

**Kind**: durable-state extension (existing `Checkpoint`) + facade/UI resume path.
**Files**: `checkpoint.ex`, `speckit_orchestrator.ex` (`resume/2`),
`web/live/escalations_live.ex`, `chunk_runner.ex`
**Satisfies**: FR-013b, FR-020, FR-020a, FR-021, FR-022, FR-023, FR-024, FR-025,
FR-025a

---

## 1. Record shape

One new **optional** top-level key on the existing checkpoint JSON. See
[data-model.md §8](../data-model.md) for the field table.

```json
"implement_chunk": {
  "ordinal": 3, "number": "3", "title": "User Story 1 - …",
  "total": 5, "sessions_used": 7, "ceiling": 14, "scope": "task_phase"
}
```

**Compatibility (non-negotiable)**: a checkpoint written before this feature has
no `implement_chunk` key. Reading one MUST NOT error, and MUST resolve exactly as
FR-025's "missing or unreadable" clause requires — the first task-phase with
incomplete tasks, reported as `:fallback`. Every existing `Checkpoint` test must
pass unmodified.

`Checkpoint.write/1` accepts an optional `:implement_chunk` entry in its input
map and omits the key entirely when absent — same `maybe_put_context/2` pattern
already used for `:context`. Write remains best-effort (`:ok` always).

---

## 2. Write timing (FR-020)

| Moment | `implement_chunk` written |
|---|---|
| after each task-phase boundary commit | ordinal/number/title of the task-phase **just completed**, `sessions_used` current |
| on the implement step's terminal outcome (any status) | the scope that was in flight |
| every other checkpoint write (other phases, `:done`) | key absent |

Writing *after* the boundary commit (not before) mirrors the existing rule in
`FeatureRunner.loop/9` — a crash between the two must not point at work that was
never committed.

---

## 3. Resume resolution (FR-021, FR-025, FR-025a)

At implement-step start, `ChunkRunner`:

1. loads the **current** `tasks.md` (FR-006 — the recorded position is resolved
   against today's file, not a snapshot);
2. builds a `TaskPhaseRef` from `implement_chunk` (or `nil` when absent);
3. calls `TaskPlan.locate/2` (data-model §5: number → title → ordinal →
   first-incomplete);
4. starts the loop at that task-phase, with `sessions_used` from the record —
   or `0` when the resume was operator-initiated (FR-013b);
5. when `match_kind != :number`, reports it (§5 below) before the first dispatch
   (FR-025a).

An explicit operator override (`:from_task_phase`) **wins over the recorded
position** and is reported as an explicit choice, not a weak match.

FR-023 ("MUST NOT re-execute tasks already marked complete") is satisfied
structurally by FR-003: the loop `{:skip, _}`s every already-complete
task-phase, whether it precedes or follows the resume point. SC-004 (zero
re-executed tasks) is asserted against that.

---

## 4. Operator surface (FR-022)

`EscalationsLive`'s resume form gains a **task-phase `<select>`**, rendered only
when both hold:

- the checkpoint's `last_phase` is `implement` (or the operator selects
  `implement` in the existing start-phase picker), **and**
- the feature's `tasks.md` parses as structured.

| Aspect | Behaviour |
|---|---|
| options | every task-phase, labelled `<ordinal>/<total> · <number>: <title>`, completed ones marked `✓` |
| default | the recorded task-phase, resolved via `TaskPlan.locate/2` |
| weaker-than-number match | an inline note: `matched by title — the task list was renumbered` (FR-025a) |
| no `implement_chunk` / unstructured | select is **not rendered**; resume behaves exactly as today (FR-019 spirit, SC-005) |
| submitted value | `:from_task_phase` on `SpeckitOrchestrator.resume/2` |

The plan is read from the feature's kept worktree via `TaskPlan.load/1`, using
the same `Worktree.locate/2` + glob path the view already uses for the clarify
`## NEEDS HUMAN` block.

`SpeckitOrchestrator.resume/2` gains:

- `:from_task_phase` — ordinal (integer) or `TaskPhaseRef.t()`; ignored unless
  the resolved `start_phase == :implement`;
- and always sets `reset_implement_sessions: true` (FR-013b — resuming is an
  explicit grant of more budget).

Guidance (`:prompt`) reaches the **first dispatched chunk only** (FR-024), which
is the direct analogue of today's `resume_phase`-anchored rule.

---

## 5. Reporting a weak match (FR-025a)

Emitted once, before the first dispatch, through all three existing operator
channels — no new surface:

- `Logger.info("feature <id> implement resume: task-phase located by <kind> …")`
- telemetry `[:speckit, :chunk, :resolved]` with
  `%{feature_id, match_kind, ordinal, number, title, requested}` → folded by
  `ConsoleReadModel` into a `:warn` feed entry for any `match_kind` other than
  `:number` (see [telemetry-chunk.md](./telemetry-chunk.md))
- the `06-implement.md` roll-up header

---

## 6. Test obligations

- Pre-015 checkpoint (no `implement_chunk`) ⇒ resume works, resolves
  `:fallback`, no crash. Existing `checkpoint_test.exs` passes untouched.
- Round-trip: write with `implement_chunk` → read → all seven fields intact.
- Renumbered task list (numbers shifted, titles stable) ⇒ located by `:title`,
  `[:speckit, :chunk, :resolved]` emitted with `match_kind: :title` (US2
  scenario 6).
- Retitled task list (numbers stable) ⇒ located by `:number`, **no** warning.
- Recorded task-phase deleted from the list ⇒ `:ordinal`, then `:fallback`.
- Failure during task-phase 3 of 5 ⇒ resume dispatches task-phase 3 first, and
  task-phases 1–2 are never dispatched (US2 scenario 1, SC-004).
- Resume discards uncommitted output (`Worktree.restore/1`, existing) ⇒
  task-phases 1–2's work **and** their `[X]` marks survive, because each
  boundary was committed (US2 scenario 5, FR-023a). This is the regression test
  that proves FR-023a is load-bearing: with per-task-phase commits removed, it
  must fail.
- `sessions_used` is `0` on the first dispatch after an operator resume
  (FR-013b).
- LiveView: select rendered for a structured implement checkpoint; absent for an
  unstructured one; submitted ordinal reaches `resume/2` as `:from_task_phase`
  (via the existing `:console_test_runner` seam).
