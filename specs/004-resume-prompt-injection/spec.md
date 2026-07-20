# Feature Specification: Operator prompt injection at the resume phase

**Feature Branch**: `004-resume-prompt-injection`

**Created**: 2026-07-20

**Status**: Draft

**Input**: User description: "@docs/breakdown/003-resume-prompt-injection.md"

## Clarifications

### Session 2026-07-20

- Q: How should a blank `resume_prompt` (empty or whitespace-only string, but non-nil) be handled? → A: Treat `nil`, `""`, and whitespace-only alike as no-guidance — append no line (guard on non-blank).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Guidance steers exactly the resumed phase (Priority: P1)

An operator resolves the cause of an escalation or halt (e.g. a `## NEEDS
HUMAN` marker at clarify, or a constitution Critical at analyze) and supplies a
short free-text prompt describing the fix. When the feature resumes, that
guidance must reach only the phase being restarted — appended to that phase's
assembled prompt — so the phase re-runs with the operator's intent in view.

**Why this priority**: This is the entire feature. Without it, a resumed phase
re-runs blind to the human's resolution and is likely to escalate or halt
again on the same issue.

**Independent Test**: Resume a feature whose `resume_phase` is `clarify` with
a `resume_prompt` of "resolved: use integer cents". Verify the clarify phase's
built prompt ends with the operator guidance line and clarify proceeds without
re-escalating on the same ambiguity.

**Acceptance Scenarios**:

1. **Given** a feature with `resume_phase: :clarify` and `resume_prompt:
   "resolved: use integer cents"`, **When** the clarify phase's request is
   built, **Then** the assembled prompt ends with a clearly delimited operator
   guidance line containing that text.
2. **Given** a feature with `resume_phase: :plan` and `resume_prompt: "use
   REST, not GraphQL"`, **When** the clarify phase's request is built (a
   different phase from `resume_phase`), **Then** the assembled prompt is
   byte-identical to what it would be with no resume state at all.

---

### User Story 2 - Downstream phases run clean after the resumed phase completes (Priority: P1)

Once the resumed phase completes and the feature advances to the next phase in
the pipeline, that next phase and every phase after it must run with no trace
of the operator's guidance — the injected instruction was scoped to steering
the one phase that needed human help, not to permanently altering the
feature's future behavior.

**Why this priority**: Equally critical to Story 1 — leaking operator guidance
downstream could silently change unrelated phases' behavior (e.g. a `plan`-time
instruction bleeding into `tasks` or `implement`), producing effects the
operator never intended for those phases.

**Independent Test**: Drive a multi-phase run where `resume_phase` is set to
one phase; confirm that phase's built prompt carries the guidance and every
other phase in the same run builds a prompt with no guidance line.

**Acceptance Scenarios**:

1. **Given** a feature resuming at `clarify` with a `resume_prompt` set,
   **When** the feature subsequently advances to `plan`, `tasks`, etc.,
   **Then** none of those later phases' built prompts contain the operator
   guidance text.

---

### Edge Cases

- What happens when `resume_prompt` is `nil` (normal, non-resumed run), an
  empty string, or whitespace-only? All are treated alike as no-guidance: the
  built prompt is unchanged from today's output — no guidance line is
  appended, not even an empty one.
- How does the system handle a transient retry of the resume phase itself
  (e.g. the harness retries a failed phase execution before the pipeline
  advances)? The guidance is re-injected on each retry of that same phase,
  since the operator's intent still applies until the phase actually
  completes and the feature moves on.
- What happens when `resume_phase` is set but `resume_prompt` is `nil` (or
  vice versa)? No guidance is injected — injection requires both a matching
  phase and a non-nil prompt.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST accept an optional operator guidance value when
  assembling a phase's prompt.
- **FR-002**: When that guidance value is present and non-blank, the system
  MUST append it to the assembled prompt as a clearly delimited trailing
  section (a blank-line separator, a marker line, then the guidance text), so
  it is visually distinguishable from the rest of the prompt.
- **FR-003**: When that guidance value is blank — `nil`, an empty string, or
  whitespace-only — the system MUST leave the assembled prompt byte-identical
  to its current (pre-feature) output; the change MUST be strictly
  additive/append-only and MUST NOT emit a marker line with an empty body.
- **FR-004**: The system MUST determine, per phase execution, whether the
  currently-executing phase is the feature's designated resume phase, and MUST
  only pass the operator's guidance through for that phase.
- **FR-005**: For every phase that is not the feature's designated resume
  phase, the system MUST pass no guidance (nil), regardless of whether the
  feature has resume state set.
- **FR-006**: A transient retry of the resume phase (before the pipeline
  advances past it) MUST re-inject the same guidance on each retry.
- **FR-007**: Injection of operator guidance MUST NOT alter model routing,
  per-phase tool permissions, or session continuity for any phase.

### Key Entities

- **Resume state**: Per-feature data carried across a resume, consisting of
  which phase is being resumed and the operator's free-text guidance for that
  phase. Established by prior work (feature 002/003); this feature only reads
  it.
- **Phase prompt**: The assembled instruction text sent to the CLI for a
  single phase's execution; operator guidance is appended to this text only
  when the phase matches the resume state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of resumed runs, the phase named as the resume phase
  receives the operator's exact guidance text in its prompt.
- **SC-002**: In 100% of resumed runs, every phase other than the designated
  resume phase produces a prompt with zero trace of the operator's guidance
  text.
- **SC-003**: In 100% of non-resumed (fresh) runs, prompts are unchanged from
  pre-feature behavior — no observable difference in output.
- **SC-004**: An operator's one-sentence fix guidance, once supplied at
  resume, requires no further manual re-entry across retries of the same
  phase.

## Assumptions

- Resume state (`resume_phase`, `resume_prompt`) is already populated on the
  feature/agent state by prior work (features 002 and 003) — this feature only
  consumes it, it does not define how it is set or persisted.
- The operator's guidance is a short, free-text string; no structured format,
  length limit, or sanitization beyond safe verbatim inclusion in the prompt
  is required.
- "Downstream phases run clean" means the guidance is not part of that phase's
  own prompt text; it does not imply erasing resume state from the feature's
  persisted record (e.g. for post-mortem/audit purposes), which is out of
  scope for this feature.
- The operator-facing resume trigger (how a human actually invokes a resume,
  the `resolve/2` facade) is a separate, later backlog item; this feature only
  covers prompt injection given that resume state already exists.
