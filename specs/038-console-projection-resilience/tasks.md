# Tasks: Console Projection Survives Coordinator Timeouts

**Input**: Design documents from `/specs/038-console-projection-resilience/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/console-projection-resilience.md, quickstart.md

**Tests**: Included. Constitution (Quality & Test Discipline) requires hermetic tests for new pure core modules (>90%) and process behaviour via injected stubs.

**Toolchain**: every Elixir command via `mise exec -- …`; `warnings_as_errors` is on. Prefix git with `rtk`.

## Format: `- [ ] [TaskID] [P?] [Story?] Description with file path`

- **[P]**: different files, no dependency on an incomplete task
- **[Story]**: US1 (P1 crash-proofing), US2 (P2 history rebuild), US3 (P3 delayed notice)

---

## Phase 1: Setup

- [X] T001 Run baseline `mise exec -- mix compile` and `mise exec -- mix test test/autonomous/web test/autonomous/console_read_model_test.exs test/autonomous/console_hydration_test.exs` on branch `038-console-projection-resilience`; record that the suite is green before any change (SC-005 reference point)

---

## Phase 2: Foundational (blocking prerequisite)

**Purpose**: the exit-safe Coordinator boundary that US1 and US3 both consume.

- [X] T002 [P] Create `lib/autonomous/coordinator_probe.ex`: `status(server, timeout) :: {:ok, map()} | :none | {:error, :timeout | :down}` per contracts §1 — registered name not whereis / pid dead → `:none`; `catch :exit, {:timeout, _}` → `{:error, :timeout}`; any other exit → `{:error, :down}`; calls `Coordinator.status/2`-style `GenServer.call(server, :status, timeout)`; `@spec` and `@moduledoc`; never raises or exits
- [X] T003 [P] Create `test/autonomous/coordinator_probe_test.exs`: stub GenServer that answers; stub that sleeps past timeout (`{:error, :timeout}`, caller alive); unregistered name (`:none`); stub that exits mid-call (`{:error, :down}`); dead pid (`:none`)

**Checkpoint**: `mise exec -- mix test test/autonomous/coordinator_probe_test.exs` green.

---

## Phase 3: User Story 1 — A slow run controller does not wipe the console (P1) 🎯 MVP

**Goal**: A missed/slow `Coordinator.status/1` never terminates the projection, never clears feed/rows, never crashes a page or action; refresh resumes on the next tick.

**Independent Test**: With a stalled stub Coordinator and several folded events, the projection pid stays the same, `read/1` still returns the events, `read/1` answers during the stall, new events append, and after the stub is released the next `:reconciled` carries fresh status. Mission Control mounts under stall in < 3 s.

### Tests for US1

- [X] T004 [P] [US1] Create `test/autonomous/console_projection_resilience_test.exs` (US1 part): stub coordinator that never answers + `probe_timeout: 50`, `reconcile_ms: 20`; fold 3 phase telemetry events; wait ≥ 3 probe timeouts; assert same pid alive, feed intact, `read/1` answers immediately mid-probe, new event appends, then release stub and assert next `{:console, :reconciled, %{coordinator: status}}` has fresh status; assert no `ConsoleProjection` crash in `capture_log`
- [X] T005 [P] [US1] Extend `test/autonomous/web/mission_control_live_test.exs`: mount `/` with `Coordinator` name registered to a stalling stub → renders last-known/empty state in < 3 s without crash (FR-003, SC-004); `continue_run` event with a runner that blocks past the bounded wait → flash "could not reach", LiveView process still alive (FR-004)

### Implementation for US1

- [X] T006 [US1] Edit `lib/autonomous/console_projection.ex`: add start options `:probe_timeout` (default 5_000); add state `last_known: %{coordinator: nil, ledger: nil}`, `probe: nil`; on `:reconcile` start one `Task.async` running `CoordinatorProbe.status(coordinator, probe_timeout)` + exit-safe `Ledger.snapshot/1` (skip tick if `probe != nil`); handle `{ref, result}` (demonitor/flush) and `{:DOWN, ref, …}`; on success replace `last_known` and broadcast `{:console, :reconciled, %{coordinator:, ledger:}}` exactly as today; on `{:error, _}` leave `model` and `last_known` untouched and broadcast nothing yet (US3 adds notice); no blocking Coordinator call remains in any callback
- [X] T007 [US1] Edit `lib/autonomous/console_projection.ex`: add `last_known/1` (`GenServer.call`, rescued → empty map with `delayed?: false`) and `read_safe/1` (exit-safe `read/1` returning `ConsoleReadModel.new()` on absent/exit) per contracts §2
- [X] T008 [P] [US1] Edit `lib/autonomous/web/live/mission_control_live.ex`: `coordinator_status/0` → `CoordinatorProbe.status(Coordinator, 1_000)` mapped (`{:ok, s}` → s, `:none` → nil, `{:error, _}` → `ConsoleProjection.last_known().coordinator`); `ledger_snapshot/0` exit-safe with `last_known` fallback; use `ConsoleProjection.read_safe/0` in `seed/1` and the `:reconciled` handler
- [X] T009 [P] [US1] Edit `lib/autonomous/web/live/escalations_live.ex`: same probe + fallback + `read_safe/0` as T008 (`coordinator_status/0`, ledger, `ConsoleProjection.read`)
- [X] T010 [P] [US1] Edit `lib/autonomous/web/live/pipeline_dag_live.ex`: same probe + fallback + `read_safe/0` as T008
- [X] T011 [P] [US1] Edit `lib/autonomous/web/live/config_live.ex`: `coordinator_status/0` via probe with `last_known` fallback in the post-apply `:reconciled` broadcast
- [X] T012 [P] [US1] Edit `lib/autonomous/web/components/layouts.ex`: topbar `coordinator_status/0` via probe (1_000 ms) with `last_known` fallback so every render stays non-crashing
- [X] T013 [US1] Edit `lib/autonomous/web/live/mission_control_live.ex`, `escalations_live.ex`, `trigger_live.ex`: replace `run_unlinked/1` body (`async_nolink |> Task.await`) with bounded `Task.yield` — `{:ok, r}` → `r`; `{:exit, reason}` → `{:error, {:controller_unreachable, reason}}`; `nil` → `{:error, :controller_unreachable}` without `Task.shutdown`; make each caller's error branch flash "could not reach the run controller" without crashing (FR-004). Sequence after T008/T009 (same files)

**Checkpoint**: US1 tests (T004, T005) green; `mise exec -- mix test` unchanged elsewhere. MVP deliverable.

---

## Phase 4: User Story 2 — History survives the console's restart (P2)

**Goal**: On every projection start, feed and slices are rebuilt from the durable record of the in-flight (else parked) run, deduped against queued live events.

**Independent Test**: Seed a run with recorded attempts + a terminal feature, start the projection (or kill and let it restart), and see the recorded entries in chronological order, ≤ 200, no duplicates once live events follow.

### Tests for US2

- [X] T014 [P] [US2] Create `test/autonomous/console_history_test.exs`: run_detail with 2 features → expected entries/texts/severities (`run started`, `phase X started`, `phase X -> outcome`, `feature terminal …`, `PR opened: …`); chronological order and tie-break; `:implement_chunk` excluded; record missing timestamp ⇒ entry skipped; > 200 entries → newest 200; `nil`/empty → `ConsoleReadModel.new()`; `run_key` set; `rebuilt_keys` populated
- [X] T015 [P] [US2] Extend `test/autonomous/console_read_model_test.exs`: with `rebuilt_keys` containing `{id, phase, text}`, applying the matching live event returns the input model minus that key (feed and spend not doubled); non-matching event unchanged; empty `rebuilt_keys` ⇒ identical to today (FR-009); `clear_rebuilt/1`
- [X] T016 [US2] Extend `test/autonomous/console_projection_resilience_test.exs` (US2 part, after T004): `:history` loader returning a run_detail → feed shows recorded entries after start; kill projection and let it restart → feed rebuilt; parked run source; empty/`:none` loader → empty model; loader raising/erroring → one warning logged, projection still starts; a live stop event equal to the newest recorded one appears once

### Implementation for US2

- [X] T017 [P] [US2] Create `lib/autonomous/console_history.ex`: pure `rebuild(run_detail | nil, now \\ DateTime.utc_now())` per data-model §4 and research R6 — feed entries reuse the live fold's texts and `ConsoleReadModel` severity rules (expose the minimal helper from T018 rather than duplicating strings), sort chronologically, keep newest 200 stored newest-first, slices via `ConsoleHydration.from_record/3` reduced to feature_slice keys plus `chunk_cost_seen: 0.0`, `run_key: run.key`, `rebuilt_keys` MapSet; `@spec`s; no Mnesia/Phoenix/telemetry dependency
- [X] T018 [US2] Edit `lib/autonomous/console_read_model.ex`: `new/0` adds `rebuilt_keys: MapSet.new()` (keep `t()` type updated); in `apply_event/4` wrapper skip an event whose resulting feed head key `{feature_id, phase, text}` ∈ `rebuilt_keys` (return input model with key removed); add `clear_rebuilt/1`; expose public `severity_for_outcome/1`/`severity_for_status/1` (or an `entry_text` helper) that T017 shares. Must keep every existing clause/behaviour when the set is empty
- [X] T019 [US2] Edit `lib/autonomous/console_projection.ex`: `init/1` returns `{:ok, state, {:continue, :rebuild}}`; add `:history` option (default loader: `Autonomous.current_run_id/0` → `Autonomous.run_detail/1`, else `Store.parked_run/1` + `run_detail/1`); `handle_continue(:rebuild)` sets `model` from `ConsoleHistory.rebuild/1`, logging one `Logger.warning` and keeping `ConsoleReadModel.new()` on loader error/raise; clear `rebuilt_keys` on first successful probe

**Checkpoint**: T014–T016 green; killing the projection under a run with records shows the rebuilt feed.

---

## Phase 5: User Story 3 — Operator can tell a stale view from a quiet run (P3)

**Goal**: From the 2nd consecutive missed refresh, Mission Control shows a delayed-status line with last-known state; clears on first success; one rate-limited warning per stall.

**Independent Test**: Stub Coordinator that misses 1 then answers → no `delayed?: true` ever; misses 2+ → `:reconciled` with `delayed?: true` and `[data-console-delayed]` rendered; success → cleared; 10 misses → exactly one warning.

### Tests for US3

- [X] T020 [P] [US3] Create `test/autonomous/console_delay_test.exs`: `step/2` (success/`:none` → 0, error → +1), `delayed?/1` (<2 false, ≥2 true), `broadcast?/2` (:reconciled/:silent/:delayed), `log?/3` (first miss warn, rate-limit 60 s, recovered, quiet)
- [X] T021 [US3] Extend `test/autonomous/console_projection_resilience_test.exs` (US3 part): single miss then success → no `delayed?: true` broadcast; two misses → `{:console, :reconciled, %{delayed?: true, coordinator: last_known}}`; success → `delayed?: false`; 10 misses within 60 s → exactly one warning and zero errors in `capture_log`, one info on recovery
- [X] T022 [P] [US3] Extend `test/autonomous/web/mission_control_live_test.exs`: broadcast `:reconciled` with `delayed?: true` → `[data-console-delayed]` text present; then `delayed?: false` → absent; absent key treated as false; normal render has no delayed markup (SC-005)

### Implementation for US3

- [X] T023 [P] [US3] Create `lib/autonomous/console_delay.ex`: pure `step/2`, `delayed?/1` (≥ 2), `broadcast?/2`, `log?/3` exactly per data-model §3; `@spec`s
- [X] T024 [US3] Edit `lib/autonomous/console_projection.ex`: add state `misses: 0`, `warned_at: nil`; on probe result apply `ConsoleDelay.step/2`; broadcast per `broadcast?/2` — success: `:reconciled` with `delayed?: false`; second+ miss: `:reconciled` with `last_known` and `delayed?: true`; single miss: nothing; log per `log?/3` (`Logger.warning` first miss then ≤ 1/60 s; `Logger.info` on recovery; never `error`); `last_known/1` returns the current `delayed?`
- [X] T025 [US3] Edit `lib/autonomous/web/live/mission_control_live.ex`: put `delayed?` on `view` (from `Map.get(payload, :delayed?, false)` in the `:reconciled` handler; from `last_known().delayed?` on fallback seed; default false); render one line above the feed when `@view.delayed?`: `live status delayed — <mono>Coordinator.status/1</mono> not answering; showing last known state` with `data-console-delayed`. Existing tokens/classes only; no inline style, no new color, no animation
- [X] T026 [P] [US3] Edit `lib/autonomous/web/live/escalations_live.ex`, `pipeline_dag_live.ex`, `config_live.ex`: `:reconciled` handlers tolerate (ignore) the added `delayed?` key; `config_live.ex` broadcast includes `delayed?: false` (or `last_known` value on fallback)
- [X] T027 [US3] Edit `priv/static/assets/console.css` only if no existing notice class fits T025 — add a rule using `:root` tokens only (no literals); run `mise exec -- mix test test/autonomous/web/design_contract_test.exs`

**Checkpoint**: T020–T022 green, design contract guard green.

---

## Phase 6: Polish & Cross-Cutting

- [X] T028 [P] Edit `docs/runbook.md`: short section — delayed-status line meaning, single rate-limited warning, history rebuild on projection start, what is not recovered (live-only messages)
- [X] T029 [P] Update the `ConsoleProjection` moduledoc in `lib/autonomous/console_projection.ex` (no longer "rebuilds from `Coordinator.status/0` + telemetry" only; now record-rebuilt) and the telemetry/console notes in `CLAUDE.md` Observability section with a one-sentence feature-038 note
- [X] T030 `mise exec -- mix format --check-formatted`, `mise exec -- mix compile --warnings-as-errors`, then full `mise exec -- mix test` (SC-005: existing console suite unchanged, coverage of new pure modules `mix test --cover` > 90%)
- [X] T031 Run quickstart.md §2 manual stall (`:sys.suspend/resume` on the Coordinator) and projection-kill rebuild check in the container; record outcome at the bottom of quickstart.md

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 → US1 → US2 → US3 → Polish. US2/US3 both edit `console_projection.ex` and build on T006/T007, so they follow US1; US2 and US3 are otherwise independent (US3's pure `ConsoleDelay` T023/T020 can start any time after Phase 2).
- Within US1: T004/T005 (tests, parallel) → T006 → T007 → T008–T012 [P] (distinct files) → T013 (touches files from T008/T009 so after them).
- Within US2: T014, T015, T017 are parallel (T017 consumes helpers from T018 — do T018 first or together) → T019 → T016.
- Within US3: T020, T023, T022 parallel → T024 → T025 → T026 [P], T027 → T021.

## Parallel Examples

- After T002/T003: T004 ∥ T005, then T008 ∥ T009 ∥ T010 ∥ T011 ∥ T012.
- US2: T014 ∥ T015 (tests) while T018 lands, then T017.
- US3: T020 ∥ T023 ∥ T022 up front.
- Polish: T028 ∥ T029.

## Implementation Strategy

- **MVP = Phase 1–3 (US1)**: removes the observed crash and page-load failures. Ship-able alone.
- Increment 2: US2 (rebuild) — limits blast radius of any other restart cause.
- Increment 3: US3 (delayed notice) — honest display; depends on US1's `last_known`.
- Behaviour change vs. today only on the miss path and after a restart; the normal path stays byte-identical (FR-009), guarded by running the untouched existing suite at each checkpoint.
