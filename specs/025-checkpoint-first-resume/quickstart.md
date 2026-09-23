# Quickstart: validating Checkpoint-First Resume

**Branch**: `025-checkpoint-first-resume` | **Spec**: [spec.md](./spec.md)

Every scenario below runs **without executing a phase and without spending
budget** — the whole feature lives in a pure decision table plus one durable
write. Details live in [contracts/](./contracts/) and
[data-model.md](./data-model.md); nothing is duplicated here.

---

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON — a warning fails
```

All Elixir commands go through mise; the bare PATH is a stale global 1.19.5.

---

## Full gate

```bash
mise exec -- mix test
mise exec -- mix test --cover     # pure core must stay >90%
mise exec -- mix format --check-formatted
```

The default suite stays hermetic — no CLI, no worktree, no network. Nothing in
this feature needs `--include integration`.

---

## Scenario 1 — the defect (SC-001, FR-001)

Reproduces run `r000002` / `mod-player` / feature `001`: a checkpoint naming
`:implement` beside a trail whose newest boundary is `:tasks`.

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/reconcile_test.exs
```

**Expected**: `Reconcile.status(:running, evidence, run_shape)` returns
`{:resume, :implement}` — not `{:resume, :analyze}`. Worked case 1 of
[contracts/reconcile-checkpoint-first.md](./contracts/reconcile-checkpoint-first.md) §4.

Exercise it directly:

```bash
mise exec -- iex -S mix
```

```elixir
alias SpeckitOrchestrator.Recovery.{Evidence, Reconcile}

ev = %Evidence{
  feature_id: "001",
  branch_committed?: true,
  last_boundary_phase: :tasks,
  checkpoint: %{phase: :implement, last_completed_phase: :analyze, status: :in_progress}
}

Reconcile.status(:running, ev, {:breakdown, "mod-player"})
#=> {:resume, :implement}

Reconcile.resume_position(ev.checkpoint, ev.last_boundary_phase)
#=> {:resume, :implement}
```

---

## Scenario 2 — the two paths agree (SC-002, FR-003)

```bash
mise exec -- mix test test/speckit_orchestrator/resume_test.exs \
                     test/speckit_orchestrator/resume_run_test.exs \
                     test/speckit_orchestrator/resume_scope_test.exs \
                     test/speckit_orchestrator/resume_crash_test.exs
```

**Expected**: for the same feature record and the same evidence, the phase
`SpeckitOrchestrator.resume/2` resolves (via `resolve_start_phase/2` on the
checkpoint) equals the phase `resume_run/1` dispatches (via
`resume_phases` → `from:` → the same `resolve_start_phase/2`) — asserted
across every phase the pipeline can be interrupted in, with an injected
`:executor` capturing `start_phase` so no session is ever opened.

---

## Scenario 3 — no checkpoint still falls back to the trail (FR-002)

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/reconcile_test.exs
```

**Expected**: with `checkpoint: nil` and `last_boundary_phase: :tasks`, the
result is `{:resume, :analyze}` — today's answer, unchanged. A record with
neither checkpoint nor any artifact is still `:pending` (FR-009), and a
persistence-failure drain still reports `gap_possible?: true` through
`resumable/1`.

---

## Scenario 4 — a contradiction blocks and is named (SC-005, FR-005/FR-006)

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/reconcile_test.exs \
                     test/speckit_orchestrator/recovery_test.exs
```

**Expected**:

1. `Reconcile.status/3` returns
   `{:conflict, {:checkpoint_behind_trail, %{checkpoint: :plan, trail: :analyze}}}`.
2. `Recovery.plan_run/2` puts that feature in `report.conflicts`, maps it to
   `:blocked` in `statuses`, and gives it **no** `resume_phases` entry.
3. `Release.next/3` never releases it and never reports it as
   `{:stopped, _, _}`.
