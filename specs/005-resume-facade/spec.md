# Feature Specification: Resume Facade (`resume/2` operator entry point)

**Feature Branch**: `005-resume-facade`

**Created**: 2026-07-20

**Status**: Draft

**Input**: User description: "@docs/breakdown/004-resume-facade.md"

## Clarifications

### Session 2026-07-20

- Q: When the checkpoint file exists but is corrupt/unreadable, what should resume do? → A: Propagate a distinct corrupt-checkpoint error and start no run (do not collapse into the no-checkpoint result).
- Q: When the operator supplies an explicit starting-phase override that is not a real pipeline phase, what should resume do? → A: Reject with a distinct unknown-phase error and start no run (validate at the boundary).
- Q: When the feature's branch is gone so the worktree cannot be recreated from it, what should resume do? → A: Propagate a distinct worktree error and start no run (never silently start a fresh unrelated branch).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume a halted/escalated feature at its checkpointed phase (Priority: P1)

An operator has a feature that halted (analyze gate) or escalated (clarify gate).
They fix the root cause directly on the feature's branch — editing the spec,
plan, or code as needed — then tell the system to resume that feature. The
system restarts the feature's pipeline at the exact phase it left off on,
reusing the same branch and the operator's committed fix, instead of
re-running the pipeline from the beginning.

**Why this priority**: This is the core value of the feature — it is the
entire reason the facade exists. Without it, an operator's only recovery path
is a full restart from `specify`, discarding every phase already paid for and
risking the loss of the operator's own fix if a later phase overwrites it.

**Independent Test**: Can be fully tested by checkpointing a feature at a
known phase (via a fixture checkpoint), invoking the resume operation with a
fake runner, and confirming the runner is invoked starting at that phase.

**Acceptance Scenarios**:

1. **Given** a feature has a persisted checkpoint recording it last stopped
   at phase `analyze`, **When** the operator resumes the feature with no
   further options, **Then** the pipeline restarts at `analyze`, not at the
   first phase.
2. **Given** a feature has no persisted checkpoint, **When** the operator
   attempts to resume it, **Then** the system reports that no checkpoint
   exists and takes no other action.
3. **Given** a feature id that does not match any known feature, **When**
   the operator attempts to resume it, **Then** the system reports the
   feature is unknown and takes no other action.

---

### User Story 2 - Attach operator guidance to the resumed phase (Priority: P2)

