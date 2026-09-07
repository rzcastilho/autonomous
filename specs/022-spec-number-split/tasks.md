# Tasks: Spec Number Split

**Input**: Design documents from `/specs/022-spec-number-split/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: included — the plan and contracts name a specific test file per module
(`spec_number_test.exs`, `checkpoint_test.exs`, …) as part of the exit criteria
(coverage target 100% on the two new pure modules), so this list treats them as
required, not optional.

**Organization**: grouped by user story (spec.md priorities P1/P2/P3) so each
story is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different files, no unmet dependency — safe to run in parallel
- **[Story]**: US1 (identity/allocation), US2 (empty-checkpoint net), US3 (resolution net)

## Path Conventions

Single Elixir/OTP project. `lib/speckit_orchestrator/`, `test/speckit_orchestrator/`, repo root for docs.

---

## Phase 1: Setup

**Purpose**: confirm the starting point is clean. No new dependency, no config change (plan.md Technical Context).

- [X] T001 Verify baseline is green: `mise exec -- mix compile` (warnings_as_errors is ON) and `mise exec -- mix test` from repo root before any change

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the shared identity field and store schema every story's tests and code build on.

**⚠️ CRITICAL**: no user story work can begin until this phase is complete.

- [X] T002 [P] Add `spec_number` field (not in `@enforce_keys`), `spec_id/1` (falls back to `id` when nil), and `spec_label/1` (returns `nil` when unallocated) to `lib/speckit_orchestrator/feature.ex` (data-model.md §1, research R3)
- [X] T003 [P] Append the `:spec_number` attribute to the `speckit_feature_run` table shape in `lib/speckit_orchestrator/store/schema.ex` (contracts/store-schema-v5.md §1)
- [X] T004 Add migration 5 (`append feature_run.spec_number (backfilled from :number)`, pinning `@feature_run_v4_attributes` and deriving the `:number` index with `Enum.find_index/2`) and bump `Migrations.current_version/0` to `5` in `lib/speckit_orchestrator/store/migrations.ex` (depends on T003)
- [X] T005 [P] Add `spec_number` to the `FeatureRun` record struct and its encode/decode in `lib/speckit_orchestrator/store/records.ex` (depends on T003)
- [X] T006 Add `Store.spec_number/2` (`nil` for unallocated, absent row, or no store) in `lib/speckit_orchestrator/store.ex` (depends on T005)
- [X] T007 Add `Writer.record_spec_number/3` (one transaction; `{:error, {:absent, key}}` on missing row; `{:error, {:already_allocated, feature_id, n}}` when already non-nil) and make `open_run/2`/`add_features/2` write `spec_number: nil` explicitly in `lib/speckit_orchestrator/store/writer.ex` (depends on T005)
- [X] T008 [P] Carry `spec_number` through `Query.run_detail/1` in `lib/speckit_orchestrator/store/query.ex` (depends on T005)
- [X] T009 [P] Backlog-parsed features carry explicit `spec_number: nil` in `lib/speckit_orchestrator/backlog.ex` (depends on T002)
- [X] T010 [P] Ad-hoc features carry explicit `spec_number: nil` in `lib/speckit_orchestrator/single_spec.ex` (depends on T002)
- [X] T011 Carry `spec_number` through `Recovery`'s store-record → `%Feature{}` mapping in `lib/speckit_orchestrator/recovery.ex` (depends on T006)
- [X] T012 [P] Unit tests for `spec_id/1` (fallback to `id`) and `spec_label/1` (`nil` when unallocated) in `test/speckit_orchestrator/feature_test.exs` (depends on T002)
- [X] T013 [P] Migration 5 test: v4 → v5 backfills `spec_number` from `:number`, zero rows dropped/truncated, a v1 directory still aborts, in `test/speckit_orchestrator/store/migrations_test.exs` (`--include integration`, quickstart §6) (depends on T004)
- [X] T014 [P] `record_spec_number/3` tests: write-once, reuse-on-resume needs no existence check, second allocation aborts `{:already_allocated, …}`, in `test/speckit_orchestrator/store/writer_test.exs` (depends on T007)
- [X] T015 [P] `run_detail/1` carries `spec_number` test in `test/speckit_orchestrator/store/query_test.exs` (depends on T008)
- [X] T016 [P] Recovery rebuild carries recorded `spec_number` test in `test/speckit_orchestrator/recovery_test.exs` (depends on T011)

**Checkpoint**: Feature struct and store carry `spec_number`; user story work can begin.

---

## Phase 3: User Story 1 - A later wave's feature builds without colliding with an earlier wave's spec (Priority: P1) 🎯 MVP

**Goal**: allocate a repo-monotonic spec number before the feature's first phase, compose the spec directory/branch from it, reuse it on resume, refuse loud on a genuine collision, and surface both numbers on every operator-facing view.

**Independent Test**: run a feature whose wave number is `001` against a target repository that already contains `specs/001-<other-slug>/`; confirm a fresh spec number is assigned, its directory/branch carry that number, and every phase reads/writes only inside its own directory.

### Tests for User Story 1

- [X] T017 [P] [US1] `SpecNumber.parse/1`, `highest/1`, `allocate/2`, `dir_name/2`, `branch_name/2` decision-table tests (gaps never filled, non-conforming entries ignored, `{:ok, 1}` on empty listing, `{:error, {:spec_dir_exists, entry}}` on highest-plus-one collision) in `test/speckit_orchestrator/spec_number_test.exs` (contracts/spec-number-allocation.md §1)
- [X] T018 [P] [US1] `Worktree.spec_dirs/2` tests: reads the base **ref** via `git ls-tree`, not the base repo's working tree; `{:ok, []}` when `specs/` is absent on the ref; only a git failure returns `{:error, _}`, in `test/speckit_orchestrator/worktree_test.exs`
- [X] T019 [P] [US1] `Worktree.locate/2` naming tests: `:path`/`:branch` composed from `spec_id`, `feature_id: feature.id` kept for logging/store lookups, in `test/speckit_orchestrator/worktree_test.exs`
- [X] T020 [US1] Allocation-flow tests in `test/speckit_orchestrator_test.exs`: reuse recorded `Store.spec_number/2` with no existence check; fresh allocate → `Worktree.spec_dirs/2` → `SpecNumber.allocate/2` → `Writer.record_spec_number/3`; FR-003a refusal notifies `:failed` with `{:spec_number, {:spec_dir_exists, entry}}` before any worktree is created and no phase runs; a run with no store (`run_key == nil`) allocates in memory and still refuses
- [X] T021 [P] [US1] Report line shows `number` and `spec_number` under distinct labels, `not allocated` when nil, in `test/speckit_orchestrator/report_test.exs`
- [X] T022 [P] [US1] `RunDetailLive` renders both numbers mono; `test/speckit_orchestrator/web/design_contract_test.exs` stays green (no new color/radius/font-size/spacing literal), in `test/speckit_orchestrator/web/run_detail_live_test.exs`
- [X] T023 [P] [US1] `EscalationsLive`'s hand-built `%Feature{}` carries and renders `spec_number` in `test/speckit_orchestrator/web/escalations_live_test.exs`
- [X] T024 [P] [US1] Backlog per-wave numeric-uniqueness guard still refuses two features within one package and does not treat the same number recurring across packages as a conflict (FR-016 confirmation) in `test/speckit_orchestrator/backlog_test.exs`

### Implementation for User Story 1

- [X] T025 [US1] Create `SpeckitOrchestrator.SpecNumber` pure module — `parse/1`, `highest/1`, `allocate/2`, `dir_name/2`, `branch_name/2` — in `lib/speckit_orchestrator/spec_number.ex` (depends on T002)
- [X] T026 [US1] Add `Worktree.spec_dirs/2` (`git -C <repo> ls-tree --name-only <base> specs/`, strip the `specs/` prefix and any trailing slash, dedupe) in `lib/speckit_orchestrator/worktree.ex`
- [X] T027 [US1] Compose `Worktree.locate/2`'s `:path`/`:branch` from `Feature.spec_id/1` instead of `id`, keeping `feature_id: feature.id` in `lib/speckit_orchestrator/worktree.ex` (depends on T025, T026)
- [X] T028 [US1] Compose `SPECIFY_FEATURE_DIRECTORY` from `spec_id` in `lib/speckit_orchestrator/phase_request.ex` (depends on T002)
- [X] T029 [US1] Wire the allocation flow into the executor seam — `run_fresh/6`, `resume_worktree/2`, `seed_executor/3`, `default_executor/5` — reusing `Store.spec_number/2` when present, else `Worktree.spec_dirs/2` → `SpecNumber.allocate/2` → `Writer.record_spec_number/3`; any failure notifies `:failed` with `{:spec_number, reason}` before `Worktree.create/2` runs, in `lib/speckit_orchestrator.ex` (depends on T025, T026, T007)
- [X] T030 [P] [US1] Show `number` and `spec_number` under distinct field names, mono, `not allocated` when nil, on the run report line in `lib/speckit_orchestrator/report.ex` (depends on T002)
- [X] T031 [P] [US1] Show both numbers on `RunDetailLive`'s feature row/drawer, mono, `not allocated` when nil, no new design token, in `lib/speckit_orchestrator/web/live/run_detail_live.ex` (depends on T002)
- [X] T032 [P] [US1] Show both numbers on `EscalationsLive`'s hand-built `%Feature{}` in `lib/speckit_orchestrator/web/live/escalations_live.ex` (depends on T002)
- [X] T033 [P] [US1] Show both numbers on the PR body's mechanical header in `lib/speckit_orchestrator.ex` (PR description assembly) (depends on T002)

**Checkpoint**: User Story 1 is independently functional — a colliding wave number gets its own spec number, directory, and branch; resume/retry/restart reuse it; both numbers are visible everywhere a feature is named.

---

## Phase 4: User Story 2 - A phase that writes nothing fails at that phase (Priority: P2)

**Goal**: a `specify`/`plan`/`tasks` phase that reports success while leaving the tree unchanged, and whose artifact was absent when it started, fails right there — independent of artifact resolution.

**Independent Test**: drive a `tasks` phase that reports success without writing anything, with artifact resolution left alone; confirm the feature fails at `tasks` naming the unchanged tree, and no later phase runs.

### Tests for User Story 2

- [X] T034 [P] [US2] `Checkpoint.armed?/1` / `verdict/3` — every cell of the decision table (armed phases × absent-at-start × commit result; unarmed phases always advance) in `test/speckit_orchestrator/checkpoint_test.exs`
- [X] T035 [US2] Boundary integration tests in `test/speckit_orchestrator/feature_runner_test.exs`: a `:tasks` phase reporting `:ok` with an unchanged tree and artifact absent at start → `{:failed, {:empty_checkpoint, :tasks}}`, no later phase runs; FR-014a — artifact present at start, unchanged tree → advances; FR-015 — `:clarify`/`:analyze`/`:implement`/`:converge` with an unchanged tree → always advance
- [X] T036 [US2] `RunFeaturePhase` probe tests: `artifact_absent_at_start?` set only for `:specify`/`:plan`/`:tasks`, only when a worktree exists, and unaffected by the artifact gate's own verdict (FR-014), in `test/speckit_orchestrator/run_feature_phase_test.exs`

### Implementation for User Story 2

- [X] T037 [US2] Create `SpeckitOrchestrator.Checkpoint` pure module — `@armed_phases [:specify, :plan, :tasks]`, `armed?/1`, `verdict/3` per the decision table — in `lib/speckit_orchestrator/checkpoint.ex`
- [X] T038 [US2] Probe `artifact_absent_at_start?` with `SpecDir.file/3` against `%{specify: "spec.md", plan: "plan.md", tasks: "tasks.md"}` before `Jido.Harness.run_request/3` is issued, and merge it into `last_signals`, in `lib/speckit_orchestrator/actions/run_feature_phase.ex` (depends on T037)
- [X] T039 [US2] Reorder `FeatureRunner.loop/12`'s `{:cont, next}` branch: commit → `Checkpoint.verdict/3` → `record_attempt/9` with the post-verdict checkpoint → recurse (breaker/persistence drain checks unchanged) or return `{:failed, reason, agent}`, in `lib/speckit_orchestrator/feature_runner.ex` (depends on T037, T038)
- [X] T040 [P] [US2] Render `{:empty_checkpoint, phase}` distinctly from `{:missing_artifact, phase, artifact}` (e.g. "tasks committed no change") wherever a terminal reason is shown, in `lib/speckit_orchestrator/report.ex` and `lib/speckit_orchestrator/web/live/run_detail_live.ex` (depends on T039)

**Checkpoint**: User Story 2 is independently functional — exercised alone (net one left as-is), it catches a phase that claims success and writes nothing.

---

## Phase 5: User Story 3 - Artifact resolution never crosses into another feature (Priority: P3)

**Goal**: every `SpecDir` candidate is constrained to the requesting feature's own spec id, so an ambiguous or cross-feature match resolves as unresolved, never another feature's file.

**Independent Test**: with two directories sharing a numeric prefix and differing slugs, ask for an artifact that exists only in the other one; confirm the answer is "unresolved", not the other directory's copy.

### Tests for User Story 3

- [ ] T041 [US3] `SpecDir.resolve/2` / `file/3` candidate tests: exact `spec_id` match; `.specify/feature.json` accepted only when its basename's numeric prefix equals `spec_id`; `specs/<spec_id>-*` accepted only on exactly one match; two directories sharing a numeric prefix → `nil` (FR-009, FR-010), in `test/speckit_orchestrator/spec_dir_test.exs`
- [ ] T042 [P] [US3] Unresolved artifact reads as missing to `missing_artifact/3` and `spec_has_needs_human?/2` in `test/speckit_orchestrator/run_feature_phase_test.exs`
- [ ] T043 [P] [US3] Unresolved task list makes `TaskPlan.load/2`/`ChunkRunner` fall back to the unstructured plan and dispatch, rather than adopting another feature's completed list, in `test/speckit_orchestrator/chunk_runner_test.exs`

### Implementation for User Story 3

- [ ] T044 [US3] Compose `SpecDir` candidate 1 (`<worktree>/specs/<spec_id>-<slug>`) from `spec_id` instead of `id` in `lib/speckit_orchestrator/spec_dir.ex` (depends on T002)
- [ ] T045 [US3] Constrain candidate 2 (`.specify/feature.json`'s `feature_directory`) to `Path.basename/1`'s numeric prefix `== spec_id`, closing the stacked-worktree leak of the previous feature's directory, in `lib/speckit_orchestrator/spec_dir.ex` (depends on T044)
- [ ] T046 [US3] Constrain candidate 3 (`specs/<spec_id>-*`) to exactly one wildcard match; two or more ⇒ unresolved, never settled by ordering (FR-010), in `lib/speckit_orchestrator/spec_dir.ex` (depends on T044)

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: prove the three pieces catch the real production failure together, and bring documentation up to date.

- [ ] T047 Regression test reproducing the observed failure — a feature whose wave number collides with an existing spec directory, whose `:tasks` phase reports success while writing nothing, fails at `:tasks` naming it, never reaches a later phase, and never reads the colliding feature's files (FR-017) — in `test/speckit_orchestrator/spec_number_split_regression_test.exs` (depends on T029, T039, T044, T045, T046)
- [ ] T048 [P] Update `docs/runbook.md` — reading both numbers on the console/report, the new FR-003a refusal
- [ ] T049 [P] Update `docs/workflow.md` — the two independent nets in the phase loop
- [ ] T050 [P] Update root `CLAUDE.md` — `Feature`, `SpecDir`, and schema-version descriptions (`spec_number`, schema v5, `SpecNumber`, `Checkpoint`)
- [ ] T051 Run full quickstart validation (`quickstart.md` §1–9): `mise exec -- mix test`, `mise exec -- mix test --cover` (`SpecNumber`/`Checkpoint` at 100%, pure core >90%), the migration integration test, and the manual scratch-repo smoke

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup — BLOCKS all user stories (every story's code and tests touch `Feature.spec_number` or the store).
- **User Story 1 (Phase 3)**: depends on Foundational only. No dependency on US2/US3.
- **User Story 2 (Phase 4)**: depends on Foundational only (`Checkpoint` needs `SpecDir.file/3`, which already exists pre-022; it does not need US1's allocation or US3's candidate constraints). Independently testable with net one untouched.
- **User Story 3 (Phase 5)**: depends on Foundational only (`spec_id/1` from T002). Independently testable with net two untouched.
- **Polish (Phase 6)**: depends on all three stories — the regression test exercises allocation (US1), the empty-checkpoint net (US2), and resolution (US3) together.

### Within Each User Story

- Tests before implementation (write first, confirm they fail).
- `SpecNumber`/`Checkpoint` (pure modules) before the code that calls them.
- `SpecDir`/`Worktree` changes before the executor/boundary code that depends on their new behaviour.

### Parallel Opportunities

- Foundational: T002, T003, T009, T010 in parallel (different files, no cross-dependency); T005/T008 after T003; T012–T016 in parallel once their respective implementation task lands.
- Once Foundational completes: **US1, US2, and US3 can proceed fully in parallel** — they touch disjoint files (`spec_number.ex`+`worktree.ex`+`speckit_orchestrator.ex` vs. `checkpoint.ex`+`run_feature_phase.ex`+`feature_runner.ex` vs. `spec_dir.ex`) and none reads the others' new code.
- Within US1: T017–T019, T021–T024 in parallel; T030–T033 in parallel once T002 lands.

---

## Parallel Example: Foundational phase

```bash
# Launch independent foundational tasks together:
Task: "Add spec_number field, spec_id/1, spec_label/1 to lib/speckit_orchestrator/feature.ex"
Task: "Append :spec_number attribute to speckit_feature_run in lib/speckit_orchestrator/store/schema.ex"
Task: "Backlog-parsed features carry explicit spec_number: nil in lib/speckit_orchestrator/backlog.ex"
Task: "Ad-hoc features carry explicit spec_number: nil in lib/speckit_orchestrator/single_spec.ex"
```

## Parallel Example: after Foundational

```bash
# Launch all three user stories together — disjoint files:
Task: "User Story 1 — spec_number.ex, worktree.ex, speckit_orchestrator.ex, report.ex, run_detail_live.ex, escalations_live.ex"
Task: "User Story 2 — checkpoint.ex, actions/run_feature_phase.ex, feature_runner.ex"
Task: "User Story 3 — spec_dir.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (blocks everything).
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: run a wave-2 feature against a target already holding an earlier wave's colliding spec directory (US1's Independent Test). This alone removes the defect that makes waves 2+ unsafe.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. Add User Story 1 → validate independently → the identity/collision defect is fixed.
3. Add User Story 2 → validate independently → a false-green `tasks` phase now fails loud.
4. Add User Story 3 → validate independently → resolution can no longer cross features even where a collision still exists.
5. Phase 6 proves all three together via the regression test and closes out docs.

### Parallel Team Strategy

1. Team completes Setup + Foundational together (one path through the store/schema work).
2. Once Foundational is done, three people can each own one story — disjoint files, no shared state.
3. Regress and merge in Phase 6 once all three land.

---

## Notes

- [P] tasks = different files, no unmet dependency.
- [US1]/[US2]/[US3] label maps a task to its user story for traceability.
- Each story is independently completable and testable per its own Independent Test in spec.md.
- Verify tests fail before implementing.
- Commit after each task or logical group.
- Stop at any checkpoint to validate a story independently before moving on.
