---

description: "Task list for FeatureRunner Resume Entry Point"
---

# Tasks: FeatureRunner Resume Entry Point

**Input**: Design documents from `/specs/003-resume-entry-point/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/resume-entry.md](./contracts/resume-entry.md), [quickstart.md](./quickstart.md)

**Tests**: Included — quickstart.md mandates one automated scenario per acceptance criterion; tasks below implement that suite through the existing `FakeSDK` seam (no new test infra).

**Organization**: Tasks are grouped by user story (spec.md) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps to spec.md user stories (US1, US2, US3)

## Path Conventions

Single-project Elixir/OTP layout (plan.md → Project Structure):
- `lib/speckit_orchestrator/pipeline.ex` — pure `step_of/1` addition
- `lib/speckit_orchestrator/feature_runner.ex` — `run/2` opts + `loop/7` start
- `lib/speckit_orchestrator/feature_agent.ex` — schema fields
- `lib/speckit_orchestrator/actions/init_feature.ex` — schema + seed
- `test/speckit_orchestrator/pipeline_test.exs` — `step_of/1` cases
- `test/speckit_orchestrator/feature_runner_test.exs` — resume/no-regression/anchor cases

---

## Phase 1: Setup

Not applicable — this feature extends the existing OTP app (no new project, no new
mix dependency, no new test infra beyond the existing `FakeSDK` seam). Proceed
directly to Foundational.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure step-numbering primitive (FR-001) that `run/2`'s resume
threading (US1) and the anchor's step label (US3) both build on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T001 [P] In `lib/speckit_orchestrator/pipeline.ex`: add
      `@spec step_of(phase()) :: pos_integer()` /
      `def step_of(phase), do: Enum.find_index(@ordered, &(&1 == phase)) + 1`,
      placed after `first/0` (around line 66). Pure, no new deps — satisfies
      contracts/resume-entry.md's `step_of/1` contract table exhaustively for all
      7 phases.
- [X] T002 [P] In `test/speckit_orchestrator/pipeline_test.exs`: add a test that
      iterates `Enum.with_index(Pipeline.phases(), 1)` and asserts
      `Pipeline.step_of(phase) == step` for every pair, plus explicit boundary
      assertions `Pipeline.step_of(:specify) == 1` and
      `Pipeline.step_of(:converge) == 7` (quickstart Scenario 1, FR-001/FR-003).

**Checkpoint**: `mise exec -- mix compile` clean; `pipeline_test.exs` green with
the new `step_of/1` cases.

---

## Phase 3: User Story 1 - Resume a halted feature at its stopped phase (Priority: P1) 🎯 MVP

**Goal**: `FeatureRunner.run/2` accepts a `:start_phase` opt and begins the loop
there, with step numbering matching that phase's position in `Pipeline.phases/0`.

**Independent Test**: Start a run with `start_phase: :plan` via the existing
`FakeSDK` seam; confirm the run begins at `:plan` (step 3), writes
`03-plan.md` first, and proceeds to a terminal state.

### Tests for User Story 1

> Write first; must fail (loop still starts at `Pipeline.first()`/step 1
> regardless of opts) before T005/T006.

- [X] T003 [US1] In `test/speckit_orchestrator/feature_runner_test.exs`: add a
      test that calls `FeatureRunner.run(feature(), start_phase: :plan, worktree:
      scaffolded_worktree(), notify: self())` and asserts the run reaches a
      terminal `:done` (happy scenario) with `.speckit_logs/03-plan.md` present
      and `.speckit_logs/01-specify.md` / `02-clarify.md` **absent** — proving the
      run began at `:plan`, not `:specify` (spec.md US1 acceptance scenario 1).
- [X] T004 [US1] In the same file: attach the `[:speckit, :phase, :stop]`
      telemetry handler (mirroring the pattern at
      `feature_runner_test.exs:358-384`) and assert the **first** received event's
      metadata is `%{phase: :plan, step: 3, ...}` — proving step numbering matches
      the phase's actual position, not step 1 (spec.md US1 acceptance scenario 2,
      FR-003).

### Implementation for User Story 1

- [X] T005 [US1] In `lib/speckit_orchestrator/actions/init_feature.ex`: add
      `phase: [type: :atom, default: nil]` to the schema; in `run/2`, resolve
      `phase = params.phase || Pipeline.first()` and seed `phase: phase` (replaces
      the current hardcoded `phase: Pipeline.first()` at line 25).
- [X] T006 [US1] In `lib/speckit_orchestrator/feature_runner.ex`: in `run/2`, read
      `start_phase = Keyword.get(opts, :start_phase, Pipeline.first())`; pass
      `phase: start_phase` into the `"feature.init"` call's data map (line 71);
      replace the hardcoded `loop(pid, feature, Pipeline.first(), 1, ...)` at
      line 76 with
      `loop(pid, feature, start_phase, Pipeline.step_of(start_phase), timeout, ledger, worktree)`.

**Checkpoint**: User Story 1 is fully functional and testable independently — a
run started at any phase begins there with the correct step number and runs to
a terminal state.

---

## Phase 4: User Story 2 - Default behavior is unchanged for fresh features (Priority: P1)

**Goal**: A run started with no resume opts behaves byte-for-byte as before this
feature — begins at `:specify`, step 1.

**Independent Test**: Start a run with no `:start_phase`/`:resume_prompt` and
confirm it begins at `:specify`, step 1, identical to pre-feature behavior.

### Tests for User Story 2

- [X] T007 [US2] In `test/speckit_orchestrator/feature_runner_test.exs`: add a
      test that calls `FeatureRunner.run(feature(), worktree:
      scaffolded_worktree(), notify: self())` with no `:start_phase` and asserts,
      via the `[:speckit, :phase, :stop]` telemetry handler, the first event is
      `%{phase: :specify, step: 1, ...}` and `.speckit_logs/01-specify.md` is the
      first transcript written — an explicit no-regression assertion distinct
      from the existing happy-path test at line 168 (spec.md US2 acceptance
      scenario 1, FR-004, SC-002).

### Implementation for User Story 2

No new implementation — T006's `Keyword.get(opts, :start_phase,
Pipeline.first())` default and T005's `params.phase || Pipeline.first()` default
already guarantee the pre-feature path when no opts are supplied. This story is
test-only, proving the shared implementation from US1 does not regress the
default case.

**Checkpoint**: User Stories 1 AND 2 both work independently — resume starts at
the requested phase, and the no-resume path is unchanged.

---

## Phase 5: User Story 3 - Resume carries a stable anchor for future prompt injection (Priority: P2)

**Goal**: `resume_phase` and `resume_prompt` are threaded into agent state at
init; `resume_phase` stays fixed at the starting phase as the loop's `phase`
advances.

**Independent Test**: Start a run with `start_phase: :plan` and a
`resume_prompt`, inspect state after `feature.init` (`resume_phase == :plan`,
`resume_prompt` set), then confirm `resume_phase` still reads `:plan` once the
loop has advanced to `:tasks`.

### Tests for User Story 3

- [X] T008 [US3] In `test/speckit_orchestrator/feature_runner_test.exs`: add a
      test using a scenario/hook that inspects agent state mid-run (e.g. a
      `:test_artifact_hook` or direct `AgentServer` inspection point) to assert
      that after starting with `start_phase: :plan, resume_prompt: "pick up at
      plan"`, the agent's `resume_phase` equals `:plan` and `resume_prompt`
      equals `"pick up at plan"` once `phase` has advanced past `:plan` to
      `:tasks` — proving the anchor is fixed while the active phase moves
      (spec.md US3 acceptance scenario 1, FR-006).

