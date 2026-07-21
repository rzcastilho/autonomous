# 005 — Resume docs + operator runbook

## Summary

Document the human-in-the-loop mid-pipeline resume flow in the operator runbook
and update the codebase guide, which previously treated resume as not yet
implemented.

## Context

`docs/runbook.md` documented `resolve/1` (full re-run from `specify`) as the only
recovery path, and `CLAUDE.md` described mid-pipeline resume as not yet
implemented. Once `resume/2` ships (features 001-004), both need updating so
operators use the correct flow.

## User value

Operators have a documented, correct escalate → fix → resume recovery loop with
exact `iex` calls, and the codebase guide reflects shipped reality.

## Prerequisites

- 004 `resume/2` operator facade

## In scope

- `docs/runbook.md`: add the resume flow beside `resolve/1` — resolve the cause
  on the feature branch (edit + commit the artifacts), then
  `SpeckitOrchestrator.resume(id, prompt: "...")`. Explain restart-at-halted-phase
  semantics and when to reach for `:from` to override the start phase.
- `CLAUDE.md`: update the observability/operability paragraph — mid-pipeline
  resume is shipped (drop the old deferred-implementation framing).

## Out of scope

- Code changes.

## Acceptance

- The runbook documents the full escalate → fix → resume loop with the exact
  `iex` calls (`resolve/1` vs `resume/2`, and the `:from` / `:prompt` opts).
- No stale reference implying mid-pipeline resume is still unimplemented or
  deferred.
