---

description: "Task list for 024-elapsed-execution-time"
---

# Tasks: Elapsed Is Execution Time

**Input**: Design documents from `/specs/024-elapsed-execution-time/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/execution-time.md, contracts/console-views.md, quickstart.md

**Tests**: Included — spec.md SC-008 requires pure tests over synthetic records/events plus console tests for cold-boot, live, resume, and diverted paths, with the existing suite and the design guard staying green.

**Organization**: Grouped by user story. US1 and US2 (both P1) jointly deliver the execution-time mechanism — US1 owns the recorded/cold-union path, US2 owns the live-fold/growth path on top of it. US3 (P2) is a read-through of behavior US1+US2 already provide, validated with tests only.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no unmet dependency)
- **[Story]**: US1 / US2 / US3
- All Elixir commands run through `mise exec --` (`.tool-versions` pins 1.20.2-otp-28; `warnings_as_errors` is ON)

## Path Conventions

Single Elixir/OTP application, existing layout: `lib/speckit_orchestrator/`, `test/speckit_orchestrator/`. No new directories.

---

## Phase 1: Setup

**Purpose**: Confirm the starting state is clean before touching pure core, fold, or views.

- [X] T001 Run `mise exec -- mix compile` and `mise exec -- mix test` at repo root; confirm both are green before starting 024 changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure window algebra and the one emitter change every user story's fold and hydration logic builds on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T002 [P] Create `lib/speckit_orchestrator/execution_time.ex`: `@type ms`, `@type window`, `from_attempts/1`, `open/3`, `close/3`, `close_all/2`, `normalize/1`, `elapsed_ms/2`, `native_to_ms/1` — no Mnesia/Phoenix/Coordinator/`:telemetry`/clock dependency, `now` always a parameter (contracts/execution-time.md §1-2.5, data-model.md "Execution window")
- [X] T003 [P] Create `test/speckit_orchestrator/execution_time_test.exs`: disjoint/nested/partial-overlap/touching window union; monotone-in-`now` and close-never-lowers properties; `normalize/1` idempotence and closed-beats-open dedup by `{key, from}`; `from_attempts/1` over every phase atom (`:specify`…`:converge`, `:remediation`, `:implement_chunk`, `:auto_remediation`) skipping nil/non-DateTime/reversed timestamps without raising; roll-up-over-chunks and final-analyze-over-superseded-runs SC-006 parity (quickstart.md §1)
- [X] T004 Add `system_time: System.system_time()` to the `[:speckit, :feature, :terminal]` measurements in `emit_terminal/4`, `lib/speckit_orchestrator/feature_runner.ex:563-571` (contracts/execution-time.md §3 "Emitter obligation")
- [X] T005 Update the `[:speckit, :feature, :terminal]` entry in the `Telemetry` moduledoc to record the new `system_time` measurement, `lib/speckit_orchestrator/telemetry.ex:13` (depends on T004)

**Checkpoint**: pure algebra total and tested; the terminal emitter carries what the fold needs to close open windows. User story work can begin.

---

## Phase 3: User Story 1 - Elapsed tells the operator how long the pipeline worked on a feature (Priority: P1) 🎯 MVP

**Goal**: A feature's ELAPSED (Mission Control row, its drawer, the Pipeline Chain drawer) equals the union of its recorded phase-attempt windows — cold and live agree, roll-ups/superseded re-runs count once, the Coordinator's since-release counter never feeds it.

**Independent Test**: A run record whose feature finished all seven phases with known per-attempt durations and idle gaps between them reads the summed attempt time (not the calendar span) in both cold-boot Mission Control and Mission Control with a live Coordinator resumed over the same record; the drawer matches the row.

### Tests for User Story 1

- [X] T006 [P] [US1] Update `test/speckit_orchestrator/console_hydration_test.exs`: `from_record/3` derives `windows` via `ExecutionTime.from_attempts/1` and `elapsed_ms` via `ExecutionTime.elapsed_ms/2` (feature's own `started_at`/`ended_at` no longer read); `layer/3` unions `recorded.windows ++ live.windows`; cold-equals-live-at-rest; no-Coordinator-fallback (a live slice with `elapsed_ms: 1348 * 60_000` and no `windows` layers to `nil` over an empty record) (quickstart.md §2, contracts/execution-time.md §5.1-5.2, §5.4)
- [X] T007 [P] [US1] Update `test/speckit_orchestrator/console_read_model_test.exs`: `merge_per_feature/2` deletes the Coordinator's `:elapsed_ms` from every per-feature row (flip the existing `elapsed_ms == 1000` assertion to `refute Map.has_key?(row, :elapsed_ms)`) (quickstart.md §3, contracts/execution-time.md §4)
- [X] T008 [US1] Update `test/speckit_orchestrator/web/mission_control_live_test.exs`: US1-1 (seven attempts summing 40 min across a 20 h span read `40m 0s` not `1200m 0s`, cold and live), US1-2/SC-005 (finished feature's elapsed unchanged after a minute or other features' broadcasts), US1-4/US1-5/SC-006 (implement-chunk roll-up and superseded-analyze-run records read the same with and without the inner attempts), FR-009 (live Coordinator reporting `elapsed_ms: 80_880_000` for a feature with no attempts/no live phase renders `—`) (contracts/console-views.md §2)
- [X] T009 [US1] Update `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: US1-3 — the node drawer's `.drawer-stat-value` ELAPSED equals the Mission Control row's for the same record (contracts/console-views.md §3)

