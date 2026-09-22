# Implementation Plan: Checkpoint-First Resume

**Branch**: `025-checkpoint-first-resume` | **Date**: 2026-09-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/025-checkpoint-first-resume/spec.md`

## Summary

A whole-run resume rewinds a feature interrupted mid-`implement` by at least
one completed phase, because it derives the resume position by scanning the
branch for `"speckit: <id> checkpoint after <phase>"` markers — which
`implement`'s per-chunk commits do not carry, and which `implement` itself
writes only once the whole phase finishes. The durable checkpoint held the
correct position all along; the single-feature resume already reads it.

**Technical approach**: promote the checkpoint to the primary position source
inside the one pure decision that both resume paths already share —
`Recovery.Reconcile.status/3`'s `:running`/`:pending` body. The checkpoint is
*already* carried in `%Evidence{}` and already consulted there (by
`no_artifacts?/1`); this feature adds a new clause that reads it for
*position*, ahead of the existing trail clause, which stays verbatim as the
no-checkpoint fallback. Because `Recovery.plan_run/2`,
`Recovery.Rebuild.propose/3` and the whole-run dispatcher's `from:` override
all descend from that one function, fixing it there satisfies FR-003 and
FR-012 structurally rather than by convention.

Three supporting changes: compare the two sources by *completed-through*
ordinal so the healthy agreement case is an exact tie (FR-004/FR-014); widen
the conflict reason to carry the two contradicting phases so the existing
report can name them (FR-005/FR-006); and **write** the
`checkpoint.implement_chunk` progress position, which the spec assumes exists
but which no producer has ever set — a 015 contract lost in the 018
file→store migration, and a hard prerequisite for FR-007/SC-006 (research R4).

## Technical Context

**Language/Version**: Elixir `1.20.2-otp-28` (pinned in `.tool-versions`; OTP 28
is system-provided). Every command runs through `mise exec --`.

**Primary Dependencies**: none added. Touches only first-party modules —
`Recovery.Reconcile`, `Recovery.Report`, `ChunkRunner`. `Jido`/`jido_harness`/
`jido_claude` and Phoenix LiveView are untouched.

**Storage**: Mnesia via `SpeckitOrchestrator.Store`. `speckit_checkpoint`'s
`implement_chunk` column already exists (`store/schema.ex:142`) — **no schema
change, no version bump**.

**Testing**: ExUnit. `mise exec -- mix test` (hermetic by default);
`--include integration` is not needed by this feature. `mix format` mandatory.

**Target Platform**: BEAM / OTP 28, macOS + Linux.

**Project Type**: single Elixir application — autonomous control plane plus a
hand-authored Phoenix LiveView operator console.

**Performance Goals**: not a perf feature. The added work is `O(1)` per
feature: two `Pipeline.step_of/1` lookups over a 7-element list, inside an
already-read evidence struct. No new I/O, no new store read.

**Constraints**: `warnings_as_errors` is ON. `Reconcile` must stay free of
git/file/CLI/process access (Principle I, FR-013). Pure-core coverage stays
>90%. Existing reconciliation behaviour must be byte-identical for records
that resume correctly today (FR-014/SC-004). Zero spend during preview
(FR-006/SC-003).

**Scale/Scope**: tens of features per run; one checkpoint row per feature run.
Estimated diff: ~120 lines of `lib`, ~450 lines of test.

## Constitution Check

*GATE: passes before Phase 0. Re-checked after Phase 1 — see §Post-Design below.*

Against constitution **4.0.0**:

| Principle | Assessment |
|---|---|
| **I. Pure Core, Isolated Contracts** | **PASS.** The whole decision lands in `Recovery.Reconcile`, which stays side-effect free: the checkpoint is gathered upstream by `Recovery.Evidence` and passed in via `%Evidence{}` — exactly FR-013, and exactly the principle's "gate signals are extracted upstream and passed in as arguments". No new argument is added to `status/3`. The one write (`implement_chunk`) sits at an existing edge (`ChunkRunner` → `Store.Writer`), not in the decision. |
| **II. Fail Loud at Boundaries** | **PASS.** An unrecognised checkpoint phase becomes `{:conflict, {:damaged_checkpoint, …}}` carrying the raw values — never `String.to_atom/1`-ed, never coerced to a neighbouring phase (FR-011). A checkpoint that contradicts the trail blocks its feature instead of being resolved silently (FR-005). No invented data: a checkpoint with nothing usable returns `:no_position` and the trail clause decides. |
| **III. Least-Privilege Containment** | **N/A — untouched.** No change to the target pack, the scope-guard hook, or per-phase permissions. |
| **IV. Cost-Bounded Autonomy** | **PASS, and this is the point of the feature.** SC-003: the defect's whole cost is re-running a completed phase. `resumable/1` previews through `plan_run/2`, which starts no `Coordinator` and makes no reservation (FR-006). A blocked feature is never released, so it spends nothing. `Ledger` and the drain-don't-kill path are untouched. |
| **V. Human-in-the-Loop Escalation** | **PASS.** Clauses 1–2 of `status/3` (`:escalated`/`:halted`/`:failed` passthrough) are byte-identical, so no checkpoint can advance a human gate (FR-008). The new contradiction does not pick a side: it reports and blocks, which is the principle's "MUST NOT fabricate resolution". The clarification session chose this explicitly. |
| **VI. Idiomatic Elixir/OTP** | **PASS.** Multi-clause functions with head destructuring for `resume_position/2`; the `status/3` body stays a flat `cond` matching the existing style; tagged tuples throughout; `@spec` on every new public function; `Pipeline.step_of/1` called only behind a `Pipeline.phase?/1` guard (it returns `nil + 1` otherwise). No process, no GenServer, no supervision change. |
| **VII. Operator Surfaces Tell the Truth** | **PASS.** No new surface — the discrepancy rides the existing `Recovery.Report` `CONFLICT` row, which already exists for `:pr_without_branch`. Labels are the real atoms an operator would type (`checkpoint_behind_trail`, `checkpoint: analyze`), never a friendlier synonym. No LiveView template, status color, or `console.css` token is touched, so `design_contract_test` is unaffected. "Show the receipt": the note names both contradicting phases, so the operator can go read the branch and the record. |
| **Quality & Test Discipline** | **PASS.** All commands via `mise exec --`; `warnings_as_errors` respected; the change is in the pure core, tested through the existing `:git`/`:remote`/`:executor`/`:writer` seams with no CLI or worktree; default suite stays hermetic. |
| **Development Workflow** | **PASS.** Spec-driven on branch `025-checkpoint-first-resume`; no in-place amendment of a shipped spec (the 015 write gap is closed *here*, under this feature's own FRs, not by editing 015's artifacts). |

**Gate result: PASS — no violations, nothing to justify in Complexity Tracking.**

Two judgment calls are recorded rather than waved through, because a reviewer
should be able to overrule either cheaply:

1. **FR-010 is read against `checkpoint.last_completed_phase == :converge`, not
   `checkpoint.phase == :converge`** (research R3). `checkpoint.phase` names
   the *next* phase, so `phase: :converge` means converge has **not** run —
   today's code resumes exactly that feature at `:converge`, and treating it as
   a completion signal would classify an unconverged feature `:done` and
   regress FR-014/SC-004 in the same spec. The literal reading is one line and
   one test case away if it was intended.
2. **The `implement_chunk` write is in scope**, contradicting the spec's
   Assumption that it is already recorded. It is not: the field is read,
   persisted and rendered, but no producer sets it, so every
   `implement_chunk` in the tree is `nil` (research R4). FR-007 and SC-006 are
   unsatisfiable without the write, and without it FR-007 silently degrades
   into FR-007a for every record.

## Project Structure

### Documentation (this feature)

```text
specs/025-checkpoint-first-resume/
├── spec.md                                        # input
├── plan.md                                        # this file
├── research.md                                    # Phase 0 — R1..R7
├── data-model.md                                  # Phase 1
├── contracts/
│   ├── reconcile-checkpoint-first.md              # the pure decision (FR-001..005, 009a..014)
│   ├── implement-chunk-checkpoint-write.md        # the durable write (FR-007, 007a)
│   └── report-discrepancy.md                      # the operator surface (FR-005, 006, 012)
├── quickstart.md                                  # Phase 1 — validation scenarios
└── tasks.md                                       # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

