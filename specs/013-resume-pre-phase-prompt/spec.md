# Feature Specification: Pre-phase remediation prompt at resume

**Feature Branch**: `013-resume-pre-phase-prompt`

**Created**: 2026-07-23

**Status**: Draft

**Input**: User description: "When I resume from some phase, or from checkpoint, the application must allow to go directly to phase execution, or run a prompt before go to the phase, for example, when the analyze return some critical ou high issues, I can prompt LLM to fix those issues before run the phase again."

## Clarifications

### Session 2026-07-23

- Q: Which model should drive the pre-phase remediation step? → A: The target phase's model by default, overridable by the operator at resume.
- Q: How should the remediation step surface in observability (telemetry + durable transcript)? → A: Full — emit a telemetry span and write a durable transcript, same as any phase.
- Q: On a transient error, what happens before FR-006's "do not proceed" applies? → A: Auto-retry like a phase; only a genuine post-retry failure stops the resume.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Fix issues, then re-run the gate phase (Priority: P1)

A feature halted at `analyze` because the gate reported one or more Critical/High
issues (for example a constitution violation in `plan.md`). The operator has read
the findings and, instead of hand-editing every artifact, wants to hand the model
a short remediation instruction — "fix the money-type Critical the analyze gate
flagged" — have it correct the artifacts, and only then re-run `analyze` so the
gate re-evaluates the corrected work. The remediation runs as its own step
*before* the phase, not folded into the phase's own execution.

**Why this priority**: This is the feature. A halted gate phase is a
read-only checkpoint — re-running it alone changes nothing, so today an operator
must leave the tool, edit artifacts by hand, and only then resume. A pre-phase
remediation step closes that loop inside the resume path and is what turns a
halt into a one-command recovery.

**Independent Test**: Resume a feature halted at `analyze` with a remediation
prompt supplied. Verify a distinct remediation step runs first (a model
execution driven by the operator's prompt, against the feature's worktree),
completes, and *then* the `analyze` phase runs — in that order — reaching a
terminal state. With an injected fake executor, assert the remediation step is
invoked exactly once and before the phase step.

**Acceptance Scenarios**:

1. **Given** a feature halted at `analyze` and a resume with a non-blank
   remediation prompt and `analyze` as the target phase, **When** the resume
   runs, **Then** a remediation step executes first carrying the operator's
   prompt, and only after it completes does the `analyze` phase execute.
