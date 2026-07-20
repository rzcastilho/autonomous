# Quickstart: FeatureRunner Resume Entry Point

Validation guide proving the resume entry point works end-to-end. All commands
run through mise (pinned toolchain).

## Prerequisites

- Repo at `003-resume-entry-point` branch.
- `mise exec -- mix deps.get` already run.

## Build & test

```bash
mise exec -- mix compile          # MUST be clean under warnings_as_errors
mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs
mise exec -- mix test test/speckit_orchestrator/feature_runner_test.exs
mise exec -- mix test             # full suite green
```

## Scenario 1 — `step_of/1` index (unit, pure)

In `pipeline_test.exs`, assert every phase resolves to its 1-based position:

```elixir
for {phase, step} <- Enum.with_index(Pipeline.phases(), 1) do
  assert Pipeline.step_of(phase) == step
end
assert Pipeline.step_of(:specify) == 1
assert Pipeline.step_of(:converge) == 7
```

**Expected**: all pass. Contract: [contracts/resume-entry.md](./contracts/resume-entry.md).

## Scenario 2 — resume starts mid-pipeline (runner, FakeSDK seam)

In `feature_runner_test.exs`, using the existing global-swapped `FakeSDK`:

```elixir
result = FeatureRunner.run(feature, start_phase: :plan, notify: self())
```

**Expected**:
- Run begins at `:plan` (step 3), not `:specify`. Verify via the transcript
  filename `03-plan.md` being the first written (or the first `[:speckit, :phase]`
  telemetry event carrying `phase: :plan, step: 3`).
- Run proceeds through `:tasks … :converge` to a terminal state.
- `result.status` is a terminal atom (`:done` on the happy scenario).

## Scenario 3 — default behavior unchanged (no-regression)

```elixir
result = FeatureRunner.run(feature, notify: self())   # no :start_phase
```

**Expected**: begins at `:specify`, step 1; first transcript `01-specify.md`;
identical to pre-feature behavior. Existing happy-path assertions still hold.

## Scenario 4 — resume prompt carried in state

Start at a chosen phase with a resume prompt and confirm the anchor is fixed:

```elixir
FeatureRunner.run(feature, start_phase: :plan, resume_prompt: "pick up at plan")
# after feature.init: agent.state.resume_phase == :plan, resume_prompt == "pick up at plan"
# after loop advances: state.phase == :tasks/…  while  resume_phase stays :plan
```

**Expected**: `resume_phase` stays `:plan` as `phase` advances; `resume_prompt`
present, unused by this feature.

## Done signal

- `mix compile` clean (no warnings).
- `pipeline_test.exs` and `feature_runner_test.exs` green including the new cases.
- Full `mix test` green — no regression.
