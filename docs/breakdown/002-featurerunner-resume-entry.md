# 002 — FeatureRunner resume entry point

## Summary

Let the runner start the pipeline at an arbitrary phase (not just `specify`) with
correct step numbering, and carry a resume-prompt anchor through agent state.
This is the mechanical core of mid-pipeline resume.

## Context

`FeatureRunner.run/2` always starts `loop/7` at `Pipeline.first()`, step 1
(`feature_runner.ex:75`), and `InitFeature` always seeds `phase:
Pipeline.first()` (`actions/init_feature.ex:25`). There is no way to begin a run
partway through the pipeline, so resume is impossible today.

## User value

The runner can begin at a chosen phase and run to a terminal state — restarting a
halted feature at exactly the phase it stopped at, avoiding the cost and
clobber-risk of re-running `specify`. Also threads a `resume_phase` anchor and
`resume_prompt` through agent state for the prompt-injection feature (003) to
consume.

## Prerequisites

None.

## In scope

- `SpeckitOrchestrator.Pipeline.step_of/1` — the 1-based index of a phase within
  `phases/0` (`:specify` → 1 … `:converge` → 7). Used so resumed transcripts keep
  phase-aligned `NN-<phase>.md` filenames.
- `FeatureRunner.run/2`:
  - Read `:start_phase` (default `Pipeline.first()`) and `:resume_prompt`
    (default `nil`) from opts.
  - Pass both into the `"feature.init"` signal payload.
  - Start the loop at `start_phase` with `step = Pipeline.step_of(start_phase)`
    rather than the hardcoded `Pipeline.first(), 1`.
- `InitFeature` (`actions/init_feature.ex`): extend the schema with `phase:
  [default: Pipeline.first()]` and `resume_prompt: [default: nil]`; seed `phase:
  params.phase`, a fixed `resume_phase: params.phase`, and `resume_prompt:
  params.resume_prompt`. `resume_phase` stays fixed while `phase` advances with
  the loop.

## Out of scope

- Injecting the prompt into the phase request (feature 003) — `resume_prompt` is
  carried in state but not yet consumed.
- The `resume/2` operator facade (feature 004).

## Acceptance

- `Pipeline.step_of/1` returns the correct 1-based index for every ordered phase.
- With an injected fake runner/agent (no CLI), `run/2` called with `start_phase:
  :plan` starts the loop at `:plan`, step 3, and runs to a terminal state.
- Default `run/2` with no resume opts behaves exactly as today (starts at
  `:specify`, step 1) — no regression.
- Compile clean under `warnings_as_errors`; tests green.

## Technical notes

- `Pipeline.phases/0` and `Enum.find_index` are already available
  (`pipeline.ex:60-62`) — `step_of/1` is a thin wrapper.
- FeatureRunner's existing tests already inject fake runners/agents; extend those
  rather than introducing real CLI calls.
