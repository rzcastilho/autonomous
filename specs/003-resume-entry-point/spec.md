# Feature Specification: FeatureRunner Resume Entry Point

**Feature Branch**: `003-resume-entry-point`

**Created**: 2026-07-20

**Status**: Draft

**Input**: User description: "Let the runner start the pipeline at an arbitrary phase (not just specify) with correct step numbering, and carry a resume-prompt anchor through agent state. This is the mechanical core of mid-pipeline resume."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume a halted feature at its stopped phase (Priority: P1)

An operator has a feature that halted or was escalated partway through the
pipeline (e.g. at `plan` or `analyze`). Instead of re-running the whole
pipeline from `specify` — which costs time, tokens, and risks clobbering
work already done — the operator wants the run to pick up exactly at the
phase where it stopped.

**Why this priority**: This is the mechanical core of resume. Without it,
every halted/escalated feature must be re-specified from scratch, which is
the exact cost/clobber problem this feature exists to remove.

**Independent Test**: Start a run with a chosen phase (e.g. `plan`) using an
injected fake runner/agent (no real CLI). Verify the run begins at that
phase, with step numbering that matches the phase's position in the
pipeline, and proceeds to a terminal state.

**Acceptance Scenarios**:

1. **Given** a feature previously halted at `plan`, **When** the operator
   starts a run with `plan` as the starting phase, **Then** the run begins
   at `plan` labeled as step 3 (its position in the phase order) and runs
   through to a terminal state.
2. **Given** a feature previously escalated at `analyze`, **When** the
   operator starts a run with `analyze` as the starting phase, **Then** the
   run begins at `analyze` with the step number matching its position, not
   step 1.

---

### User Story 2 - Default behavior is unchanged for fresh features (Priority: P1)

An operator starting a brand-new feature (no resume) expects the run to
behave exactly as it does today: start at `specify`, step 1.

**Why this priority**: Equal priority to Story 1 — resume support must not
regress the existing, far more common fresh-start path.

**Independent Test**: Start a run with no resume options set and confirm it
begins at `specify`, step 1, identical to current behavior.

**Acceptance Scenarios**:

1. **Given** no starting phase or resume prompt is provided, **When** a run
   is started, **Then** it begins at `specify`, step 1, with no observable
   difference from current behavior.

---

### User Story 3 - Resume carries a stable anchor for future prompt injection (Priority: P2)

A future feature (prompt injection into the resumed phase's request) needs a
fixed record of which phase the run was resumed at, distinct from the phase
that is currently executing as the loop advances.

**Why this priority**: Not needed for resume to function mechanically, but
without this anchor threaded through now, the follow-on feature has no place
to read "the phase resume started at" once the loop has moved past it.

**Independent Test**: Start a run with a chosen starting phase and a resume
prompt value; inspect agent state after initialization and confirm the
starting-phase anchor stays fixed at the original value while the active
phase advances through subsequent phases.

**Acceptance Scenarios**:

1. **Given** a run started at `plan` with a resume prompt supplied, **When**
   the loop advances to `tasks`, **Then** the resume anchor still reads
   `plan` while the active phase reads `tasks`.

---

### Edge Cases

- What happens when a starting phase is requested that is not a valid
  pipeline phase? (Out of scope for this feature: validation of the
  requested phase is assumed to be the caller's responsibility, per the
  scope note below.)
- What happens when no resume prompt is supplied but a starting phase is?
  The resume prompt anchor is simply absent/empty; the run still starts at
  the requested phase.
- What happens when a run starts at the pipeline's terminal phase
  (`converge`)? The run should still execute that single phase and reach a
  terminal state, rather than being treated as already complete.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST be able to report the 1-based position (step
  number) of any given pipeline phase within the overall phase order.
- **FR-002**: The system MUST allow a run to begin at any pipeline phase
  supplied by the caller, rather than always beginning at the first phase.
- **FR-003**: When a run begins at a given phase, the system MUST label that
  phase with the step number matching its actual position in the phase
  order (e.g. starting at the third phase produces step 3, not step 1).
- **FR-004**: When no starting phase is supplied, the system MUST default to
  beginning at the first phase, step 1, matching current behavior exactly.
- **FR-005**: The system MUST accept an optional resume-prompt value when
  starting a run and carry it into the feature's initial state.
- **FR-006**: The system MUST record the starting phase as a fixed anchor in
  the feature's state, distinct from the currently active phase, so that the
  anchor remains readable and unchanged as the run advances through later
  phases.
- **FR-007**: When no resume-prompt value is supplied, the system MUST treat
  it as absent without error.

### Key Entities

- **Pipeline phase order**: The fixed, ordered sequence of phases a feature
  run progresses through (e.g. specify, clarify, plan, tasks, analyze,
  implement, converge); each phase has a stable 1-based position within this
  order.
- **Resume anchor**: The phase a run was started/resumed at, fixed for the
  lifetime of that run, kept separate from the phase currently executing.
- **Resume prompt**: An optional piece of context supplied at run start,
  carried in feature state for a later feature to consume when constructing
  the resumed phase's request.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can resume any halted or escalated feature at the
  exact phase it stopped at, with zero re-execution of already-completed
  phases.
- **SC-002**: 100% of fresh (non-resume) runs behave identically to
  pre-feature behavior — no regression is observable in step numbering or
  starting phase.
- **SC-003**: Every phase in the pipeline's defined order resolves to a
  correct, verifiable 1-based step number with no exceptions or fallback
  guessing.

## Assumptions

- The caller (e.g. an operator-facing resume command, out of scope here) is
  responsible for choosing a valid starting phase; this feature does not add
  new validation for invalid/unknown phase values beyond what the pipeline's
  existing phase order already implies.
- Consuming the resume prompt to alter a phase's actual request/behavior is
  a separate, later feature; this feature only carries the value through
  state.
- An operator-facing "resume" command/facade that wraps this entry point is
  a separate, later feature; this feature only provides the underlying
  mechanism.
