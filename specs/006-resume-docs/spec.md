# Feature Specification: Resume Docs & Operator Runbook

**Feature Branch**: `006-resume-docs`

**Created**: 2026-07-20

**Status**: Draft

**Input**: User description: "Document the human-in-the-loop mid-pipeline resume flow in the operator runbook and update the codebase guide, which currently calls resume a 'v2 concern'."

## Clarifications

### Session 2026-07-20

- Q: What is the scope for the "no stale future/v2 resume reference" requirement (FR-007 vs SC-003 tension)? → A: All markdown documentation files repo-wide are in scope for stale-reference removal; source-code docstrings are out of scope (the breakdown puts code changes out of scope).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator recovers a halted/escalated feature via documented resume loop (Priority: P1)

An operator whose feature halted (analyze gate) or escalated (clarify gate) needs to fix the
root cause on the feature branch and restart the pipeline from the correct phase, using only
`docs/runbook.md` as reference — no source-diving required.

**Why this priority**: This is the primary operational payoff of shipping `resume/2` (features
001-004). Without documentation, operators fall back to the more expensive `resolve/1` full
re-run even when a targeted resume would work, or they resume incorrectly.

**Independent Test**: Can be fully tested by having an operator unfamiliar with the `resume/2`
internals follow only the runbook text and successfully invoke the escalate → fix → resume loop
with correct `iex` syntax on a real halted/escalated feature.

**Acceptance Scenarios**:

1. **Given** a feature halted at the analyze gate, **When** the operator reads
   `docs/runbook.md`, **Then** they find the exact `iex` call to fix the artifact on the feature
   branch and resume from the halted phase by default.
2. **Given** a feature that needs to restart earlier than the phase it halted/escalated at,
   **When** the operator reads the resume section, **Then** they find documented guidance on
   using the `:from` option to override the start phase.
3. **Given** a feature that needs an extra instruction injected into the resumed phase's prompt,
   **When** the operator reads the resume section, **Then** they find documented guidance on
   using the `:prompt` option.

---

### User Story 2 - Reader of CLAUDE.md gets an accurate picture of shipped capability (Priority: P2)

A contributor or future Claude Code session reading `CLAUDE.md` for project orientation should
not be told that mid-pipeline resume is a deferred v2 concern when it has already shipped.

**Why this priority**: Stale scope framing misleads anyone (human or agent) using `CLAUDE.md` as
the source of truth for what's built, risking duplicate work or incorrect operational advice.

**Independent Test**: Can be fully tested by grepping `CLAUDE.md` for language describing
mid-pipeline resume as future/unshipped and confirming zero matches, while confirming the
observability/operability paragraph describes the shipped `resume/2` facade.

**Acceptance Scenarios**:

1. **Given** the current `CLAUDE.md`, **When** the observability/operability paragraph is read,
   **Then** it describes mid-pipeline resume as shipped, not as a "v2 concern."

---

### Edge Cases

- What happens when an operator only knows about `resolve/1` and isn't aware `resume/2` exists
  or when to prefer it? The runbook must state selection criteria between the two recovery
  paths, not just describe `resume/2` in isolation.
- What happens if the artifact fix requires no phase override (the common case)? The
  restart-at-halted-phase default must be documented as the default path, with `:from` presented
  as the override for the uncommon case.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `docs/runbook.md` MUST document the `resume/2` recovery flow alongside the
  existing `resolve/1` flow, both under the runbook's recovery/operations guidance.
- **FR-002**: `docs/runbook.md` MUST document the full escalate → fix → resume loop: resolve the
  root cause on the feature branch (edit + commit the artifacts), then invoke
  `SpeckitOrchestrator.resume(id, prompt: "...")`, with exact `iex` call syntax.
- **FR-003**: `docs/runbook.md` MUST explain restart-at-halted-phase semantics — that resume
  restarts at the phase the feature halted or escalated at by default.
- **FR-004**: `docs/runbook.md` MUST document the `:from` option for overriding the phase resume
  starts at, and the `:prompt` option for injecting operator guidance into the resumed phase,
  including when an operator should reach for `:from`.
- **FR-005**: `docs/runbook.md` MUST state the decision criteria for choosing `resolve/1` (full
  re-run from `specify`) versus `resume/2` (targeted restart) for a given recovery scenario.
- **FR-006**: `CLAUDE.md` MUST update the observability/operability paragraph to describe
  mid-pipeline resume as shipped, removing any "v2 concern" or deferred-scope framing.
- **FR-007**: No markdown documentation file (`.md`) in the repository MUST describe mid-pipeline
  resume as a future/unshipped capability after this change. This scope covers every `.md` doc
  (e.g. `docs/runbook.md`, `CLAUDE.md`, `docs/workflow.md`, the phase-7 runbook), not just the
  two files edited directly. Source-code docstrings (e.g. `lib/speckit_orchestrator.ex`) are out
  of scope — the breakdown places code changes out of scope, so the `resolve/1` docstring's "v2"
  wording is left untouched.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can execute the full escalate → fix → resume recovery loop using only
  the `iex` calls documented in `docs/runbook.md`, without reading source code.
- **SC-002**: Every code example in the runbook's resume section runs against the shipped
  `resume/2` facade signature without modification.
- **SC-003**: A repository-wide search across all `.md` files for deferred/future-tense framing of
  mid-pipeline resume (e.g. "v2 concern") returns zero matches; source-code docstrings are
  excluded from the search.

## Assumptions

- `resume/2` (features 001-004) is fully shipped and its public API (`SpeckitOrchestrator.resume/2`
  with `:from` and `:prompt` opts) is stable at documentation time.
- This is a docs-only change per the breakdown's explicit out-of-scope note — no source code is
  modified.
- The audience is operators already familiar with the existing `resolve/1` flow documented in
  `docs/runbook.md`, so the new section builds on that existing structure rather than
  re-explaining it from scratch.