Single Elixir project. Files this feature changes, and nothing else:

```text
lib/speckit_orchestrator/
├── recovery/
│   ├── reconcile.ex        # CHANGED — checkpoint-first clause + resume_position/2 (the core)
│   └── report.ex           # CHANGED — reason_label/1 + two existing call sites
├── chunk_runner.ex         # CHANGED — chunk_checkpoint/4 on the existing attempt payload
├── recovery.ex             # UNCHANGED — persisted_status/1's {:conflict, _} wildcard already fits
├── recovery/evidence.ex    # UNCHANGED — already collects the checkpoint
├── recovery/rebuild.ex     # UNCHANGED — reuses Reconcile.status/3; reason travels opaquely
├── pipeline.ex             # UNCHANGED — step_of/1, phase?/1, phases/0 already public
├── release.ex              # UNCHANGED — :blocked already releases nothing
├── store/writer.ex         # UNCHANGED — record_phase_attempt/2 already writes payload[:checkpoint]
├── task_plan.ex            # UNCHANGED — locate/2 already handles nil + out-of-range
└── speckit_orchestrator.ex # UNCHANGED — resolve_start_phase/2's `:from` now carries the right phase

test/speckit_orchestrator/
├── recovery/reconcile_test.exs    # the decision table + the FR-014 byte-identical guard
├── recovery_test.exs              # plan_run/reconcile_run wiring, statuses, conflicts, no-write
├── recovery/rebuild_test.exs      # FR-012 — the rebuild preview agrees
├── resume_test.exs                # FR-003 single-feature side
├── resume_run_test.exs            # FR-001/003 whole-run side (the defect)
├── resume_crash_test.exs          # mid-implement crash shape
├── chunk_runner_test.exs          # FR-007/007a — the write, and the nil-record fallback
└── store/writer_test.exs          # implement_chunk round-trips through the transaction
```

