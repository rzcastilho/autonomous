# Feature Specification: Checkpoint-First Resume

**Feature Branch**: `025-checkpoint-first-resume`

**Created**: 2026-09-22

**Status**: Draft

**Input**: User description: "Resume must start from the durable store checkpoint, not the git commit trail. A crashed run resumed one phase too early — it re-ran `analyze` when the feature had already completed analyze and was mid-`implement` — because the resume phase is derived by scanning branch commit subjects for a boundary marker that `implement`'s per-chunk commits do not carry, and that `implement` only writes once it completes. The durable record held the correct position the whole time."

## Context

Two ways to restart an interrupted feature exist today, and they disagree with each other about the same feature:

- Resuming **one named feature** reads the feature's durable checkpoint and starts at the phase the checkpoint names. This is correct.
- Resuming **a whole crashed run** ignores the checkpoint for phase purposes and instead reconstructs the position from the feature branch's commit history, taking the newest commit whose subject matches a phase-boundary marker and starting at the phase *after* it.

Those per-phase boundary commits are written after every completed phase. But the implementation phase also writes its own progress commits, in a different subject shape, and the implementation phase's own boundary commit is written only when the whole phase finishes. So a crash in the middle of implementation leaves the newest *matching* boundary marker at the phase two steps back, and a whole-run resume rewinds two phases — re-running analysis work that was already finished and already recorded.

This was observed live on a real run (run `r000002`, target repository `mod-player`, feature `001`). Boundary markers present on the branch were: specify, clarify, plan, tasks — then a gap covering the implementation progress commits — then analyze, written *after* the rewind, on top of the implementation work. The durable record for that feature said, correctly and from the moment the analysis phase finished, that the next phase was implementation.

The rewind is not only wasted money and wall-clock. It re-opened an artifact-writing phase over a tree that a later phase had already advanced, and — combined with a second, separate defect covered by its own feature — produced two concurrent sessions writing to one worktree, visible as a duplicated implementation progress commit on the branch.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A whole-run resume continues where the crash happened (Priority: P1)

An operator whose orchestrator process died mid-run asks for the whole run to be resumed. The feature that was in flight when the crash hit had finished several phases, including analysis, and was part-way through implementation. The resume starts that feature at implementation — the phase it was actually in — not at any earlier phase.

**Why this priority**: This is the defect. Every whole-run resume of a feature interrupted during implementation currently redoes at least one completed phase, spends budget on it, and rewrites artifacts a later phase had already moved past. Nothing else in this feature matters if this does not hold.

**Independent Test**: Take a durable record whose feature shows a checkpoint naming implementation as the next phase, paired with a branch whose newest boundary marker names an earlier phase. Ask what phase that feature resumes at. It must answer implementation. Fully testable against a reconstructed record and evidence, with no phase execution and no spend.

**Acceptance Scenarios**:

1. **Given** a feature whose durable checkpoint names implementation as the next phase and whose branch's newest boundary marker names the phase before analysis, **When** a whole-run resume computes the feature's resume position, **Then** it resumes at implementation.
2. **Given** the same feature, **When** a single-feature resume and a whole-run resume each compute the resume position, **Then** both name the same phase.
3. **Given** a feature whose durable checkpoint and whose newest boundary marker agree, **When** either resume path computes the position, **Then** the result is unchanged from today's behaviour.
4. **Given** a feature interrupted during implementation whose checkpoint records how far the implementation work had progressed, **When** the resume starts it, **Then** the implementation work continues from the recorded position rather than repeating already-completed portions.

---

### User Story 2 - A record without a checkpoint still resumes from the commit trail (Priority: P2)

An operator resumes a run whose feature has no durable checkpoint — an older record written before checkpoints existed, or a feature whose final checkpoint write was lost when the durable store became unwritable mid-run. The resume still reconstructs a position from the branch's commit history exactly as it does today.

**Why this priority**: Making the checkpoint primary must not make the system helpless when there is no checkpoint. The commit trail is the fallback that keeps existing records and persistence-failure cases recoverable, and it is the only evidence in those cases.

**Independent Test**: Take a record whose feature carries no checkpoint, paired with a branch carrying boundary markers. The resume position must be derived from the markers, identical to the position produced today.

**Acceptance Scenarios**:

1. **Given** a feature with no durable checkpoint and a branch whose newest boundary marker names a non-final phase, **When** the resume position is computed, **Then** it is the phase after that marker — the current behaviour, unchanged.
2. **Given** a feature with neither a checkpoint nor any corroborating artifact of any kind, **When** its status is reconciled, **Then** it is classified as never-started and runs fresh from the first phase.
3. **Given** a run drained by a durable-store write failure, leaving one feature's last checkpoint unwritten, **When** the operator resumes, **Then** the feature resumes from the commit trail and the resume is still flagged as possibly incomplete, as it is today.

---

### User Story 3 - A genuine disagreement is reported, never resolved silently (Priority: P2)

An operator resumes a run in which one feature's durable checkpoint and its branch evidence tell contradictory stories that cannot both be true — for example the checkpoint claims a position *behind* what the branch proves was already completed. The resume reports the disagreement to the operator as a discrepancy rather than picking a side quietly.

**Why this priority**: The existing reconciliation rule is that store-versus-evidence disagreements surface for a human instead of being resolved silently. Promoting the checkpoint to primary must not create a new silent override. But the common case — a checkpoint that is simply *ahead* of the commit trail, which is exactly what the defect above produces — is the expected, healthy shape and must not be reported as a conflict.

**Independent Test**: Feed a checkpoint naming an earlier phase than the newest boundary marker proves completed. The result must be a reported discrepancy. Feed a checkpoint naming a later phase than the newest marker and confirm it resolves to the checkpoint's phase with no discrepancy raised.

