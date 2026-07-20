---

description: "Task list for Operator prompt injection at the resume phase"
---

# Tasks: Operator prompt injection at the resume phase

**Input**: Design documents from `/specs/004-resume-prompt-injection/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/phase_request_build.md, quickstart.md

**Tests**: Included — `research.md`/`quickstart.md` define the pure-unit-test scenarios (Scenarios 1-6, contract guarantees G1-G6) this feature must satisfy, and the existing `phase_request_test.exs` suite is TDD-style, so new tests follow the same convention.

**Organization**: Both user stories are P1 and share one two-seam implementation (`PhaseRequest.build/3` + `RunFeaturePhase.run/2`) — the seam is Foundational; each story is validated by its own dedicated test task so it stays independently testable per spec.md's Independent Test criteria.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2)

## Path Conventions

Single Elixir project (existing). All paths are repo-root-relative.

---

## Phase 1: Foundational (Blocking Prerequisites)

**Purpose**: The two-seam append-only change that both user stories depend on — no user story task can start until this compiles clean under `warnings_as_errors`.

- [X] T001 Add `:resume_prompt` opt to `PhaseRequest.build/3` in `lib/speckit_orchestrator/phase_request.ex`: blank-guard on `is_binary(x) and String.trim(x) != ""` (nil/""/whitespace-only → no-op, no marker, no separator); when non-blank, append `"\n\n---\nOperator guidance (resume): <prompt>"` verbatim to the assembled prompt; no other `RunRequest` field (`model`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `max_turns`, `cwd`, `session_id`) may change (FR-001, FR-002, FR-003, FR-007; contract G1-G4)
- [X] T002 Add private `resume_prompt_for(state, phase)` helper to `lib/speckit_orchestrator/actions/run_feature_phase.ex` returning `state.resume_prompt` when `phase == state.resume_phase` else `nil`; pass its result as the `:resume_prompt` opt into the existing `PhaseRequest.build/3` call in `run/2` (FR-004, FR-005, FR-006; data-model.md `resume_prompt_for/2`; contract's Caller contract table)

**Checkpoint**: `mix compile` clean; both user stories can now be implemented/tested against this seam.

---

## Phase 2: User Story 1 - Guidance steers exactly the resumed phase (Priority: P1) 🎯 MVP

**Goal**: An operator's resume guidance reaches only the phase being restarted, appended to that phase's assembled prompt, and re-injects on every retry of that same phase before the pipeline advances.

**Independent Test**: Resume a feature whose `resume_phase` is `clarify` with `resume_prompt: "resolved: use integer cents"`; verify the clarify phase's built prompt ends with the operator guidance line.

### Tests for User Story 1

- [X] T003 [P] [US1] Add `:resume_prompt` tests to `test/speckit_orchestrator/phase_request_test.exs`: non-blank guidance is appended as the exact trailing section with the base prompt as unchanged prefix (contract G1, quickstart Scenario 1); `resume_prompt ∈ {nil, "", "   ", "\n\t"}` and the opt being absent all produce a `prompt` byte-identical to no-opt output (contract G2, quickstart Scenario 2); `model`/`permission_mode`/`allowed_tools`/`disallowed_tools`/`max_turns`/`cwd`/`session_id` identical with and without `:resume_prompt` (contract G4, quickstart Scenario 3)
- [X] T004 [US1] Add `resume_prompt_for/2` retry test to `test/speckit_orchestrator/run_feature_phase_test.exs`: with `resume_phase = :analyze` and a non-blank `resume_prompt` in agent state, computing the injected opt for `:analyze` twice (simulating a transient retry before the pipeline advances) returns the same non-nil guidance both times, with the built prompt carrying the guidance section on each call (contract G6, FR-006, SC-004; quickstart Scenario 6)

**Checkpoint**: User Story 1 is independently testable — the resumed phase receives the operator's exact guidance text, and retries need no re-entry.

---

## Phase 3: User Story 2 - Downstream phases run clean after the resumed phase completes (Priority: P1)

**Goal**: Once the resumed phase completes and the run advances, every later phase's built prompt carries zero trace of the operator's guidance — and a fresh (non-resumed) run is unaffected in every phase.

**Independent Test**: Drive a multi-phase run with `resume_phase` set to one phase; confirm that phase's built prompt carries the guidance and every other phase in the same run builds a prompt with no guidance line.

### Tests for User Story 2

- [X] T005 [US2] Add a downstream-clean test to `test/speckit_orchestrator/run_feature_phase_test.exs`: with agent state `resume_phase = :clarify`, `resume_prompt = "use REST, not GraphQL"`, compute `resume_prompt_for/2` (and the resulting built prompt) across `specify, clarify, plan, tasks, analyze, implement`; assert the guidance text is present only in `:clarify`'s built prompt and absent from every other phase's (contract G5, FR-005, SC-002; quickstart Scenario 4)
- [X] T006 [US2] Add a fresh-run-clean test to `test/speckit_orchestrator/run_feature_phase_test.exs`: with agent state `resume_phase = nil`, `resume_prompt = nil`, assert the injected opt is `nil` for every phase in `specify, clarify, plan, tasks, analyze, implement` and each built prompt is byte-identical to pre-feature (no-resume-state) output (contract G2 + G5, SC-003; quickstart Scenario 5)

**Checkpoint**: Both user stories independently functional — guidance is scoped to exactly the resume phase, with no leakage downstream or on fresh runs.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Regression guard and final validation against the feature's own success criteria.

- [X] T007 [P] Run `mise exec -- mix compile` (clean under `warnings_as_errors`) and `mise exec -- mix test` (full suite) — confirm zero regressions in existing per-phase prompt tests (SC-003)
- [X] T008 Walk `specs/004-resume-prompt-injection/quickstart.md` Scenarios 1-6 end-to-end and check off its "Done when" checklist

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately. T002 depends on T001 only insofar as `resume_prompt_for/2`'s output is consumed by the same `PhaseRequest.build/3` call; implementations may still be written in either order but T001 must compile before T002's wiring is exercised. BLOCKS both user stories.
- **User Story 1 (Phase 2)**: Depends on Foundational (Phase 1) completion. No dependency on US2.
- **User Story 2 (Phase 3)**: Depends on Foundational (Phase 1) completion. No dependency on US1 — independently testable in parallel with Phase 2.
- **Polish (Phase 4)**: Depends on Phases 2 and 3 both complete.

### Within Each Phase

- T001 and T002 touch different files but T002's behavior is only meaningful once T001 exists — implement sequentially.
- T003 and T004 touch different test files and different guarantees (G1-G4 vs G6) — parallelizable.
- T005 and T006 both touch `run_feature_phase_test.exs` — sequential (same file).

### Parallel Opportunities

- T003 (`phase_request_test.exs`) and T004 (`run_feature_phase_test.exs`) can run in parallel once Phase 1 is done.
- Phase 2 (US1) and Phase 3 (US2) can be staffed in parallel once Phase 1 is done — different assertions, and T005/T006 only add to the same test file T004 also touches, so coordinate ordering if worked concurrently by different people.

---

## Parallel Example: Foundational → User Stories

```bash
# After T001 + T002 (Foundational) land:
Task: "Add :resume_prompt tests to test/speckit_orchestrator/phase_request_test.exs"       # T003, US1
Task: "Add downstream-clean test to test/speckit_orchestrator/run_feature_phase_test.exs"   # T005, US2
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Foundational (T001, T002)
2. Complete Phase 2: User Story 1 (T003, T004)
3. **STOP and VALIDATE**: `mise exec -- mix test test/speckit_orchestrator/phase_request_test.exs test/speckit_orchestrator/run_feature_phase_test.exs` — guidance reaches the resumed phase, retries re-inject
4. This alone is demoable: an operator's guidance reaches the phase they resumed

### Incremental Delivery

1. Foundational → seam ready (T001-T002)
2. Add User Story 1 → test independently → guidance-at-resume-phase proven (T003-T004)
3. Add User Story 2 → test independently → no-leak-downstream proven (T005-T006)
4. Polish → full-suite regression + quickstart sign-off (T007-T008)

---

## Notes

- No new modules, no new struct fields — this is a two-file, append-only change (plan.md Scale/Scope).
- [P] tasks = different files, no dependencies.
- [Story] label maps task to specific user story for traceability.
- Verify `mix compile` stays clean (`warnings_as_errors` is ON) after every task.
- Commit after each task or logical group.
