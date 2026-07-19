# Feature Specification: Single-Spec Run Mode

**Feature Branch**: `001-single-spec-run`

**Created**: 2026-07-18

**Status**: Draft

**Input**: User description: "Let's create a specification that allows a single spec be implemented in speckit orchestrator"

## Clarifications

### Session 2026-07-18

- Q: How does the operator supply the one feature to a single-spec run? → A: A free-text feature description only; the orchestrator auto-assigns the feature id and derives the slug (no breakdown file, no operator-supplied id/slug).
- Q: Where does the single-feature pipeline start? → A: Always start at `specify` and run the full sequence, identical to a backlog feature (no pre-written spec, no phase skipping).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run one feature without authoring a backlog (Priority: P1)

An operator has a single feature they want the orchestrator to build. They give
the orchestrator a free-text description of that one feature and start a run; the
orchestrator auto-assigns the feature id and derives its slug. It drives the feature
through the full Spec Kit pipeline (specify → clarify → plan → tasks → analyze →
implement → converge) on its own isolated branch and reports a terminal outcome —
without the operator first having to create a directory of numbered breakdown
files or declare any prerequisite wiring.

**Why this priority**: This is the core value of the feature. Today the smallest
possible run still forces the operator to construct a multi-file breakdown
backlog with prerequisite sections, which is disproportionate overhead for a
single feature and the main barrier to trying the orchestrator on one spec.
Delivering just this story is a viable, valuable product on its own.

**Independent Test**: Give the orchestrator one free-text feature description
(with no backlog directory present) and start a run; confirm the orchestrator
assigns an id and slug, the feature progresses through the pipeline on its own
branch and reaches a terminal state with a report, with no prerequisite
declarations and no breakdown files authored anywhere.

**Acceptance Scenarios**:

1. **Given** a single free-text feature description and no backlog directory,
   **When** the operator starts a single-spec run, **Then** the orchestrator
   assigns an id and slug and runs that one feature as a wave of one, reporting
   its terminal outcome.
2. **Given** a single-spec run that completes successfully, **When** the run
   drains, **Then** the final report accounts for exactly one feature with a
   `done` outcome and a spend figure within budget.
3. **Given** a single feature with no prerequisites, **When** the run starts,
   **Then** the orchestrator does not require, read, or validate any prerequisite
   or dependency information.

---

### User Story 2 - Same safety guarantees as a full backlog run (Priority: P1)

An operator running a single feature gets exactly the same protections a full
backlog run provides: the run stops and asks for a human when the spec is
materially ambiguous, halts on a governance violation, never overspends, contains
all file writes to the feature's own workspace, keeps a durable record of each
phase, and preserves the workspace for inspection when the feature does not
finish cleanly.

**Why this priority**: A convenience path that quietly drops the orchestrator's
safety behaviors would be worse than no path at all — it would produce
unreviewed, non-compliant, or over-budget work. The guarantees are the product,
so they must hold identically in single-spec mode. Tied P1 with Story 1.

**Independent Test**: Run single features that each trip one guarantee (an
ambiguous spec, a governance-violating design, a pre-exhausted budget) and
confirm each produces the same escalate/halt/drain outcome and workspace
retention that the full backlog run produces.

**Acceptance Scenarios**:

1. **Given** a single feature whose specification is materially ambiguous, **When**
   the clarify phase runs, **Then** the feature escalates for human attention and
   its workspace is retained.
2. **Given** a single feature whose design violates a governance rule, **When**
   the analyze phase runs, **Then** the feature halts and its workspace is
   retained.
3. **Given** a budget that is already exhausted, **When** a single-spec run is
   started, **Then** no new work is released and the run reports no spend beyond
   what was already committed.
4. **Given** any single-spec run, **When** it executes, **Then** every attempted
   file write outside the feature's own workspace is refused, and a durable
   per-phase record is written to the workspace.
5. **Given** a single feature that finishes cleanly, **When** the run drains,
   **Then** its workspace is removed; **Given** a feature that escalates, halts,
   or fails, **Then** its workspace is kept for inspection.

---

### User Story 3 - Optionally open a pull request for the single feature (Priority: P3)

When the operator wants the finished feature delivered as a reviewable change,
they can enable the pull-request workflow for the single-spec run so that a
successful feature has its branch published and a pull request opened for it.

**Why this priority**: Useful for operators who want the result handed off for
human review, but not required to realize the core value of running one spec. It
reuses the existing pull-request workflow rather than introducing new behavior,
so it is the lowest priority.

**Independent Test**: Enable the pull-request workflow for a single-spec run of a
feature that completes cleanly, and confirm the feature's branch is published and
a pull request is opened against the expected base.

**Acceptance Scenarios**:

1. **Given** the pull-request workflow is enabled and the single feature finishes
   cleanly, **When** the run drains, **Then** the feature's branch is published
   and a pull request is opened for it.
2. **Given** the pull-request workflow is enabled but the target's remote is not
   ready, **When** the run is started, **Then** the run refuses to start and
   reports the preflight problem instead of running the feature.

---

### Edge Cases

- What happens when the operator supplies an empty or whitespace-only feature
  description? The run must refuse to start with a clear error rather than
  starting an empty or partial run.
- What happens when the auto-derived slug would collide with, or the auto-assigned
  id would duplicate, an existing feature from a prior run? The id/slug assignment
  must be deterministic and must not silently overwrite an unrelated prior
  feature's workspace or branch.
