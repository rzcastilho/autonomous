# Feature Specification: Crash Recovery

**Feature Branch**: `009-crash-recovery`

**Created**: 2026-07-21

**Status**: Draft

**Input**: User description: "009 crash recovery"

## Overview

Today a `speckit_orchestrator` run lives entirely in memory: the `Coordinator`
holds each feature's status and the wave position, the `Ledger` holds committed
spend, and one in-flight `claude` phase runs as a child process. If the BEAM node
crashes (or is killed) mid-run, all of that is lost — even though the durable
artifacts survive on disk: each feature's git worktree holds the work, and each
phase already writes a transcript. Recovery is only partial and manual: the
existing per-feature checkpoint (`checkpoint.json`) is written **only** when a
feature diverts at a gate (`:escalated` / `:halted` / `:failed`), so a feature that
was running cleanly when the node died leaves no resume pointer, and the worktree's
mid-run edits are uncommitted.

This feature makes a crashed run **resumable at the phase boundary**. It writes a
progress checkpoint and commits the worktree after every phase, so each phase
boundary is a clean, content-addressed restore point; it records a small run
manifest so the whole backlog can be reseeded and continued; and it exposes a
resume path that re-runs only the interrupted phase and then carries the run to
completion. It reuses the existing `resume/2` machinery (feature 007) rather than
building a second resume engine, and it introduces **no datastore** — git is the
artifact store and small JSON files are the pointers.

This is an orchestrator **core** capability. The Control Plane console (feature
008) will later *surface* it (detect a crashed run, offer a resume action); this
spec covers the recovery mechanics and the operator-facing resume entry points,
not the UI.

## Clarifications

### Session 2026-07-22

- Q: How are the per-phase checkpoint commits reconciled at feature completion
  (FR-004 / commit-noise edge case)? → A: **Squash** — all per-phase commits are
  squashed into a single feature commit at completion, so the final branch/PR shows
  one clean reviewable commit and no intermediate checkpoint commits.
- Q: Does the system track one run's manifest at a time, or can multiple crashed
  runs coexist on disk (FR-005 / FR-008 / FR-017)? → A: **Single manifest slot** —
  one run is tracked at a time; starting a new run supersedes/clears the prior
  manifest, so "is there a resumable run?" is an unambiguous single-slot check.

### Session 2026-07-21

- Q: What is the atomic unit of resume — can a run resume mid-phase? → A: The
  **phase boundary**. A resume re-runs the interrupted phase from scratch (speckit
  phases regenerate their own artifact, so re-running is safe); resuming *inside* a
  phase is out of scope because the phase's `claude` subprocess does not survive a
  crash.
- Q: Is recovery automatic on the next boot, or operator-initiated? → A:
  **Operator-initiated**. Because a resume re-runs a phase and therefore spends
  money, the system MUST NOT auto-restart a crashed run on boot; a human triggers
  the resume (Cost-Bounded Autonomy). The system MAY detect and report a resumable
  run, but starts nothing on its own.
- Q: Does this introduce a persistence datastore? → A: **No.** Recovery uses the
  existing git worktrees (artifacts) and per-phase transcripts (audit) plus small
  JSON pointer/manifest files. No SQLite or other datastore — this is crash
  recovery, not the run-history persistence deliberately excluded from feature 008
  (FR-036 there).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume a crashed feature from its last completed phase (Priority: P1)

The node crashed while a feature was mid-run. On restart, the operator resumes that
feature; it picks up at the phase after the last one that completed cleanly, having
discarded any partial output from the interrupted phase, and runs to a terminal
state — without re-doing the phases it had already finished.

**Why this priority**: This is the core of crash recovery and the MVP. A single
expensive feature that had completed five of seven phases must not restart from
zero after an unlucky crash. Everything else (whole-run resume, cost continuity)
builds on a feature being individually resumable from disk alone.

**Independent Test**: Run a feature partway (e.g. through `plan`), simulate a node
crash (kill the run mid-`tasks`), restart, and resume the feature. Confirm it
resumes at `tasks` (the interrupted phase), the earlier phases' artifacts are
untouched (not regenerated), and the feature reaches a terminal state.

**Acceptance Scenarios**:

1. **Given** a feature that completed phases `specify…plan` and then the node died
   during `tasks`, **When** the operator resumes the feature, **Then** it restarts
   at `tasks`, the `specify…plan` artifacts are preserved unchanged, and the
   feature continues through the remaining phases.
