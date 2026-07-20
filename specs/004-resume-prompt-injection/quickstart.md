# Quickstart: Operator prompt injection at the resume phase

Validation guide proving guidance reaches exactly the resumed phase and no
other. All scenarios are pure unit tests — no CLI, worktree, or network.

## Prerequisites

- Toolchain via mise (`.tool-versions` pins `1.20.2-otp-28`):
  ```bash
  mise exec -- mix deps.get
  mise exec -- mix compile        # warnings_as_errors is ON — must be clean
  ```
- Reference: [contracts/phase_request_build.md](./contracts/phase_request_build.md) (guarantees G1–G6),
  [data-model.md](./data-model.md) (`resume_prompt_for/2`).

## Run the feature's tests

```bash
mise exec -- mix test test/speckit_orchestrator/phase_request_test.exs
mise exec -- mix test test/speckit_orchestrator/actions/run_feature_phase_test.exs
mise exec -- mix test        # full suite stays green (SC-003 regression guard)
```

## Scenario 1 — Guidance appended at the resume phase (G1, US1 AS-1)

Build a request with a non-blank `:resume_prompt` and assert the trailing
section is present.

- **Setup**: any `%Feature{}`, `phase = :clarify`, `opts = [resume_prompt: "resolved: use integer cents"]`.
- **Run**: `req = PhaseRequest.build(feature, :clarify, opts)`.
- **Expect**: `String.ends_with?(req.prompt, "\n\n---\nOperator guidance (resume): resolved: use integer cents")` is `true`, and the clarify base prompt is the unchanged prefix.

## Scenario 2 — Byte-identical when blank / absent (G2, FR-003, SC-003)

- **Setup**: `base = PhaseRequest.build(feature, :plan)`.
- **Run**: build again for each `resume_prompt ∈ {nil, "", "   ", "\n\t"}`.
- **Expect**: every resulting `prompt` equals `base.prompt` exactly (no marker, no separator).

## Scenario 3 — Other RunRequest fields unchanged (G4, FR-007)

- **Setup**: same phase, with and without a non-blank `:resume_prompt`.
- **Expect**: `model`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `max_turns`, `cwd`, `session_id` are equal across both; only `prompt` differs.

## Scenario 4 — Injected only at the resume phase (G5, US2 AS-1)

Drive `resume_prompt_for/2` (via `RunFeaturePhase`, or a direct unit of the
helper) over a multi-phase run.

- **Setup**: agent state with `resume_phase = :clarify`, `resume_prompt = "use REST, not GraphQL"`.
- **Run**: compute the passed opt for each phase in `specify, clarify, plan, tasks, analyze, implement`.
- **Expect**: only `:clarify` yields the guidance in its built prompt; every other phase's built prompt contains no occurrence of `"use REST, not GraphQL"`.

## Scenario 5 — Fresh run is clean (G2 + G5, SC-003)

- **Setup**: agent state with `resume_phase = nil`, `resume_prompt = nil`.
- **Expect**: for every phase, the passed opt is `nil` and the built prompt is byte-identical to pre-feature output.

## Scenario 6 — Retry re-injects (G6, FR-006, SC-004)

- **Setup**: `resume_phase = :analyze`, non-blank `resume_prompt`.
- **Run**: compute the opt for `:analyze` twice (simulating a transient retry before the pipeline advances).
- **Expect**: both computations return the same non-nil guidance; the built prompt carries the section on each, with no extra operator input.

## Done when

- [X] `mix compile` clean under `warnings_as_errors`.
- [X] Scenarios 1–6 pass.
- [X] Full suite green — no existing per-phase prompt test regresses (SC-003).