### Implementation for User Story 1

- [X] T010 [US1] `ConsoleHydration.from_record/3`, `lib/speckit_orchestrator/console_hydration.ex`: replace `elapsed_for/2` with `windows = ExecutionTime.from_attempts(phase_attempts)` / `elapsed_ms = ExecutionTime.elapsed_ms(windows, now)`; add `:windows` to `recorded_slice()`; remove the now-unused `elapsed_for/2` helper (contracts/execution-time.md §5.1)
- [X] T011 [US1] `ConsoleHydration.layer/2` → `layer/3` (adds `now :: DateTime.t()`), `lib/speckit_orchestrator/console_hydration.ex`: `windows = normalize((recorded.windows || []) ++ (live.windows || []))`, `elapsed_ms = ExecutionTime.elapsed_ms(windows, now)`; `@default_row` gains `windows: []` (depends on T010; contracts/execution-time.md §5.2)
- [X] T012 [US1] `ConsoleReadModel.merge_per_feature/2`, `lib/speckit_orchestrator/console_read_model.ex:506-520`: delete `:elapsed_ms` from the Coordinator status slice before merging the projection slice, so no per-feature row carries it (contracts/execution-time.md §4)
- [X] T013 [US1] `ConsoleReadModel.hydrate/3`, `lib/speckit_orchestrator/console_read_model.ex:387-421`: update both `ConsoleHydration.layer/2` call sites to `layer(recorded, live_row, now)` and `layer(ConsoleHydration.from_record(f, cost_entries, now), nil, now)` (depends on T011)

**Checkpoint**: cold and live ELAPSED agree, are correctly deduplicated across roll-ups/superseded attempts, and never fall back to the Coordinator's counter — User Story 1 is independently testable.

---

## Phase 4: User Story 2 - A running feature's elapsed grows only while a phase runs (Priority: P1)

**Goal**: A live phase's window accumulates through the console fold from its observed start, advances on each refresh while it runs, freezes between phases/parked/down, survives a restart+resume without double counting or dipping when the record lands.

**Independent Test**: Record a feature through four phases with known durations, restart, resume it, open Mission Control while the fifth phase runs — ELAPSED starts at the four durations' total plus the live fifth phase's time so far, grows roughly with the refresh interval, and continues without a jump or dip once the fifth phase's record arrives.

### Tests for User Story 2

