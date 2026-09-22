# Phase 0 Research: Checkpoint-First Resume

**Branch**: `025-checkpoint-first-resume` | **Date**: 2026-09-22 |
**Spec**: [spec.md](./spec.md)

All unknowns below were resolved by reading the shipped code; no Technical
Context entry remains `NEEDS CLARIFICATION`.

---

## R1 — Where the two resume paths actually disagree

**Decision**: The disagreement is one line, and it is in the pure layer.

Both paths converge on `SpeckitOrchestrator.run/1` with an injected executor,
but they resolve the start phase from different sources:

| Path | Entry | Start phase comes from |
|---|---|---|
| single feature | `SpeckitOrchestrator.resume/2` (`lib/speckit_orchestrator.ex:638`) | `resolve_start_phase(feature_record.checkpoint, opts)` — the **checkpoint** |
| whole run | `SpeckitOrchestrator.resume_run/1` → `dispatch_resume/7` (`lib/speckit_orchestrator.ex:1495`) | `resume_phases[feature.id]`, passed as `from:` into the *same* `resolve_start_phase/2` — and `:from` **wins over** the checkpoint (`lib/speckit_orchestrator.ex:1645`) |

`resume_phases` is built by `Recovery.plan_run/2` from
`Reconcile.status/3` clause 5:

```elixir
recorded == :running and evidence.last_boundary_phase in @resumable_boundaries ->
  {:resume, phase_after(evidence.last_boundary_phase)}
```

`Evidence.checkpoint` is *already collected* (`recovery/evidence.ex`,
`store_checkpoint/1`) and is *already consulted* — but only by
`Reconcile`'s clause-6 `no_artifacts?/1` guard, never for position.

**Rationale**: Fixing clause 5 fixes both paths at once, because the
whole-run path's `from:` override is derived from it and the single-feature
path already reads the checkpoint. `Recovery.Rebuild.propose/3` (the
`recover_record/1` preview) calls the same `Evidence`/`Reconcile` pair, so
FR-012's "single shared rule" holds for free.

**Alternatives considered**:
- *Make `implement`'s per-chunk commits carry the boundary marker.* Rejected
  by the spec itself (Assumptions): it makes the position git-derivable but
  leaves two resume paths reading two sources — the root disagreement.
- *Drop the `from:` override in `dispatch_resume/7`.* Rejected: it silently
  discards reconciliation's `{:resume, _}` for every feature, including the
  no-checkpoint fallback FR-002 must preserve, and leaves `Rebuild`'s preview
  reporting a phase the resume would not use.

**Evidence of the live defect**: `implement`'s progress commits are written by
`ChunkRunner.maybe_commit_boundary/4` as
`"speckit: <id> implement task-phase N/M <title>"` — which
`Evidence`'s `@boundary_re`
(`^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$`) does not match.
`FeatureRunner` writes the `checkpoint after implement` boundary only at
`{:cont, next}`, i.e. after the *whole* phase. A crash mid-`implement`
therefore leaves `:tasks` as the newest matching marker and clause 5 rewinds
to `:analyze`.

---

## R2 — Comparing a checkpoint position against a trail position

**Decision**: Compare *completed-through* ordinals, using
`Pipeline.step_of/1`, guarded by `Pipeline.phase?/1`.

The two sources speak different vocabularies:

- `Evidence.last_boundary_phase` is the **phase just completed**
  (`"checkpoint after <phase>"`).
- `checkpoint.phase` is the **next phase to run**; `checkpoint.last_completed_phase`
  is the phase just completed (`FeatureRunner.checkpoint_for/3`).

So the comparable value is `checkpoint.last_completed_phase`, with
`predecessor(checkpoint.phase)` as the fallback for a record written without
it. A checkpoint is **behind** iff
`step_of(cp_completed) < step_of(last_boundary_phase)`.

**Rationale**: Comparing `checkpoint.phase` to `last_boundary_phase` directly
would mis-classify the healthy agreement case (`cp.phase = :analyze`,
trail = `:tasks` — one step apart by construction) as a boundary condition
that has to be special-cased. Comparing completed-through values makes
agreement an exact tie and needs no special case, which is what FR-014
(byte-identical behaviour for records that resume correctly today) requires.

Checked against the recorded incident (run `r000002`, `mod-player`, feature
`001`): checkpoint `phase: :implement`, `last_completed_phase: :analyze`
(step 5); trail `:tasks` (step 4). `5 > 4` ⇒ ahead ⇒ checkpoint wins ⇒
resume at `:implement`. Correct.