**Structure Decision**: no new module, no new directory, no new dependency. The
feature is deliberately shaped as an extension of the 014 recovery pack
(`Recovery.{Evidence, Reconcile, Report, Rebuild}`) plus one write repair in
`ChunkRunner`, because `Reconcile.status/3` is already the single shared rule
FR-012 demands — introducing a parallel "resume position" module would create
exactly the second, divergent copy that requirement forbids.

## Complexity Tracking

> No Constitution Check violations. Table intentionally empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |

## Post-Design Constitution Re-Check

Re-evaluated after Phase 1 (`data-model.md`, the three contracts,
`quickstart.md`) — **still PASS**, with the design confirming rather than
straining each gate:

- **I / FR-013**: `reconcile-checkpoint-first.md` §1 fixes `status/3` at its
  current arity and puts the checkpoint read behind `%Evidence{}`. The design
  added no I/O anywhere in the decision path; the only new write is at an
  existing store edge.
- **II**: the contract enumerates every damaged/unusable shape and assigns each
  a named refusal or an explicit fall-through — no residual "otherwise" that
  guesses.
- **IV**: `report-discrepancy.md` §1 confirms `resumable/1` reaches the
  discrepancy through `plan_run/2`, which performs no write for a
  non-`:done` verdict — FR-006 needed no new code path, so the zero-spend
  guarantee is structural.
- **V**: `data-model.md` §6 shows clauses 1–3 untouched, so the human-gate
  passthrough is preserved by construction rather than by a test.
- **VI**: the one risky primitive (`Pipeline.step_of/1` on an unvalidated
  atom) is guarded in the contract, and `chunk_checkpoint/4` returns `nil`
  rather than a partial map so `write_checkpoint/3`'s existing `nil` clause
  keeps the row intact.
- **VII**: `report-discrepancy.md` §6 verifies by inspection that the console
  renders no conflict reason today, so no design-contract token, keyframe, or
  status color enters scope.

One design finding worth carrying into `/speckit-tasks`: because
`Store.Writer.write_checkpoint/3` writes **every** column from the map it is
handed, `chunk_checkpoint/4` must emit the whole checkpoint — including
`analyze_remediation`, carried from the row `ChunkRunner.run/1` already loaded
— or a mid-implement write would null fields `resume/2` reads back. Recorded in
`implement-chunk-checkpoint-write.md` §3.1.
