# Implementation Plan: Single-Spec Run Mode

**Branch**: `spec/001-single-spec-run` | **Date**: 2026-07-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-single-spec-run/spec.md`

## Summary

Add a first-class operator entry point that drives **exactly one** feature
through the full Spec Kit pipeline (`specify → clarify → plan → tasks → analyze →
implement → converge`) from a **free-text description only** — no breakdown
backlog, no prerequisite wiring. The orchestrator auto-assigns the feature id and
derives its slug, materializes a one-off breakdown **seed file** inside the
feature worktree so the existing `specify` phase reads it unchanged, and runs the
feature as a **wave of one** through the existing `Coordinator`. All safety
behavior (clarify/analyze gates, cost breaker drain-not-kill, write containment,
durable transcripts, worktree isolation, kept-on-non-done) is inherited by reuse,
not reimplemented.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned via `.tool-versions`; run
through `mise exec --`). `warnings_as_errors` is on.

**Primary Dependencies**: Jido/OTP (control plane), `jido_harness` + `jido_claude`
(`:claude` provider wrapping the `claude` CLI; pinned to GitHub SHAs), `telemetry`.

**Storage**: Filesystem + git only — per-feature git worktrees on
`feature/NNN-slug` branches, a materialized breakdown seed file, durable
per-phase transcripts under `<repo>/.speckit-transcripts`. No database.

**Testing**: ExUnit (`mise exec -- mix test`). The existing injected seams
(`:runner`, `:executor`, `:publisher`, `:features`, `:ledger`) let the new path
be unit-tested with no CLI, no worktree, no `gh`. Real-harness paths stay behind
`--include integration`.

**Target Platform**: BEAM (single OTP application).

**Project Type**: Single project — an Elixir control-plane library with an `iex`
operator facade. No frontend/mobile.

**Performance Goals**: N/A — a single-feature run; latency is dominated by the
Claude CLI phases, unchanged by this feature.

**Constraints**: Reuse the existing feature-running machinery (Feature, Worktree,
FeatureRunner, Coordinator, Ledger, Release, PhaseRequest) unchanged wherever
possible; keep pure logic side-effect free; `>90%` coverage on new pure code;
zero compiler warnings.

**Scale/Scope**: One feature per run; effective in-flight cap of one.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution v1.0.0.

| Principle | Gate | Verdict |
|-----------|------|---------|
| I. Pure Core, Isolated Contracts | id/slug derivation and description validation are pure functions; all IO (seed write, worktree, git) lives in the runner/facade boundary, never in pure modules. No new dependency from pure logic on the CLI/harness/Jido. | PASS |
| II. Fail Loud at Boundaries | Empty/whitespace description rejected at the facade entry with a clear error and no partial run; id/slug assignment deterministic and non-clobbering; no silent fallback. | PASS |
| III. Least-Privilege Containment (Fail-Closed) | Reuses `Worktree.create` scaffold assertion and the unchanged per-phase `PhaseRequest` permissions; the seed file is written **inside the worktree only**. No new privilege surface. | PASS |
| IV. Cost-Bounded Autonomy (Drain, Don't Kill) | Reuses `Ledger` + `Coordinator` + `FeatureRunner` breaker/drain path verbatim; no new spend path. | PASS |
| V. Human-in-the-Loop Escalation | Reuses the clarify gate (`## NEEDS HUMAN`), analyze gate (constitution Critical), and kept-on-non-done worktree retention unchanged. | PASS |

**Initial Constitution Check: PASS.** No violations; Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-single-spec-run/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── run_spec.md      # Facade command + seed-file + runner-seam contract
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit-specify)
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── ../speckit_orchestrator.ex # facade — ADD run_spec/2 + seed-writing runner
├── single_spec.ex             # NEW pure module: build a Feature from a description
│                              #   (auto id, derived slug, seed path + contents)
├── feature.ex                 # reused unchanged (id/slug/path/prereqs/status)
├── worktree.ex                # reused unchanged (create/locate/commit/remove)
├── feature_runner.ex          # reused unchanged (drives the pipeline)
├── coordinator.ex             # reused unchanged (wave of one)
├── release.ex                 # reused unchanged (no-prereq → released now)
├── ledger.ex                  # reused unchanged (breaker/drain)
└── phase_request.ex           # reused unchanged (specify reads the seed via breakdown_ref)

test/speckit_orchestrator/
├── single_spec_test.exs       # NEW pure unit tests (id/slug/seed, validation)
└── run_spec_test.exs          # NEW facade tests via injected :runner/:features seams
```

**Structure Decision**: Single Elixir project. One new pure module
(`SingleSpec`) plus a thin facade function and a seed-writing runner wrapper in
the existing `SpeckitOrchestrator` module. No changes to the pipeline, the
request builder, the worktree manager, or the coordinator.

## Complexity Tracking

> No Constitution Check violations. This section is intentionally empty.
