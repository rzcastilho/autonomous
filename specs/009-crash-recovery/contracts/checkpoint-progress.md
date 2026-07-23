# Contract: `Checkpoint` per-phase progress write (extension)

Extends `SpeckitOrchestrator.Checkpoint` usage — **no signature change**. The
existing `write/1`/`read/1`/`delete/1` already accept and round-trip the fields
below; this contract fixes the new *call site* and the new `status` value.

## New write timing (FR-001)

`FeatureRunner.loop/7`, after each successful phase (the `{:cont, next}` branch of
`Pipeline.next/3`, before recursing), calls:

```elixir
Checkpoint.write(%{
  feature_id: feature.id,
  last_phase: completed_phase,   # the phase that just finished
  status: :in_progress,          # NEW checkpoint-level marker
  reason: nil,
  session_id: agent.state.session_id,
  slug: feature.slug,
  path: feature.path,
  run_context: run_context       # threaded into the loop (new)
})
```

- `:in_progress` is serialized to `"in_progress"` by the existing
  `Atom.to_string/1`. It is a **checkpoint status**, not a `Feature.status()`.
- `run_context` must now be threaded through `loop/7` (today it is only passed to
  the terminal `checkpoint/5`).
- Write is best-effort; a failure never breaks the phase loop.

## Unchanged behavior

- Terminal divert writes (`:escalated`/`:halted`/`:failed`) — unchanged.
- `:done` deletes the checkpoint — unchanged.
- `read/1` three-way return — unchanged; `resume/2` consumes it as today.

## Resume semantics

`resume/2` validates `last_phase` via `Pipeline.phase?/1` and starts at the
**next** phase; it does **not** branch on the checkpoint `status`. So an
`"in_progress"` record resumes identically to a divert record — the interrupted
phase is re-run from a clean tree (after `Worktree.restore/1`).

## Test contract

- After a feature runs cleanly through phase `plan`, a checkpoint exists with
  `last_phase == "plan"`, `status == "in_progress"`, and a `context` object.
- The checkpoint is **overwritten** (not appended) each phase — reading after
  `tasks` shows `last_phase == "tasks"`.
- On `:done`, no checkpoint remains (deleted).
