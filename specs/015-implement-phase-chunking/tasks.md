---

description: "Task list for Implement Phase Chunking"
---

# Tasks: Implement Phase Chunking

**Input**: Design documents from `/specs/015-implement-phase-chunking/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — the plan's Project Structure and every contract's "Test obligations" section name specific test files as part of this feature's scope, so test tasks are generated alongside implementation tasks.

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P4) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: Maps the task to US1 (long task lists finish), US2 (resume at task-phase), US3 (console visibility), US4 (turn-exhaustion continuation)
- File paths are exact, per `plan.md`'s Project Structure

## Path Conventions

Single Elixir application. Production code under `lib/speckit_orchestrator/` (+ `lib/speckit_orchestrator_web/` for the LiveView console); tests under `test/speckit_orchestrator/`; fixtures under `test/fixtures/tasks/`. No new directories beyond these.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Fixture data every pure-core test in this feature parses against

- [X] T001 Create `test/fixtures/tasks/structured.md` (5-task-phase quickpoll shape), `unstructured.md` (checkboxes, no `Phase n:` headings), `empty_task_phase.md` (a heading with zero tasks), `duplicate_numbers.md` (two `## Phase 3:` headings), `fenced.md` (checkbox-looking lines inside a fenced code block), and `no_checkboxes.md` (prose plan, vacuously complete) per contracts/task_plan.md §4-5

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure structs, parser, and classification primitives every user story depends on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T002 Define `TaskPlan`, `TaskPlan.TaskPhase`, `TaskPlan.Task` structs and the `parse/2` grammar (task-phase heading, task-line, task-id regexes; fenced-block skipping; checkboxes outside any task-phase excluded) in `lib/speckit_orchestrator/task_plan.ex` per contracts/task_plan.md §1
- [X] T003 Implement `TaskPlan` derived accessors `total_tasks/1`, `completed_tasks/1`, `incomplete/1`, `complete?/1`, `task_phase_count/1`, `at/2`, `first_incomplete/1` in `lib/speckit_orchestrator/task_plan.ex` (depends on T002)
- [X] T004 Define `TaskPhaseRef` struct and implement `TaskPlan.locate/2` (number → title → ordinal → first-incomplete-fallback, falling through on ambiguity) and `TaskPlan.ref/1` in `lib/speckit_orchestrator/task_plan.ex` per data-model.md §5 (depends on T003)
- [X] T005 Implement `TaskPlan.load/1` edge reader — globs `specs/**/tasks.md` under a worktree path, reads the first match, delegates to `parse/2`, never raises — in `lib/speckit_orchestrator/task_plan.ex` (depends on T004)
- [X] T006 [P] Write `test/speckit_orchestrator/task_plan_test.exs` covering grammar (T1–T10 of contracts/task_plan.md §3) against the T001 fixtures, plus the golden parse of this repo's own `specs/014-recovery-reconciliation/tasks.md` (depends on T005)
- [X] T007 [P] Add `subtype` field to `PhaseResult` (folded from the `:session_failed` payload's `"subtype"`) and `PhaseResult.exhausted?/1` (`subtype == "error_max_turns"`) in `lib/speckit_orchestrator/phase_result.ex`, leaving `transient?/1` unchanged, per research R1
- [X] T008 [P] Add `Config.implement_no_progress_limit/0` (default 2), `Config.implement_sessions_per_task_phase/0` (default 2), `Config.implement_sessions_headroom/0` (default 4) accessors in `lib/speckit_orchestrator/config.ex`, with matching defaults in `config/config.exs`
- [X] T009 [P] Write `test/speckit_orchestrator/phase_result_test.exs` exhaustion-classification cases: `"error_max_turns"` subtype ⇒ `exhausted?/1 == true`; a server-error subtype ⇒ `exhausted?/1 == false` and `transient?/1` unchanged (depends on T007)

**Checkpoint**: Foundation ready — `TaskPlan`, `PhaseResult.exhausted?/1`, and chunk config knobs exist and are independently tested

---

## Phase 3: User Story 1 - Long task lists finish (Priority: P1) 🎯 MVP

**Goal**: A feature whose task list exceeds one session's turn cap completes the implement step across one bounded session per task-phase, in order, with an unstructured-list fallback.

**Independent Test**: Run a feature whose task list holds 18 tasks across 5 task-phases under the per-session turn cap (80) that previously failed it; verify 5 bounded sessions dispatch in order and the feature completes with all 18 tasks `[X]`.

- [X] T010 [US1] Add `ChunkScope` type (`{:task_phase, tp} | {:sweep, tasks} | :whole_list`), `ChunkAttempt` struct, and `ChunkState` struct in `lib/speckit_orchestrator/chunking.ex` per data-model.md §4, §6, §7
- [X] T011 [US1] Implement `Chunking.start/2` — freezes `ceiling = per_task_phase * max(task_phase_count, 1) + headroom` from `Config`, accepts `:from_ordinal` and `:sessions_used` — in `lib/speckit_orchestrator/chunking.ex` (depends on T008, T010)
- [X] T012 [US1] Implement `Chunking.next/2`, the full 13-row decision table (transient retry, error, exhaustion+progress continuation, no-progress bound, session ceiling, breaker halt, fallback dispatch, skip, task-phase dispatch, done, sweep, unchecked-tasks failure) in `lib/speckit_orchestrator/chunking.ex` per contracts/chunking.md §2 (depends on T011)
- [X] T013 [P] [US1] Write `test/speckit_orchestrator/chunking_test.exs` covering every row of contracts/chunking.md §2 and the full test-obligations list in §4 (5-task-phase full run, pre-complete skip, progress continuation ×N, no-progress bound, alternating progress reset, ceiling distinct from stuck, unstructured fallback + continuation, sweep once + no second sweep, out-of-scope completion, breaker at boundary only) (depends on T012)
- [X] T014 [US1] Extend `PhaseRequest.build/3` with an optional `:scope` option (honoured only for `phase == :implement`): task-phase scoping block (all four FR-005 clauses), sweep block, and byte-identical `:whole_list`/absent prompt, in `lib/speckit_orchestrator/phase_request.ex` per contracts/chunk_session.md §1
- [X] T015 [P] [US1] Write `test/speckit_orchestrator/phase_request_test.exs` scoped-prompt assertions (all four FR-005 clauses present) and a byte-identical-fallback assertion against today's bare `/speckit.implement` output (depends on T014)
- [X] T016 [US1] Extend `Actions.RunFeaturePhase` to thread `scope:` into `PhaseRequest.build/3` and skip the `:implement` artifact gate for a scoped run (`classify(:implement, …)` returns `{:ok, %{}}` when `scope` is present) in `lib/speckit_orchestrator/actions/run_feature_phase.ex` per research R10 (depends on T014)
- [X] T017 [US1] Extend `Transcripts`: add `write_labelled/6` (label string instead of a phase atom), render two new header lines (`error`, `subtype`), and chunk transcript naming `06-implement-p<NN>-a<N>.md` / `06-implement-sweep-a<N>.md` / roll-up `06-implement.md` in `lib/speckit_orchestrator/transcripts.ex` per contracts/chunk_session.md §5 (depends on T007)
- [X] T018 [US1] Create `lib/speckit_orchestrator/chunk_runner.ex`: `ChunkRunner.run/1` drives the loop via `Chunking.next/2`, dispatching one `"phase.run"` signal per chunk; classifies each session outcome in fixed order (`exhausted?/1` ⇒ `:exhausted`; `transient?/1` ⇒ `:error, transient?: true`; else `:error`; else `:ok`); measures progress via `TaskPlan.completed_tasks/1` on a freshly loaded plan before/after each session; commits the worktree at each task-phase boundary with subject `speckit: <id> implement task-phase <ordinal>/<total> <title>` (verified not to match `Recovery.Evidence`'s boundary regex); evaluates the artifact gate once on the roll-up — per contracts/chunk_session.md §2-4, §6 (depends on T012, T014, T016, T017)
- [X] T019 [US1] Extend `FeatureRunner.run_phase_with_retry/8`: when `phase == :implement`, delegate to `ChunkRunner.run/1` and map its result into the existing `{outcome, reason, agent}` shape (`last_outcome`, `last_signals`, `terminal_reason`) in `lib/speckit_orchestrator/feature_runner.ex` per contracts/chunk_session.md §6 (depends on T018)
- [X] T020 [P] [US1] Write `test/speckit_orchestrator/chunk_runner_test.exs` (fake-agent seam + tmp git repo): scoped prompts dispatched correctly, transcript naming (`06-implement-p03-a1.md`), roll-up written, `07-converge.md` still resolves for `Evidence.final_marker?/2` after a chunked run (depends on T018)
- [X] T021 [P] [US1] Extend `test/speckit_orchestrator/recovery/evidence_test.exs`: task-phase commit subject does not match `Evidence`'s boundary regex, and `Evidence.default_git/1` over a branch carrying both commit kinds still reports `last_boundary_phase: :tasks` (depends on T018)
- [X] T022 [P] [US1] Add an integration test (tagged `--include integration`) running one real chunked implement session against a fixture target repo in `test/speckit_orchestrator/chunk_runner_test.exs` (depends on T019)

**Checkpoint**: User Story 1 is fully functional and independently testable — chunked dispatch, fallback, and continuation-on-progress all work end-to-end

---

## Phase 4: User Story 2 - Resume at the failing task-phase (Priority: P2)

**Goal**: Resuming a diverted feature restarts at the recorded task-phase rather than the beginning, without redoing or clobbering completed work.

**Independent Test**: Fail a run during task-phase 3 of 5, resume from the operator surface, and verify the resumed run dispatches its first session scoped to task-phase 3 with task-phases 1–2 never re-dispatched.

- [X] T023 [US2] Extend `Checkpoint` with an optional `implement_chunk` key (ordinal/number/title/total/sessions_used/ceiling/scope), following the existing `maybe_put_context/2` pattern so pre-015 checkpoints (no key) remain valid, in `lib/speckit_orchestrator/checkpoint.ex` per contracts/checkpoint-implement-chunk.md §1
- [X] T024 [P] [US2] Extend `test/speckit_orchestrator/checkpoint_test.exs`: pre-015 checkpoint (no `implement_chunk`) still reads and resolves `:fallback`; round-trip write→read preserves all seven fields (depends on T023)
- [X] T025 [US2] Extend `ChunkRunner`: at implement-step start, build a `TaskPhaseRef` from the checkpoint's `implement_chunk` (or `nil`), resolve via `TaskPlan.locate/2`, start the loop at that task-phase with `sessions_used` from the record (or `0` on operator resume), and emit `[:speckit, :chunk, :resolved]` when `match_kind != :number`, in `lib/speckit_orchestrator/chunk_runner.ex` per contracts/checkpoint-implement-chunk.md §3 (depends on T023, T018)
- [X] T026 [US2] Add `:start_task_phase` and `:reset_implement_sessions` options to `FeatureRunner.run/2`, threaded to `ChunkRunner.run/1`, in `lib/speckit_orchestrator/feature_runner.ex` (depends on T025)
- [X] T027 [US2] Extend `SpeckitOrchestrator.resume/2`: add `:from_task_phase` (ordinal or `TaskPhaseRef`, honoured only when `start_phase == :implement`, overriding the recorded position), always set `reset_implement_sessions: true`, and ensure guidance reaches only the first dispatched chunk, in `lib/speckit_orchestrator.ex` per contracts/checkpoint-implement-chunk.md §4 (depends on T026)
- [X] T028 [US2] Extend `EscalationsLive`'s resume form with a task-phase `<select>` (rendered only when `last_phase == implement` and `tasks.md` parses as structured; options labelled `<ordinal>/<total> · <number>: <title>`, completed ones marked `✓`; default the recorded task-phase; inline note on a weaker-than-number match) in `lib/speckit_orchestrator_web/live/escalations_live.ex` per contracts/checkpoint-implement-chunk.md §4 (depends on T027)
- [X] T029 [P] [US2] Extend `test/speckit_orchestrator/resume_test.exs`: `:from_task_phase` reaches the first dispatched session; failure during task-phase 3 of 5 resumes at task-phase 3 with 1–2 never re-dispatched; renumbered task list (numbers shifted, titles stable) resolves by `:title` with `[:speckit, :chunk, :resolved]` emitted; retitled-but-renumbered-stable resolves by `:number` with no warning; deleted recorded task-phase falls through to `:ordinal` then `:fallback`; `sessions_used` is `0` after operator resume (depends on T027)
- [X] T030 [P] [US2] Extend `test/speckit_orchestrator/web/escalations_live_test.exs`: picker rendered for a structured implement checkpoint, absent for an unstructured one, submitted ordinal reaches `resume/2` as `:from_task_phase` (via the `:console_test_runner` seam) (depends on T028)

**Checkpoint**: User Stories 1 AND 2 both work independently — chunked resume restarts at the correct task-phase without redoing completed work

---

## Phase 5: User Story 3 - See which task-phase is running (Priority: P3)

**Goal**: The console shows, per running feature, the current task-phase position/total/title, and the activity feed carries one entry per task-phase boundary.

**Independent Test**: Start a run and watch the console; at any moment during implement the feature's row states the current task-phase position and total, and the feed carries a boundary entry at each transition.

- [X] T031 [US3] Add `[:speckit, :chunk, :start | :stop | :exception | :resolved]` event names to `Telemetry.events/0` and wrap `ChunkRunner`'s per-chunk loop body in `:telemetry.span([:speckit, :chunk], …)`, in `lib/speckit_orchestrator/telemetry.ex` and `lib/speckit_orchestrator/chunk_runner.ex` per contracts/telemetry-chunk.md §1 (depends on T018)
- [X] T032 [US3] Extend `ConsoleReadModel.apply_event/4` with the chunk fold (start/stop/exception/resolved → feature slice `:chunk` field + feed entries per contracts/telemetry-chunk.md §2-3), including the no-double-count rule for the implement phase-stop cost, in `lib/speckit_orchestrator/console_read_model.ex` (depends on T031)
- [X] T033 [US3] Extend `ConsoleReadModel.overlay_last_known_statuses/3` to seed the reconstructed feature slice's `:chunk` field from `checkpoint["implement_chunk"]` (absent ⇒ `nil`) in `lib/speckit_orchestrator/console_read_model.ex` (depends on T023, T032)
- [X] T034 [US3] Extend `phase_strip/1` in `lib/speckit_orchestrator_web/components/core_components.ex`: render `<ordinal>/<total> · <title>` sub-label when `chunk.scope == :task_phase`, `sweep · N left` for `:sweep`, ` (attempt N)` suffix when `attempt > 1`, and today's unchanged rendering for `nil`/`:whole_list` (depends on T032)
- [X] T035 [P] [US3] Extend `test/speckit_orchestrator/console_read_model_test.exs`: fold assertions for every row of contracts/telemetry-chunk.md §2, double-count avoidance (total feature spend equals the ledger's for a chunked run), and the overlay test for inactive runs (depends on T032, T033)
- [X] T036 [P] [US3] Extend `test/speckit_orchestrator/telemetry_test.exs`: `Telemetry.events/0` includes the four new chunk event names, and `attach_default_logger/0` handles them without a `FunctionClauseError` (depends on T031)
- [X] T037 [P] [US3] Add a phase-strip rendering test in `test/speckit_orchestrator/web/` asserting markup-identical rendering for `nil`/`:whole_list` against the pre-change strip, and the sub-label for `:task_phase`/`:sweep` (depends on T034)

**Checkpoint**: User Stories 1, 2, AND 3 all work independently — operators can see task-phase progress live and after the fact

---

## Phase 6: User Story 4 - Turn exhaustion with progress is not a failure (Priority: P4)

**Goal**: A task-phase that exhausts its session budget while making progress continues in a fresh session; one that exhausts while completing nothing counts against a no-progress bound and eventually fails as stuck, distinct from an exhausted feature session ceiling.

**Independent Test**: Force a task-phase to exhaust its turn budget after completing at least one task and verify a fresh session for the same task-phase is dispatched; then force one to exhaust having completed nothing and verify the feature eventually fails as stuck.

- [X] T038 [US4] Verify and wire `ChunkRunner`'s end-to-end classification order (exhausted before transient before terminal error) against `Chunking.next/2`'s continuation rows through the full dispatch loop, including the frozen ceiling from `Chunking.start/2`, in `lib/speckit_orchestrator/chunk_runner.ex` per contracts/chunk_session.md §3 (depends on T012, T018)
- [X] T039 [US4] Implement the failure-reason → operator-sentence mapping (contracts/chunking.md §3: stuck task-phase, session ceiling, unchecked tasks, session error) and wire it into the `06-implement.md` roll-up failure line, in `lib/speckit_orchestrator/chunking.ex` and `lib/speckit_orchestrator/transcripts.ex` (depends on T012, T017)
- [X] T040 [P] [US4] Extend `test/speckit_orchestrator/chunk_runner_test.exs` with end-to-end cases: exhaustion+progress ×N sessions continues without failure; no-progress ×limit fails as `{:stuck_task_phase, …}`; ceiling reached fails as `{:session_ceiling, …}` distinct from stuck; a non-exhaustion session error is handled by the existing unchanged transient-versus-terminal ladder (depends on T038)
- [X] T041 [P] [US4] Write `test/speckit_orchestrator/chunking_test.exs --only sc002` asserting the four failure reasons are exhaustive by construction and each maps to a distinct sentence (depends on T039)

**Checkpoint**: All four user stories are independently functional — chunked execution, resume, visibility, and the exhaustion/continuation invariant all hold

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Whole-suite verification against the spec's success criteria

- [X] T042 [P] Run `mise exec -- mix test --cover` and confirm pure-core coverage stays >90%, with `task_plan.ex` and `chunking.ex` near 100%
- [X] T043 Run quickstart.md scenarios S1–S4 (hermetic suite, SC-005 unstructured-list byte-identity, SC-002 failure-reason totality) and confirm no pre-existing test (`checkpoint_test.exs`, `recovery/evidence_test.exs`, `pipeline_test.exs`, `telemetry_test.exs`) was modified to accommodate the change
- [X] T044 Run `mise exec -- mix format --check-formatted` and `mise exec -- mix compile` (warnings-as-errors) clean across every changed file

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup (fixtures) — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational — delivers the MVP
- **User Story 2 (Phase 4)**: Depends on Foundational; depends on US1's `ChunkRunner` (T018) and `Checkpoint` write path existing
- **User Story 3 (Phase 5)**: Depends on Foundational; depends on US1's `ChunkRunner` (T018) for events to fold, and on US2's `Checkpoint.implement_chunk` (T023) for the inactive-run overlay
- **User Story 4 (Phase 6)**: Depends on Foundational and US1's `Chunking.next/2` (T012) + `ChunkRunner` (T018); independent of US2/US3's own code (console/resume), though its tests benefit from the full loop being wired
- **Polish (Phase 7)**: Depends on all four user stories being complete

### User Story Dependencies

- **US1 (P1)**: No dependency on other stories — this is the standalone chunked-execution slice
- **US2 (P2)**: Builds on US1's `ChunkRunner`/`Checkpoint` plumbing; not independently meaningful without US1's dispatch loop existing
- **US3 (P3)**: Builds on US1's telemetry-emitting loop and US2's checkpoint field; purely observational, adds no new decision logic
- **US4 (P4)**: Builds on US1's `Chunking.next/2`, which already contains the continuation/ceiling rows (US4 hardens and verifies them end-to-end rather than re-implementing them)

### Within Each User Story

- Structs/types before the functions that consume them
- Pure core (`Chunking`, `TaskPlan`) before the edge module (`ChunkRunner`) that calls it
- `ChunkRunner` before `FeatureRunner` integration
- Implementation before its test file
- Story complete before moving to the next priority

### Parallel Opportunities

- T006, T007+T009, T008 (three independent tracks: `TaskPlan`, `PhaseResult`, `Config`) can run in parallel within Foundational
- T013, T015 can run in parallel once T012/T014 land (different test files)
- T020, T021, T022 can run in parallel once T018/T019 land (different test files)
- T024 can run parallel to US2's remaining chain once T023 lands
- T029, T030 can run in parallel once T027/T028 land
- T035, T036, T037 can run in parallel once T032–T034 land
- T040, T041 can run in parallel once T038/T039 land
- T042 can run in parallel with T043/T044

---

## Parallel Example: Foundational

```bash
# Three independent tracks, once T001's fixtures exist:
Task: "TaskPlan structs + parse/2 grammar in lib/speckit_orchestrator/task_plan.ex"      # T002 (track A)
Task: "PhaseResult subtype + exhausted?/1 in lib/speckit_orchestrator/phase_result.ex"    # T007 (track B)
Task: "Config accessors in lib/speckit_orchestrator/config.ex"                           # T008 (track C)
```

## Parallel Example: User Story 1 test fan-out

```bash
# Once T012 (Chunking.next/2) and T014 (PhaseRequest scope) land:
Task: "chunking_test.exs — full decision table"          # T013
Task: "phase_request_test.exs — scoped prompts"           # T015
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (fixtures)
2. Complete Phase 2: Foundational (`TaskPlan`, `PhaseResult.exhausted?/1`, config knobs) — CRITICAL, blocks all stories
3. Complete Phase 3: User Story 1 (`Chunking`, `ChunkRunner`, scoped `PhaseRequest`, `FeatureRunner` delegation)
4. **STOP and VALIDATE**: quickstart.md S1 (unit suite) + S5 (the exact 2026-07-25 production case) — a feature previously terminally failed at 8/18 tasks now completes all 18
5. This alone turns the observed production failure into a success (spec's stated rationale for US1's priority)

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. Add US1 → chunked execution works end-to-end → validate against quickstart S5 (MVP)
3. Add US2 → resume restarts at the correct task-phase → validate against quickstart S7
4. Add US3 → console shows live task-phase progress → validate against quickstart S6
5. Add US4 → exhaustion/continuation invariant hardened and verified → validate against quickstart S4
6. Polish → full suite, coverage, quickstart S1–S4 regression sweep

---

## Notes

- [P] tasks touch different files with no completed-task dependency
- [Story] label maps each task to its user story for traceability
- Chunking's full 13-row decision table (T012) is built once in US1: it already contains the continuation/no-progress/ceiling rows US4's acceptance scenarios exercise, so US4 hardens and end-to-end-verifies existing rows rather than duplicating them
- FR-008 (seven-step pipeline model unchanged) and FR-019/SC-005 (unstructured-list rendering byte-identical) are cross-cutting invariants guarded by tests in multiple phases (T015, T021, T037, T043) — do not relax any of them to make a later task pass
- Commit at logical checkpoints; per-task-phase worktree commits (T018) are themselves part of the feature under test, not a instruction about how to commit *this* work
- Verify each contract's "Test obligations" section against the corresponding test task before marking a phase's checkpoint complete
