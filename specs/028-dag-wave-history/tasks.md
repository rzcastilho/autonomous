---

description: "Task list for 028-dag-wave-history"
---

# Tasks: Pipeline Chain Shows Each Wave's Own History

**Input**: Design documents from `/specs/028-dag-wave-history/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/wave-history.md, contracts/dag-surface.md, quickstart.md

**Tests**: Required — spec FR-011 and plan.md's Testing section both mandate automated coverage; quickstart.md lists the exact test files.

**Organization**: Tasks are grouped by user story (US1 P1, US2 P2, US3 P3) per spec.md priorities.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: Maps the task to US1/US2/US3
- All commands run through `mise exec --` per CLAUDE.md; git/gh through `rtk`

## Path Conventions

Existing single-project OTP/Phoenix layout (see plan.md's Project Structure) — no new setup phase is needed; this feature only touches:

- `lib/speckit_orchestrator/wave_history.ex` (new)
- `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- `lib/speckit_orchestrator/web/components/core_components.ex`
- `priv/static/assets/console.css`
- `test/speckit_orchestrator/wave_history_test.exs` (new)
- `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- `test/speckit_orchestrator/web/phase_strip_test.exs`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure resolution module every story's LiveView work builds on

**⚠️ CRITICAL**: No user story implementation can begin until T001 exists

- [X] T001 Create `SpeckitOrchestrator.WaveHistory` (new pure module, no Mnesia/Coordinator/PubSub/LiveView dependency) with `@type source :: {:live, map()} | {:recorded, map()} | :none | {:unavailable, term()}` and `source_for(slug, history)` implementing contracts/wave-history.md's 4-rule table (skip `%{damaged: true}` and non-`{:breakdown, _}` scopes) in `lib/speckit_orchestrator/wave_history.ex`
- [X] T002 [P] Unit tests for `source_for/2`: live match, recorded match in each of `:parked`/`:completed`/`:superseded`, ad-hoc scope skipped, damaged summary skipped, two runs of the same wave (newest wins unless the other is in-flight), `{:error, _}` history, and empty history in `test/speckit_orchestrator/wave_history_test.exs`

**Checkpoint**: `WaveHistory.source_for/2` compiles and its unit tests pass — US1 implementation can start

---

## Phase 3: User Story 1 - Another wave never shows the last run's phases (Priority: P1) 🎯 MVP

**Goal**: Selecting a wave draws only that wave's own scoped run (live or recorded) — the cross-wave leak (root cause R1) is closed

**Independent Test**: Finish a run for one wave, select a different wave with overlapping feature ids, verify no leaked status/phases/spend on nodes or in the drawer; verify the run's own wave still shows its recorded state

### Tests for User Story 1

- [X] T003 [US1] LiveView test: a completed run for wave `beta`'s `001` (with phases + spend), no run in flight, select `alpha` → `alpha`'s `001` is `data-status="pending"`, no `phase-cell-completed`, `$0.00` (FR-001/FR-002, SC-001) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T004 [US1] LiveView test: same setup as T003, click `alpha`'s `001` node → the drawer shows none of `beta`'s run state (FR-003) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T005 [US1] LiveView test: an in-flight `beta` run, select `alpha`, broadcast `{:console, :feature_updated, ...}` for `001` → `alpha`'s `001` node is unchanged (FR-004) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T006 [US1] LiveView test: a completed `beta` run, select `beta` itself → `beta`'s `001` node shows that run's recorded status, phases, spend (FR-005, US1 scenario 3) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`

### Implementation for User Story 1

- [X] T007 [US1] Remove `run_package/1` and `drawing_run_package?/1`; at `mount/3` and on `select_package`, resolve `wave_source = WaveHistory.source_for(selected_package, SpeckitOrchestrator.run_history())` and assign it (replaces the `run_package` assign) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T008 [US1] For a `{:recorded, s}` source, fetch `SpeckitOrchestrator.run_detail(s.run_id)` and hydrate it through `ConsoleReadModel.hydrate/3` over a fresh inactive view (`%{active?: false, per_feature: %{}, observed: %{}}`), assigned as `wave_view` in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T009 [US1] Rewrite `chain_view/1` to source `per_feature` from `assigns.view` for `{:live, _}`, `assigns.wave_view` for `{:recorded, _}`, and `%{}` for `:none`/`{:unavailable, _}`; keep the legacy `selected_package == nil` path drawing `assigns.view` ungated (FR-009) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T010 [US1] Update `drawer_feature/3` to read the backlog node's state from the same resolved map `chain_view/1` used, so the drawer never disagrees with the node (FR-003) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T011 [US1] Re-resolve `wave_source`/`wave_view` on `select_package`, on `{:console, :run_finished, _}`, and on a `{:console, :reconciled, _}` tick only when `SpeckitOrchestrator.current_run_id/0` differs from a newly cached `live_run_id` assign; leave `view` (live model) as the only thing `feature_updated` ever mutates (FR-004, R5) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`

