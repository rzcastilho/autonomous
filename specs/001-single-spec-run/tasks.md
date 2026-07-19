---

description: "Task list for Single-Spec Run Mode"
---

# Tasks: Single-Spec Run Mode

**Input**: Design documents from `specs/001-single-spec-run/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/run_spec.md, quickstart.md (all present)

**Tests**: Included. The constitution's Quality & Test Discipline section mandates
>90% coverage on the pure core and no dependency on a mocked hook, so new pure
logic (`SingleSpec`) and the facade wiring are test-driven throughout.

**Organization**: Tasks are grouped by user story (spec.md P1/P1/P3) to enable
independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Every task includes its exact file path

## Path Conventions

Single Elixir project (per plan.md): `lib/speckit_orchestrator/`, `test/speckit_orchestrator/`.

---

## Phase 1: Setup

**Purpose**: Create the new module and test file skeletons that every later task fills in

- [X] T001 Create `lib/speckit_orchestrator/single_spec.ex` module skeleton (`@moduledoc`, `alias SpeckitOrchestrator.Feature`, empty function stubs for `next_id/1`, `slug/1`, `seed_body/2`, `build/3` per contracts/run_spec.md §4)
- [X] T002 [P] Create `test/speckit_orchestrator/single_spec_test.exs` skeleton (`use ExUnit.Case, async: true`, `alias SpeckitOrchestrator.SingleSpec`)
- [X] T003 [P] Create `test/speckit_orchestrator/run_spec_test.exs` skeleton (`use ExUnit.Case, async: true`, `alias SpeckitOrchestrator`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: `SingleSpec` — the pure id/slug/seed derivation every user story depends on to build a `Feature` from a description

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 Write tests for `SingleSpec.next_id/1` in `test/speckit_orchestrator/single_spec_test.exs` — empty list → `"001"`; `["001", "003"]` → `"004"`; ids drawn from `feature/NNN-*` branch names are honored (data-model.md, research.md R3)
- [X] T005 Implement `SingleSpec.next_id/1` in `lib/speckit_orchestrator/single_spec.ex` (depends on T004)
- [X] T006 Write tests for `SingleSpec.slug/1` in `test/speckit_orchestrator/single_spec_test.exs` — kebab-case derivation, first-5-token limit, ≤40-char truncation, no-alphanumeric description falls back to `"feature"` (research.md R4)
- [X] T007 Implement `SingleSpec.slug/1` in `lib/speckit_orchestrator/single_spec.ex` (depends on T006)
- [X] T008 Write tests for `SingleSpec.seed_body/2` in `test/speckit_orchestrator/single_spec_test.exs` — renders `# <id> — <Title>` + description + `## Prerequisites\n\nNone`; output round-trips through `SpeckitOrchestrator.Backlog.load!/1` as a single no-prereq feature (contracts/run_spec.md §3)
- [X] T009 Implement `SingleSpec.seed_body/2` in `lib/speckit_orchestrator/single_spec.ex` (depends on T008)
- [X] T010 Write tests for `SingleSpec.build/3` in `test/speckit_orchestrator/single_spec_test.exs` — `nil`/`""`/whitespace-only description → `{:error, :empty_description}`; valid description + taken-ids list → `{:ok, %Feature{prereqs: [], status: :pending, ...}}` (data-model.md, FR-003, FR-012)
- [X] T011 Implement `SingleSpec.build/3` in `lib/speckit_orchestrator/single_spec.ex`, composing `next_id/1`, `slug/1`, `seed_body/2` (depends on T005, T007, T009, T010)

**Checkpoint**: `SingleSpec` complete and covered — user story implementation can now begin

---

## Phase 3: User Story 1 - Run one feature without authoring a backlog (Priority: P1) 🎯 MVP

**Goal**: `SpeckitOrchestrator.run_spec/2` drives one feature end-to-end from a free-text description — no breakdown directory, no prerequisite declarations, wave of one

**Independent Test**: call `run_spec/2` with an injected `:runner` and `:features` seam; assert the one feature runs and the drain report accounts for exactly it (spec.md US1 AC1-3)

### Tests for User Story 1

- [X] T012 [P] [US1] Write tests for the taken-id gathering helper (scans `Config.breakdown_dir()` `NNN-*.md` filenames and `feature/NNN-*` branch names) in `test/speckit_orchestrator/run_spec_test.exs`
- [X] T014 [P] [US1] Write tests for the seed-writing runner wrapper in `test/speckit_orchestrator/run_spec_test.exs` — writes the seed to `<worktree.path>/<breakdown_dir>/<id>-<slug>.md` after `Worktree.create/2` succeeds and before `FeatureRunner.run/2` (contracts/run_spec.md §2, research.md R1-R2)
- [X] T016 [P] [US1] Write tests for the seed-write failure path in `test/speckit_orchestrator/run_spec_test.exs` — a failing seed write calls `notify.(id, :failed, {:seed, reason})` and never invokes `FeatureRunner.run/2` (contracts/run_spec.md §2, edge case: fail loud)
- [X] T018 [P] [US1] Write tests for `run_spec/2` (non-PR path) in `test/speckit_orchestrator/run_spec_test.exs` — empty/whitespace description → `{:error, :empty_description}` with no Coordinator/worktree/file side effect (SC-005); valid description with injected `:runner`/`:features` → one feature runs as a wave of one and the drain report accounts for exactly it with spend within budget (SC-001, SC-002, SC-004, SC-006)