While resuming a feature, the operator wants to leave a short note explaining
what they changed or what the next phase should pay attention to (e.g. "fixed
the float in data-model.md, re-run analyze"). That note should reach the
resumed phase so it has the operator's context, not just the bare state left
behind by the halt.

**Why this priority**: Valuable and directly requested, but the resume
mechanism (User Story 1) has standalone value even without a guidance note —
an operator can resume silently today. This layers on top rather than gating
the core flow.

**Independent Test**: Can be fully tested by resuming a feature with a
guidance string and confirming that same string is passed through to the
phase runner unchanged.

**Acceptance Scenarios**:

1. **Given** an operator resumes a feature with a guidance note, **When**
   the resumed phase runs, **Then** the phase receives that guidance note.
2. **Given** an operator resumes a feature without a guidance note,
   **When** the resumed phase runs, **Then** the phase runs without one
   (no error, no placeholder text injected).

---

### User Story 3 - Override the resume starting phase (Priority: P3)

An operator sometimes knows better than the checkpoint — for example, they
want to re-run an earlier phase because their fix changes an upstream
artifact, not just the phase where the halt occurred. They can explicitly
name the phase to resume from, overriding the checkpointed one.

**Why this priority**: A useful escape hatch for a secondary situation
(checkpoint phase isn't actually where the operator wants to restart), but
the default (checkpointed phase) covers the common case handled by User
Story 1.

**Independent Test**: Can be fully tested by resuming a feature that has a
checkpoint at phase X while explicitly requesting phase Y, and confirming
the runner starts at Y, not X.

**Acceptance Scenarios**:

1. **Given** a feature checkpointed at phase `analyze`, **When** the
   operator resumes it with an explicit override of phase `plan`, **Then**
   the pipeline restarts at `plan`.

---

### Edge Cases

- What happens when the feature's worktree was removed (e.g. after a prior
  `resolve/1`) but the branch still exists? The resume path recreates the
  worktree from the existing feature branch rather than starting a fresh,
  unrelated branch — the operator's committed fix is not lost or bypassed.
- What happens when the feature's branch itself is gone, so the worktree
  cannot be recreated from it? Resume propagates a distinct worktree error
  and starts no run — it never silently starts a fresh, unrelated branch.
- What happens when the persisted checkpoint is corrupt or unreadable?
  Resume returns a distinct corrupt-checkpoint result and starts no run —
  it does not collapse this into the no-checkpoint result, and does not
  silently resume from the wrong phase or from the beginning.
- What happens when the operator's explicit starting-phase override names a
  phase that is not part of the pipeline? Resume rejects it with a distinct
  unknown-phase result and starts no run, rather than passing an invalid
  phase downstream or falling back to the first phase.
- What happens if the operator tries to resume more than one feature at
  once? Out of scope for this feature — one feature per resume call.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide an operator-facing entry point that
  resumes exactly one previously halted or escalated feature, identified by
  its feature id.
- **FR-002**: System MUST look up the feature's persisted checkpoint and, by
  default, restart the feature's pipeline at the phase recorded in that
  checkpoint.
- **FR-003**: System MUST allow the operator to explicitly override the
  starting phase for the resumed run, taking precedence over the
  checkpointed phase when supplied. If the supplied override names a phase
  that is not part of the pipeline, the system MUST reject it with a
  distinct unknown-phase result and start no run.
- **FR-004**: System MUST allow the operator to attach an optional free-text
  guidance note to a resume call, and MUST deliver that note to the resumed
  phase.
- **FR-005**: System MUST reuse the feature's existing branch and worktree
  state for the resumed run — recreating the worktree from the existing
  branch if it was previously removed — rather than starting the feature
  over from an empty state. If the branch is gone so the worktree cannot be
  recreated from it, the system MUST propagate a distinct worktree error and
  start no run, never silently starting a fresh, unrelated branch.
- **FR-006**: System MUST report a distinct, recognizable result when no
  checkpoint exists for the given feature id, without starting any run.
- **FR-006a**: System MUST report a distinct, recognizable result (separate
  from the no-checkpoint result) when the feature's checkpoint exists but is
  corrupt or unreadable, without starting any run.
- **FR-007**: System MUST report a distinct, recognizable result when the
  given feature id does not match any known feature, without starting any
  run.
- **FR-008**: System MUST accept the same general run configuration options
  as the existing full-run entry point (e.g. concurrency/runner
  overrides used for testing), so resume behaves consistently with the rest
  of the operator surface.
- **FR-009**: System MUST leave the existing full-restart recovery path
  (clearing a feature's worktree so the next full run starts over)
  unchanged and available as a separate, distinct operation from resume.
- **FR-010**: System MUST treat resume as scoped to a single feature per
  call; it MUST NOT resume or affect any other feature in the backlog.

### Key Entities

- **Checkpoint**: The persisted record of where a feature's pipeline last
  stopped (its last completed/attempted phase) and enough state to restart
  meaningfully from there. Already defined by prerequisite work; this
  feature reads it, does not change its shape.
- **Resume request**: The operator's ask to restart one feature — the
  feature id, plus optional overrides (starting phase, guidance note, run
  configuration).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can resolve a halted or escalated feature and get
  it running again with a single call, without manually re-triggering every
  prior phase.
- **SC-002**: Resuming a feature never re-executes phases that already
  completed successfully before the halt/escalation — only the checkpointed
  (or explicitly overridden) phase onward runs.
- **SC-003**: An operator's guidance note reaches the resumed phase in 100%
  of resume calls where one is supplied.
- **SC-004**: Attempting to resume a feature with no checkpoint, or an
  unknown feature id, always produces a clear, distinguishable result rather
  than an unhandled failure or a silent no-op.
- **SC-005**: Every failure mode that prevents a safe resume — no checkpoint,
  corrupt checkpoint, unknown feature id, invalid starting-phase override, or
  a missing branch that blocks worktree recreation — produces its own
  distinct result and starts no run; none silently falls back to the first
  phase or a fresh branch.

## Assumptions

- The checkpoint persistence mechanism, the phase-level resume entry point
  on the per-feature runner, and operator-guidance-note delivery into a
  resumed phase are already implemented by prerequisite work (features 001,
  002, and 003 respectively); this feature only adds the single top-level
  operator entry point that wires them together for one feature at a time.
- "Operator" refers to the human running this system interactively (e.g.
  from an interactive session), consistent with the existing full-restart
  entry point aimed at the same audience.
- Multi-feature batch resume and any UI/CLI surface beyond the existing
  operator entry-point style are out of scope for this feature.
