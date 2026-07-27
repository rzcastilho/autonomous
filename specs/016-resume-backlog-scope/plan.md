# Implementation Plan: Resume Preserves Backlog Scope

**Branch**: `016-resume-backlog-scope` | **Date**: 2026-07-26 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/016-resume-backlog-scope/spec.md`

## Summary

`SpeckitOrchestrator.resume/2` today builds a **one-feature run**
(`Keyword.put(:features, [feature])`) and hands it to `run/1`, which begins with
`RunManifest.clear/0`. The Coordinator — the manifest's single writer — then
records that one feature as the whole run, destroying the record of every other
feature in the backlog. Observed live against `../quickpoll`: resuming `001`
completed it, reported "Done: 1", and erased `002`/`003`.

Three changes, in priority order:

1. **Resume continues the whole run** (US1). `resume/2` restores the recorded
   feature set, reconciles every restored feature against durable evidence with
   feature 014's existing whole-run reconciliation, seeds the Coordinator with
   the reconciled statuses, and applies the operator's overrides to the **named
   feature only**. `resume/2` and `resume_run/1` converge on one private
   continuation path parameterized by an optional resume target.
2. **The record cannot silently narrow** (US2). `RunManifest.write/1` reads the
   record it is about to replace and refuses any write dropping a
   currently-recorded feature id — identity-based, so a swap is refused too. The
   refusal is a run-level telemetry event folded by the default logger and the
   console feed. `run/1` gains `:supersede` (default `true`) so a deliberately
   fresh run still supersedes via `clear/0`, while resume paths write into the
   guarded chain.
3. **Damaged records are repairable** (US3). A new `Recovery.Rebuild` computes a
   rebuild proposal from the surviving record ∪ the backlog on disk ∪ per-feature
   evidence; `SpeckitOrchestrator.recover_record/1` previews it by default and
   writes only on `confirm: true`.

Approach per [research.md](./research.md) (D1–D10). No new dependency, no new
process, no datastore; the pure/edge split and the existing Coordinator seams
carry all three changes.

## Technical Context

**Language/Version**: Elixir `~> 1.20` on OTP 28, pinned `1.20.2-otp-28` via
`.tool-versions`; every command through `mise exec --`.

**Primary Dependencies**: OTP (`Coordinator`, `Ledger`, `Task.Supervisor`);
`:telemetry` (already a transitive dep, already the console's event bus);
Phoenix LiveView (operator surface, read-only changes); `git` via the existing
`Recovery.Evidence` seam. **No new dependency.**

**Storage**: Files only — the single-slot run manifest (`run.json`), per-feature
`checkpoint.json` / `pr.json` / transcripts under the 012 `Layout` roots, and
git branches/commits. No datastore (constitution, Technology Stack).

**Testing**: ExUnit via `mise exec -- mix test`. Pure/hermetic tests for
`Recovery.Rebuild`, the `write/1` guard, and the `ConsoleReadModel` fold;
seam-level tests (Coordinator `:runner`/`:manifest`) for resume dispatch;
one opt-in `--include integration` end-to-end regression (SC-003) modelled on
`recovery_quickpoll_test.exs`.

**Target Platform**: Local operator machine / BEAM control plane driving the
`claude` CLI against a target git repo.

**Project Type**: Single Elixir project (control plane + data plane in one app).

**Performance Goals**: Not latency-bound. The guard adds one small JSON read per
manifest write (a few per phase, against phase runtimes measured in minutes).
Reconciliation on resume is O(features) local reads + one `git log` per branch —
feature 014's existing cost, now also paid by `resume/2`.

**Constraints**: **Never fatal** — a refused or failed manifest write must not
abort a live run (FR-014); `write/1` keeps its `:: :ok` contract.
**Behaviour-preserving** — once a resume is permitted to start, a single-feature
run and a no-manifest run must dispatch exactly what they dispatch today
(SC-005). **No durable effect on preview** — US3's default path writes nothing
(FR-019a). **Offline-first** — inherited from 014's evidence collector.

**Scale/Scope**: One repo slot, one run at a time; a wave is the
LedgerLite/quickpoll 7-feature scale. Two run shapes (breakdown wave, ad-hoc
single spec) both covered.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution v1.1.0 (principles I–VI + Technology Stack).

| Principle | Assessment |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | ✅ The new decision surfaces are pure: `Recovery.Rebuild.propose/3` takes an already-read record plus an already-loaded backlog and returns a proposal; the narrowing comparison is a pure set difference over ids; the console fold stays in the pure `ConsoleReadModel`. All I/O (manifest read/write, backlog load, evidence) sits at the edges behind existing seams (`:manifest`, `:runner`, `:git`, `:remote`). |
| **II. Fail Loud at Boundaries** | ✅ This feature *is* a fail-loud fix: a write that would lose recorded work is refused and announced instead of applied. Recovery reports what it cannot reconcile rather than inventing a state (FR-017/018), and refuses to write an inconsistent proposal (FR-020). `Backlog.load!`'s raises are caught at the `recover_record/1` boundary and returned as tagged errors rather than crashing an operator session. |
| **III. Least-Privilege Containment** | ✅ No new tool grants, no out-of-tree writes, no change to the target pack or per-phase permissions. The only new write is the operator-confirmed record rebuild, through the existing `RunManifest.write/1`. |
| **IV. Cost-Bounded Autonomy** | ✅ A resumed run restores the recorded spend (`Ledger.restore/2`) and stays under the original budget; the breaker keeps drain-don't-kill semantics — a resume that would release dependents releases none while tripped (spec edge case, SC-007). Preview spends nothing and runs no phase. |
| **V. Human-in-the-Loop Escalation** | ✅ Non-target diverted features stay diverted and are never re-dispatched (FR-006); conflicts stay held gate-like; the target's resume is an explicit human act whose stated phase outranks the automated verdict (D2). Recovery is operator-invoked and preview-first (FR-019/019a). |
| **VI. Idiomatic Elixir/OTP & FP** | ✅ Multi-clause pattern matching for the fold and the rebuild table; tagged tuples from `propose/3` and `recover_record/1`; `with` for the resume pipeline; no new process — the Coordinator's existing `:runner` seam carries the target/non-target split as a function. `@spec` on every new public function; `mix format`; warnings-as-errors. |

**Technology Stack**: No new runtime dependency, no frontend build step, no
database. Console changes are additive folds over the existing telemetry bus and
LiveView copy; the file-backed run state remains authoritative.

**Result: PASS** — no violations. Complexity Tracking below is empty.

**Post-Phase-1 re-check**: The Phase 1 design adds one pure module
(`Recovery.Rebuild`), one telemetry event, one facade verb, and one option
(`:supersede`) — no datastore, no process, no external contract. Splitting
`Recovery.reconcile_run/2` into `plan_run/2` + rewrite *increases* purity by
lifting the only write out of the decision path. Constitution Check still
**PASS**.

## Project Structure

### Documentation (this feature)

```text
specs/016-resume-backlog-scope/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — 10 decisions (D1–D10)
├── data-model.md        # Phase 1 output — 7 entities + resume lifecycle
├── quickstart.md        # Phase 1 output — validation scenarios S1–S7
├── contracts/           # Phase 1 output
│   ├── resume-scope.md      # resume/2 as whole-run continuation
│   ├── manifest-guard.md    # write/1 refusal rule + refusal event
│   └── record-recovery.md   # recover_record/1 + Recovery.Rebuild
├── checklists/
│   └── requirements.md  # already present
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── speckit_orchestrator.ex     # CHANGED — resume/2 restores the recorded set (US1);
│                               #   shared private continue_run/2 with resume_run/1;
│                               #   run/1 gains :supersede; resume/2 gains :force;
│                               #   NEW recover_record/1 (US3 preview/confirm)
├── run_manifest.ex             # CHANGED — write/1 anti-narrowing guard + refusal event (US2)
├── recovery.ex                 # CHANGED — split plan_run/2 (no write) from reconcile_run/2
├── recovery/
│   ├── rebuild.ex              # NEW — pure: record ∪ backlog ∪ evidence → proposal + discrepancies
│   ├── evidence.ex             # reused as-is (collector + :git/:remote seams)
│   ├── reconcile.ex            # reused as-is (pure decision table)
│   └── report.ex               # CHANGED (small) — render discrepancy rows
├── telemetry.ex                # CHANGED — [:speckit, :run, :scope_narrowing_refused] + logger clause
├── console_read_model.ex       # CHANGED — fold the refusal into a run-level :warn feed entry
├── console_projection.ex       # CHANGED — broadcast_diff clause for the run-level event
├── coordinator.ex              # reused — :features/:statuses/:runner/:manifest seams unchanged
├── backlog.ex                  # reused — load!/1 is US3's backlog source
└── web/live/
    ├── escalations_live.ex     # CHANGED — copy: resume continues the whole run (FR-021);
    │                           #   render the {:active_run, pid} refusal (FR-010a)
    └── mission_control_live.ex # CHANGED (small) — every restored feature listed after a resume (FR-022)

