# Implementation Plan: Operator prompt injection at the resume phase

**Branch**: `004-resume-prompt-injection` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-resume-prompt-injection/spec.md`

## Summary

On resume, the operator's free-text guidance must reach exactly the phase being
restarted — appended to that phase's assembled prompt — and no other phase. The
approach is strictly additive and lives at two seams already present in the
codebase: `PhaseRequest.build/3` gains an optional `:resume_prompt` opt that,
when non-blank, appends a clearly delimited trailing section to the built
prompt; and `Actions.RunFeaturePhase` computes that opt as
`state.resume_prompt` only when `phase == state.resume_phase`, `nil` otherwise.
Blank guidance (`nil`, `""`, whitespace-only) leaves the prompt byte-identical
to today's output. No change to model routing, per-phase permissions, or
session continuity.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned in `.tool-versions`; run via `mise exec --`)

**Primary Dependencies**: Jido/OTP (control plane), `jido_harness` + `jido_claude` (data plane, pinned to GitHub SHAs). No new dependency.

**Storage**: N/A — resume state (`resume_phase`, `resume_prompt`) lives in `FeatureAgent` state, seeded by feature 002/003; this feature only reads it.

**Testing**: ExUnit (`mise exec -- mix test`); pure-core unit tests, no CLI/worktree needed for the injection logic.

**Target Platform**: BEAM / headless `claude` CLI

**Project Type**: Single project (Elixir library + OTP app)

**Performance Goals**: N/A — string append on an already-assembled prompt; negligible.

**Constraints**: `warnings_as_errors` is ON — a compiler warning fails the build. Change MUST be strictly append-only so existing per-phase prompt tests stay byte-valid when no `resume_prompt` is passed (FR-003, SC-003).

**Scale/Scope**: Two files touched (`phase_request.ex`, `actions/run_feature_phase.ex`) plus tests. No new module.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | ✅ `PhaseRequest.build/3` stays side-effect free — the guidance is an argument passed in, not read inside the builder. The decision "is this the resume phase?" is a pure comparison (`phase == state.resume_phase`) made upstream in the action. No new CLI/harness/Jido coupling in pure logic. |
| **II. Fail Loud at Boundaries** | ✅ N/A-neutral. No new input contract to validate; blank guidance is a defined, benign no-op (FR-003), not a silent papering-over of malformed data. |
| **III. Least-Privilege Containment (Fail-Closed)** | ✅ Unaffected — FR-007 forbids altering per-phase tool permissions; `permissions(phase)` is untouched. |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | ✅ Unaffected — no change to `Ledger`, cost accounting, or wave release. |
| **V. Human-in-the-Loop Escalation** | ✅ Directly serves it — this is the mechanism by which a human's resolution reaches the resumed phase so it does not re-escalate blind. Injection is scoped to the one phase that needed human help; downstream phases run clean (Story 2). |
| **Quality & Test Discipline** | ✅ mise toolchain, `warnings_as_errors`, pure-core unit tests through the existing seams. Byte-identical-when-blank is a testable invariant (SC-003). |

**Result**: PASS. No violations; Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/004-resume-prompt-injection/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── phase_request_build.md   # PhaseRequest.build/3 contract with :resume_prompt
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── phase_request.ex               # ADD :resume_prompt opt + append-only trailing section
└── actions/
    └── run_feature_phase.ex       # PASS resume_prompt_for(state, phase) into build/3

test/speckit_orchestrator/
├── phase_request_test.exs         # ADD: append when non-blank; byte-identical when blank
└── actions/
    └── run_feature_phase_test.exs # ADD: injected at resume_phase only; nil elsewhere
```

**Structure Decision**: Single Elixir project (existing). The feature is a
two-seam, append-only change — no new modules, no new directories. The pure
builder (`PhaseRequest`) holds the append; the action (`RunFeaturePhase`) holds
the per-phase gating decision, keeping the builder pure per Principle I.

## Complexity Tracking

> No Constitution Check violations. Section intentionally empty.