- What happens when a workspace or branch for this feature already exists from a
  prior run (e.g. after a human resolved an earlier escalation and the same
  description is re-run)? The run must reuse the existing branch and re-run the
  feature rather than failing.
- What happens if an operator supplies a description that reads as several
  features? The run must still run exactly one feature — a single-spec run never
  fans out into a multi-feature run.
- What happens when the budget is exhausted mid-run? The in-flight phase finishes
  and the feature halts between phases; the run drains rather than being killed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a way to start a run for exactly one
  feature from a single free-text feature description, without requiring a
  directory of breakdown files or any breakdown file at all.
- **FR-002**: The system MUST NOT require the operator to declare any
  prerequisite or dependency information for a single-feature run; the feature is
  treated as having no prerequisites.
- **FR-003**: The system MUST auto-assign the feature's id and derive its slug
  from the operator's description; the operator MUST NOT be required to supply an
  id or slug. Assignment MUST be deterministic and MUST NOT overwrite an
  unrelated existing feature's workspace or branch.
- **FR-004**: The system MUST always start the single feature at the `specify`
  phase and drive it through the same full pipeline sequence used for backlog
  features (specify → clarify → plan → tasks → analyze → implement → converge); it
  MUST NOT accept a pre-written specification or skip phases.
- **FR-005**: The system MUST run the single feature in its own isolated
  workspace on its own feature branch, carrying in the committed project scaffold,
  exactly as a backlog feature does.
- **FR-006**: The system MUST apply the clarify gate: a materially ambiguous
  specification escalates the feature for human attention instead of proceeding.
- **FR-007**: The system MUST apply the analyze gate: a governance (constitution)
  Critical finding halts the feature instead of proceeding.
- **FR-008**: The system MUST enforce the cost circuit breaker for the
  single-feature run, releasing no new work once the budget is reached and
  finishing any in-flight phase before halting (drain, not kill).
- **FR-009**: The system MUST enforce the same least-privilege write containment
  for the single feature that applies to backlog features, refusing writes
  outside the feature's workspace.
- **FR-010**: The system MUST write a durable per-phase record to the feature's
  workspace for a single-spec run.
- **FR-011**: The system MUST remove the workspace when the feature finishes
  cleanly and retain it when the feature escalates, halts, or fails.
- **FR-012**: The system MUST reject a single-spec run at start time when the
  feature description is empty or whitespace-only, with a clear error and no
  partial run.
- **FR-013**: The system MUST reuse an existing feature branch when one is already
  present, so a human-resolved feature can be re-run.
- **FR-014**: The system MUST produce a final report for the single-spec run that
  accounts for the one feature's terminal outcome and the run's total spend.
- **FR-015**: The system MUST allow the operator to optionally enable the existing
  pull-request workflow for the single feature, publishing its branch and opening
  a pull request on clean completion, subject to the same start-time preflight.
- **FR-016**: The operator surface for starting and observing a single-spec run
  MUST remain the existing interactive operator surface (no new user interface).

### Key Entities *(include if feature involves data)*

- **Feature**: The single unit of work — identified by an auto-assigned id and an
  auto-derived slug, with no prerequisites in single-spec mode, and a lifecycle
  status that ends in one of: done, escalated, halted, or failed.
- **Run**: One execution driving the single feature to a terminal state, holding
  the feature's status, the workspace, the accumulated spend against the budget,
  and the final report.
- **Feature description**: The operator-supplied free-text description of the one
  feature to run, from which the orchestrator derives the Feature (id, slug) and
  which seeds the `specify` phase.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can start a run for one feature without creating any
  breakdown-backlog directory or authoring any prerequisite declaration.
- **SC-002**: Starting a single-spec run requires supplying only a feature
  description and one command to begin — no file authoring or multi-file setup step.
- **SC-003**: 100% of the orchestrator's existing run guarantees (clarify
  escalation, analyze halt, breaker drain-not-kill, write containment, durable
  transcripts, workspace retention on non-clean outcomes) are observably
  preserved in single-spec mode.
- **SC-004**: A single-spec run of a clean feature reaches a `done` terminal
  state and reports total spend within budget plus at most one outstanding
  reservation.
- **SC-005**: An empty or whitespace-only feature description is rejected at start
  with a clear error and produces no partial run in 100% of cases.
- **SC-006**: A single-spec run never runs more than one feature, regardless of
  input.

## Assumptions

- The operator supplies the single feature as a free-text description only; the
  orchestrator auto-assigns the feature id and derives the slug (no breakdown file
  and no operator-supplied id/slug). The single-spec path reuses the existing
  feature-running machinery for one feature with no prerequisites.
- "Implemented" means driven through the full existing pipeline to a terminal
  state, always starting at `specify` (no pre-written spec, no phase skipping);
  single-spec mode changes how a run is *started and scoped*, not what the
  pipeline does per phase.
- The single feature runs as a wave of one; existing concurrency, budget, and
  release policy apply unchanged with an effective in-flight cap of one.
- The pull-request workflow, when enabled for a single feature, behaves as it
  already does for a single backlog feature (sequential, branch published, pull
  request opened against the expected base after clean completion).
- No new operator user interface is introduced; the existing interactive operator
  surface is the entry point for starting and observing the run.