2. **Given** the interrupted phase wrote partial files into the worktree before the
   crash, **When** the feature is resumed, **Then** the worktree is first restored
   to its last clean phase-boundary state so the re-run of the interrupted phase
   starts from a consistent tree, with no leftover partial output.
3. **Given** a feature that had already diverted at a human gate (`:escalated` /
   `:halted`) before the crash, **When** recovery runs, **Then** the resume MUST
   NOT auto-run past that gate; the feature retains its divert and its existing
   human-resolution path (Constitution V) is unchanged.
4. **Given** a feature whose checkpoint exists but whose worktree/branch is missing
   or unusable, **When** the operator attempts a checkpoint resume, **Then** the
   system reports it cannot resume from the checkpoint and steers the operator to a
   full restart from the first phase.

---

### User Story 2 - Resume an entire crashed run (Priority: P2)

A whole backlog run was in progress — several features done, some running, some
still pending — when the node crashed. The operator resumes the **run**: the
orchestrator reconstructs which features were done, in flight, or not started, and
continues releasing dependency-and-cap waves for the remaining work, re-running any
interrupted feature from its last completed phase.

**Why this priority**: Recovering one feature is the MVP, but a real backlog run has
many features and a wave schedule. Without run-level resume the operator would have
to resume each feature by hand and rebuild the wave order. This makes an unattended
multi-feature run robust to a crash.

**Independent Test**: Start a multi-feature backlog run, let a few features finish
and one be mid-flight, simulate a crash, restart, and resume the run. Confirm the
completed features are not re-run, the interrupted feature resumes at its phase,
and pending features release in the correct dependency order to completion.

**Acceptance Scenarios**:

1. **Given** a crashed run with features in mixed states (done / running / pending),
   **When** the operator resumes the run, **Then** the run continues from a
   reconstructed state: already-done features are not re-run, interrupted features
   resume at their last completed phase, and pending features release in dependency
   order under the original concurrency cap.
2. **Given** the crashed run recorded its run-shaping context (concurrency, budget,
   PR mode, PR base/remote, plan stack), **When** it is resumed, **Then** it
   re-executes under that same recorded context rather than defaults.
3. **Given** no resumable run exists (a clean prior completion, or no prior run),
   **When** the operator asks to resume a run, **Then** the system reports there is
   nothing to resume and starts no work.
4. **Given** a resumable run recorded on disk **and** a different run already active
   in the node, **When** a resume is requested, **Then** the system MUST NOT clobber
   the active run; it requires an explicit, unambiguous operator action to proceed.

---

### User Story 3 - Preserve cost accounting across a crash (Priority: P3)

The cost circuit breaker's committed spend is in memory and is lost on a crash. When
a run resumes, its budget guard must account for what was already spent so the
resumed run cannot quietly exceed the original budget by starting the tally from
zero.

**Why this priority**: Cost-bounded autonomy is a core principle. Resume re-runs
phases, which costs money; if the breaker resets to zero on resume, a crash becomes
a way to silently double the budget. This closes that gap, but the run is still
usable (if less precise) without it, so it ranks below getting resume working.

**Independent Test**: Run until a known committed spend, simulate a crash, resume,
and confirm the breaker's committed spend resumes from (at least) the recorded
pre-crash value rather than zero, and that the resumed run still honors the budget.

**Acceptance Scenarios**:

1. **Given** a run that had committed a known spend before the crash, **When** it is
   resumed, **Then** the breaker's committed spend is restored from the recorded
   value (not reset to zero) so the budget continues to bound the whole run.