**Checkpoint**: User Story 1 is fully functional and independently testable — the reported leak is fixed

---

## Phase 4: User Story 2 - Each wave shows its own most recent recorded run (Priority: P2)

**Goal**: Every wave (not just the live one) draws its own most recent run — with a visible receipt, interrupted mid-run features drawn honestly, and unreadable records failing safely

**Independent Test**: With recorded runs for two different waves, select each and verify each shows exactly its own most recent run's status/phases/spend, including a mid-run feature drawn as interrupted and a visible run receipt

### Tests for User Story 2

- [X] T012 [US2] LiveView test: completed runs for both `alpha` and `beta`, select each in turn → each shows its own run's status/phases/spend (US2-1, SC-002) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T013 [US2] LiveView test: two `alpha` runs (older `001: :done`, newer `001: :halted`) → selecting `alpha` shows `:halted` with no merged phases (US2-2, FR-006) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T014 [US2] LiveView test: `alpha` never run → cold nodes, `data-wave-source="none"` (US2-3) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T015 [US2] LiveView test: a superseded `alpha` run with `003` recorded `:running`, checkpoint `last_completed_phase: :tasks` → `003` is `data-status="blocked"`, reads "Interrupted", has `phase-cell-interrupted` on the next phase, and no `phase-cell-active` anywhere on the node (US2-4, FR-007a) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T016 [US2] LiveView test: a completed `beta` run → `data-wave-source="recorded"`, `run_id` linked to `/runs/<run_id>`, state reads `:completed` (US2-5, FR-007) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T017 [US2] LiveView test: `alpha`'s newest summary is readable but its `run_detail` is damaged → cold nodes, `data-wave-source="unavailable"`, no status color, no `beta` state bleed-through (FR-010) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T018 [P] [US2] Test: an interrupted phase cell renders `phase-cell-interrupted`, never `phase-cell-active`, and matches no `scPulse` selector in `test/speckit_orchestrator/web/phase_strip_test.exs`
- [X] T019 [P] [US2] Unit tests for `WaveHistory.interrupt/2`: `:running` with a checkpoint, `:running` with no checkpoint (`current_phase: nil`), `:running` on the final phase (status changes, `phases` untouched), terminal-status rows unchanged, `run_state: :in_flight` always unchanged, in `test/speckit_orchestrator/wave_history_test.exs`

### Implementation for User Story 2

