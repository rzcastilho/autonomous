---

description: "Task list for Resume Facade (resume/2 operator entry point)"
---

# Tasks: Resume Facade (`resume/2` operator entry point)

**Input**: Design documents from `/specs/005-resume-facade/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/resume.md, quickstart.md

**Tests**: Included — quickstart.md's hermetic suite is the primary validation path (Constitution: pure/seam tests, >90% coverage) and contracts/resume.md's T1-T9 table defines the exact scenarios `resume_test.exs` must cover.

**Organization**: Three user stories, each additive on top of the last: US1 (P1, MVP) delivers the core checkpoint-driven restart with worktree reuse/recreate and every distinct failure result; US2 (P2) layers the optional guidance note onto US1's already-working wrapper; US3 (P3) layers the `:from` override onto US1's already-working phase resolution. No user story requires changes to another once built.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

## Path Conventions

Single Elixir project (existing). All paths are repo-root-relative.

---

## Phase 1: Foundational (Blocking Prerequisites)

**Purpose**: The one pure-core addition every later phase depends on — validating a phase string/atom against the real pipeline before it can drive `FeatureRunner.run` (used both for the checkpoint's stored `last_phase` in US1 and the `:from` override in US3).

- [X] T001 [P] Add `phase?/1` to `lib/speckit_orchestrator/pipeline.ex`: `@spec phase?(atom()) :: boolean()`, `def phase?(phase), do: phase in @ordered` — pure, no new deps
- [X] T002 [P] Add `phase?/1` unit tests to `test/speckit_orchestrator/pipeline_test.exs`: `true` for every member of `Pipeline.phases()`, `false` for a non-phase atom (e.g. `:bogus`)

**Checkpoint**: `mix compile` clean; `Pipeline.phase?/1` available for the resume boundary validation in every user story below.

---

## Phase 2: User Story 1 - Resume a halted/escalated feature at its checkpointed phase (Priority: P1) 🎯 MVP

**Goal**: `SpeckitOrchestrator.resume(feature_id, opts)` looks up the feature and its checkpoint, restarts the pipeline at the checkpointed phase (never `Pipeline.first()`), reuses or recreates the feature's worktree from its existing branch, and returns a distinct `{:error, …}` result for every unsafe precondition — no run starts on any of them.

**Independent Test**: Checkpoint a fixture feature at `analyze` (via `Checkpoint.write/1` under a temp `transcript_root`), call `resume(id)` with a fake `:runner`, and confirm the run is invoked starting at `:analyze`, never at the first phase.

### Tests for User Story 1

- [X] T003 [US1] Create `test/speckit_orchestrator/resume_test.exs` with shared fixtures (a minimal `%Feature{}`, a `Checkpoint.write/1`-backed fixture checkpoint under a temp `transcript_root` app-env swap per `checkpoint_test.exs`'s pattern, a capturing fake `:runner`) plus the test "resume/2 restarts at the checkpointed phase, not `Pipeline.first()`" (contract T1; US1 AS1; SC-002)
- [X] T004 [US1] Add test "resume/2 reports `{:error, :no_checkpoint}` and starts no run when the feature has no checkpoint" — assert the fake runner is never invoked (contract T2; US1 AS2)
- [X] T005 [US1] Add test "resume/2 reports `{:error, {:unknown_feature, id}}` and starts no run for a feature id absent from the backlog" — assert the fake runner is never invoked (contract T3; US1 AS3)
- [X] T006 [US1] Add test "resume/2 reports `{:error, :corrupt_checkpoint}`, distinct from `:no_checkpoint`, and starts no run when the checkpoint file exists but is undecodable" — write raw invalid JSON to the checkpoint path (contract T8; FR-006a; edge case)
- [X] T007 [US1] Add integration test (`@tag :integration`, real git via a `scaffolded_repo/0` helper mirroring `resolve_test.exs`) "resume/2 recreates the worktree from the existing branch when the worktree was previously freed (e.g. by `resolve/1`) and the operator's committed fix is present after recreation" (FR-005; quickstart "Branch reuse")
- [X] T008 [US1] Add integration test (`@tag :integration`) "resume/2 propagates `{:error, {:worktree, reason}}` via a `:failed` notification and starts no fresh, unrelated branch when the feature's branch is gone" (contract T9; FR-005 edge case; SC-005)

### Implementation for User Story 1

- [X] T009 [US1] Implement `SpeckitOrchestrator.resume/2` boundary validation in `lib/speckit_orchestrator.ex`: look up the feature in `Keyword.get_lazy(opts, :features, &load_backlog/0)` (`{:error, {:unknown_feature, id}}` on miss, matching `resolve/1`), then `Checkpoint.read(feature_id)` dispatching `{:error, :no_checkpoint}` / `{:error, :corrupt_checkpoint}`, then resolve `start_phase` from the checkpoint's `last_phase` string via `String.to_existing_atom/1` guarded by `Pipeline.phase?/1` (`{:error, {:unknown_phase, phase}}` on a bad stored value — never `String.to_atom/1` on file contents) — depends on T001
- [X] T010 [US1] Implement the private resume-runner wrapper in `lib/speckit_orchestrator.ex`: `Worktree.locate/2` the feature and reuse its path if the directory exists, else `Worktree.create/2` to recreate from the existing branch; on `Worktree.create` failure call `notify.(feature.id, :failed, {:worktree, reason})` exactly as `default_runner/2` does; otherwise `FeatureRunner.run(feature, worktree: wt, ledger: Ledger, notify: notify, start_phase: start_phase, resume_prompt: nil)` (prompt threading lands in US2) — depends on T009
- [X] T011 [US1] Wire `resume/2` to delegate to `run/1`: inject the T010 wrapper as `:runner` only when the caller did not already supply one (mirror `spec_run_opts/3`'s `caller_test_mode?` guard), pass `features: [feature]` plus all other opts through unchanged (FR-008), and return `run/1`'s `on_start` tuple — depends on T009, T010

**Checkpoint**: User Story 1 is independently functional — `resume/2` restarts a checkpointed feature at the right phase, reuses/recreates its worktree correctly, and every precondition failure is distinct with zero side effects.

---

## Phase 3: User Story 2 - Attach operator guidance to the resumed phase (Priority: P2)

**Goal**: An operator-supplied `:prompt` reaches the resumed phase as `resume_prompt`; omitting it runs the phase with no note and no placeholder text.

**Independent Test**: Resume a feature with `resume(id, prompt: "…")` and confirm that exact string reaches the phase runner unchanged; resume without it and confirm `resume_prompt: nil` with no error.

### Tests for User Story 2

- [X] T012 [US2] Add test "resume/2 delivers the `:prompt` guidance note to the resumed phase unchanged" to `test/speckit_orchestrator/resume_test.exs` (contract T4; US2 AS1; SC-003)
- [X] T013 [US2] Add test "resume/2 with no `:prompt` runs the resumed phase with `resume_prompt: nil` — no error, no placeholder text injected" (contract T5; US2 AS2)

### Implementation for User Story 2

- [X] T014 [US2] In the T010 resume-runner wrapper (`lib/speckit_orchestrator.ex`), replace the hardcoded `resume_prompt: nil` with the resume request's `:prompt` opt (default `nil` when absent), passed through unchanged to `FeatureRunner.run` — depends on T010

**Checkpoint**: User Stories 1 AND 2 both work independently — guidance passthrough adds no regression to US1's checkpoint-driven restart.

---

## Phase 4: User Story 3 - Override the resume starting phase (Priority: P3)

**Goal**: An operator-supplied `:from` phase takes precedence over the checkpointed phase; an invalid override is rejected with its own distinct result and starts no run.

**Independent Test**: Checkpoint a feature at `analyze`, call `resume(id, from: :plan)`, and confirm the run starts at `:plan`, not `:analyze`.

### Tests for User Story 3

- [X] T015 [US3] Add test "resume/2 with a valid `:from` overrides the checkpointed phase" to `test/speckit_orchestrator/resume_test.exs` (contract T6; US3 AS1)
- [X] T016 [US3] Add test "resume/2 with an invalid `:from` rejects with `{:error, {:unknown_phase, phase}}` and starts no run" — assert the fake runner is never invoked (contract T7; SC-005)

### Implementation for User Story 3

- [X] T017 [US3] In `resume/2`'s boundary validation (`lib/speckit_orchestrator.ex`, T009), resolve `start_phase` as `opts[:from] || parsed_checkpoint_phase`, validating `opts[:from]` against `Pipeline.phase?/1` the same way as the checkpoint's stored phase (`{:error, {:unknown_phase, phase}}` on a bad override) — depends on T009, T001

**Checkpoint**: All three user stories work independently and together — default checkpoint resume, guidance passthrough, and explicit phase override each behave per their acceptance scenarios with no cross-story regression.

---

## Phase 5: Polish & Cross-Cutting Concerns

- [X] T018 [P] Run `mise exec -- mix compile` and confirm a clean build under `warnings_as_errors`
- [X] T019 Run `mise exec -- mix test` (full hermetic suite) and confirm no regression — all existing suites (including `resolve_test.exs`) still pass alongside the new `resume_test.exs`/`pipeline_test.exs` cases; then `mise exec -- mix test --include integration` for T007/T008
- [X] T020 Walk through quickstart.md's unit validation, full-suite, integration, and manual `iex` smoke sections end-to-end, confirming documented expected output matches; confirm `resolve/1` remains unchanged and available as the separate full-restart path (FR-009)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — BLOCKS all user stories (both US1's checkpoint-phase validation and US3's override validation call `Pipeline.phase?/1`).
- **User Story 1 (Phase 2)**: Depends on Foundational only. MVP.
- **User Story 2 (Phase 3)**: Depends on Foundational + US1 (T010's wrapper, extended in place by T014).
- **User Story 3 (Phase 4)**: Depends on Foundational + US1 (T009's checkpoint-phase resolution, extended in place by T017).
- **Polish (Phase 5)**: Depends on all three user stories being complete.

### Within Each User Story

- Tests written first (expected to fail), then implementation: T003-T008 → T009-T011; T012-T013 → T014; T015-T016 → T017.
- US2 and US3 each extend a specific US1 implementation task in place (T014 extends T010; T017 extends T009) rather than duplicating the wrapper/resolution logic.

### Parallel Opportunities

- T001 and T002 (Foundational) — different files.
- T003-T008 (US1 tests) all edit `resume_test.exs` — not marked `[P]`, added as sequential test cases in one file.
- T009 and T010 both edit `lib/speckit_orchestrator.ex` — sequential, not `[P]` (T010 depends on T009's resolved `start_phase`/error tuples).
- T018 and later Polish tasks may run alongside a final read-through, though T019/T020 depend on T001-T017 being complete to be meaningful.

---

## Parallel Example: Foundational

```bash
# T001 (pipeline.ex) and T002 (pipeline_test.exs) touch different files:
Task: "Add phase?/1 to lib/speckit_orchestrator/pipeline.ex"
Task: "Add phase?/1 unit tests to test/speckit_orchestrator/pipeline_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Foundational (`Pipeline.phase?/1`)
2. Complete Phase 2: User Story 1 — checkpoint-driven restart, worktree reuse/recreate, all five distinct failure results
3. **STOP and VALIDATE**: `mix test test/speckit_orchestrator/resume_test.exs` green, quickstart's hermetic scenarios pass
4. This alone satisfies SC-001, SC-002, SC-004, SC-005 (minus the `:from`-specific failure) and FR-001/002/005/006/006a/007/009/010

### Incremental Delivery

1. Foundational → Foundation ready
2. US1 → independently testable → the core recovery path is usable end-to-end (MVP)
3. US2 → independently testable → operators can now leave guidance on a resume call
4. US3 → independently testable → operators can override the start phase when the checkpoint isn't where they want to resume
5. Polish → full-suite + integration confirmation, quickstart walkthrough

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- No new persisted entity and no change to `Checkpoint`'s on-disk shape (data-model.md)
- `resolve/1` is untouched by every task above (FR-009) — T019/T020 exist specifically to confirm that stays true
