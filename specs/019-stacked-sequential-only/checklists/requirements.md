# Specification Quality Checklist: Stacked Sequential Runs as the Only Behaviour

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-28
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

Three scope decisions were resolved with the operator before drafting, and are
recorded in the spec rather than left as clarification markers:

1. **Prerequisites are dropped entirely** — no parsing, no dependency graph, no
   cycle check. Numbering is the sole ordering input (FR-009, FR-010).
2. **The concurrency setting is removed entirely**, not pinned to one — it
   disappears from configuration, environment, run options, live edits, the
   console, and the recorded run shape (FR-006, FR-007, FR-008).
3. **Stop-on-first-non-completed is in scope** for this feature, not deferred
   (FR-014 – FR-017), because ordering guarantees are meaningless if the chain
   skips a broken link.

A clarification session on 2026-07-28 resolved five further decisions, recorded
in the spec's Clarifications section:

4. **No pre-change compatibility** — persistence is reset as part of shipping,
   so there is no migration path to build (FR-022, FR-023, SC-006).
5. **Ad-hoc features form their own "Ad-hoc" group**, ordered by creation time,
   running one at a time (FR-024 – FR-027).
6. **Ad-hoc features always root at the configured base branch** — they never
   stack and never advance the backlog chain (FR-028).
7. **A stopped run is parked**; the operator chooses at resolve time whether to
   continue it or end it, and the system never decides for them
   (FR-019 – FR-019c, SC-008).
8. **A parked run blocks new work** for its repository — a new run (backlog or
   ad-hoc) is refused, naming the parked run, rather than superseding it
   (FR-020a, FR-020b, SC-009).

Follow-ups deliberately left to planning, not gaps in the spec:

- Retiring prerequisites removes the load-time dangling-prereq and cycle
  guards. FR-012 (duplicate number) is their replacement as the backlog's
  fail-loud boundary; planning should confirm no other guard is lost.
- Parking is a new run state with its own lifecycle and refusal rule. Planning
  must reconcile it with the existing "a fresh run supersedes a prior in-flight
  run" behaviour, which FR-020a now overrides for parked runs specifically.
