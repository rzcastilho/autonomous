# Research: FeatureRunner Resume Entry Point

No open `NEEDS CLARIFICATION` items — the spec and breakdown doc pinned scope
tightly. This file records the small design decisions taken against the current
codebase.

## Decision 1: `step_of/1` lives in `Pipeline` as a pure wrapper

- **Decision**: Add `Pipeline.step_of(phase) :: pos_integer()` returning the
  1-based index of `phase` within `phases/0` (`:specify` → 1 … `:converge` → 7),
  implemented as `Enum.find_index(@ordered, &(&1 == phase)) + 1`.
- **Rationale**: Principle I keeps ordering knowledge in the pure `Pipeline`
  module, not duplicated in the runner. `phases/0` and the `@ordered` list already
  exist (`pipeline.ex:35,62`); this is a thin, side-effect-free wrapper — unit
  testable with no CLI/agent.
- **Alternatives considered**:
  - Compute the index inline in `FeatureRunner` — rejected: leaks phase-ordering
    into the impure runner, and can't be unit-tested in `pipeline_test.exs`.
  - Store step alongside phase in a map constant — rejected: redundant with the
    ordered list, another thing to keep in sync.

## Decision 2: Invalid start phase is the caller's contract, not validated here

- **Decision**: `step_of/1` returns `nil + 1`-style failure only for an unknown
  phase; the feature does not add guarding. Callers (the future `resolve/2` /
  operator facade, feature 004) pass a phase from `Pipeline.phases/0`.
- **Rationale**: Spec Assumptions and the breakdown's out-of-scope both assign
  validation to the caller. Adding a raise here would be scope creep and the only
  producer of `start_phase` today is internal. Keeps the change minimal.
- **Alternatives considered**:
  - Raise `ArgumentError` on unknown phase (fail-loud, Principle II) — deferred:
    reasonable, but out of this feature's scope; will be reconsidered when the
    operator facade (004) accepts human/CLI input at a real boundary.
  - Silent fallback to `Pipeline.first()` — rejected: masks a caller bug, exactly
    the silent-inward-carry Principle II forbids.

## Decision 3: `resume_phase` fixed, `phase` advances

- **Decision**: `InitFeature` seeds `phase: params.phase` (advances with the loop)
  and `resume_phase: params.phase` (never mutated after init). `resume_prompt`
  seeded from params, default `nil`.
- **Rationale**: Feature 003-followup (prompt injection) needs to know where the
  run resumed *from* even after the loop has moved past it. The runner's `loop/7`
  already threads the active `phase` as a local arg and writes it to
  `agent.state.phase` via `RunFeaturePhase`; `resume_phase` must be a separate,
  immutable state field so it survives that advance.
- **Alternatives considered**:
  - Reuse `phase` alone — rejected: it changes every phase; the anchor would be
    lost after the first `{:cont, next}`.
  - Derive resume point from `history` — rejected: fragile, and empty on a fresh
    resume before any phase runs.

## Decision 4: Test through the existing FakeSDK seam, not a new injected runner

- **Decision**: Extend `feature_runner_test.exs` (global-swapped `FakeSDK`) with a
  resume case that passes `start_phase:` to `run/2`, plus a default-behavior
  no-regression case. Add `step_of/1` index cases to `pipeline_test.exs`.
- **Rationale**: The breakdown doc said "inject fake runners/agents"; the real
  current seam is a `FakeSDK` swapped via app env driving the real agent. Starting
  at `:plan` with that seam exercises the true `run/2` → `loop/7` → transcript path
  and proves step numbering end-to-end without real CLI. Hermetic; no
  `--include integration`.
- **Alternatives considered**:
  - Add a `:runner` injection fun to `run/2` — rejected: `run/2` drives the agent
    directly (there is no runner seam at this layer); the FakeSDK seam already
    covers it and matches the acceptance criteria.
