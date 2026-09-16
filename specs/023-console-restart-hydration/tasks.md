---

description: "Task list for Console Restart Hydration"
---

# Tasks: Console Restart Hydration

**Input**: Design documents from `/specs/023-console-restart-hydration/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/console-hydration.md, contracts/console-views.md

**Tests**: Included — plan.md's Testing section and Scale/Scope explicitly enumerate the test files as deliverables (1 new + 3 amended), and constitution Principle I targets >90% coverage on the pure core (this module: 100%).

**Organization**: Tasks are grouped by user story per spec.md priorities (US1 P1, US2 P1, US3 P2). All three stories share one pure module (`ConsoleHydration`), built once in Foundational, then wired/exercised per story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps task to US1/US2/US3; Setup/Foundational/Polish tasks carry no story label
- File paths are exact and repo-relative

## Path Conventions

Single Elixir/OTP application, existing layout (plan.md Project Structure):

- `lib/speckit_orchestrator/console_hydration.ex` — NEW pure module
- `lib/speckit_orchestrator/console_read_model.ex` — amended
- `lib/speckit_orchestrator/web/live/mission_control_live.ex` — amended
- `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` — amended
- `lib/speckit_orchestrator/web/components/feature_drawer.ex` — amended
- `test/speckit_orchestrator/console_hydration_test.exs` — NEW
- `test/speckit_orchestrator/console_read_model_test.exs` — amended
- `test/speckit_orchestrator/web/mission_control_live_test.exs` — amended
- `test/speckit_orchestrator/web/pipeline_dag_live_test.exs` — amended

All commands run through `mise exec --` (repo toolchain rule); `warnings_as_errors` is ON.

---

## Phase 1: Setup

**Purpose**: Confirm a clean baseline before touching hydration code.

- [X] T001 Run `mise exec -- mix compile` and `mise exec -- mix test` from repo root to confirm the tree is green before any change (no code change; establishes the regression baseline for SC-007)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure `ConsoleHydration` module (`from_record/3`, `layer/2`, `apply_update/2`) that every user story depends on, per contracts/console-hydration.md §1–4.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T002 Create `lib/speckit_orchestrator/console_hydration.ex` with module doc, `@type recorded_slice()`/`row()` (data-model.md "Recorded row slice"), and `@spec` stubs for `from_record/3`, `layer/2`, `apply_update/2`
- [X] T003 Implement `ConsoleHydration.from_record/3` per contract rules 1.1–1.4 and 1.6–1.11: phase-cell eligibility filtered to `Pipeline.phases/0` (FR-003), last-attempt-wins per phase carrying its own outcome/model/cost (FR-002), `current_phase` from `checkpoint.last_completed_phase`, later cells dropped unless `current_phase` is `nil` (FR-002a), spend as the sum of cost entries whose `id` is in the feature's attempt-id set (FR-005), `elapsed_ms` from `(ended_at || now) - started_at` (FR-006/FR-007), `pr_url`/`chunk`/`slug`/`group`/`spec_number`/`status` passthrough, and `Map.get`-only field access so absent fields never raise (FR-013) in `lib/speckit_orchestrator/console_hydration.ex`
- [X] T004 Implement `ConsoleHydration.from_record/3` rule 1.5: for a feature with `status ∈ [:escalated, :halted, :failed]` and non-nil `current_phase`, the cell at `current_phase` becomes `%{state: :active, outcome: status, cost: <attempt.cost_usd | nil>, model: <attempt.model | nil>}` while every earlier cell stays `:completed` (FR-004) in `lib/speckit_orchestrator/console_hydration.ex`
- [X] T005 Implement `ConsoleHydration.layer/2` per contract §2–§3 seed/reconcile column: `phases` = `Map.merge(record.phases, live.phases)` then trim cells later than any `live.phases` cell with `state: :active`; `status`/`slug`/`group`/`spec_number` live-if-present else record; `current_phase` = live active phase → live `current_phase` → record; `spend` = `max(record.spend, live.spend)`; `elapsed_ms` = record if non-nil else live; `pr_url`/`chunk` live-if-non-nil else record; `remediation` = live; `chunk_cost_seen` dropped; handles either argument being `nil` in `lib/speckit_orchestrator/console_hydration.ex`
- [X] T006 Implement `ConsoleHydration.apply_update/2` per contract §3–§4 update column: `phases` merged then trimmed after the update's active phase without blanking untouched earlier cells; `spend` = `max(row.spend, update.spend)` (never decreases); `pr_url` update-if-non-nil else row; `chunk`/`remediation`/`current_phase` replaced by the update (nil clears); `chunk_cost_seen` dropped; `update == nil` returns `row` unchanged; a missing row starts from the documented default shape (`status: :pending, elapsed_ms: nil, phases: %{}, spend: 0.0, …`) in `lib/speckit_orchestrator/console_hydration.ex`
- [X] T007 Write pure tests in `test/speckit_orchestrator/console_hydration_test.exs` for `from_record/3` baseline behavior: a `:done` feature recorded through all seven phases yields seven completed cells + correct spend + `elapsed = ended_at - started_at` (US1-1); non-phase attempts (`:remediation`, `:implement_chunk`, `:auto_remediation`) never produce a cell and chunk attempts add no spend (FR-003/FR-005); a phase with multiple attempts uses the last attempt's own cost (clarification 2)
- [X] T008 [P] Write pure tests in `test/speckit_orchestrator/console_hydration_test.exs` for `layer/2` and `apply_update/2` properties from contract §3: idempotence, monotone spend, no-blanking of untouched earlier cells, live-wins-per-phase, and the `nil`-argument cases

**Checkpoint**: `ConsoleHydration` compiles, is fully unit-tested in isolation, and is ready for every user story to consume.

---

## Phase 3: User Story 1 - Finished features keep their history across a restart (Priority: P1) 🎯 MVP

**Goal**: Mission Control and the Pipeline Chain render a finished feature's full phase strip, spend, and elapsed from the durable record, in both cold-boot and live (post-resume) modes.

**Independent Test**: With a run record holding two finished features (all phases, costs, timestamps) and no live activity touching them, open `/` cold and again with a live Coordinator resumed over the same store — both show seven completed cells, correct spend, and non-`—` elapsed.

- [X] T009 [US1] Replace `ConsoleReadModel.overlay_last_known_statuses/2` with `hydrate/3` per contract §5: live mode iterates `view.per_feature`'s keys only (never adds a record-only feature, FR-008) and layers `from_record(f, cost_entries, now)` under the live row; cold mode (`view.active? == false`) builds/`Map.put_new`s rows from the record via `layer(from_record(f, cost_entries, now), nil)`, then still calls `overlay_observed/1`; `run_detail == nil` or `run_detail.features` not a list leaves the view unchanged in `lib/speckit_orchestrator/console_read_model.ex`
- [X] T010 [US1] Update `overlay_observed/1` to merge each live slice via `ConsoleHydration.layer/2` instead of `Map.merge`, keeping its existing promotion rule (a feature with a live `:active` cell becomes `:running`) in `lib/speckit_orchestrator/console_read_model.ex`
- [X] T011 [P] [US1] Write/amend tests in `test/speckit_orchestrator/console_read_model_test.exs` for `hydrate/3`: live mode fills every coordinator-listed row from the record and ignores a record-only feature (FR-008); cold mode builds full rows from the record; `overlay_observed/1` still promotes on a live active phase without blanking record cells
- [X] T012 [US1] Wire `MissionControlLive` mount/seed and `:reconciled` handling to call `ConsoleReadModel.hydrate(view, current_run_detail(), DateTime.utc_now())` in place of the prior overlay call in `lib/speckit_orchestrator/web/live/mission_control_live.ex`
- [X] T013 [US1] Wire `PipelineDagLive` mount/seed and `:reconciled` handling to call `hydrate/3` the same way (run_detail already fetched for `default_package/2`) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T014 [US1] Add cold-boot and live-Coordinator LiveView tests in `test/speckit_orchestrator/web/mission_control_live_test.exs`: two `:done` features recorded through all seven phases (attempts + cost entries + `started_at`/`ended_at`) render seven `phase-cell-completed`, correct `$<spend>`, and non-`—` elapsed with **no** Coordinator (US1-5) and identically with a live Coordinator started over the same store (US1-1); a feature finished in the current session shows the same elapsed one tick later (US1-3, SC-005); other features' live telemetry does not change a finished row (US1-2)
- [X] T015 [P] [US1] Add a Pipeline Chain LiveView test in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: a `:done` pre-restart feature's DAG node carries the same phase cells and spend as its Mission Control row (US1-4)

**Checkpoint**: User Story 1 is independently functional and testable — finished features render correctly cold and live.

---

## Phase 4: User Story 2 - The resumed feature shows its whole history (Priority: P1)

**Goal**: A feature resumed mid-pipeline shows pre-restart phases completed, the live phase active, elapsed from its original start, and live updates never blank its pre-restart cells; the drawer shows model alongside cost for every completed cell.

**Independent Test**: Record a feature through four phases, restart, resume it, open `/` while phase five runs — cells 1–4 completed, cell 5 active, elapsed from the original recorded start; a live update carrying only since-boot phases leaves cells 1–4 untouched.

- [X] T016 [US2] Replace the `Map.merge(row, slice)` handling of `{:console, :feature_updated, %{feature: slice}}` with `ConsoleHydration.apply_update(row, slice)` in `lib/speckit_orchestrator/web/live/mission_control_live.ex`
- [X] T017 [US2] Apply the same replacement in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [X] T018 [US2] Update `FeatureDrawerComponent.timeline_meta/1` to render `"$<cost> · <model>"` when both are present, `"$<cost>"` or `"<model>"` alone otherwise, and the state word when neither is present (FR-016), for live and record-derived cells alike, in `lib/speckit_orchestrator/web/components/feature_drawer.ex`
- [X] T019 [US2] Add LiveView tests in `test/speckit_orchestrator/web/mission_control_live_test.exs`: a feature resumed at phase five with four pre-restart phases recorded renders cells 1–4 completed, cell 5 active, elapsed measured from the recorded start (US2-1); a feature resumed from `plan` with `tasks`/`analyze` recorded before the restart renders `plan` active and `tasks`/`analyze` pending (US2-5); sending `{:console, :feature_updated, %{id:, feature: since_boot_slice}}` after mount leaves the four pre-restart cells completed and spend non-decreasing (US2-2, SC-004); opening the drawer for that feature shows `$<cost> · <model>` for each completed pre-restart phase (US2-4)
- [X] T020 [P] [US2] Add a `console_hydration_test.exs` case for `from_record/3` on a feature resumed from an earlier phase: recorded attempts of phases later than `current_phase` render pending even though attempts exist (edge case, US2-5) in `test/speckit_orchestrator/console_hydration_test.exs`

**Checkpoint**: User Stories 1 and 2 both work independently; live updates no longer regress hydrated rows.

---

## Phase 5: User Story 3 - Diverted features keep their marker and their receipt (Priority: P2)

**Goal**: A feature that escalated, halted, or failed before the restart shows the diverted phase with its status marker and the recorded cost/model of that attempt, earlier phases completed, and non-empty spend/elapsed.

**Independent Test**: Record a feature halted at `analyze` with four completed phases before it, restart, open `/` with and without a resumed Coordinator — the `analyze` cell carries the halted marker with recorded cost/model, the four earlier cells are completed, spend and elapsed are non-empty.

- [X] T021 [P] [US3] Add a `console_hydration_test.exs` case asserting `from_record/3` rule 1.5 end-to-end: a feature halted at `analyze` with an attempt at that phase yields `%{state: :active, outcome: :halted, cost: <attempt cost>, model: <attempt model>}`, and the same with no attempt at that phase degrades to `cost: nil, model: nil` (FR-004) in `test/speckit_orchestrator/console_hydration_test.exs`
- [X] T022 [US3] Add a LiveView test in `test/speckit_orchestrator/web/mission_control_live_test.exs`: a feature halted at `analyze` before the restart renders `phase-cell-halted` with recorded cost/model, four earlier cells completed, and non-empty spend/elapsed, both cold and with a resumed Coordinator (US3-1/2)
- [X] T023 [US3] Add a LiveView test in `test/speckit_orchestrator/web/mission_control_live_test.exs`: an escalated feature with a recorded `pr_url` keeps that link after a live update whose slice carries `pr_url: nil` (US3-3, FR-011)

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Tolerance guarantees and final regression sign-off across all stories.

- [X] T024 [P] Add a `console_hydration_test.exs` case: a record whose feature lacks `phase_attempts`, `checkpoint`, `started_at`/`ended_at`, or `pr_url`, and a `run_detail` lacking `cost_entries`, all render via `from_record/3`/`layer/2` as empty cells / `nil` elapsed / `0.0` spend with no raise (FR-013, SC-006) in `test/speckit_orchestrator/console_hydration_test.exs`
- [X] T025 Run `mise exec -- mix test` (full suite, including `design_contract_test.exs`) and confirm no regressions and no new color/radius/font-size/spacing literal or status value (Principle VII gate, SC-007)
- [X] T026 Walk through `specs/023-console-restart-hydration/quickstart.md` steps 1–4 end-to-end and confirm each expected result

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — run first.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories — `ConsoleHydration` is consumed by every story.
- **User Story 1 (Phase 3)**: Depends on Foundational only. Delivers the MVP (finished-feature hydration, both modes).
- **User Story 2 (Phase 4)**: Depends on Foundational; reuses the read-model wiring US1 lands (`hydrate/3` call sites) but its own tasks (apply_update wiring, drawer, resume-specific tests) are additive, not blocking, on US1's files.
- **User Story 3 (Phase 5)**: Depends on Foundational only (rule 1.5 is already implemented in T004); its tasks are pure additions of tests plus one LiveView scenario.
- **Polish (Phase 6)**: Depends on all three stories being complete.

### Within Each Phase

- T003 → T004 → T005 → T006 are sequential (same file, each rule builds on the prior).
- T007 depends on T003–T004 (asserts their behavior); T008 depends on T005–T006.
- T009 depends on T003–T006 (calls `from_record/3`/`layer/2`); T010 depends on T009.
- T012/T013 depend on T009–T010 (the new `hydrate/3` must exist to be called).
- T016/T017 depend on T006 (`apply_update/2`); T018 is independent of T016/T017 (different file) but its test (part of T019) depends on it.

### Parallel Opportunities

- T008 (layer/apply_update tests) can start once T005–T006 land, in parallel with T007 if staffed separately (same file — sequence if solo).
- T011 (read-model tests) and T015 (DAG test) touch different files from T012/T013/T014 and from each other — parallelizable.
- T020, T021, T024 each add one case to `console_hydration_test.exs` in different phases; run them in phase order, not concurrently, since they share a file.
- Within Phase 3–5, any task marked `[P]` targets a file no other in-flight task in that phase touches.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1: Setup (baseline).
2. Phase 2: Foundational — `ConsoleHydration` complete and unit-tested.
3. Phase 3: User Story 1 — wire `hydrate/3` into both LiveViews, cold-boot and live tests green.
4. **STOP and VALIDATE**: run `mission_control_live_test.exs` and `pipeline_dag_live_test.exs`; the finished-feature defect (the bug that prompted this feature) is fixed.

### Incremental Delivery

1. Setup + Foundational → pure module ready, fully tested.
2. Add User Story 1 → finished features hydrate correctly, both modes → validate (MVP).
3. Add User Story 2 → resumed feature's full history + no-blank live updates + drawer model → validate.
4. Add User Story 3 → diverted-feature marker/receipt scenarios → validate.
5. Polish → tolerance case, full suite, quickstart walkthrough.

---

## Notes

- All three stories share one pure module built once in Foundational; story phases mostly add call-site wiring and test coverage, keeping each story's own file changes small and independently reviewable.
- `RunDetailLive`, `Store.Query`, `Records`, and `Writer` are out of scope (contracts/console-hydration.md §6) — no task touches them.
- No task introduces a new color, radius, font-size, spacing literal, table, or schema field (FR-015; Principle VII).
- Commit after each task or logical group; stop at each phase checkpoint to validate that story independently before continuing.