Checked against a gate divert: `checkpoint_for({:escalated, _}, :clarify, st)`
writes `phase: :clarify, last_completed_phase: :clarify` and no boundary
commit is written for a divert, so the trail sits at `:specify` (step 1) and
`2 > 1` ⇒ ahead ⇒ resume at `:clarify` — identical to what `resume/2` does
today.

**Alternatives considered**: a monotonic sequence number on the checkpoint
row. Rejected — it is a schema change that buys nothing the existing phase
ordering does not already give, and it would not be readable from the
pre-existing records FR-014 protects.

---

## R3 — FR-010, "a checkpoint naming the final phase"

**Decision (flagged — this is a deliberate reading of FR-010, not a literal
one)**: FR-010 is implemented against `checkpoint.last_completed_phase ==
:converge`, not against `checkpoint.phase == :converge`.

**Rationale**: `checkpoint.phase` names the *next* phase. A checkpoint with
`phase: :converge` means implement finished and **converge has not run** —
the ordinary, healthy mid-run shape. Today `Reconcile` resumes exactly that
feature at `:converge` (`:implement` is in `@resumable_boundaries`, and
`phase_after(:implement) == :converge`). Treating it as a completion signal
would classify an unconverged feature `:done`, skip the converge phase, and
regress FR-014/SC-004 on every run interrupted between implement and
converge.

The spec's own edge-case wording — "treated the same as today's final-phase
boundary" — points at the trail's `checkpoint after converge` marker, whose
checkpoint-vocabulary analogue is `last_completed_phase: :converge`. That
value is unreachable through the writer (`checkpoint_for({:done, :done}, …)`
returns `nil` and `Store.Writer.record_feature_terminal/4` deletes the row),
so the clause is defensive: present, tested, and never taken by a record this
system wrote.

**Consequence if the literal reading was intended instead**: a one-line
change to the clause, plus deleting the FR-014 regression case for
`phase: :converge`. Called out here so a reviewer can overrule it cheaply.

**Alternatives considered**: asking before planning. Rejected — the literal
reading is a provable regression against FR-014, which is in the same spec,
so the conservative reading is the one that satisfies the whole document.

---

## R4 — FR-007 and the implement progress position (spec assumption is wrong)

**Decision**: The write side of `checkpoint.implement_chunk` is **in scope**.
The spec's Assumption — "The checkpoint already records the implementation
progress position; this feature reads it, it does not introduce it" — does
not hold against the shipped code.

**Finding**: `implement_chunk` exists end-to-end on the *read* side —

- `Store.Schema`/`Store.Records.Checkpoint` carry the field
  (`store/schema.ex:142`, `store/records.ex:215`);
- `Store.Writer.write_checkpoint/3` persists `Map.get(checkpoint, :implement_chunk)`
  (`store/writer.ex:850`);
- `ChunkRunner.ref_from_record/1` and `start_sessions_used/2` read it
  (`chunk_runner.ex:117,132`);
- `ConsoleHydration.checkpoint_chunk/1` renders it (`console_hydration.ex:153`);

— but **nothing ever writes a non-`nil` value**. The only checkpoint
producer is `FeatureRunner.checkpoint_for/3` (`feature_runner.ex:418-443`),
whose three clauses build the map literally and never include the key;
`ChunkRunner.record_chunk_attempt/6` passes `attempt` and `transcript` only.
Every `implement_chunk` in the test suite is `nil`. The contract that
specified the write —
`specs/015-implement-phase-chunking/contracts/checkpoint-implement-chunk.md` §2
— was written against the pre-018 file checkpoint (`Checkpoint.write/1`,
since replaced by the store) and the write did not survive that migration.

**Rationale for including it**: FR-007 and SC-006 are unsatisfiable without
it. With `implement_chunk` always `nil`, every implement resume takes
`TaskPlan.locate(plan, nil)`'s `:fallback` branch, and FR-007 degrades into
FR-007a for all records.

**Decision on placement**: write it from `ChunkRunner.record_chunk_attempt/6`,
by adding a `checkpoint:` key to the payload it already hands
`Store.Writer.record_phase_attempt/2` — that function already persists
`Map.get(payload, :checkpoint)` in the same transaction
(`store/writer.ex:207`), and `maybe_commit_boundary/4` already runs
immediately before it (`chunk_runner.ex:220-221`), which is exactly 015 §2's
"write after the boundary commit, never before" ordering.