test/speckit_orchestrator/
├── resume_scope_test.exs           # NEW — US1 at the seam level (S1, S2)
├── run_manifest_test.exs           # CHANGED — guard decision table + refusal event (S3)
├── telemetry_test.exs              # CHANGED — logger clause for the refusal (S4)
├── console_read_model_test.exs     # CHANGED — refusal fold (S4)
├── recovery/rebuild_test.exs       # NEW — pure union + discrepancy table (S5)
├── record_recovery_test.exs        # NEW — preview writes nothing; confirm writes; refusals (S5)
├── resume_test.exs                 # CHANGED — SC-005 no-regression + :force guard
├── resume_run_test.exs             # CHANGED — unchanged behaviour through the shared path
├── recovery_test.exs               # CHANGED — plan_run/2 vs reconcile_run/2 split
├── resume_backlog_e2e_test.exs     # NEW — SC-003 regression, @tag :integration (S6)
└── web/escalations_live_test.exs   # CHANGED — copy + refusal rendering (S7)
```

**Structure Decision**: Single Elixir project (Option 1), matching the existing
`lib/speckit_orchestrator/` layout. The one new module lands in the existing
`recovery/` submodule beside `Reconcile`/`Evidence`, keeping the pure-core/edge
split. No new supervision-tree child, no new public module namespace: the fix is
a convergence of two existing paths plus a guard at the writer they share.

### Sequencing

US1 (P1) is independently deliverable and closes the observed defect on its own.
US2 (P2) depends on `run/1`'s `:supersede` option landing with US1 but is
otherwise independent. US3 (P3) depends on the `Recovery.plan_run/2` split only.
Recommended order: US1 → US2 → US3, each shippable alone.

## Complexity Tracking

> No Constitution Check violations — no entries required.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| _(none)_  | —          | —                                    |
