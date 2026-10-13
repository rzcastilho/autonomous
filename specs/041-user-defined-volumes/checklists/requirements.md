# Specification Quality Checklist: User-Defined Persistent Volumes

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-13
**Feature**: [spec.md](../spec.md)

## Content Quality

- [X] No implementation details (languages, frameworks, APIs)
- [X] Focused on user value and business needs
- [X] Written for non-technical stakeholders
- [X] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [X] Requirements are testable and unambiguous
- [X] Success criteria are measurable
- [X] Success criteria are technology-agnostic (no implementation details)
- [X] All acceptance scenarios are defined
- [X] Edge cases are identified
- [X] Scope is clearly bounded
- [X] Dependencies and assumptions identified

## Feature Readiness

- [X] All functional requirements have clear acceptance criteria
- [X] User scenarios cover primary flows
- [X] Feature meets measurable outcomes defined in Success Criteria
- [X] No implementation details leak into specification

## Notes

- Open: FR-005 / Clarifications — location and owner of the volume declaration.
- Operator-facing identifiers (`scripts/autonomous reset-cache`, example variable
  names such as `CARGO_TARGET_DIR`) are kept on purpose: constitution Principle VII
  requires surfaces and docs to use the identifiers the operator types. No
  internal module, library or storage design is specified.

## Notes — T047 hand-run (2026-10-13)

`scripts/container-smoke.sh volumes` on macOS (uutils `timeout` + BSD-`script` shim), real docker:
all checks passed — persistence across stop/start and image rebuild (SC-001), clean host repo (SC-002),
1/5/20 volumes, cross-target isolation, five rejection classes with no container/volume (SC-003), reset
by name/all/idempotent/running-refusal/unknown name, `stop --purge`. Skipped: the end-to-end agent session
check (needs `SMOKE_AGENT=1`, spends cents). The "path dir is first on PATH" check was relaxed: `erlexec`
prepends its own `erts-*/bin` when the VM starts, so only `erts` entries may precede the volume's path dir.