**Read side needs no change**: `dispatch_resume/7` → `run_from_checkpoint/8`
does not set `:start_task_phase` or `:reset_implement_sessions`, so
`ChunkRunner.run/1` re-reads the checkpoint itself via
`Store.checkpoint(run_key, feature.id)` and resolves the position through
`TaskPlan.locate/2`. FR-007a (no recorded position ⇒ start at the beginning,
no discrepancy) and the "position past the end of a regenerated task list"
edge case are both already handled there —
`locate/2` returns `{:ok, fallback, :fallback}` for a `nil` ref and for an
out-of-range ordinal, and `report_resolution/4` already logs and emits
`[:speckit, :chunk, :resolved]` for every non-`:number` match.

**Alternatives considered**: threading the position up through
`FeatureRunner.checkpoint_for/3` at the `:implement` roll-up only. Rejected —
the roll-up runs once, when the phase *finishes*, which is precisely the
moment a crashed run never reaches.

---

## R5 — Carrying the checkpoint/trail phases into the operator report

**Decision**: widen `Reconcile`'s conflict reason from a bare atom to
`atom() | {atom(), map()}` and render it through a new
`Recovery.Report.reason_label/1`.

FR-005 requires the report to name "the feature, the checkpoint's phase, and
the trail's phase". `Report`'s existing `conflict_row` is
`%{id: String.t(), reason: atom()}` and the note is built by string
interpolation (`"CONFLICT — #{reason}; human resolve"`,
`recovery/report.ex:97`), which would crash on a tuple.

**Rationale**: this is the smallest change that keeps one surface. The
downstream consumers already pass the reason through opaquely —
`Recovery.persisted_status({:conflict, _reason})` matches on the wildcard and
`Rebuild`'s `for %{kind: :unreconcilable, id: id, detail: reason}`
comprehension copies it — so only the two rendering sites in `Report` need to
learn the new shape.

**Alternatives considered**:
- *A third field on `conflict_row`*. Rejected — `Reconcile.result/0` is the
  value that travels; a field only `Recovery` populates would let the two
  callers of `Reconcile.status/3` diverge, against FR-012.
- *A new console view*. Rejected — the spec's Assumptions say no new
  operator surface is introduced, and Principle VII's "one entity, one detail
  view" is already satisfied by the existing `CONFLICT` row.

---

## R6 — Blocking a feature, and what "blocked" already does

**Decision**: reuse the existing `{:conflict, _}` → `:blocked` path
unchanged. No new status, no `Release`/`Coordinator` change.

`Recovery.persisted_status({:conflict, _})` already returns `{:blocked, nil}`
(`recovery.ex`), and `:blocked`:

- is **not** in `Feature.@terminal_statuses`, so it never becomes a
  `{:stopped, id, status}` in `Release.next/3`;
- is **not** `:pending`, so `Release.next/3` never releases it — it falls to
  the `true -> :none` clause;
- carries no `resume_phase`, so `dispatch_statuses/2` never flips it back to
  `:pending`.

A blocked feature therefore runs nothing and spends nothing, which is exactly
FR-005/SC-005, and it is already how `{:conflict, :pr_without_branch}` and
`{:conflict, :ambiguous_evidence}` behave today.

**Rationale**: the clarification session chose "consistent with every
existing store-vs-evidence conflict" — this is that mechanism, not a parallel
one.

**Note on FR-009a**: a feature with a checkpoint and no committed branch is
*already* blocked today — `no_artifacts?/1` excludes it (it tests
`is_nil(evidence.checkpoint)`), so it falls through to clause 7's
`{:conflict, :ambiguous_evidence}`. FR-009a is therefore a **reason-naming**
change, not a behaviour change: `:checkpoint_without_branch` instead of
`:ambiguous_evidence`. FR-009 (neither checkpoint nor artifact ⇒
never-started) needs no change at all.

---

## R7 — Best practice for the regression guard FR-014/SC-004 demands

**Decision**: assert byte-identical reconciliation over the existing
`test/speckit_orchestrator/recovery/reconcile_test.exs` corpus by running
every existing case a second time with `checkpoint: nil` *and* with the
checkpoint the writer would have produced at that same boundary, and
asserting both give today's answer.

**Rationale**: FR-014's claim is about *existing records*, which come in
exactly two shapes — pre-checkpoint (nil) and checkpoint-in-agreement. Both
must land on today's phase. Generating the agreeing checkpoint from the
boundary phase (rather than hand-writing it per case) is what makes the guard
mechanical rather than a transcription of the fix.

**Alternatives considered**: golden-file snapshots of `Report.format/1`.
Rejected — they would also freeze the rendering change R5 makes, coupling an
FR-014 regression guard to an FR-005 feature.