### Implementation for User Story 1

- [X] T013 [US1] Implement the taken-id gathering helper in `lib/speckit_orchestrator.ex` (depends on T012)
- [X] T015 [US1] Implement the seed-writing runner wrapper in `lib/speckit_orchestrator.ex`, wrapping `default_runner/2` (depends on T014, T013, T011)
- [X] T017 [US1] Wire the seed-write failure branch into the runner wrapper in `lib/speckit_orchestrator.ex` (depends on T016, T015)
- [X] T019 [US1] Implement `SpeckitOrchestrator.run_spec/2` — validate the description via `SingleSpec.build/3`, then delegate to `start_run(features: [feature], runner: seed_runner)` per contracts/run_spec.md §1 (depends on T018, T017, T011)

**Checkpoint**: An operator can call `run_spec("...")` and get one feature built with no breakdown file authored — MVP complete and independently testable

---

## Phase 4: User Story 2 - Same safety guarantees as a full backlog run (Priority: P1)

**Goal**: Every existing guarantee (clarify escalation, analyze halt, breaker drain-not-kill, write containment, durable transcripts, worktree retention) fires identically through `run_spec/2`

**Independent Test**: run single features engineered to trip each guarantee via the injected seams; assert identical escalate/halt/drain/containment/transcript/retention behavior to a backlog run (spec.md US2 AC1-5)

### Tests for User Story 2

- [X] T020 [P] [US2] Write test in `test/speckit_orchestrator/run_spec_test.exs`: a single feature whose stubbed clarify result carries `## NEEDS HUMAN` escalates via `run_spec/2` and its worktree is retained (FR-006)
- [X] T021 [P] [US2] Write test in `test/speckit_orchestrator/run_spec_test.exs`: a single feature whose stubbed analyze result is Critical halts via `run_spec/2` and its worktree is retained (FR-007)
- [X] T022 [P] [US2] Write test in `test/speckit_orchestrator/run_spec_test.exs`: starting `run_spec/2` against an already-tripped `Ledger` releases no new work and reports no spend beyond what was already committed (FR-008, drain-not-kill)
- [X] T023 [P] [US2] Write test in `test/speckit_orchestrator/run_spec_test.exs`: the seed file is written only inside the feature's worktree path, never in the base repo tree (FR-009, containment)
- [X] T024 [P] [US2] Write test in `test/speckit_orchestrator/run_spec_test.exs`: a `run_spec/2` run writes a durable per-phase transcript to the feature's workspace (FR-010)

### Implementation for User Story 2

- [X] T025 [US2] Close any gap surfaced by T020-T024 in `lib/speckit_orchestrator.ex` (expected to be none — these guarantees are inherited by delegation to `Coordinator`/`FeatureRunner`/`Ledger`; this task exists to fix regressions the tests catch) (depends on T020, T021, T022, T023, T024, T019)

**Checkpoint**: `run_spec/2` provably carries every safety guarantee a backlog run has

---

## Phase 5: User Story 3 - Optionally open a pull request for the single feature (Priority: P3)

**Goal**: `run_spec(description, pr_workflow: true)` stacks the single feature and opens a PR for it on clean completion

**Independent Test**: inject `:executor`/`:publisher`; assert the branch is published and a PR opened on `:done`, and that a failed remote/pack preflight refuses to start (spec.md US3 AC1-2)

### Tests for User Story 3

- [X] T026 [P] [US3] Write tests for the seed-writing executor wrapper in `test/speckit_orchestrator/run_spec_test.exs` — writes the seed after `Worktree.create(feature, base: base)` and before `FeatureRunner.run/2` (contracts/run_spec.md §2, research.md R6)
- [X] T028 [P] [US3] Write tests for `run_spec(description, pr_workflow: true)` in `test/speckit_orchestrator/run_spec_test.exs` — cap-1 sequential run, remote/pack preflight via `TargetPack.verify/2`; on `:done` the branch is published and a PR opened via injected `:executor`/`:publisher`; a failed preflight returns `{:error, {:preflight, problems}}` and runs nothing (FR-014, Story 3 AC1-2)

### Implementation for User Story 3

- [X] T027 [US3] Implement the seed-writing executor wrapper in `lib/speckit_orchestrator.ex`, wrapping `default_executor/3` (depends on T026, T011)
- [X] T029 [US3] Wire `run_spec/2`'s `pr_workflow: true` path — delegate to `run_stacked(features: [feature], executor: seed_executor)` per contracts/run_spec.md §1 (depends on T028, T027, T019)

