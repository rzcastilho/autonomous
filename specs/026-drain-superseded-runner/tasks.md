---

description: "Task list for 026-drain-superseded-runner"
---

# Tasks: Drain the Superseded Runner

**Input**: Design documents from `/specs/026-drain-superseded-runner/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/workers.md, contracts/facade-supersession.md, quickstart.md

**Tests**: Included — spec's Independent Test criteria and quickstart.md scenarios are explicit and hermetic (stub workers, no CLI spend); each user story's contract is asserted by ExUnit tests written before its implementation.

**Organization**: Tasks are grouped by user story (US1, US2, US3) per spec.md priorities. All three stories share one new process-layer module (`Workers`) built in Foundational.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1, US2, or US3 — omitted for Setup/Foundational/Polish

## Path Conventions

Single OTP project. `lib/speckit_orchestrator/`, `test/speckit_orchestrator/`, `docs/`, repo-root `CLAUDE.md`.

---

## Phase 1: Setup

**Purpose**: No new dependencies, no scaffolding beyond what Foundational needs. This phase is empty by design — proceed to Foundational.

**Checkpoint**: N/A — Foundational starts immediately.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `Workers` registry/drain module and its pure `Bound` helper that every user story depends on. No worker can be findable or drainable until this phase is done.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T001 [P] Implement `SpeckitOrchestrator.Workers.Bound.wait_ms/3` (pure) in `lib/speckit_orchestrator/workers/bound.ex` per data-model.md § Drain bound: `remaining = max(0, diff_ms(deadline_at, now))` (nil `deadline_at` ⇒ `Config.phase_timeout/0`), `wait_ms = remaining + call_grace_ms + finalize_margin_ms`
- [X] T002 [P] Write `test/speckit_orchestrator/workers/bound_test.exs` covering: nil deadline uses `Config.phase_timeout/0`, past deadline clamps to 0 + grace + margin, future deadline adds full remaining, several-worker max is a caller concern (not `Bound`'s)
- [X] T003 Add `SpeckitOrchestrator.WorkerRegistry` (`Registry`, `keys: :duplicate`) to the supervision tree in `lib/speckit_orchestrator/application.ex`, positioned before `{Task.Supervisor, name: SpeckitOrchestrator.RunnerSup}`
- [X] T004 Add `SpeckitOrchestrator.Workers` (table owner: the ETS drain-request table, public, named) to the supervision tree in `lib/speckit_orchestrator/application.ex`, positioned before `RunnerSup`, after `WorkerRegistry`
- [X] T005 Implement `SpeckitOrchestrator.Workers` module skeleton in `lib/speckit_orchestrator/workers.ex`: `start_link/1` (owns the ETS table, named `:public`), `spawn(run_key, feature_id, fun) :: {:ok, pid()} | {:error, term()}` per contracts/workers.md (registers `{repo_id, %{feature_id, run_id, deadline_at: nil}}` as the child's first act before calling `fun`; `run_key == nil` ⇒ no registration; child MUST NOT be linked to caller or Coordinator)
- [X] T006 Implement `SpeckitOrchestrator.Workers.session_started(deadline_ms) :: :ok` in `lib/speckit_orchestrator/workers.ex` — owner-only `Registry.update_value/3` setting `deadline_at = now + deadline_ms`; no-op when caller unregistered
- [X] T007 Implement `SpeckitOrchestrator.Workers.drain_requested?() :: boolean()` in `lib/speckit_orchestrator/workers.ex` — pure ETS lookup keyed by `self()`, never consumes the latch
- [X] T008 Implement `SpeckitOrchestrator.Workers.in_flight(repo_id) :: [entry]` in `lib/speckit_orchestrator/workers.ex` — `Registry.lookup/2` scoped to `repo_id`, returns `%{pid, feature_id, run_id, deadline_at}` list
- [X] T009 Implement `SpeckitOrchestrator.Workers.drain(repo_id) :: :ok | {:error, {:drain_timeout, stuck}}` in `lib/speckit_orchestrator/workers.ex` per contracts/workers.md steps 1–5: empty `in_flight/1` ⇒ immediate `:ok`; otherwise monitor each pid, insert drain request, wait up to `Bound.wait_ms/3` max across entries for every `:DOWN`, delete all requests, emit `[:speckit, :drain, :start]`/`[:speckit, :drain, :stop]` telemetry with `%{repo_id, feature_ids}` / `%{result: :ok | :timeout}`. MUST NOT `Process.exit/2` a worker or stop its agent, including on timeout.
- [X] T010 [P] Write `test/speckit_orchestrator/workers_test.exs` with stub `RunnerSup` worker processes covering: registration scoping by `repo_id` (FR-007, a worker under another `repo_id` never appears), `drain/1` on empty registry returns `:ok` immediately with no wait (FR-012), `drain/1` waits for `drain_requested?/0`-observing stub to exit and returns `:ok`, `drain/1` times out on a stub that ignores the drain past its bound and names the stuck feature/run (FR-004), `drain/1` no-ops on an already-dead pid (edge case), `session_started/1` updates `deadline_at` and is owner-only, `spawn/3` with `run_key: nil` registers nothing

**Checkpoint**: `Workers` is fully unit-tested against stub processes. User story implementation can now begin.

---

## Phase 3: User Story 1 - Starting a new run never leaves the old one working (Priority: P1) 🎯 MVP

**Goal**: `run/1` (and `run_spec/2`) drains every in-flight worker for the target repository before superseding the prior run's record and releasing any feature — closing the two-sessions-one-working-copy defect from incident `r000002`.

**Independent Test**: Start a run while a prior run has a worker in flight (stubbed executor/session, no CLI spend). Observe the new run's executor is not invoked until the stub worker hits its boundary and exits; `Workers.in_flight/1` is empty before `Store.open_run/2` runs; the prior record's supersession outcome (`:superseded` / `:ended_by_supersession`) is unchanged.

### Tests for User Story 1

- [X] T011 [P] [US1] Write `test/speckit_orchestrator/supersession_drain_test.exs` covering quickstart.md's US1 rows: start-while-worker-in-flight blocks the new executor until the stub drains (AS1), no external session belonging to the prior run remains alive after supersession completes (AS2), no-worker start behaves exactly as today with no added delay (AS3, SC-005), and the superseded record/feature outcome is byte-identical to today (AS4, FR-010) — assert this FAILS before T014–T016

### Implementation for User Story 1

- [X] T012 [US1] Route all five direct `Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, …)` call sites in `lib/speckit_orchestrator.ex` (lines ~763, ~1484, ~1677, ~1985, ~2227 — `default_executor/5`, `seed_executor/3`, `resume_executor/8`, `resume_run_executor/5`, `split_resume_executor/6`) through `SpeckitOrchestrator.Workers.spawn/3`, passing each site's `run_key` and `feature_id`
- [X] T013 [US1] Wire `SpeckitOrchestrator.Workers.session_started/1` into every session-driving `AgentServer.call` immediately before the call: phase call in `lib/speckit_orchestrator/feature_runner.ex`, chunk call in `lib/speckit_orchestrator/chunk_runner.ex` (per-chunk `deadline_ms`), remediation call in `lib/speckit_orchestrator/analyze_runner.ex`
- [X] T014 [US1] Reorder the fresh-run path in `lib/speckit_orchestrator.ex` (`open_or_continue_run/3` / `run/1`) per contracts/facade-supersession.md: after existing preflights 1–6 unchanged, move "stop prior Coordinator" (`stop_previous_run/0`) earlier as step 7, add step 8 `Workers.drain(repo_id)`, then step 9 `Store.open_run/2` (supersedes record), then step 10 `run_stacked/4` as today; `run/1` **with** `:run_key` still skips 7–9
- [X] T015 [US1] On `Workers.drain/1` timeout at step 8, return `{:error, {:drain_timeout, stuck}}` from `run/1`/`run_spec/2` without calling `Store.open_run/2` or starting a Coordinator (FR-004, SC-006)
- [X] T016 [US1] Emit `[:speckit, :feature, :drained]` (not `[:speckit, :feature, :terminal]`) and log it in `lib/speckit_orchestrator/telemetry.ex`'s default logger attachment, distinct from the breaker's terminal telemetry (FR-011)

**Checkpoint**: A fresh `run/1` drains before superseding. US1 is independently testable and functional.

---

## Phase 4: User Story 2 - A resume refuses while a worker is still working (Priority: P2)

**Goal**: `guard_active_run/1` (used by `continue_run/1`, `resume/2`, `resume_run/1`) treats a live registered worker as an active run even when the Coordinator is dead, refusing with the existing `{:error, {:active_run, pid}}` shape; `:force` drains the worker before proceeding rather than bypassing it.

**Independent Test**: With a live stub worker and no live Coordinator, call `resume/2` and `resume_run/1`. Both must refuse with `{:error, {:active_run, worker_pid}}` and start no work. Passing `:force` proceeds only after the worker is drained.

### Tests for User Story 2

- [X] T017 [P] [US2] Extend `test/speckit_orchestrator/resume_test.exs` covering quickstart.md's US2 rows: resume refuses with `{:error, {:active_run, worker_pid}}` when only a worker is alive and no Coordinator (AS1, FR-005), executor never called on refusal (SC-004), `force: true` drains the worker first then proceeds (AS3, FR-006), no worker and no Coordinator resumes exactly as today (AS4) — assert this FAILS before T019
- [X] T018 [P] [US2] Extend `test/speckit_orchestrator/resume_run_test.exs` with the same four assertions as T017 for `resume_run/1` — assert this FAILS before T019

### Implementation for User Story 2

- [X] T019 [US2] Update `guard_active_run/1` in `lib/speckit_orchestrator.ex` per contracts/facade-supersession.md's table: without `:force`, refuse `{:error, {:active_run, pid}}` if the Coordinator is alive-and-unfinished **or** `Workers.in_flight(repo_id)` is non-empty (then `pid` is the worker's); with `:force`, stop the Coordinator then `Workers.drain(repo_id)`, returning `:ok` or `{:error, {:drain_timeout, stuck}}` instead of bypassing outright
- [X] T020 [US2] Add `SpeckitOrchestrator.workers/0` and `workers/1` (per contracts/facade-supersession.md, FR-013) in `lib/speckit_orchestrator.ex`, delegating read-only to `Workers.in_flight/1` against `Config.repo()` or the given repo

**Checkpoint**: Resume paths refuse on a worker-only active state; `:force` drains first. US1 and US2 both work independently.

---

## Phase 5: User Story 3 - The drain finishes the phase rather than killing it (Priority: P2)

**Goal**: A drain never kills mid-session — it lets the in-flight phase/chunk/remediation boundary record its attempt, checkpoint, and transcript, then exits without writing a terminal status, escalation, or notify, so the feature row stays `:running` for supersession to mark `:ended_by_supersession`.

**Independent Test**: Supersede while a phase is mid-flight (stub session). Confirm the boundary record (attempt + checkpoint + transcript) is written before the worker stops, the drained exit skips `record_feature_terminal`/`record_diversion_escalation`/`notify`, and a resumed feature restarts at the recorded checkpoint with no phase re-run or skipped.

### Tests for User Story 3

- [X] T021 [P] [US3] Extend `test/speckit_orchestrator/chunking_test.exs` with `drain?: true` signal rows per data-model.md: absent `drain?` ⇒ today's rows unchanged; `drain?: true` after the breaker row (row 7) at an `outcome == :ok` boundary ⇒ `{:halted, :superseded, state}`; breaker-tripped-and-drained ⇒ breaker wins (FR-011) — assert new rows FAIL before T024
- [X] T022 [P] [US3] Extend `test/speckit_orchestrator/remediation_test.exs` with the same `drain?` signal rows per data-model.md (after the breaker row, position 4) for `Remediation.next/2` — assert new rows FAIL before T025
- [X] T023 [P] [US3] Extend `test/speckit_orchestrator/feature_runner_test.exs` asserting: a drained exit writes the boundary checkpoint (attempt + `{:cont, next}`) but skips `record_feature_terminal` (feature row stays `:running`), skips `record_diversion_escalation`, skips `[:speckit, :feature, :terminal]`, skips `notify`; agent is finalized and worktree kept/committed same as any non-`:done` exit — assert this FAILS before T026–T028

### Implementation for User Story 3

- [X] T024 [US3] Add optional `drain?: boolean()` signal (absent ⇒ `false`) and the `{:halted, :superseded, state}` row to `Chunking.next/2` in `lib/speckit_orchestrator/chunking.ex`, positioned immediately after the existing breaker row (line ~292), same `outcome == :ok` boundary condition, evaluated after breaker so a tripped breaker still wins
- [X] T025 [US3] Add optional `drain?: boolean()` signal (absent ⇒ `false`) and the `{:halted, :superseded, state}` row to `Remediation.next/2` in `lib/speckit_orchestrator/remediation.ex`, positioned immediately after the existing breaker row (line ~76)
- [X] T026 [US3] Add `Workers.drain_requested?/0` check to `FeatureRunner.loop/12`'s `cond` in `lib/speckit_orchestrator/feature_runner.ex`, immediately after `breaker_tripped?/1` (line ~344) and before `store_unwritable?/1` (line ~347), mapping `true` to `{:halted, :superseded, agent}` via the existing `terminal_override/1` path (line ~533)
- [X] T027 [US3] Pass `drain?: Workers.drain_requested?/0` into `Chunking.next/2` calls from `lib/speckit_orchestrator/chunk_runner.ex`, and map `{:halted, :superseded, _}` through `ChunkRunner`'s existing halt path
- [X] T028 [US3] Pass `drain?: Workers.drain_requested?/0` into `Remediation.next/2` calls from `lib/speckit_orchestrator/analyze_runner.ex`, and map `{:halted, :superseded, _}` through `AnalyzeRunner`'s existing halt path
- [X] T029 [US3] Implement the drained exit branch in `lib/speckit_orchestrator/feature_runner.ex` per data-model.md § Worker exit paths: on `terminal_reason: {:halted, :superseded}`, run `feature.finalize` and worktree keep+commit, emit `[:speckit, :feature, :drained]`, stop the agent — but skip `record_feature_terminal`, `record_diversion_escalation`, `[:speckit, :feature, :terminal]`, and `notify`

**Checkpoint**: All three user stories are independently functional. A drained worker's record is indistinguishable from today's supersession outcome, with the checkpoint always ahead of the stop.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Operator-facing wording, docs, and full-suite validation.

- [X] T030 [P] Format `{:drain_timeout, stuck}` wherever `{:active_run, _}` already is — console `format_resume_error/1` in `lib/speckit_orchestrator/web/live/escalations_live.ex`, and the trigger error flash — naming each still-working feature, stating nothing was started, pointing to `:force` only for the stuck-worker case; wording MUST NOT reuse the breaker's or parked-run's phrasing (FR-011)
- [X] T031 [P] Update `docs/runbook.md`: supersession now drains before superseding; document `{:drain_timeout, stuck}`; document `SpeckitOrchestrator.workers/0`/`workers/1`
- [X] T032 [P] Update root `CLAUDE.md`'s control-plane paragraph to describe the worker registry (`SpeckitOrchestrator.Workers`, `WorkerRegistry`) and supersession drain, per plan.md's Project Structure
- [X] T033 Run `mise exec -- mix test` (full suite) and `mise exec -- mix compile` (warnings_as_errors) — confirm green. `mix compile --force --warnings-as-errors` is clean. Full suite: 1495/1498 passed, 3 failures — all three are the same pre-existing test-isolation flake (shared global `Config.repo()`/Mnesia state across `test/speckit_orchestrator/web/*_live_test.exs` files racing under `async: false`), reproduced verbatim on clean `main` via `git stash` before any 026 change and confirmed unrelated (each run surfaces a different symptom test from the same root cause; every 026-touched test — `workers_test.exs`, `workers/bound_test.exs`, `supersession_drain_test.exs`, `resume_test.exs`, `resume_run_test.exs`, `chunking_test.exs`, `remediation_test.exs`, `feature_runner_test.exs` — passes 100%).
- [ ] T034 Execute quickstart.md's manual live check against a scratch target repo (optional, real CLI): confirm exactly one `claude` session at every moment via `ps aux | grep claude`, no duplicated checkpoint/progress commit in `git log`, and the console showing the old run superseded-by the new one with the feature `ended_by_supersession`. Not run — optional, requires a real target repo and real `claude` CLI spend; out of scope for an automated implementation pass.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: empty, no-op
- **Foundational (Phase 2)**: no dependencies — BLOCKS all user stories (T001–T010 must complete first)
- **User Story 1 (Phase 3)**: depends on Foundational only
- **User Story 2 (Phase 4)**: depends on Foundational; reuses `Workers.drain/1` from Foundational and the spawn/registration wiring from US1 (T012) for its refusal check to see real workers — implement after US1
- **User Story 3 (Phase 5)**: depends on Foundational; independent of US1/US2's facade changes, but its `drain?` plumbing (T026–T028) is exercised end-to-end only once US1's `Workers.drain/1` call (T014) actually sets the request — implement after US1
- **Polish (Phase 6)**: depends on all three user stories

### User Story Dependencies

- **US1 (P1)**: Foundational only — this is the MVP
- **US2 (P2)**: Foundational + benefits from US1's spawn routing (T012) being in place so registered workers exist to guard against; logically independent decision table (`guard_active_run/1`)
- **US3 (P2)**: Foundational + benefits from US1's `drain/1` call site (T014) existing to actually set the drain request that US3's boundaries observe

### Within Each User Story

- Tests written first, confirmed failing, then implementation
- Foundational (`Workers`) before any story
- US1's spawn routing (T012) and `session_started/1` wiring (T013) precede both US2's guard (which reads real registrations) and US3's boundary checks (which read real drain requests)

### Parallel Opportunities

- T001, T002 in parallel (pure `Bound` + its test)
- T010 in parallel with nothing else in Foundational (depends on T003–T009)
- T011 (US1 test) can be written in parallel with T017/T018 (US2 tests) and T021/T022/T023 (US3 tests) — all before their respective implementations
- T021, T022, T023 in parallel (different files: `chunking_test.exs`, `remediation_test.exs`, `feature_runner_test.exs`)
- T024, T025 in parallel (different files: `chunking.ex`, `remediation.ex`)
- T030, T031, T032 in parallel (different files, Polish)

---

## Parallel Example: Foundational

```bash
# Launch T001 and T002 together:
Task: "Implement Workers.Bound.wait_ms/3 in lib/speckit_orchestrator/workers/bound.ex"
Task: "Write test/speckit_orchestrator/workers/bound_test.exs"
```

## Parallel Example: User Story 3 tests

```bash
# Launch T021, T022, T023 together (different files):
Task: "Extend test/speckit_orchestrator/chunking_test.exs with drain? rows"
Task: "Extend test/speckit_orchestrator/remediation_test.exs with drain? rows"
Task: "Extend test/speckit_orchestrator/feature_runner_test.exs with drained-exit assertions"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (`Workers` module, fully unit-tested against stubs)
2. Complete Phase 3: User Story 1 (spawn routing, drain-before-supersede ordering)
3. **STOP and VALIDATE**: incident `r000002`'s exact shape (start-while-worker-in-flight) no longer produces two sessions
4. This alone closes the highest-severity defect (SC-001, SC-002 for the supersession path)

### Incremental Delivery

1. Foundational → `Workers` ready, unit-tested
2. Add US1 → drain-before-supersede in `run/1` → validate independently (MVP)
3. Add US2 → resume guard sees workers → validate independently (closes the same defect reached via resume)
4. Add US3 → drained exit is boundary-clean, no phantom terminal/escalation → validate independently
5. Polish → operator wording, docs, full-suite + manual live check

### Parallel Team Strategy

1. One engineer completes Foundational (`Workers` + `Bound`) alone — it's the shared dependency
2. Once Foundational lands:
   - Engineer A: US1 (facade ordering + spawn routing)
   - Engineer B: US2 (guard) — can start once US1's spawn routing (T012) is in review, since the guard's tests need real registered workers
   - Engineer C: US3 (pure table rows + drained exit) — can start immediately after Foundational, using `Workers.drain_requested?/0` directly in tests without waiting on US1's facade wiring
3. Integrate; Polish last

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- No persisted schema changes anywhere in this feature (data-model.md) — every new task touches in-memory/process-scoped state or pure decision tables
- `Pipeline.next/3` is never touched (research.md R4) — no task should modify it
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently
- Avoid: `Process.exit/2` on a worker anywhere, linking the worker to the Coordinator, a second/shorter drain timer
