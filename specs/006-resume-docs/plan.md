# Implementation Plan: Resume Docs & Operator Runbook

**Branch**: `006-resume-docs` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-resume-docs/spec.md`

## Summary

Document the shipped `SpeckitOrchestrator.resume/2` mid-pipeline recovery flow in
`docs/runbook.md` alongside the existing `resolve/1` flow, update the `CLAUDE.md`
observability/operability paragraph to name mid-pipeline resume as shipped, and
purge every remaining "resume is a v2/future concern" framing from repository
markdown. Docs-only: no source code changes (the `resolve/1` docstring's "v2"
wording in `lib/speckit_orchestrator.ex` is explicitly out of scope). The
documented API surface must match the real `resume/2` signature so every runbook
example runs unmodified.

## Technical Context

**Language/Version**: Markdown documentation (repo pins Elixir 1.20.2-otp-28, but
no code is edited).

**Primary Dependencies**: The shipped `SpeckitOrchestrator.resume/2` facade
(features 001–005) — its public signature and options are the documented subject.

**Storage**: N/A (files edited in place: `docs/runbook.md`, `CLAUDE.md`, and any
other `.md` carrying stale framing).

**Testing**: Manual + `grep`-based verification (SC-003 zero-match search);
operator dry-read of the runbook resume section (SC-001); example-vs-signature
parity check against `lib/speckit_orchestrator.ex` (SC-002). No automated test
suite is added — this feature ships no code.

**Target Platform**: Repository documentation (rendered on GitHub / read in-repo).

**Project Type**: Documentation change to an existing single Elixir project.

**Performance Goals**: N/A.

**Constraints**: Docs-only — MUST NOT modify `lib/`, `test/`, or config. Every
documented `iex` call MUST match the shipped `resume/2` arity and option names
(`:from`, `:prompt`) exactly. Stale-reference scope is repo-wide `.md` files;
source-code docstrings are excluded.

**Scale/Scope**: Two files edited directly (`docs/runbook.md`, `CLAUDE.md`); a
repo-wide `.md` sweep confirms no third file needs a stale-framing fix (current
sweep: only `docs/runbook.md:281` carries "mid-pipeline resume is v2").

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The constitution governs the orchestrator control plane and enforcement pack.
This feature edits documentation only and adds no code path, so the code-facing
principles (I–IV) are not engaged. Relevant checks:

- **V. Human-in-the-Loop Escalation** — This feature *documents* the operator side
  of the escalate → fix → resume loop that Principle V mandates. It strengthens
  compliance (the human resolution path is now discoverable) and contradicts none
  of it. ✅ PASS
- **Quality & Test Discipline** — "no code" means `warnings_as_errors`, coverage,
  and the injected-seam rules are not triggered; no test regression is possible.
  Verification is grep/read-based per Success Criteria. ✅ PASS (N/A to code)
- **Development Workflow** — Spec-driven, feature-by-feature; this is the `plan`
  phase of feature 006 following the Spec Kit loop. ✅ PASS

No principle deviations → **Complexity Tracking is empty**.

## Project Structure

### Documentation (this feature)

```text
specs/006-resume-docs/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (the doc-surface "entities": resume/2 API + doc sections)
├── quickstart.md        # Phase 1 output (grep + operator-dry-read validation)
├── contracts/
│   └── resume-doc-surface.md   # Phase 1 output (exact signatures the docs must match — SC-002 anchor)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

No source code is created or modified. Files touched by the implementation phase
are documentation only:

```text
docs/
└── runbook.md           # ADD resume/2 recovery section; FIX line ~281 "resume is v2" framing
CLAUDE.md                # UPDATE observability/operability paragraph to name shipped resume/2

# Read-only reference (NOT edited — out of scope):
lib/speckit_orchestrator.ex   # resume/2 @doc is the source of truth for the documented signature;
                              # resolve/1 docstring "v2" wording stays (source docstrings excluded)
```

**Structure Decision**: No code structure. The unit of work is the operator
documentation set. The authoritative reference for every documented call is the
`resume/2` `@doc`/`@spec` in `lib/speckit_orchestrator.ex` (lines ~138–162);
`contracts/resume-doc-surface.md` freezes that surface so the runbook examples
and the code cannot silently drift (SC-002).

## Complexity Tracking

> No Constitution Check violations. Section intentionally empty.
