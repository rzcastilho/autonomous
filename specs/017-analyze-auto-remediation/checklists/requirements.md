# Specification Quality Checklist: Analyze Auto-Remediation Loop

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-26
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

### Validation notes (iteration 1 — all pass)

- **Domain vocabulary vs. implementation detail**: the spec uses *worktree*,
  *branch*, *cost circuit breaker*, *analyze phase*, and *finding severity*.
  These are this product's own operator-facing concepts (the orchestrator's
  value proposition is per-feature worktree isolation under a cost breaker), not
  leaked technology choices. No language, framework, module, or function name
  appears.
- **Constitution tension flagged, not hidden**: Principle V requires the analyze
  gate to halt on a Critical finding and forbids retrying a gate diversion past
  the human. The spec resolves this by ordering the loop strictly *before* the
  gate diverts (FR-007) and preserving the identical terminal state on
  exhaustion (FR-006), and it names the residual softening in Assumptions for
  explicit re-confirmation at `/speckit-plan` Constitution Check. This is the
  one item a reviewer should scrutinize before planning.
- **Zero clarification markers**: the two candidates — whether Critical is in
  scope, and the attempt-limit default — are settled by the user's own phrasing
  ("equals or worse than the configured, default is high") and by a
  conventional small default, both recorded as Assumptions.

### Validation notes (iteration 2 — after `/speckit-clarify`, all pass)

Five clarifications integrated; 16/16 items still pass. What changed and why it
matters for the checklist:

- **"Testable and unambiguous" strengthened.** FR-004 previously said "a small
  fixed number" — not testable. It now states default 2 with an accepted range
  of 1–5 (FR-004a), and FR-011 validates against that range instead of "positive
  whole number". FR-001a pins the full severity ordering the threshold floors
  against, so "at or above" is now mechanically checkable.
- **A contradiction was found and removed.** Making Medium and Low selectable
  exposed a conflict: the original FR-006 asserted every exhausted loop ends in
  a human-facing state, but Medium has no gate behavior today. FR-006 now hands
  the final findings back to the gate unchanged and explicitly forbids inventing
  a stop for a severity that has none, with a matching edge case and an updated
  US2 acceptance scenario.
- **Scope grew by one deliverable, deliberately.** FR-017 puts the governing-
  document amendment inside this feature rather than assuming it lands
  elsewhere. "Scope is clearly bounded" still passes — the amendment is named,
  bounded to the one principle, and forbidden from weakening other gates.
- **Two invisible-cost gaps closed.** FR-009b (dedicated cost estimate) and
  SC-008 exist because loop steps whose actual spend goes unreported would
  otherwise be accounted as free, quietly breaking the budget guarantee in
  FR-009/SC-006. FR-012a/FR-012b make the per-attempt evidence non-overwriting
  and keep the recorded pipeline position unchanged, so "success criteria are
  measurable" and FR-012's promise to a human reviewer are both real.
- **Still no implementation detail.** The added requirements name a model tier
  only by reference to the analyze phase's existing configured model, not by
  product name, and describe records by their content rather than file naming.

### Validation notes (iteration 3 — second `/speckit-clarify` pass, all pass)

Two further clarifications integrated (7 total); 16/16 items still pass.

- **The off-switch became a first-class per-run setting.** FR-010 previously
  said only that an operator "can disable the loop" — silent on scope, default,
  and lifetime. It now states a per-run on/off setting defaulting to on, with
  FR-010b fixing all three settings for the run's lifetime and FR-010c
  forbidding them from leaking into the next run. That last one is not
  hypothetical: this project has already shipped a launch toggle that wrote
  itself back into global state and silently became the following run's default.
- **Scope grew a second time, deliberately.** FR-010d–f put the three settings
  in the operator console's launch form, so console work is in scope. "Scope is
  clearly bounded" still passes because the console surface is named exactly —
  the launch form plus the loop's progress display (FR-013) — and the Assumptions
  restate that the console must not become a second source of truth.
- **One ambiguity the new scope created, closed.** With "all three settings" in
  the launch form, the separate model override from iteration 2 was left
  homeless. FR-009a now says explicitly that it is configuration-level and not a
  launch-form control.
- **Acceptance scenarios renumbered.** US3 now carries nine scenarios in file
  order; the insertions did not leave a broken sequence.
- **Testability held.** Each new requirement has a matching scenario: defaults
  (US3-8), off-run equivalence (US3-3, SC-007a), no forward leak (US3-6),
  immutability mid-run (US3-7), and form-level validation (US3-9).