2. **Given** a resumed run whose restored spend is already at or above budget,
   **When** the resume starts, **Then** the breaker is treated as tripped and no new
   work is released (drain, don't kill) — consistent with the live-run breaker.

---

### Edge Cases

- **Crash mid-phase (partial artifacts)**: the interrupted phase may have written
  partial files. Resume MUST restore the worktree to the last clean phase-boundary
  commit before re-running that phase, so no partial output leaks into the re-run.
- **Crash before the first commit**: if the node dies during the very first phase
  (`specify`), before any phase-boundary commit exists, there is no clean restore
  point for that feature; recovery MUST treat it as a restart of the feature from
  the first phase rather than a resume.
- **Missing / corrupt checkpoint or manifest**: recovery MUST fail loudly and steer
  the operator to a full restart rather than resuming from an untrustworthy pointer
  (never fabricate state).
- **Idempotent phase re-run**: re-running the interrupted phase MUST be safe when
  that phase had partially produced its artifact — the phase regenerates its output
  rather than appending to or corrupting a half-written one.
- **Already-terminal features**: a feature that reached `:done` before the crash MUST
  NOT be re-run on resume; a feature that reached a gate divert MUST retain it (see
  US1 scenario 3).
- **Commit noise**: per-phase commits accumulate on the feature branch; the recovery
  design MUST NOT let intermediate phase commits corrupt the final branch/PR outcome
  — they are squashed into a single feature commit at feature completion.
- **Stale manifest vs a fresh run**: a leftover manifest from a completed or
  abandoned run MUST NOT be silently resumed over a new run (see US2 scenario 4).

## Requirements *(mandatory)*

### Functional Requirements

**Progress checkpointing & restore points**

- **FR-001**: The system MUST write a durable progress checkpoint for a feature
  after each phase completes — recording the last completed phase, the feature's
  identity (slug/path), and the run-shaping context — not only when the feature
  diverts at a gate.
- **FR-002**: The progress checkpoint MUST be sufficient, together with the
  feature's on-disk worktree, to resume the feature at the next phase using the
  existing resume machinery, with no in-memory run state.
- **FR-003**: The system MUST commit the feature's worktree at each phase boundary so
  that every completed phase is a clean, restorable state; a resume MUST restore the
  worktree to the last such commit before re-running the interrupted phase.
- **FR-004**: Per-phase commits MUST be squashed into a single feature commit at
  feature completion so the final branch (and any PR opened under the PR workflow)
  reflects the feature's completed work as one clean reviewable commit, with no
  intermediate checkpoint commits remaining in the branch history.

**Run manifest & run-level resume**

- **FR-005**: The system MUST record a durable run manifest capturing the run's
  feature set, each feature's last-known lifecycle status, and the run-shaping
  context, updated as features change state, so a run can be reconstructed after a
  crash. The system tracks a single active manifest at a time (one run tracked
  concurrently); starting a new run supersedes/clears the prior manifest.
- **FR-006**: The operator MUST be able to resume a crashed run from the manifest and
  per-feature checkpoints alone: already-`:done` features are not re-run, interrupted
  features resume at their last completed phase, and pending features release in
  dependency order under the recorded concurrency cap.
- **FR-007**: A resumed run MUST re-execute under the run-shaping context recorded at
  the original run's start (concurrency, budget, PR workflow, PR base/remote, plan
  stack), consistent with the existing resume-context reapply behavior.
- **FR-008**: The system MUST detect and report whether a resumable run exists (the
  single active manifest holding unfinished work) without starting any work on its
  own.

**Feature resume**

- **FR-009**: The operator MUST be able to resume a single crashed feature from its
  last completed phase, independently of a full-run resume.
- **FR-010**: A resume MUST re-run the interrupted phase from a clean worktree state
  and continue through the remaining phases to a terminal state.
- **FR-011**: The system MUST NOT resume *within* a phase; the phase is the atomic
  unit of resume (the interrupted phase is re-run in full).

**Cost continuity**

- **FR-012**: The system MUST record committed spend durably enough that a resumed
  run restores the breaker's committed spend from the recorded value rather than
  resetting it to zero.
- **FR-013**: A resumed run MUST continue to honor the original budget: if restored
  spend is at or above budget the breaker is treated as tripped and releases no new
  work (drain, don't kill); the breaker invariant (committed below budget plus one
  outstanding reservation) MUST continue to hold.

**Safety & failure handling**

- **FR-014**: Recovery MUST be operator-initiated; the system MUST NOT automatically
  resume or restart a crashed run on boot (it MAY report that one is resumable).
- **FR-015**: A resume MUST NOT carry a feature past a human gate: a feature that was
  `:escalated` or `:halted` before the crash retains that state and its human
  resolution path; recovery does not auto-pass a gate.
- **FR-016**: On a missing or corrupt checkpoint or manifest, or a missing/unusable
  worktree for a checkpointed feature, the system MUST fail loudly and steer the
  operator to a full restart rather than resuming from untrustworthy state.
- **FR-017**: Recovery MUST NOT silently resume a stale manifest over a different run
  already active in the node; proceeding requires an explicit operator action.
