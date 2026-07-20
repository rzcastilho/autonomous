# Implementation Plan: FeatureRunner Resume Entry Point

**Branch**: `003-resume-entry-point` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-resume-entry-point/spec.md`

## Summary

Let `FeatureRunner.run/2` start the pipeline at an arbitrary phase with
step numbering aligned to that phase's position in `Pipeline.phases/0`, and
thread a fixed `resume_phase` anchor plus an optional `resume_prompt` through
agent state for a later prompt-injection feature to consume. The mechanical
core of mid-pipeline resume: a halted/escalated feature restarts at exactly
the phase it stopped at, skipping already-completed phases. Achieved with one
new pure `Pipeline.step_of/1` helper, two new `run/2` opts, and two new
`InitFeature`/`FeatureAgent` state fields — no CLI, harness, or worktree
changes.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned `.tool-versions`; run via `mise exec --`)

**Primary Dependencies**: Jido/OTP (`Jido.Agent`, `Jido.AgentServer`); pure core has no external deps

**Storage**: N/A — state lives in agent process; no persistence added by this feature

**Testing**: ExUnit (`mise exec -- mix test`); existing `feature_runner_test.exs` FakeSDK seam + `pipeline_test.exs`

**Target Platform**: BEAM / Linux+macOS dev

**Project Type**: Single Elixir library (control plane)

**Performance Goals**: N/A — a run-start branch and a list index lookup; no hot path

**Constraints**: `warnings_as_errors` ON; pure core coverage must stay >90%; `Pipeline` MUST remain side-effect free (Principle I)

**Scale/Scope**: 7-phase pipeline; ~4 files touched (`pipeline.ex`, `feature_runner.ex`, `actions/init_feature.ex`, `feature_agent.ex`) plus tests

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Pure Core, Isolated Contracts** — PASS. `step_of/1` is a pure wrapper over
  `phases/0` + `Enum.find_index`, added to `Pipeline` (pure module). No CLI /
  harness / Jido dependency introduced into the decision surface. `run/2` reads
  the start phase from opts and passes it in — the pure layer still receives its
  inputs as arguments.
- **II. Fail Loud at Boundaries** — PASS (bounded). Invalid-phase validation is
  explicitly the caller's responsibility (spec Assumptions; breakdown out-of-scope).
  `step_of/1` returns `nil` for an unknown phase via `find_index`; this feature
  does not add silent inward-carrying of bad state — the default paths (`start_phase`
  absent → `Pipeline.first()`) are total. No new parser/loader boundary.
- **III. Least-Privilege Containment** — N/A. No CLI invocation, tool permissions,
  or scope-guard surface changes.
- **IV. Cost-Bounded Autonomy** — PASS (unaffected). The existing drain-don't-kill
  breaker check in `loop/7` is untouched; resume starts the same loop later.
- **V. Human-in-the-Loop Escalation** — PASS (supportive). This is the mechanism a
  human uses after a `:escalated`/`:halted` divert to re-run from the stop phase;
  it complements `resolve/1` (worktree reuse) rather than bypassing any gate. Gates
  still fire normally from the resumed phase onward.

**Quality gates**: coverage on `Pipeline.step_of/1` and the new `run/2` branch via
unit tests through the existing seam; no `--include integration` needed (hermetic).

No violations → Complexity Tracking omitted.

## Project Structure

### Documentation (this feature)

```text
specs/003-resume-entry-point/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── resume-entry.md  # Phase 1 output — function contracts
└── tasks.md             # /speckit-tasks output (not created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── pipeline.ex                    # + step_of/1 (pure)
├── feature_runner.ex              # run/2: read :start_phase + :resume_prompt opts;
│                                  #   start loop/7 at start_phase, step_of(start_phase)
├── feature_agent.ex               # + resume_phase, resume_prompt state fields
└── actions/
    └── init_feature.ex            # schema + seed: phase, resume_phase, resume_prompt

test/speckit_orchestrator/
├── pipeline_test.exs              # + step_of/1 index cases (all 7 phases)
└── feature_runner_test.exs        # + start_phase resume case; default no-regression case
```

**Structure Decision**: Single Elixir library, existing layout. The pure helper
lands in `Pipeline` (Principle I keeps it out of the runner). Runner and action
carry the new opts/state; the agent schema gains two nullable fields. No new
modules, directories, or dependencies.

## Notes on current code (grounding)

The breakdown doc's line references predate features 001/002 landing; the plan
tracks the current tree:

- `feature_runner.ex:76` already calls `loop(pid, feature, Pipeline.first(), 1, …)`
  — the hardcoded start to replace with `start_phase` / `step_of(start_phase)`.
- `actions/init_feature.ex:19-29` seeds `phase: Pipeline.first()` with schema
  `feature`/`worktree`/`ledger` — extend schema with `phase`/`resume_phase`/
  `resume_prompt`, seed all three.
- `feature_agent.ex:22-35` schema has no `resume_phase`/`resume_prompt` — add both
  as `[type: :atom/:string, default: nil]`.
- Tests use a global-swapped `FakeSDK` (not an injected runner fun); the resume
  case sets `start_phase:` on `run/2` and asserts the transcript step number +
  starting phase via the telemetry/transcript path already exercised.