4. `Recovery.Report.format/1` renders
   `CONFLICT — checkpoint_behind_trail (checkpoint: plan, trail: analyze); human resolve`.

Preview it end-to-end against a live store, still without spending:

```elixir
{:ok, %{report: report}} = SpeckitOrchestrator.resumable_run()
IO.puts(SpeckitOrchestrator.Recovery.Report.format(report))
```

`resumable/1` starts no `Coordinator` and makes no `Ledger` reservation, so
`Spend:` is unchanged by running it (SC-003).

Also asserted here: FR-009a — a checkpoint with `branch_committed?: false` and
no other artifact yields `{:conflict, :checkpoint_without_branch}`, never
`:pending`; and FR-011 — an unrecognised checkpoint phase yields
`{:conflict, {:damaged_checkpoint, …}}` and is never coerced to a neighbour.

---

## Scenario 5 — implement progress is recorded and honoured (SC-006, FR-007)

```bash
mise exec -- mix test test/speckit_orchestrator/chunk_runner_test.exs \
                     test/speckit_orchestrator/store/writer_test.exs
```

**Expected**:

1. After each successful `{:task_phase, tp}` boundary, the feature's
   checkpoint row carries a non-`nil` `implement_chunk` with that task-phase's
   `ordinal`/`number`/`title` and the current `sessions_used`, written in the
   same transaction as the `:implement_chunk` phase attempt and **after** the
   boundary commit — see
   [contracts/implement-chunk-checkpoint-write.md](./contracts/implement-chunk-checkpoint-write.md) §2.1.
   This is a **new** assertion: no value was written before this feature
   (research R4).
2. `phase` stays `:implement` and `last_completed_phase` stays the phase
   before it, so Scenario 1's comparison keeps working mid-phase.
3. `analyze_remediation` survives the write.
4. Resuming that record re-enters `ChunkRunner` at the recorded task-phase,
   with already-complete task-phases `{:skip, _}`ped — zero re-executed tasks.
5. FR-007a: a record with `implement_chunk: nil` resolves through
   `TaskPlan.locate(plan, nil)` to the first incomplete task-phase, reported
   as `:fallback`, with **no** discrepancy raised.
6. A recorded ordinal past the end of a regenerated `tasks.md` also resolves
   to `:fallback` and logs `"located by fallback"`.

---

## Scenario 6 — nothing that works today changes (SC-004, FR-014)

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/ \
                     test/speckit_orchestrator/recovery_test.exs \
                     test/speckit_orchestrator/recovery_quickpoll_test.exs \
                     test/speckit_orchestrator/record_recovery_test.exs \
                     test/speckit_orchestrator/web/reconcile_test.exs
```

**Expected**: every pre-existing reconciliation case resolves to the identical
phase, in both shapes an existing record can have — `checkpoint: nil`, and the
agreeing checkpoint the writer would have produced at that same boundary
(research R7). Zero new conflicts are reported for them, and
`Report.format/1`'s output for bare-atom reasons is byte-identical.

Specifically unchanged: `:escalated`/`:halted`/`:failed`/`:done` passthrough
(FR-008), `done_signal?/2`, `phase_after/1`, `no_artifacts?/1`,
`:pr_without_branch`, `:ambiguous_evidence`, `Release`, `Coordinator`, and
`Feature.status()`.

---

## Manual end-to-end (optional, costs real budget)

Only if a live proof is wanted beyond the suite: start a run against a target
repo, kill the BEAM mid-`implement` (`Ctrl+\`), then

```elixir
{:ok, %{report: r}} = SpeckitOrchestrator.resumable_run()
IO.puts(SpeckitOrchestrator.Recovery.Report.format(r))   # shows "resume: implement"
SpeckitOrchestrator.resume_run()
```

**Expected**: the report names `resume: implement` before anything starts, and
the resumed feature's first phase attempt is `:implement_chunk`, not
`:analyze`. `docs/runbook.md` has the full operator flow.