**Acceptance Scenarios**:

1. **Given** a feature whose checkpoint names a phase strictly ahead of what the commit trail shows, **When** the position is computed, **Then** the checkpoint's phase is used and no discrepancy is reported.
2. **Given** a feature whose checkpoint names a phase strictly behind what the commit trail proves was already completed, **When** the position is computed, **Then** a discrepancy is reported to the operator naming the feature, the checkpoint's phase, and the trail's phase.
3. **Given** a reported discrepancy, **When** the operator reads the resume preview, **Then** the discrepancy is visible before any work starts and no budget has been spent.

---

### Edge Cases

- A feature whose checkpoint records a terminal, human-facing outcome (escalated, halted, failed): unchanged — those classifications take precedence over any evidence and are never advanced by this feature.
- A feature already proven complete by its release evidence: unchanged — completion still wins over any checkpoint or trail position.
- A checkpoint naming the final phase in the pipeline: treated the same as today's final-phase boundary, a completion signal rather than a resume position.
- A checkpoint naming a phase the pipeline does not recognise (a record written by a different version): reported as a damaged record rather than silently coerced to a neighbouring phase.
- A feature whose branch no longer exists but whose checkpoint does: the checkpoint alone is not proof that work landed; classification follows the existing rules for a feature with no committed branch.
- Implementation progress recorded in the checkpoint that points past the end of the current task list (the task list was regenerated since): the implementation work restarts from the beginning of the list rather than skipping it entirely, and the operator is told.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When a feature carries a durable checkpoint that names a non-terminal next phase, the whole-run resume MUST use that phase as the feature's resume position.
- **FR-002**: When a feature carries no durable checkpoint, the whole-run resume MUST derive the resume position from the branch's phase-boundary commit trail, producing exactly the position it produces today.
- **FR-003**: The single-feature resume and the whole-run resume MUST produce the same resume position for the same feature and the same evidence.
- **FR-004**: A checkpoint whose phase is ahead of the commit trail's newest boundary MUST be treated as the expected shape — the checkpoint wins, and no discrepancy is reported.
- **FR-005**: A checkpoint whose phase is behind what the commit trail proves was already completed MUST be reported to the operator as a discrepancy, naming the feature, the checkpoint's phase, and the trail's phase.
- **FR-006**: A reported discrepancy MUST be visible in the read-only resume preview — before any phase runs and before any budget is spent.
- **FR-007**: A resume that starts a feature at the implementation phase MUST carry the checkpoint's recorded implementation progress position, so already-completed portions of the implementation work are not repeated.
- **FR-008**: The precedence rules that classify a feature as complete, escalated, halted, or failed MUST be unchanged by this feature; no checkpoint may advance a human-facing terminal state.
- **FR-009**: A feature with neither a checkpoint nor any corroborating artifact MUST still be classified as never-started and run from the first phase.
- **FR-010**: A checkpoint naming the final phase of the pipeline MUST be treated as a completion signal, never as a resume position.
- **FR-011**: A checkpoint naming an unrecognised phase MUST be reported as a damaged record and MUST start no work.
- **FR-012**: The decision that maps a reconciled feature onto a status and a resume position MUST remain a single shared rule, used identically by the resume paths and by the record-repair preview — no second, divergent copy.
- **FR-013**: The part of the system that makes this decision MUST remain free of direct repository, file, and process access; all evidence — checkpoint included — MUST be gathered before the decision is made and passed into it.
- **FR-014**: Existing records that resume correctly today MUST resume to the identical phase after this change, with no new discrepancies reported for them.

### Key Entities

- **Durable checkpoint**: the per-feature record written when a phase completes, naming the next phase, the phase just completed, and — for the implementation phase — how far the chunked work progressed. Already written today; this feature changes who reads it.
- **Boundary commit trail**: the sequence of phase-completion markers in a feature branch's history. Remains corroborating evidence and the fallback source of position.
- **Resume position**: the phase a feature restarts at, plus, for implementation, the point within that phase's work.
- **Discrepancy**: an operator-facing report that the checkpoint and the trail tell contradictory stories, carried in the existing resume report alongside the other conflicts it already reports.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A run interrupted during implementation and then resumed as a whole run restarts at implementation in 100% of cases, re-running zero already-completed phases.
- **SC-002**: The phase chosen for a given feature is identical whether the operator resumes that one feature or the whole run — verified across every phase the pipeline can be interrupted in.
- **SC-003**: Zero spend is incurred on re-running a phase that the durable record already shows as completed.
- **SC-004**: Every record that resumes correctly today resumes to the identical phase after the change, with zero new discrepancies reported.
- **SC-005**: A checkpoint-versus-trail contradiction is reported to the operator before any work starts, in 100% of cases, and is never resolved silently.
- **SC-006**: An interrupted implementation phase resumes without repeating any portion of the work the checkpoint records as completed.

## Assumptions

- The durable checkpoint is written in the same transaction as the phase result it describes, so a checkpoint that exists is at least as current as the phase attempt it accompanies. This is already the case.
- The checkpoint already records the implementation progress position; this feature reads it, it does not introduce it.
- The commit trail remains trustworthy as corroboration; this feature does not change how boundary commits are written, nor what subject they carry. Making the implementation phase's progress commits carry boundary markers was considered and rejected — it would make the position derivable from git, but leaves the two resume paths reading different sources, which is the root disagreement.
- The concurrent-session defect observed alongside this one (a superseding run leaving the previous feature's runner alive) is a separate concern with its own feature, and is out of scope here.
- Operator-facing wording for the new discrepancy follows the existing resume report's conventions; no new operator surface is introduced.
