# Implementation Plan: Crash Recovery

**Branch**: `009-crash-recovery` | **Date**: 2026-07-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-crash-recovery/spec.md`

## Summary

Make a crashed `speckit_orchestrator` run resumable at the phase boundary, using
only git commits and small JSON files — no datastore. Three additions, each
extending existing machinery rather than replacing it:

1. **Per-phase progress** — `FeatureRunner` writes a durable checkpoint and
   commits the worktree after *every* phase (not only on a gate divert), so each
   phase boundary is a clean, content-addressed restore point. Per-phase commits
   are **squashed** into one feature commit at completion.
2. **Run manifest** — a new `RunManifest` module persists a single-slot record of
   the run (feature set, per-feature last-known status, run-shaping context,
   recorded spend). The `Coordinator` updates it as features change state; a new
   run supersedes the prior manifest.
3. **Resume entry points** — the facade gains `resume_run/1` (reconstruct and
   continue a crashed run from disk) and `resumable_run/0` (detect/report without
   starting work), reusing feature 007's `resume/2` for the per-feature case and
   restoring the `Ledger`'s committed spend so the resumed run stays within the
   original budget.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned in `.tool-versions`; run via
`mise exec --`). `warnings_as_errors` is ON.

**Primary Dependencies**: Jido/OTP (control plane); `jido_harness` + `jido_claude`
(pinned to GitHub SHAs) for the data plane. `Jason` for JSON. `git` CLI for
worktrees/commits. No new dependency is introduced.

**Storage**: Git (feature branches/worktrees = the artifact store) plus small JSON
pointer files under `Config.transcript_root()` (default `<repo>/.speckit-transcripts`):
per-feature `checkpoint.json` (extended) and a new single-slot run manifest
`run.json`. **No datastore** (FR-018, SC-007).

**Testing**: ExUnit. Pure/wave/DAG/breaker logic through the existing injected
seams (`:runner`, `:manifest`) with no CLI or worktree. Real-git and real-harness
paths behind `--include integration` so the default suite stays hermetic.

**Target Platform**: BEAM node (local operator surface via `iex` facade).

**Project Type**: Single Elixir application (control plane + data-plane boundary).

**Performance Goals**: Not latency-bound. Correctness targets are the SCs:
100% of pre-crash-completed phases preserved (SC-002), resumed spend within
budget + one reservation (SC-003).

**Constraints**: Recovery MUST rely only on on-disk state that survives a BEAM
crash (git worktrees survive; per-phase transcripts already dual-write to the
durable transcript root). No in-memory run state may be required to resume
(SC-005). Operator-initiated only — never auto-start on boot (FR-014, SC-006).

**Scale/Scope**: One trusted local operator; a single active run tracked at a
time (single manifest slot). Backlogs are tens of features, not thousands.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Compliance |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | `RunManifest` is pure serialization over string-keyed maps (mirrors `Checkpoint`/`RunContext`); no CLI/harness/Jido dependency. `Pipeline`/`Release`/`Ledger` decision surfaces stay side-effect free — resume feeds them reconstructed state as data. Manifest IO is an injected `:manifest` seam on the `Coordinator`, so wave/DAG logic stays unit-testable without disk. |
| **II. Fail Loud at Boundaries** | A missing/corrupt checkpoint or manifest, or a missing/unusable worktree for a checkpointed feature, MUST fail loudly and steer the operator to a full restart — never resume from fabricated state (FR-016, edge cases). Reuses `Checkpoint.read/1`'s three-way `:no_checkpoint`/`:corrupt` distinction; `RunManifest.read/0` mirrors it. |
| **III. Least-Privilege Containment (Fail-Closed)** | No new execution surface. Recovery writes only git commits inside the feature worktree/branch and JSON under the transcript root; resume re-runs phases through the *same* contained runner/executor path (scope-guard hook + per-phase permissions unchanged). |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | Committed spend is recorded durably at phase boundaries; resume restores the `Ledger`'s committed from the recorded value, not zero (FR-012). A resumed run whose restored spend is at/above budget is treated as tripped and releases nothing (drain, not kill), preserving the invariant `committed < budget + max single reservation` (FR-013, SC-003). |
| **V. Human-in-the-Loop Escalation** | Resume MUST NOT carry a feature past a human gate: an `:escalated`/`:halted` feature retains its state and its `resolve/1` path (FR-015, SC-004). Recovery is operator-initiated because a resume spends money (FR-014). |

**Result**: PASS. No principle deviation → Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/009-crash-recovery/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — design decisions & alternatives
├── data-model.md        # Phase 1 output — entities & on-disk shapes
├── quickstart.md        # Phase 1 output — crash/resume validation guide
├── contracts/           # Phase 1 output — module contracts
│   ├── run_manifest.md
│   ├── checkpoint-progress.md
│   ├── worktree-squash-restore.md
│   ├── ledger-restore.md
│   └── resume_run.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── run_manifest.ex          # NEW — single-slot run.json write/read/clear/resumable?
├── checkpoint.ex            # EXTEND — per-phase in_progress write (last completed phase)
├── worktree.ex              # EXTEND — squash/3 (FR-004), restore/1 (FR-003)
├── feature_runner.ex        # EXTEND — per-phase checkpoint + phase-boundary commit;
│                            #          squash on :done; restore before resumed phase
├── coordinator.ex           # EXTEND — :statuses init opt (reconstructed);
│                            #          :manifest seam; write manifest on state change
├── ledger.ex                # EXTEND — restore/2 (set committed from recorded spend)
├── speckit_orchestrator.ex  # EXTEND — resume_run/1, resumable_run/0, manifest lifecycle
└── application.ex           # (unchanged — Ledger + RunnerSup already supervised)

test/speckit_orchestrator/
├── run_manifest_test.exs        # NEW — write/read/clear/corrupt/single-slot
├── checkpoint_test.exs          # EXTEND — per-phase in_progress record
├── worktree_test.exs            # EXTEND (integration) — squash & restore against real git
├── feature_runner_test.exs      # EXTEND — per-phase commit/checkpoint via fakes
├── coordinator_test.exs         # EXTEND — reconstructed statuses; manifest seam calls
├── ledger_test.exs              # EXTEND — restore/2 & tripped-on-restore
└── resume_run_test.exs          # NEW — facade resume_run/resumable_run + guards
```

**Structure Decision**: Single Elixir app, existing `lib/speckit_orchestrator/`
flat module layout. One new module (`RunManifest`) alongside the existing
`Checkpoint`/`RunContext` pointer modules; every other change extends an existing
module in place. No new supervision tree — the app-level `Ledger` and
`RunnerSup` already exist; the per-run `Coordinator` is started by the facade as
today.

## Complexity Tracking

> No Constitution Check violations — this section is intentionally empty.
