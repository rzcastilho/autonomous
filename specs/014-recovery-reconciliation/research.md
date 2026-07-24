# Phase 0 Research: Recovery State Reconciliation

**Feature**: 014-recovery-reconciliation | **Date**: 2026-07-24

The spec carries no open `NEEDS CLARIFICATION` markers — all eight ambiguities
were resolved in the spec's Clarifications (Session 2026-07-24). This document
records the *design* decisions that turn those resolved requirements into a
buildable plan on the existing 009/012 machinery. Each decision is grounded in
the codebase map of the current recovery path.

## Context: what exists today (the thing being fixed)

- **The blind reset.** `RunManifest.reconstruct_status/1`
  (`run_manifest.ex:202`) maps `"running" → :pending`; `resume_run/2`
  (`speckit_orchestrator.ex:427`) consumes it and seeds the Coordinator with
  those reconstructed statuses. No git, PR, transcript, or checkpoint evidence
  is consulted — a stale `running` for an already-finished feature becomes a
  full re-run. This is the exact defect FR-001…FR-006 target.
- **Durable evidence already on disk** (per `Layout`, feature 012), all under
  `<autonomous_root>/transcripts/<segment>/<feature-dir>/`:
  - `pr.json` — `%{"pr_title","pr_body"}`, written at `:done` teardown
    (`Describe.write_pr/3`; read via `Describe.read_pr/2`).
  - `checkpoint.json` — `last_phase` + `status` (`Checkpoint.read/2`).
  - `NN-<phase>.md` transcripts, converge success marker `## CONVERGE: READY`.
  - The feature's **git branch** `feature/NNN-slug` with per-phase boundary
    commits `"speckit: <id> checkpoint after <phase>"`
    (`FeatureRunner`, `worktree.ex`).
- **Injection seam.** `Coordinator.init/1` seeds `statuses` from the `:statuses`
  option (`coordinator.ex:109`); a done/diverted seed keeps a feature out of
  `Release.next_wave`. Reconciled statuses flow in through exactly this seam.

## Decision 1 — Repository-as-truth resolution table (FR-002, FR-003)

**Decision**: A pure decision function reconciles `recorded_status × evidence ×
run_shape → reconciled_status`. The repository always wins over the manifest.
For a non-terminal (`running`/`pending`) feature the done-signal is:

- **PR-workflow run**: `pr.json` present **AND** the feature branch exists with
  its work committed → `:done`.
- **non-PR-workflow run**: final-phase (`converge`) transcript success marker
  **AND** committed branch → `:done`.

**Rationale**: The spec names the PR record as the authoritative "done" signal
(Clarification Q4): PR push is the last lifecycle step, so its durable record
implies every prior phase succeeded. Keeping the decision a pure multi-clause
function (Principle I/VI) makes the whole table unit-testable with no git or CLI.

**Alternatives rejected**: (a) Trust the manifest and only patch `running` —
rejected: the spec requires reconciling *every* feature (US3). (b) Require a
live remote PR query as the done-signal — rejected: violates offline-first
(FR-018); the local record is primary.

## Decision 2 — Resume point from the latest committed git boundary (FR-005)

**Decision**: For a `running` feature with only intermediate progress, the
resume phase = the phase **after** the latest committed boundary commit on its
branch. Parse `git log` on `feature/NNN-slug` for the newest
`"speckit: <id> checkpoint after <phase>"` subject; resume at
`Pipeline` phase-after-that. Checkpoint and transcripts corroborate but never
override; manifest status alone is never used.

**Rationale**: A phase's work isn't complete until its boundary commit lands
(Clarification Q8). Anchoring to the committed boundary guarantees a clean
worktree and never skips a phase whose transcript was written but whose commit
never landed. Reuses 009's existing phase-boundary resume — no within-phase
resume is introduced.

**Alternatives rejected**: checkpoint's `last_phase` as authority — rejected:
the checkpoint can be newer than the last commit (written before the boundary
commit), which would skip an uncommitted phase. Git is the tie-breaker.

## Decision 3 — Corrupt/absent single-source tolerance (FR-011, edge cases)

**Decision**: Evidence collection reads each of the four sources independently;
any one absent or corrupt is treated as "no evidence from this source" and the
decision falls back to the remaining durable evidence. Only self-contradictory
evidence (Decision 5) or a missing/corrupt **manifest** surfaces loudly.