**Checkpoint**: All three user stories independently functional — single-spec mode complete

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Verify quality gates and close the loop with operator-facing docs

- [X] T030 [P] Run `mise exec -- mix test --cover` and confirm >90% coverage on `lib/speckit_orchestrator/single_spec.ex` (constitution: Quality & Test Discipline)
- [X] T031 [P] Run `mise exec -- mix compile` and confirm zero warnings (`warnings_as_errors`)
- [X] T032 Execute the quickstart.md unit validation section end-to-end: `mise exec -- mix test test/speckit_orchestrator/single_spec_test.exs test/speckit_orchestrator/run_spec_test.exs`
- [X] T033 Add a "Single-spec run" operator section to `docs/runbook.md` documenting `run_spec/2`, its options, and a pointer to `specs/001-single-spec-run/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (every story builds a `Feature` via `SingleSpec`)
- **User Story 1 (Phase 3)**: Depends on Foundational — no dependency on US2/US3
- **User Story 2 (Phase 4)**: Depends on Foundational; its tests exercise `run_spec/2` from US1 (T019), so in practice runs after US1 lands, though the guarantees themselves are pre-existing behavior, not new code
- **User Story 3 (Phase 5)**: Depends on Foundational; its facade wiring (T029) extends `run_spec/2` from US1 (T019) with the `pr_workflow: true` branch
- **Polish (Phase 6)**: Depends on all three user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Foundational only. This is the MVP.
- **User Story 2 (P1, tied)**: Foundational + exercises the `run_spec/2` surface US1 builds; adds no new production code path of its own (guarantees are inherited by reuse), only proof.
- **User Story 3 (P3)**: Foundational + extends `run_spec/2` from US1 with an additive option; independently testable via its own seam.

### Within Each User Story

- Tests written before the implementation task they validate (see per-task `depends on`)
- `SingleSpec` (Foundational) before any runner/facade code
- Runner/executor wrapper before the `run_spec/2` wiring that uses it
- Story complete (checkpoint) before moving to the next priority

### Parallel Opportunities

- T002, T003 (Setup) in parallel — different files
- T004, T006, T008, T010 (Foundational tests) in parallel — same file, but independent test cases; treat as logically parallel authoring, sequential file writes
- T012, T014, T016, T018 (US1 tests) in parallel with each other; all in `run_spec_test.exs` but cover independent behaviors
- T020, T021, T022, T023, T024 (US2 tests) fully parallel — independent guarantee checks, all read-only against existing modules
- T026, T028 (US3 tests) in parallel
- Once Foundational (Phase 2) completes, US1 and the *test-writing* halves of US2/US3 could start in parallel if staffed, but US2/US3 *implementation* tasks (T025, T027, T029) depend on US1's T019 landing first — see Phase Dependencies

---

## Parallel Example: Foundational Phase

```bash
# Author all four SingleSpec test groups together (same file, independent cases):
Task: "Write tests for SingleSpec.next_id/1"
Task: "Write tests for SingleSpec.slug/1"
Task: "Write tests for SingleSpec.seed_body/2"
Task: "Write tests for SingleSpec.build/3"
```

## Parallel Example: User Story 2

```bash
# All five guarantee-preservation tests are independent and read-only:
Task: "Clarify escalation test for run_spec/2"
Task: "Analyze halt test for run_spec/2"
Task: "Breaker drain-not-kill test for run_spec/2"
Task: "Seed containment test for run_spec/2"
Task: "Durable transcript test for run_spec/2"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (`SingleSpec` — CRITICAL, blocks all stories)
3. Complete Phase 3: User Story 1 (`run_spec/2` non-PR path)
4. **STOP and VALIDATE**: run quickstart.md's unit validation section; confirm `run_spec("...")` runs one feature with no breakdown file
5. This alone is a viable, valuable increment (spec.md: "a viable, valuable product on its own")

### Incremental Delivery

1. Setup + Foundational → `SingleSpec` ready
2. Add User Story 1 → validate independently → MVP usable
3. Add User Story 2 → prove guarantees hold → safe to recommend for real runs
4. Add User Story 3 → optional PR delivery available
5. Polish → coverage/warnings gates + docs

### Parallel Team Strategy

1. One contributor completes Setup + Foundational (small, sequential — `SingleSpec` is one file)
2. Once Foundational lands: one contributor takes US1 (blocking for US2/US3 implementation); US2 and US3 *test* authoring can start immediately against the contract, implementation follows once T019 merges

---

## Notes

- [P] tasks touch different files, or independent test cases with no ordering dependency
- [Story] label maps each task to its user story for traceability
- Tests are written before their implementation task (see `depends on`) — confirm they fail first
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently
- No new production module besides `single_spec.ex`; `speckit_orchestrator.ex` gains `run_spec/2` plus two small private helpers (seed-writing runner, seed-writing executor) — avoid over-splitting these into more files than plan.md's Source Code section specifies