- [X] T014 [P] [US2] Extend `test/speckit_orchestrator/console_read_model_test.exs`: `[:speckit, :phase | :remediation | :chunk, :start]` opens a window from `native_to_ms(system_time)`; `:stop`/`:exception` closes it at `from + native_to_ms(duration)`; a `:stop`/`:exception` with no open window, or a `:start` missing `system_time`, leaves `windows` unchanged; `[:speckit, :feature, :terminal]` with `system_time` closes every open window, without it leaves them (quickstart.md §3, contracts/execution-time.md §3) (sequence after T007)
- [X] T015 [P] [US2] Extend `test/speckit_orchestrator/console_hydration_test.exs`: `apply_update/3` is idempotent for a fixed `now`, never lowers `elapsed_ms`, and an update whose closed live window is contained in the row's recorded window leaves the value unchanged (FR-004) (quickstart.md §2, contracts/execution-time.md §5.4) (sequence after T006)
- [X] T016 [US2] Extend `test/speckit_orchestrator/web/mission_control_live_test.exs`: US2-1 (four recorded phases + live `:analyze` start reads their union plus time-since-start, grows on the next reconcile tick), US2-2/SC-004 (after the phase's `:stop` and its record landing, value is ≥ last live value and ≤ it + one reconcile interval), US2-3/FR-006 (a feature whose live phase has stopped shows the same elapsed across ticks), US2-4 (a feature resumed from `plan` with stale `tasks`/`analyze` attempts counts those windows too) (contracts/console-views.md §2) (sequence after T008)
- [X] T017 [US2] Extend `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: same live-growth/no-dip parity as Mission Control for the drawer (sequence after T009)

### Implementation for User Story 2

- [X] T018 [US2] `ConsoleReadModel` fold, `lib/speckit_orchestrator/console_read_model.ex`: `feature_slice/2`'s default map and the `feature_slice` type gain `windows: []`; `apply_event/4` clauses for `[:speckit, :phase | :remediation | :chunk, :start]` call `ExecutionTime.open/3` with `ExecutionTime.native_to_ms(measurements.system_time)`; `:stop`/`:exception` clauses call `ExecutionTime.close/3` with `from + ExecutionTime.native_to_ms(measurements.duration)`; the `[:speckit, :feature, :terminal]` clause calls `ExecutionTime.close_all/2` with `ExecutionTime.native_to_ms(measurements.system_time)` when present (depends on T002, T004; contracts/execution-time.md §3)
- [X] T019 [US2] `ConsoleHydration.apply_update/2` → `apply_update/3` (adds `now :: DateTime.t()`), `lib/speckit_orchestrator/console_hydration.ex`: `windows = normalize((row.windows || []) ++ (update.windows || []))`; `elapsed_ms = max_nil(row.elapsed_ms, ExecutionTime.elapsed_ms(windows, now))` with `max_nil(nil, x) = x`, `max_nil(x, nil) = x` (depends on T011; contracts/execution-time.md §5.3)
- [X] T020 [US2] `ConsoleReadModel.overlay_observed/1` → `overlay_observed/2` (threads `now`), `lib/speckit_orchestrator/console_read_model.ex:447-468`: its internal `ConsoleHydration.layer/2` call becomes `layer(recorded, known(slice), now)`; update both `hydrate/3` call sites to pass `overlay_observed(view, now)` (depends on T013, T011; contracts/execution-time.md §6)
- [X] T021 [US2] [P] `MissionControlLive.handle_info/2` for `:feature_updated`, `lib/speckit_orchestrator/web/live/mission_control_live.ex:94-96`: `ConsoleHydration.apply_update(Map.get(view.per_feature, id), feature, DateTime.utc_now())` (depends on T019)
- [X] T022 [US2] [P] `PipelineDagLive.handle_info/2` for `:feature_updated`, `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex:161-163`: `ConsoleHydration.apply_update(Map.get(view.per_feature, id), feature, DateTime.utc_now())` (depends on T019)

**Checkpoint**: a running feature's ELAPSED grows only while a phase is live, survives restart/resume, and reconciles without regressing when the record arrives — User Story 2 is independently testable.

---

## Phase 5: User Story 3 - Diverted and unstarted features read correctly (Priority: P2)

**Goal**: A halted/escalated/failed feature's ELAPSED includes every completed phase plus the attempt it diverted on; a feature with no recorded attempt and no live phase reads `—`.

**Independent Test**: A feature halted at `analyze` after four completed phases reads the five attempts' union, cold and live; a pending feature with no attempt and no live phase reads `—`.

No production change is expected here: `ExecutionTime.from_attempts/1` (T002) already includes every `phase_attempts` entry regardless of the feature's `status` — `ConsoleHydration.mark_diverted/3` only relabels the phase *cell*, never the attempt list `from_attempts/1` reads — and `ExecutionTime.elapsed_ms([], _now)` (T002) already returns `nil`, which `format_elapsed/1` already renders as `—`. This phase is validation.

### Tests for User Story 3

- [X] T023 [P] [US3] Extend `test/speckit_orchestrator/web/mission_control_live_test.exs`: US3-1 (halted at `analyze` after four completed phases reads all five recorded attempts' union, cold and live), US3-2 (a feature with no recorded attempt and no live phase reads `—`), US3-3 (a feature whose only activity is a live `:start` reads the seconds since it) (contracts/console-views.md §2) (sequence after T016)
- [X] T024 [P] [US3] Extend `test/speckit_orchestrator/console_hydration_test.exs`: a diverted feature's (`:escalated`/`:halted`/`:failed`) recorded attempt list includes the diverting phase's attempt, and `from_record/3`'s `elapsed_ms` includes its window — regression coverage that `mark_diverted/3` never touches `windows` (sequence after T015)

**Checkpoint**: all three user stories independently pass their acceptance scenarios.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Whole-suite and design-guard confirmation (SC-008).

- [X] T025 [P] Run `mise exec -- mix test` — full suite green, no regressions
- [X] T026 [P] Run `mise exec -- mix test test/speckit_orchestrator/design_contract_test.exs` — guard stays clean: no new color/radius/font-size/spacing literal, status value, keyframe, or inline style (Principle VII)
- [X] T027 [P] Run `mise exec -- mix test --cover` — `ExecutionTime` at 100% coverage; `ConsoleHydration`/`ConsoleReadModel` not below their 023 level
- [X] T028 Walk quickstart.md §1-5 end-to-end (§6 is an optional manual check against a real multi-day run record)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — BLOCKS all user stories (the fold and hydration changes in US1/US2 call `ExecutionTime` and read the terminal's `system_time`)
- **User Story 1 (Phase 3)**: depends on Foundational only
- **User Story 2 (Phase 4)**: depends on Foundational; its implementation tasks (T018-T022) additionally depend on User Story 1's `layer/3` and `hydrate/3` changes (T011, T013) — US2 is not independent of US1's code, only of US1's *test* pass/fail
- **User Story 3 (Phase 5)**: depends on User Story 1 and User Story 2 being implemented (it asserts on their combined behavior) but adds no code of its own
- **Polish (Phase 6)**: depends on all three user stories

### Within Each User Story

- Tests before or alongside implementation; all must pass before the story's checkpoint
- `ConsoleHydration` changes before `ConsoleReadModel` changes that call into it
- `ConsoleReadModel` changes before the LiveView call sites that depend on their new arity

### Parallel Opportunities

- T002 and T003 in parallel once Setup is done (module and its test file)
- T006 and T007 in parallel (different test files) at the start of US1
- T014/T015 in parallel with each other; T016/T017 in parallel with each other, all after their respective US1 predecessors land
- T021 and T022 in parallel (different LiveView files, same dependency)
- T023 and T024 in parallel
- T025, T026, T027 in parallel (independent test runs); T028 last

---

## Parallel Example: Foundational

```bash
# Launch together once Setup (T001) is green:
Task: "Create lib/speckit_orchestrator/execution_time.ex per contracts/execution-time.md §1-2.5"
Task: "Create test/speckit_orchestrator/execution_time_test.exs per quickstart.md §1"
```

## Parallel Example: User Story 1 tests

```bash
Task: "Update test/speckit_orchestrator/console_hydration_test.exs for from_record/3 + layer/3"
Task: "Update test/speckit_orchestrator/console_read_model_test.exs for merge_per_feature/2"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational)
2. Complete Phase 3 (User Story 1) — cold-boot and resumed-live ELAPSED already stop lying about idle time for every finished/halted feature
3. **STOP and VALIDATE**: run T006-T009's tests independently
4. This alone fixes the reported symptom (feature 003 reading 1348m) for any feature that is not currently mid-phase

### Incremental Delivery

1. Setup + Foundational → pure algebra ready
2. User Story 1 → finished/halted features read correctly, cold and live
3. User Story 2 → in-flight features grow only while running, survive restart/resume
4. User Story 3 → validate diverted/unstarted rendering (no new code)
5. Polish → full suite, design guard, coverage, quickstart walkthrough

---

## Notes

- No new Mnesia table/field, no new design token/status value, no new timer, no new event source (FR-014; plan.md "no persistence change").
- `Store.*`, `Records`, `Writer`, `Coordinator`, `Report`, `RunDetailLive`, `RunsLive`, and `format_elapsed/1` are out of scope and untouched.
- `Report.format_status/1` keeps reading the Coordinator's `elapsed_ms` directly from `Coordinator.status/0` — only the console's per-feature row drops it (T012).
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