**Rationale**: FR-011 + the edge-case list. `Checkpoint.read`, `Describe.read_pr`,
and `RunManifest.read` already return three-way `{:ok|:error, :corrupt|:absent}`
results — the collector maps `:error` to "no evidence," never a crash. Fail-loud
(Principle II) is reserved for the manifest and for true conflicts, not for a
single truncated per-feature artifact.

## Decision 4 — Offline-first, remote as fallback only (FR-018)

**Decision**: Reconciliation runs from local state (`pr.json` + local git
branch) alone. A live `gh` remote query is attempted **only** when the local PR
record is absent/corrupt, and any remote failure/unreachability is mapped to "no
additional evidence" — never a recovery error. Remote query is an injected seam
(default: local-only / a no-op stub in tests) so the default suite stays
hermetic and offline.

**Rationale**: FR-018 + Clarification Q7. Recovery must work with GitHub down.
The seam keeps the network out of the pure decision and out of unit tests.

## Decision 5 — Conflict held like a human gate (FR-014)

**Decision**: When evidence is self-contradictory (e.g. manifest `done` but no
branch/PR; or PR record present but branch missing), the feature reconciles to a
**conflict** state, mapped onto the existing `Feature` `:blocked` status and
surfaced in the report. A conflict feature is not released and its dependents
stay blocked (unmet prereq), but independent features elsewhere in the DAG still
release — `Release.next_wave` already blocks only features whose prereqs aren't
`:done`, so one conflict never freezes the run.

**Rationale**: FR-014 + Clarification Q6 + Principle V (human-in-the-loop). Reuses
the existing `:blocked` lifecycle status and the existing DAG-release semantics —
no new release logic, only a new way to *enter* blocked.

**Alternatives rejected**: a brand-new `:conflict` status atom threaded through
Release/Coordinator/Report — rejected: `:blocked` already means "held, dependents
wait," which is exactly the required behavior; the report carries the reason.

## Decision 6 — Immediate manifest rewrite at reconcile time (FR-009)

**Decision**: Reconciliation rewrites the run manifest with corrected statuses
immediately, before the operator continues. The rewrite is status-only (features/
context/spend/segment/scope preserved), runs no phase, and spends no budget.

**Rationale**: FR-009. A subsequent restart then reads an already-correct picture
and never re-derives from stale data. `RunManifest.write/1` already persists the
whole record; reconciliation supplies corrected `statuses` and preserves the rest.
Status-only ⇒ FR-010 (read-only-w.r.t.-work) still holds.

## Decision 7 — Spend preservation (FR-013)

**Decision**: `resume_run` already restores committed spend via `Ledger.restore`
from the manifest's `"spend"`. Reconciliation preserves that field verbatim — a
`done`-reconciled feature's committed cost is neither dropped nor re-added, and
the restored budget bounds continuation.

**Rationale**: FR-013, SC-007. Spend is a run-level number in the manifest, not
per-feature; reconciliation touches only `statuses`, so the number is carried
through unchanged and `Ledger.restore` remains the single spend-restore path.

## Decision 8 — Module placement (Principle I/VI, no new deps)

**Decision**: Two new modules plus one changed call site — no new dependency, no
datastore (FR-016):

- **`Recovery.Reconcile`** (pure) — the resolution table + resume-phase rule +
  conflict rule as multi-clause functions over data. No I/O. >90% covered.
- **`Recovery.Evidence`** (I/O at the edge) — gathers a `%Evidence{}` per feature
  from `Describe.read_pr`, `Checkpoint.read`, `Transcripts`, and a git-log parse
  (via `Worktree`), behind an injected `:remote` seam for the offline fallback.
- **`Recovery`** (thin orchestration) — for a manifest record + layout: collect
  evidence per feature, run the pure table, rewrite the manifest, return the
  reconciled status map + report. `resume_run/2` calls this in place of the raw
  `RunManifest.reconstruct/1`.

**Rationale**: Mirrors the established pure-core/edge split (`Ledger`/`Release`/
`Pipeline` are pure; `Coordinator`/`FeatureRunner` do I/O). Keeps the fix inside
existing OTP idioms and existing persistence (git + JSON pointer files only).

**Alternatives rejected**: fold reconciliation into `RunManifest.reconstruct/1` —
rejected: that function is pure-string-mapping today and would gain git/CLI I/O,
breaking Principle I and its unit tests. Keep reconstruct as the dumb parser; add
reconciliation as a layer above it.