- [X] T020 [US2] Implement `WaveHistory.interrupt/2` and `interrupt_all/2` per contracts/wave-history.md: on non-`:in_flight` `run_state` and `row.status == :running`, set `status: :interrupted` and mark the phase after `current_phase` (or the first phase when `nil`) `%{state: :interrupted}`, leaving earlier `:completed` cells and any other row untouched in `lib/speckit_orchestrator/wave_history.ex`
- [X] T021 [US2] Apply `WaveHistory.interrupt_all/2` (using the source's `state`) to the rows built for `wave_view` in T008 in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T022 [P] [US2] Add `status_class(:interrupted)` → `"blocked"` and the `:interrupted` entry in the labels map (→ `"Interrupted"`), following the `:never_started` precedent in `lib/speckit_orchestrator/web/components/core_components.ex`
- [X] T023 [US2] Add `phase_cell_state(%{state: :interrupted}, _status)` → `"interrupted"` clause (depends on T022 landing first in the same file) in `lib/speckit_orchestrator/web/components/core_components.ex`
- [X] T024 [P] [US2] Add `.phase-cell-interrupted { background: var(--blocked); }` (no `animation`, tokens only, passes the design-contract guard) in `priv/static/assets/console.css`
- [X] T025 [US2] Render the source receipt strip `<div class="dag-wave-source" data-wave-source="...">` under `.dag-canvas-header` whenever `selected_package != nil`, per contracts/dag-surface.md's `recorded`/`live` variants (run id linked to `/runs/:run_id` in mono + state in mono) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T026 [US2] Render the `{:unavailable, reason}` variant of the strip and cold nodes: "History for `<slug>` could not be read" plus the `run_id` in mono when known, neutral text tokens only, never a status color (FR-010) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T027 [US2] Render the `:none` variant of the strip and cold nodes: "No recorded run for `<slug>`", no link, no call to action (FR-010) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`

**Checkpoint**: User Stories 1 AND 2 both work independently — every wave shows its own truthful history

---

## Phase 5: User Story 3 - Default wave follows the most recent activity (Priority: P3)

**Goal**: With no run in flight, opening the Pipeline Chain lands on the wave of the most recent recorded run instead of the first alphabetically

**Independent Test**: With a finished `beta` run and no run in flight, open the view fresh and verify the picker selects `beta`

### Tests for User Story 3

- [X] T028 [US3] LiveView test: no run in flight, most recent recorded run scoped to `beta`, fresh mount → `beta` is `selected` (US3-2, SC-004) in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T029 [P] [US3] Unit tests for `WaveHistory.default_package/2`: in-flight wins, newest non-damaged `{:breakdown, _}` wins when nothing is in flight, ad-hoc-only history falls back to `List.first(packages)`, a summary's slug not in `packages` is skipped, `{:error, _}`/no runs falls back to `List.first(packages)`, `packages == []` → `nil`, in `test/speckit_orchestrator/wave_history_test.exs`

### Implementation for User Story 3

- [X] T030 [US3] Implement `WaveHistory.default_package/2` per contracts/wave-history.md's 4-rule table in `lib/speckit_orchestrator/wave_history.ex`
- [X] T031 [US3] Replace the LiveView's `current_run_detail`-based `default_package/2` at `mount/3` with `WaveHistory.default_package(packages, SpeckitOrchestrator.run_history())` in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`

**Checkpoint**: All three user stories are independently functional

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T032 [P] Run the full existing `pipeline_dag_live_test.exs` suite (live-wave, ad-hoc lane, legacy no-packages layout, empty/invalid backlog) and confirm every pre-existing case still passes unchanged (SC-005)
- [X] T033 [P] Run `mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs` — confirm the guard stays clean (no new literals, no duplicated status value, no unlisted keyframe)
- [X] T034 Run the full quickstart.md validation sequence (`wave_history_test.exs`, `pipeline_dag_live_test.exs`, `phase_strip_test.exs`, `design_contract_test.exs`, full `mix test`) via `mise exec --`
- [X] T035 Grep for stray references to the removed `run_package`/`drawing_run_package?/1` helpers across `lib/` and `test/` to confirm full removal

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 2)**: No dependencies — BLOCKS all user stories (`WaveHistory.source_for/2` is used by every story's LiveView wiring)
- **User Story 1 (Phase 3)**: Depends on Phase 2 only
- **User Story 2 (Phase 4)**: Depends on Phase 2 and on US1's `wave_view`/`chain_view` plumbing (T007–T011) already existing — it adds `interrupt/2` and the receipt strip on top
- **User Story 3 (Phase 5)**: Depends on Phase 2 only; independent of US1/US2's LiveView changes beyond the shared `mount/3` (touches a different assign, `selected_package`'s initial value)
- **Polish (Phase 6)**: Depends on all three stories being complete

### Within Each User Story

- Tests are written first and must fail before the implementation tasks land
- `WaveHistory` pure functions before the LiveView wiring that calls them
- `chain_view`/`wave_view` plumbing (US1) before the receipt strip and interrupt rendering (US2), since both read the same `wave_source`/`wave_view` assigns

### Parallel Opportunities

- T001 and T002 are sequential (T002 tests T001's code) despite different files — `WaveHistory` doesn't exist until T001 lands
- T018, T019 (US2 tests) and T022, T024 (US2 impl) touch different files and can run in parallel with each other
- T029 (US3 unit tests) can run in parallel with any US2 task — different concern, different function

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (`WaveHistory.source_for/2`)
2. Complete Phase 3: User Story 1 — this alone fixes the reported bug
3. **STOP and VALIDATE**: run T003–T006 against `mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
4. Ship the leak fix if US2/US3 aren't ready yet — US1 is a complete, correct behavior on its own (a non-current wave draws cold rather than its own history, which is truthful, just less informative)

### Incremental Delivery

1. Foundational → US1 (leak closed, MVP) → US2 (own-wave history + receipt + interrupted) → US3 (default wave convenience) → Polish
2. Each story is independently testable per its Independent Test in spec.md

## Notes

- [P] tasks = different files, no dependency on an incomplete task
- Same-file tasks within a story are ordered but not marked [P], even when logically independent, to avoid edit conflicts
- Commit after each task or logical group; run `rtk git status`/`rtk git diff` before committing
- `warnings_as_errors` is on — every task must leave `mise exec -- mix compile` clean