### Implementation for User Story 3

- [X] T009 [US3] In `lib/speckit_orchestrator/feature_agent.ex`: add
      `resume_phase: [type: :atom, default: nil]` and
      `resume_prompt: [type: :string, default: nil]` to the schema (after
      `phase`, around line 26).
- [X] T010 [US3] In `lib/speckit_orchestrator/actions/init_feature.ex`: add
      `resume_prompt: [type: :string, default: nil]` to the schema; in `run/2`,
      seed `resume_phase: phase` (same resolved value as T005's `phase` seed) and
      `resume_prompt: params.resume_prompt` into the returned state map.
- [X] T011 [US3] In `lib/speckit_orchestrator/feature_runner.ex`: in `run/2`, read
      `resume_prompt = Keyword.get(opts, :resume_prompt)` and add it to the
      `"feature.init"` call's data map alongside `phase` (T006's edit at line 71).

**Checkpoint**: All three user stories are independently functional — resume
starts correctly, the default path is unchanged, and the resume anchor survives
loop advancement for a future prompt-injection feature to consume.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T012 [P] Run `mise exec -- mix compile` and confirm a clean build under
      `warnings_as_errors` (no unused schema fields or dead branches from
      T005/T009/T010).
- [X] T013 Run `mise exec -- mix test` (full suite) and confirm no regression —
      all existing `feature_runner_test.exs` and `pipeline_test.exs` cases still
      pass alongside the new T002-T004/T007-T008 cases.