2. **Given** the same resume, **When** the remediation step completes, **Then**
   the subsequently-run `analyze` phase evaluates the artifacts as the
   remediation step left them (the phase sees the remediation's changes).

---

### User Story 2 - Resume directly, with no remediation (Priority: P1)

An operator resuming a feature that only needs a straightforward re-run (a
transient failure, or a fix they already made by hand) wants to go straight to
phase execution with no remediation step inserted — identical to the resume
behavior that exists today.

**Why this priority**: Equal to Story 1 — the remediation step MUST be strictly
opt-in. The far more common "just resume the phase" path must not regress or
gain an extra model execution (and its cost) that the operator did not ask for.

**Independent Test**: Resume a feature with no remediation prompt supplied and
confirm no remediation step runs — the target phase executes directly, identical
to current resume behavior, reaching a terminal state.

**Acceptance Scenarios**:

1. **Given** a resume with no remediation prompt (absent, empty, or
   whitespace-only), **When** the resume runs, **Then** no remediation step is
   invoked and the target phase executes directly as it does today.

---

### User Story 3 - Remediation is scoped to this one resume, not the whole pipeline (Priority: P2)

Once the remediation step has run and the target phase has re-run, the pipeline
advances normally. The remediation instruction must not re-fire on later phases:
it was a one-time correction for the phase being resumed, not a standing
instruction that alters `implement`, `converge`, or any subsequent phase.

**Why this priority**: A leaking remediation instruction could silently drive
edits into phases the operator never intended to touch, at machine speed —
exactly the class of unintended autonomous change the pipeline exists to
prevent. Necessary for safety, but only observable once the mechanism in
Stories 1–2 works.

**Independent Test**: Drive a resume with a remediation prompt at one target
phase through to a later phase; confirm the remediation step runs exactly once
(before the target phase) and no remediation step is inserted before any
subsequent phase.

**Acceptance Scenarios**:

1. **Given** a resume with a remediation prompt targeting `analyze`, **When**
   the pipeline advances past `analyze` to `implement`, **Then** no remediation
   step precedes `implement` or any later phase.

---

### Edge Cases

- **Remediation prompt supplied but blank** (empty or whitespace-only): treated
  as no remediation — the target phase runs directly, identical to Story 2. A
  blank prompt MUST NOT trigger an empty remediation execution.
- **Remediation runs but the re-run gate still fails** (e.g. `analyze` still
  reports a Critical after the fix): the feature diverts to its normal terminal
  state for that gate (halted/escalated) and retains its worktree, exactly as a
  first-time gate failure would. The operator may resume again — remediation
  does not auto-loop. (See Assumptions for the rationale: no automatic
  retry past a human gate.)
- **Remediation step itself fails** (the model execution errors or produces no
  usable change): the resume MUST surface the failure rather than silently
  proceeding to run the phase as if remediation had succeeded; the operator is
  left with a diagnosable state and the worktree intact.
- **Target phase is a non-gate phase** (e.g. resuming at `plan` with a
  remediation prompt): the pre-phase remediation still runs first, then the
  phase — the mechanism is not restricted to gate phases, though the motivating
  case is a halted gate.
- **Both a remediation prompt and an in-phase resume note are meaningful**: the
  two are independent — the remediation step (this feature) runs as its own
  execution before the phase; any in-phase operator guidance (feature 004)
  continues to append to the phase's own prompt. Neither suppresses the other.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: When resuming a feature at a target phase, the system MUST accept
  an optional operator remediation prompt distinct from the phase to resume at.
- **FR-002**: When a non-blank remediation prompt is supplied, the system MUST
  execute a remediation step — a model execution driven by that prompt, operating
  on the feature's existing worktree/artifacts — as a discrete step that
  completes *before* the target phase is executed.
- **FR-003**: The system MUST execute the target phase only after the
  remediation step has completed, and the target phase MUST observe the
  artifacts in the state the remediation step left them.
- **FR-004**: When the remediation prompt is blank — absent, empty, or
  whitespace-only — the system MUST run the target phase directly with no
  remediation step inserted, behaving identically to a resume with no
  remediation prompt at all.
- **FR-005**: The system MUST insert the remediation step at most once per
  resume, ahead of the target phase only, and MUST NOT insert it before any
  subsequent phase the pipeline advances to.
- **FR-006**: If the remediation step fails, the system MUST NOT proceed to
  execute the target phase as though remediation had succeeded, and MUST leave
  the feature in a diagnosable state with its worktree retained. A *transient*
  failure (e.g. a timeout) MUST first be auto-retried under the same policy a
  normal phase gets; only a genuine failure that persists past that retry
  policy counts as a failure that stops the resume.
- **FR-007**: When the re-run target phase subsequently diverts (a gate halt or
  escalation), the system MUST apply its normal terminal handling for that
  divert — including worktree retention for post-mortem — and MUST NOT
  automatically re-run the remediation step or the phase without a further
  operator action.
- **FR-008**: The remediation step MUST be governed by the same cost circuit
  breaker as any other model execution, so its spend is reserved, counted, and
  bounded by the run's budget.
- **FR-009**: The remediation step MUST run under containment no weaker than a
  normal phase execution (out-of-tree writes and dangerous operations denied), so
  an operator prompt cannot broaden what the model may touch.
- **FR-010**: The pre-phase remediation capability MUST be independent of the
  existing in-phase resume-note injection: supplying a remediation prompt MUST
  NOT change how (or whether) an in-phase note is appended to the target phase's
  own prompt, and vice versa.
- **FR-011**: The system MUST route the remediation step to the resumed target
  phase's model by default, and MUST allow the operator to override the model
  for the remediation step at resume time. The chosen model MUST NOT change the
  target phase's own model routing.
- **FR-012**: The system MUST make the remediation step observable on par with a
  phase: it MUST emit a telemetry span for the step (start/stop/exception) and
  MUST write a durable transcript of the step into the feature's worktree, using
  the same conventions as a phase transcript.

### Key Entities

- **Remediation prompt**: An optional free-text operator instruction supplied at
  resume, describing the correction the model should make before the target
  phase re-runs. Consumed once, for the target phase of this resume only.
- **Remediation step**: A discrete model execution that carries the remediation
  prompt and operates on the feature's worktree/artifacts, sequenced strictly
  before the target phase's execution.
- **Target phase**: The pipeline phase the feature is being resumed at (the
  phase that stopped, or an operator-chosen earlier phase); it executes after
  the remediation step, if any.
- **Resume state**: Per-feature data carried across a resume — which phase is
  resumed at and any operator prompts. Prior resume work (002/003/004/005/007)
  establishes the phase-entry and in-phase-note machinery; this feature adds the
  pre-phase remediation step on top of it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of resumes with a non-blank remediation prompt, a
  remediation step is executed exactly once and completes before the target
  phase begins.
- **SC-002**: In 100% of resumes with no (or blank) remediation prompt, zero
  remediation steps run and the target phase executes directly — no additional
  model execution or cost versus today's resume.
- **SC-003**: In 100% of remediation resumes, no remediation step precedes any
  phase after the target phase.
- **SC-004**: An operator can turn a gate-halted feature into a corrected,
  re-evaluated feature with a single resume command (remediation + re-run),
  without leaving the tool to hand-edit artifacts, in the common case where the
  fix is expressible as a short instruction.
- **SC-005**: A remediation step that fails never results in the target phase
  running on unremediated artifacts as if the fix had succeeded — the operator
  always sees the failure.
- **SC-006**: Every executed remediation step leaves a complete post-mortem
  trail — a telemetry span and a durable transcript — with no run requiring an
  operator to reconstruct what the remediation changed.

## Assumptions

- The resume entry point, phase-position/step numbering, resume-prompt carrying,
  and in-phase note injection already exist (features 002, 003, 004, 005, 007);
  this feature adds a pre-phase remediation step and does not redefine them.
- The remediation step is a standalone model execution (not merely extra prompt
  text folded into the phase). It is what lets a read-only gate phase like
  `analyze` be preceded by an actual artifact-fixing pass — the phase itself
  cannot fix what it only evaluates.
- The operator explicitly opts into remediation by supplying a prompt; the
  default resume behavior (direct phase execution) is unchanged. This preserves
  the human-in-the-loop principle: the model does not decide on its own to run a
  fixing pass.
- No automatic remediation loop: if the re-run gate still fails, the feature
  halts/escalates to the human again rather than the system iterating fixes on
  its own — consistent with "a gate divert MUST NOT be retried past the human."
- The remediation prompt is short free-text; no structured format or length
  limit beyond safe verbatim inclusion is assumed.
- "Direct to phase execution" is the existing resume path; this feature only
  adds the optional preceding step and does not alter model routing, per-phase
  permissions, or session continuity of the target phase itself.