- **FR-018**: Recovery MUST introduce no persistence datastore; it MUST rely on the
  existing git worktrees, per-phase transcripts, and small JSON pointer/manifest
  files.

### Key Entities *(include if feature involves data)*

- **Progress checkpoint**: the per-feature resume pointer, extended to be written
  after every phase (status may be a non-terminal "in progress" as well as the
  existing terminal divert states) — last completed phase, feature identity, divert
  reason (if any), and recorded run context.
- **Phase-boundary commit**: a git commit of the feature's worktree made after each
  phase completes, serving as the clean restore point for that phase boundary.
- **Run manifest**: the durable record of a run — its feature set, per-feature
  last-known status, and run-shaping context — used to reconstruct and continue a
  crashed run. A single active manifest is tracked at a time; starting a new run
  supersedes the prior one.
- **Recorded spend**: the durable committed-spend figure used to restore the cost
  breaker on resume.
- **Resume operation**: an operator-initiated action that reconstructs a feature (or
  a whole run) from the artifacts above and continues it to completion.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a crash simulated at any phase boundary of a multi-feature run,
  the operator can resume and the run reaches the same terminal outcome it would
  have reached without the crash, re-running only the interrupted phase(s).
- **SC-002**: On resume, no already-completed phase's artifact is regenerated —
  100% of phases completed before the crash are preserved (only the interrupted
  phase re-runs).
- **SC-003**: A resumed run's total spend stays within the original budget plus at
  most one outstanding reservation — a crash-and-resume cannot exceed the budget the
  run was started with.
- **SC-004**: 100% of features that had reached a human gate (`:escalated` /
  `:halted`) before a crash retain that state after recovery — recovery never
  auto-passes a gate.
- **SC-005**: A crashed run is resumable from on-disk state alone (checkpoints +
  worktrees + manifest) with no reliance on any in-memory state that the crash
  destroyed — verified by resuming in a freshly started node.
- **SC-006**: The system never auto-starts work on boot; a resumable run is reported
  but nothing runs until the operator initiates it.
- **SC-007**: Recovery adds no datastore — verified by the absence of any database
  dependency; all recovery state is git commits and JSON files.

## Assumptions

- **Same single trusted operator and existing facade**: recovery is driven through
  the orchestrator's operator surface (the `iex` facade plus, later, the feature-008
  console), for one trusted local operator; no new access model is introduced.
- **Reuses the existing resume machinery**: this feature extends feature 007's
  `resume/2` (checkpoint read, identity recovery, run-context reapply, branch reuse)
  and the existing `Checkpoint`, `Worktree`, `Transcripts`, and `RunContext`
  components rather than building a parallel resume engine.
- **Phase is the atomic recovery unit**: mid-phase resume is out of scope because the
  interrupted phase's `claude` subprocess does not survive a crash; the interrupted
  phase is re-run in full, which is safe because speckit phases regenerate their
  artifacts.
- **Operator-initiated recovery**: the system does not auto-resume on boot; a human
  triggers recovery, consistent with cost-bounded autonomy (a resume spends money).
- **No datastore; git + JSON only**: git worktrees are the artifact store, per-phase
  transcripts are the audit trail, and small JSON files are the checkpoints and run
  manifest. This is crash recovery, distinct from the run-history persistence
  deliberately excluded from feature 008.
- **Console integration is feature 008's responsibility**: this spec delivers the
  core recovery mechanics and operator entry points; surfacing "resume a crashed
  run" in the web console is done in the Control Plane feature, not here.
- **Cost continuity is best-effort granular**: recorded spend is captured at phase
  boundaries (alongside checkpoints), so at most the interrupted phase's spend may be
  re-incurred on resume; this is acceptable and still bounded by the budget.

## Dependencies

- The existing orchestrator control plane and its resume path: `Coordinator`,
  `Ledger`, `Release`/`Backlog`, `Worktree`, `FeatureRunner`, `Transcripts`,
  `Checkpoint`, `RunContext`, and the facade's `resume/2` / `resolve/2` / `run/1`.
- The per-phase telemetry already emitted (`[:speckit, :phase, …]`,
  `[:speckit, :feature, :terminal]`), useful for updating the manifest as state
  changes.
- Read/write access to the on-disk transcript root (where per-feature checkpoints
  and the run manifest live) and to each feature's git worktree/branch.
