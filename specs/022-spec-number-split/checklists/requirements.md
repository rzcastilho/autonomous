# Specification Quality Checklist: Spec Number Split

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-03
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

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`

### Validation record

Two iterations were run against the criteria above.

**Iteration 1 findings (fixed in the spec):**

- *No implementation details* — the first draft named source modules and functions
  (`SpecDir.candidates/2`, `Worktree.commit`'s `:noop`, `TaskPlan.load`,
  `FeatureRunner`) in the requirements. Those are the *how*. Rewritten as
  behavioural statements: "resolution of a named artifact", "a checkpoint that
  commits nothing", "the implementation step falls back to its unstructured plan".
  The originating defect is still described concretely enough to reproduce, but in
  terms of observable behaviour rather than call sites.
- *Success criteria technology-agnostic* — an early criterion measured a schema
  migration. Replaced by SC-005, which measures the operator-visible outcome
  (records stay readable, nothing dropped).

**Iteration 2 findings (fixed in the spec):**

- *Testable and unambiguous* — FR-015 originally said the check applies "where
  appropriate". Tightened to "the artifact-producing phases only", with the
  complementary edge case listed under Edge Cases.
- *Scope bounded* — added the closing assumption that cleaning up spec directories
  already present in a target repository is out of scope, so the reader cannot
  mistake this for a data-repair feature.

**Deliberate judgment calls, recorded rather than clarified:**

- Allocation reads the *stack base* the worktree is created from, not the target's
  default branch. Stacked features must see the directory the previous feature just
  created; reading the default branch would hand two features in one run the same
  number. Recorded as an assumption.
- Allocation is highest-plus-one, not gap-filling. Reusing a deleted feature's
  number would point a new feature at a name that history already attributes to
  another feature.
- Pre-change records are backfilled rather than refused. Constitution Principle II
  permits a refusal migration only for a recorded clean break; here the old value is
  known and true (those features built in a directory named for their wave number),
  so a transform records fact and a refusal would destroy readable history for no
  gain.
- No `[NEEDS CLARIFICATION]` markers were raised. The three candidate ambiguities
  (allocation base, gap policy, legacy records) all had a defensible default whose
  alternative would be strictly worse, so each was decided and documented here
  instead of spending a clarification slot.