- [X] T014 Walk through quickstart.md's four scenarios end-to-end (step_of index,
      mid-pipeline resume, default no-regression, anchor fixed) confirming the
      documented expected output matches.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: N/A — no tasks.
- **Foundational (Phase 2)**: No dependencies — BLOCKS all user stories (US1's
  loop-start and US3's step-numbering both call `Pipeline.step_of/1`).
- **User Story 1 (Phase 3)**: Depends on Foundational only. MVP.
- **User Story 2 (Phase 4)**: Depends on Foundational + US1 (T006's default-opt
  handling); adds no new implementation, only a regression test.
- **User Story 3 (Phase 5)**: Depends on Foundational + US1 (T005's resolved
  `phase` value, T006's `"feature.init"` call site edit).
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### Within Each User Story

- Tests written first, expected to fail, then implementation (T003-T004 →
  T005-T006; T007 → none, US2 reuses US1's implementation; T008 → T009-T011).
- Story complete before moving to the next priority tier (P1 → P1 → P2).

### Parallel Opportunities

- T001 and T002 (Foundational) — different files.
- T003 and T004 (US1 tests) both edit `feature_runner_test.exs` — not marked
  `[P]`, add as sequential edits to one file.
- T005 (`init_feature.ex`) and T006 (`feature_runner.ex`) touch different files
  but T006's `"feature.init"` data map depends on T005's schema accepting
  `phase:` — implement T005 first, or land both together since neither compiles
  meaningfully alone.
- T009 (`feature_agent.ex`), T010 (`init_feature.ex`), and T011
  (`feature_runner.ex`) each touch a different file — T009 has no dependency on
  the others; T010 and T011 both build on T005/T006's `phase` threading already
  in place.
- T012 (compile check) can run alongside review of T013/T014, though T013/T014
  are validation steps best run after T012 passes.

---

## Parallel Example: Foundational

```bash
# Launch both Foundational tasks together (different files):
Task: "Add step_of/1 to lib/speckit_orchestrator/pipeline.ex"
Task: "Add step_of/1 index cases to test/speckit_orchestrator/pipeline_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (`step_of/1`).
2. Complete Phase 3: User Story 1 (`start_phase` threading through `run/2` and
   `InitFeature`).
3. **STOP and VALIDATE**: `mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs test/speckit_orchestrator/feature_runner_test.exs`
   green for T002-T004; confirm a `start_phase: :plan` run begins at step 3 and
   reaches `:done`.

### Incremental Delivery

1. Foundational → US1 (resume starts mid-pipeline) → US2 (default path
   regression-proven) → US3 (resume anchor threaded for future prompt
   injection) → Polish.
2. Each story is independently testable per its "Independent Test" above before
   moving to the next.

---

## Notes

- All three user stories converge on the same four files
  (`pipeline.ex`, `feature_runner.ex`, `feature_agent.ex`, `init_feature.ex`) —
  parallelism is naturally limited to Foundational (T001/T002) and US3's
  `feature_agent.ex` edit (T009); the `run/2`/`InitFeature` edits are sequential
  by shared-file/shared-call-site dependency, not by story independence.
- Per plan.md scope: `resume_prompt` is carried through state only — no phase
  request is altered by this feature (that's feature 004+).
- Per research.md Decision 2: an invalid `start_phase` is the caller's contract;
  no validation task is included here by design.
- Verify tests fail before implementing (T003-T004, T007, T008 each before their
  corresponding implementation task).
