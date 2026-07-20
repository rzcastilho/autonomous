# Feature Specification: Resume Checkpoint Persistence

**Feature Branch**: `002-resume-checkpoint`

**Created**: 2026-07-20

**Status**: Draft

**Input**: User description: "@docs/breakdown/001-resume-checkpoint.md — Persist a durable, machine-readable pointer to the phase a feature reached when it terminated, so a later resume knows where to restart."

## Clarifications

### Session 2026-07-20

- Q: What should a read return when the checkpoint file exists but is corrupt or unreadable? → A: A distinct error signal for corrupt/unreadable, separate from the "no checkpoint" absent case, so callers can tell "never checkpointed" from "checkpoint damaged."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Diverted feature leaves a durable checkpoint (Priority: P1)

When a feature run terminates at a non-completed state (escalated at clarify,
halted at analyze, or a gate failure), the orchestrator records a durable,
machine-readable pointer capturing which phase the feature reached and why it
stopped. An operator — or a later automated resume — can read that record to
know exactly where the feature halted, without reconstructing it from transcripts.

**Why this priority**: This is the foundational record. Everything else in the
resume story (reading the pointer, restarting at the right phase) depends on the
checkpoint existing first. It is independently valuable on its own: operators
gain an at-a-glance "where did this stop" without parsing per-phase transcripts.

**Independent Test**: Drive a feature to a diverted terminal state and confirm a
checkpoint record exists whose halted-phase field matches the phase the pipeline
diverted at, and whose status and reason reflect the terminal outcome.

**Acceptance Scenarios**:

1. **Given** a feature that escalates at the clarify phase, **When** the run
   drains and its worktree is kept, **Then** a checkpoint record exists recording
   `clarify` as the last phase and `escalated` as the status.
2. **Given** a feature that halts at the analyze phase, **When** the run
   terminates, **Then** a checkpoint record exists recording `analyze` as the
   last phase and `halted` as the status.
3. **Given** a terminated feature with a tuple-shaped reason, **When** the
   checkpoint is written, **Then** the reason is stored in a readable,
   machine-parseable serialized form (not lost, not causing a write failure).

---

### User Story 2 - Completed feature leaves no stale pointer (Priority: P2)

When a feature run completes successfully, no resume pointer should linger. A
completed feature needs no restart point, and a leftover checkpoint from an
earlier diverted attempt must not mislead a later resume into thinking the
feature is still unfinished.

**Why this priority**: Prevents a correctness hazard for the downstream resume
feature — a stale checkpoint on a done feature would be read as "resume needed."
Depends on the same write path as P1 but is a distinct guarantee.

**Independent Test**: Run a feature to a completed terminal state (optionally
after a prior diverted attempt that wrote a checkpoint) and confirm no checkpoint
record remains for that feature.

**Acceptance Scenarios**:

1. **Given** a feature that reaches the completed terminal state, **When** the
   run finalizes, **Then** any existing checkpoint record for that feature is
   removed.
2. **Given** a feature with no prior checkpoint that completes successfully,
   **When** the run finalizes, **Then** no checkpoint record is created and no
   error is raised.

---

### User Story 3 - Checkpoint records round-trip reliably (Priority: P2)

An operator or automated caller can read back a previously written checkpoint and
receive the same fields that were written. Reading a checkpoint that does not
exist returns a clear "no checkpoint" signal rather than an error or fabricated
data.

**Why this priority**: The record is only useful if it can be read back
faithfully. This is the read side of the contract that the resume feature will
consume.

**Independent Test**: Write a checkpoint, read it back, and confirm the returned
fields match what was written; then read a checkpoint for a feature that has none
and confirm the "no checkpoint" result.

**Acceptance Scenarios**:

1. **Given** a checkpoint was written for a feature, **When** it is read back,
   **Then** the returned record's fields match the written values.
2. **Given** a feature with no checkpoint on record, **When** a read is
   attempted, **Then** the result is an explicit "no checkpoint" outcome.

---

### Edge Cases

- **Write failure never breaks the run**: If the checkpoint cannot be written
  (unwritable location, serialization problem, I/O error), the run MUST continue
  and finalize normally — checkpoint persistence is best-effort and never fails
  or crashes the feature run.
