# Contract: implement-chunk progress is actually written

**Kind**: durable-write repair (the write half of a 015 contract that did not
survive the 018 file→store checkpoint migration).
**Module**: `SpeckitOrchestrator.ChunkRunner`
**Completes**: `specs/015-implement-phase-chunking/contracts/checkpoint-implement-chunk.md` §2
**Satisfies**: FR-007, FR-007a, SC-006

---

## 1. Why this is in scope

The spec assumes the position is already recorded. It is not: `implement_chunk`
is read by `ChunkRunner`, persisted by `Store.Writer.write_checkpoint/3`, and
rendered by `ConsoleHydration` — but **no producer ever sets it**.
`FeatureRunner.checkpoint_for/3`'s three clauses build the checkpoint map
literally without the key, and `ChunkRunner.record_chunk_attempt/6` passes
only `attempt` and `transcript`. Every `implement_chunk` in the suite is
`nil`. Full finding: research R4.

Without the write, FR-007 collapses into FR-007a for every record and SC-006
is unverifiable.

---

## 2. Write site

`ChunkRunner.record_chunk_attempt/6` adds one key to the payload it already
hands `Store.Writer.record_phase_attempt/2`:

```elixir
Writer.record_phase_attempt(run_key, %{
  attempt: %{…},                     # unchanged
  transcript: result && result.final_text,   # unchanged
  checkpoint: chunk_checkpoint(ctx, state1, scope, outcome)
})
```

`Store.Writer.record_phase_attempt/2` already persists
`Map.get(payload, :checkpoint)` through `write_checkpoint/3` in the same
transaction (`store/writer.ex:207`) — no writer change is needed.

### 2.1 Ordering

`maybe_commit_boundary/4` already runs immediately before
`record_chunk_attempt/6` in `ChunkRunner.dispatch/4`. The checkpoint is
therefore written **after** the boundary commit, which is 015 §2's
non-negotiable ordering: a crash between the two leaves the older position and
re-runs committed work idempotently (`Chunking.next/2` `{:skip, _}`s complete
task-phases), whereas the reverse order would point at work that was never
committed.

---

## 3. `chunk_checkpoint/4`

```elixir
@spec chunk_checkpoint(map(), Chunking.state(), Chunking.scope(), atom()) :: map() | nil
```

| `scope` | `outcome` | Result |
|---|---|---|
| `{:task_phase, tp}` | `:ok` | full checkpoint map (§3.1) |
| `{:task_phase, tp}` | anything else | `nil` — nothing completed, position unchanged |
| `:sweep` / `:whole_list` | any | `nil` — no task-phase identity to record |

`nil` is a no-op: `Store.Writer.write_checkpoint/3` has a
`write_checkpoint(_, _, nil) -> :ok` clause, so a skipped write leaves the
previous row intact rather than clearing it.

### 3.1 Map shape

Because `write_checkpoint/3` writes **every** column from the map it is given,
the map must carry the whole checkpoint, not just the new key — otherwise the
phase/`last_completed_phase` columns would be nulled mid-implement.

```elixir
%{
  phase: :implement,
  last_completed_phase: :analyze,          # the phase before :implement
  status: :in_progress,
  reason: nil,
  session_id: agent.state.session_id,
  analyze_remediation: <carried from the existing row>,
  implement_chunk: %{
    ordinal: tp.ordinal,
    number: tp.number,
    title: tp.title,
    total: TaskPlan.task_phase_count(state1.plan),
    sessions_used: state1.sessions_used,
    ceiling: state1.ceiling,
    scope: :task_phase
  }
}
```

- `phase: :implement` — a mid-implement crash must resume **at** implement,
  which is what makes case 1 of `reconcile-checkpoint-first.md` §4 work.
- `last_completed_phase` — the phase preceding `:implement` in
  `Pipeline.phases/0`, so `resume_position/2`'s completed-through derivation
  places the checkpoint at `rank(:analyze)`, strictly above the trail's
  `:tasks`.
- `analyze_remediation` must be **preserved**, not dropped: it is read back by
  `resume/2`'s context restore. It is carried from the checkpoint row
  `ChunkRunner.run/1` already loaded (`checkpoint_record/3`), threaded onto
  `ctx` beside `:baseline_sessions_used`.
- `ordinal`/`number`/`title` describe the task-phase **just completed**, per
  015 §2. `TaskPlan.locate/2` resolves `number → title → ordinal`, and
  `Chunking.next/2` `{:skip, _}`s it on resume because its tasks are complete
  — so recording the completed phase (not the next one) is correct and needs
  no "+1".

---

## 4. Read side — unchanged

No change is required, and none is made:

- `dispatch_resume/7` → `run_from_checkpoint/8` sets neither
  `:start_task_phase` nor `:reset_implement_sessions`, so `ChunkRunner.run/1`
  re-reads the row itself via `Store.checkpoint(run_key, feature.id)` and
  carries `sessions_used` forward.
- `ref_from_record/1` builds a `%TaskPhaseRef{}` from the three identity keys.
- `TaskPlan.locate/2` already returns `{:ok, fallback, :fallback}` for a
  `nil` ref — **FR-007a**: an older record with no recorded position starts
  the implement work at the first incomplete task-phase and raises no
  discrepancy.
- `TaskPlan.locate/2` also returns `{:ok, fallback, :fallback}` for an
  ordinal past the end of a regenerated `tasks.md`, and
  `report_resolution/4` already logs
  `"feature <id> implement resume: task-phase located by fallback"` and emits
  `[:speckit, :chunk, :resolved]` — the spec's "task list was regenerated"
  edge case, already satisfied.
- An operator's explicit `:from_task_phase` still wins over the recorded
  position (`start_ref/2`), unchanged.

---

## 5. Non-goals

- No new `phase_attempt` row and no `cost_entry`: the `:implement` roll-up
  still carries the step's summed cost, and per-chunk cost entries would
  double-count.
- No change to `Chunking`, `TaskPlan`, `Store.Schema`, or the store schema
  version — `implement_chunk` is an existing column.
- No change to `FeatureRunner.checkpoint_for/3`: the `:implement` roll-up
  fires only when the phase *finishes*, which a crashed run never reaches.