- **Non-serializable reason**: A terminal reason may be a compound value (e.g. a
  tuple). It MUST be serialized into a stored form rather than causing the write
  to fail.
- **Overwriting an earlier checkpoint**: A feature re-run that reaches a new
  terminal state overwrites its prior checkpoint with the current phase/status,
  rather than leaving both.
- **Reading a corrupt or partially written record**: A read that finds a
  checkpoint file but cannot parse it into a valid record MUST surface a distinct
  "corrupt/unreadable" failure signal — separate from the "no checkpoint" absent
  result — never fabricated fields, so a caller can distinguish a damaged record
  from a feature that was never checkpointed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: On a feature run terminating at any non-completed state, the system
  MUST persist a durable checkpoint record for that feature.
- **FR-002**: The checkpoint record MUST capture the phase the feature reached
  when it terminated (the halted phase), the terminal status, the terminal
  reason, and the session identifier of the run.
- **FR-003**: The recorded halted phase MUST match the phase at which the
  pipeline diverted the feature.
- **FR-004**: A terminal reason that is a compound value MUST be stored in a
  serialized, human- and machine-readable form rather than causing a write
  failure or being dropped.
- **FR-005**: On a feature run reaching the completed terminal state, the system
  MUST remove any existing checkpoint record for that feature.
- **FR-006**: The system MUST provide a read operation with three distinct
  outcomes: (a) the previously written checkpoint's fields when a valid record
  exists; (b) an explicit "no checkpoint" result when none exists for the
  requested feature; (c) a distinct "corrupt/unreadable" error result — separate
  from (b) — when a checkpoint file exists but cannot be parsed into a valid
  record.
- **FR-007**: The system MUST provide a delete operation that removes a feature's
  checkpoint record.
- **FR-008**: Checkpoint persistence MUST be best-effort: any failure to write a
  checkpoint MUST NOT fail, halt, or crash the feature run.
- **FR-009**: Checkpoint records MUST be stored under the same durable root used
  for per-phase durable transcripts, keyed by feature identifier, so records live
  alongside a feature's other durable artifacts.
- **FR-010**: This feature MUST only produce and manage the checkpoint record; it
  MUST NOT read the checkpoint back into a run, nor alter any resume or
  start-phase behavior.

### Key Entities *(include if feature involves data)*

- **Checkpoint record**: A per-feature durable pointer describing where and why a
  feature run stopped. Attributes: the feature identifier it belongs to, the last
  (halted) phase, the terminal status, the terminal reason (serialized), and the
  session identifier. Keyed by feature identifier; at most one per feature at any
  time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of feature runs terminating at a non-completed state produce a
  checkpoint record whose halted phase matches the phase the pipeline diverted at.
- **SC-002**: 100% of feature runs reaching the completed terminal state leave no
  checkpoint record for that feature.
- **SC-003**: A written checkpoint reads back with every field identical to what
  was written (lossless round-trip); a read for a feature with no checkpoint
  returns the explicit "no checkpoint" result, and a read of a corrupt/unreadable
  checkpoint file returns the distinct "corrupt/unreadable" result — never
  confused with each other — in 100% of cases.
- **SC-004**: A forced checkpoint write failure never causes a feature run to
  fail or crash — the run still finalizes at its correct terminal state.
- **SC-005**: An operator can determine where a terminated feature stopped by
  reading its checkpoint record alone, without opening any transcript file.

## Assumptions

- The durable transcript root already exists and is the correct shared location
  for checkpoint records; checkpoints live alongside per-phase durable
  transcripts, keyed by feature identifier.
- The halted phase is available from the feature's run state at termination (set
  when each phase runs), and the terminal status, reason, and session identifier
  are available from the same run finalization point.
- "Completed" is the single successful terminal state; all other terminal states
  (escalated, halted, gate-failed) are treated as "diverted" and warrant a
  checkpoint.
- Records are stored in a machine-readable serialized document format consistent
  with existing durable-artifact conventions in the project.
- Concurrency: at most one run finalizes a given feature at a time, so a single
  record per feature is sufficient (no multi-writer contention on one feature's
  checkpoint).
