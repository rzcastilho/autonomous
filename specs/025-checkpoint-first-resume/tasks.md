---

description: "Task list for Checkpoint-First Resume"
---

# Tasks: Checkpoint-First Resume

**Input**: Design documents from `/specs/025-checkpoint-first-resume/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. Every touched module (`Recovery.Reconcile`, `Recovery.Report`,
`ChunkRunner`) already has a test suite this feature extends, plan.md names the
exact files, and the constitution requires pure-core coverage to stay >90%.

**Organization**: Grouped by user story (spec.md P1/P2/P2). The three stories
share one pure decision table (`Reconcile.status/3` clause 4b), so the shared
logic is built once in Foundational and each story adds its own test coverage
plus any story-specific edge of the implementation (the chunk write for US1,
the report rendering for US3).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- All commands run through `mise exec --` (see plan.md Toolchain)

## Path Conventions

Single Elixir project, repository root. `lib/speckit_orchestrator/` and
`test/speckit_orchestrator/` — no new files, no new directories (plan.md
Project Structure).

---

## Phase 1: Setup

**Purpose**: Confirm the baseline is green before touching anything

- [X] T001 Run `mise exec -- mix deps.get && mise exec -- mix compile && mise exec -- mix test` from repo root and confirm a clean baseline (`warnings_as_errors` is ON) before making any change

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one shared pure decision every story's acceptance scenarios exercise

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T002 Implement `Reconcile.resume_position/2` in `lib/speckit_orchestrator/recovery/reconcile.ex` per `contracts/reconcile-checkpoint-first.md` §2 — no-checkpoint → `:no_position` (§2.1), damaged checkpoint → `{:conflict, {:damaged_checkpoint, %{phase:, last_completed_phase:}}}` (§2.2), `last_completed_phase == :converge` → `:no_position` (§2.3), `completed_through/1`/`predecessor/1` derivation (§2.4), and the ahead/tie/behind verdict against `last_boundary_phase` (§2.5)
- [X] T003 Wire `resume_position/2` into `Reconcile.status/3`'s `recorded in [:running, :pending]` clause in `lib/speckit_orchestrator/recovery/reconcile.ex` as clause 4b (checkpoint-first, ahead of the existing clause 5 trail fallback) and clause 6b (`not branch_committed? and not is_nil(checkpoint)` → `{:conflict, :checkpoint_without_branch}`, ahead of clause 7's `:pr_without_branch`), via a private `checkpoint_position/2` that returns `false` instead of `:no_position` so the `cond` falls through — per contract §3 (depends on T002; same file)

**Checkpoint**: `Reconcile.status/3`'s full clause order (1–7 plus 4b/6b) compiles and every existing test still passes. Foundation ready — story work can begin.

---

## Phase 3: User Story 1 - A whole-run resume continues where the crash happened (Priority: P1) 🎯 MVP

**Goal**: A feature interrupted mid-implement whole-run-resumes at implement (not two phases back), single-feature and whole-run resume agree, and the implement work itself continues from its recorded chunk position instead of repeating completed task-phases.

**Independent Test**: Feed a checkpoint naming implement (with `last_completed_phase: :analyze`) beside a trail whose newest boundary is `:tasks`; `Reconcile.resume_position/2` and `Reconcile.status/3` must both answer `{:resume, :implement}`, and `resume/2`/`resume_run/1` must dispatch the same phase for the same record.

### Tests for User Story 1

- [X] T004 [P] [US1] Add cases to `test/speckit_orchestrator/recovery/reconcile_test.exs` for worked cases 1 (the defect: checkpoint `:implement`/`last_completed_phase: :analyze` vs trail `:tasks` → `{:resume, :implement}`), 2 (agreeing checkpoint/trail → unchanged), and 6 (checkpoint names `:converge` as next phase, `last_completed_phase: :implement` → `{:resume, :converge}`) per `contracts/reconcile-checkpoint-first.md` §4
- [X] T005 [P] [US1] Add a case to `test/speckit_orchestrator/resume_run_test.exs` asserting a whole-run resume of a feature interrupted during implement dispatches `:implement`, not `:analyze` (SC-001, the reproduced `r000002`/`mod-player`/`001` shape from spec.md Context)
- [X] T006 [P] [US1] Add cases to `test/speckit_orchestrator/resume_test.exs` asserting `resume/2` and `resume_run/1` resolve the identical phase for the same feature record and evidence, across every phase the pipeline can be interrupted in (FR-003, SC-002). Not duplicated into `resume_scope_test.exs`: every fixture there passes a top-level `:runner` override, which bypasses `resolve_start_phase`/`dispatch_resume` for every feature (target and restored alike) — there is no real phase resolution left to observe on that path.
- [X] T007 [P] [US1] Add a mid-implement crash case to `test/speckit_orchestrator/resume_crash_test.exs`: checkpoint ahead of the trail and carrying a task-phase position, resumed feature re-enters `ChunkRunner` at that position

### Implementation for User Story 1

- [X] T008 [US1] Add `chunk_checkpoint/4` to `lib/speckit_orchestrator/chunk_runner.ex` per `contracts/implement-chunk-checkpoint-write.md` §3: full checkpoint map (`phase: :implement`, `last_completed_phase` = predecessor of `:implement`, `status: :in_progress`, carried `analyze_remediation`, `implement_chunk: %{ordinal, number, title, total, sessions_used, scope: :task_phase}`) for a `{:task_phase, tp}` `:ok` boundary, `nil` otherwise; thread the checkpoint row `run/1` already loads (`checkpoint_record/3`) onto `ctx` beside `:baseline_sessions_used`; pass `checkpoint: chunk_checkpoint(ctx, state1, scope, outcome)` into `record_chunk_attempt/6`'s `Writer.record_phase_attempt/2` payload, ordered after `maybe_commit_boundary/4` (already the case)
- [X] T009 [P] [US1] Add cases to `test/speckit_orchestrator/chunk_runner_test.exs`: a `{:task_phase, tp}` `:ok` boundary writes a full `implement_chunk` (ordinal/number/title/total/sessions_used), `:sweep`/`:whole_list`/non-`:ok` write `nil` (no-op, prior row intact), and `analyze_remediation` survives the write (SC-006, FR-007)
- [X] T010 [P] [US1] Add a case to `test/speckit_orchestrator/store/writer_test.exs` confirming `implement_chunk` round-trips through `record_phase_attempt/2`'s transaction

**Checkpoint**: User Story 1 is independently functional — a mid-implement crash whole-run-resumes at `:implement`, agrees with single-feature resume, and continues implementation without repeating completed task-phases.

---

## Phase 4: User Story 2 - A record without a checkpoint still resumes from the commit trail (Priority: P2)

**Goal**: Promoting the checkpoint to primary must not break the checkpoint-less case — the commit trail remains the exact fallback it is today.

**Independent Test**: Feed `checkpoint: nil` beside a trail whose newest boundary is a non-final phase; the resume position must be the phase after that marker, byte-identical to today.

### Tests for User Story 2

- [X] T011 [P] [US2] Add cases to `test/speckit_orchestrator/recovery/reconcile_test.exs` for worked case 3 (`checkpoint: nil`, trail `:tasks` → `{:resume, :analyze}`, unchanged) and a record with neither checkpoint nor any artifact → `:pending` (FR-002, FR-009)
- [X] T012 [P] [US2] Add a case to `test/speckit_orchestrator/recovery_test.exs` (or `recovery_quickpoll_test.exs`) for a persistence-failure drain — one feature's checkpoint write lost — still resuming from the commit trail with `gap_possible?: true` reported, as it is today

**No implementation tasks**: clause 5 (trail fallback) and clause 6 (`:pending`) of `Reconcile.status/3` are untouched by T003 — this phase is regression verification only.

**Checkpoint**: User Story 2 is independently verified — checkpoint-less and drained records still resume exactly as they do today.

---

## Phase 5: User Story 3 - A genuine disagreement is reported, never resolved silently (Priority: P2)

**Goal**: A checkpoint that contradicts the trail (or has no branch to resume onto, or names an unrecognised phase) is reported to the operator and blocks the feature — never guessed from either source, never resolved silently.

**Independent Test**: Feed a checkpoint naming a phase strictly behind what the trail proves completed; the result must be `{:conflict, {:checkpoint_behind_trail, %{checkpoint:, trail:}}}`, the feature classified `:blocked`, and the discrepancy visible in the read-only resume preview before any spend.

### Implementation for User Story 3

- [X] T013 [US3] Widen `Recovery.Report`'s `@type conflict_reason` and `conflict_row` to `atom() | {atom(), map()}` in `lib/speckit_orchestrator/recovery/report.ex` per `contracts/report-discrepancy.md` §2
- [X] T014 [US3] Add `Recovery.Report.reason_label/1` (pure; bare atom → `to_string/1` unchanged, `{tag, detail}` → `"<tag> (k: v, k: v)"` with insertion-sorted keys) and rewire `reconciled_label/1` and `note/4`'s `"CONFLICT — …"` branch to call it, in `lib/speckit_orchestrator/recovery/report.ex` per `contracts/report-discrepancy.md` §3–4 (depends on T013; same file)

### Tests for User Story 3

- [X] T015 [P] [US3] Add cases to `test/speckit_orchestrator/recovery/reconcile_test.exs` for worked cases 4 (`checkpoint_behind_trail`), 7 (`last_completed_phase: :converge` falls through to `:no_position`), 8 (`{:damaged_checkpoint, …}` for an unrecognised phase), and 9 (`checkpoint_without_branch` when `branch_committed?: false`) per `contracts/reconcile-checkpoint-first.md` §4
- [X] T016 [P] [US3] Add cases to `test/speckit_orchestrator/recovery/report_test.exs` for `reason_label/1`'s full table (bare atoms unchanged, `checkpoint_behind_trail`, `damaged_checkpoint` with a garbled string value rendered via `inspect/1`) per `contracts/report-discrepancy.md` §3
- [X] T017 [P] [US3] Add a case to `test/speckit_orchestrator/recovery_test.exs`: `plan_run/2` puts a checkpoint-behind-trail feature in `report.conflicts`, maps it to `:blocked` in `statuses`, gives it no `resume_phases` entry, `Release.next/3` never releases it and never reports it `{:stopped, _, _}`, and `Report.format/1` renders `CONFLICT — checkpoint_behind_trail (checkpoint: plan, trail: analyze); human resolve` (SC-005, SC-003)
- [X] T018 [P] [US3] Add a case to `test/speckit_orchestrator/recovery/rebuild_test.exs` confirming `Rebuild.propose/3`'s preview carries the same widened conflict reason for an `:unreconcilable` feature (FR-012)

**Checkpoint**: User Story 3 is independently verified — a genuine contradiction is named, reported before any spend, and blocks its feature without stopping other features from resuming.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Prove nothing that resumes correctly today changed (SC-004/FR-014), then run the full gate

- [X] T019 [P] Add byte-identical regression cases across `test/speckit_orchestrator/recovery_quickpoll_test.exs`, `test/speckit_orchestrator/record_recovery_test.exs`, and `test/speckit_orchestrator/web/reconcile_test.exs` covering both existing-record shapes — `checkpoint: nil` and the agreeing checkpoint a writer would have produced at the same boundary — asserting zero new conflicts and identical resume phases (SC-004, FR-014)
- [X] T020 Run `mise exec -- mix test --cover` and confirm pure-core coverage stays >90% (plan.md Testing)
- [X] T021 Run `mise exec -- mix format --check-formatted && mise exec -- mix test`, then walk `quickstart.md` Scenarios 1–6 end-to-end (including the `resumable_run/0` preview showing zero spend change) as the final gate

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (T003 depends on T002, same file, sequential)
- **User Story 1 (Phase 3)**: Depends on Foundational. T008 (chunk write) has no dependency on T002/T003 beyond compiling against the same `Reconcile` module and can start as soon as Foundational lands
- **User Story 2 (Phase 4)**: Depends on Foundational — test-only, no implementation
- **User Story 3 (Phase 5)**: Depends on Foundational (T002's damaged/no-branch/behind-trail clauses). T014 depends on T013 (same file)
- **Polish (Phase 6)**: Depends on Phases 3–5 all being complete

### User Story Dependencies

- **US1 (P1)**: Foundational only. No dependency on US2/US3.
- **US2 (P2)**: Foundational only. Independently testable; verifies what US1 does not change.
- **US3 (P2)**: Foundational only. Independently testable; can run in parallel with US1/US2 once Foundational is done — different files (`report.ex` vs `chunk_runner.ex`).

### Parallel Opportunities

- T004–T007 (US1 tests) can run in parallel once T002/T003 land — different files
- T009, T010 (US1) can run in parallel with each other, but T008 (the implementation) must land first
- T011, T012 (US2) can run in parallel with the whole of US1 and US3 — different files, no shared state
- T015–T018 (US3 tests) can run in parallel once T013/T014 land — different files
- US1 and US3 implementation (T008 vs T013/T014) touch disjoint files and can proceed in parallel once Foundational is done
- T019 can run in parallel with nothing else in Phase 6 (T020/T021 are sequential gates over the whole suite)

---

## Parallel Example: User Story 1

```bash
# Once T002/T003/T008 land, launch US1's test tasks together:
Task: "Add worked-case coverage to test/speckit_orchestrator/recovery/reconcile_test.exs"
Task: "Add whole-run defect coverage to test/speckit_orchestrator/resume_run_test.exs"
Task: "Add resume-path parity coverage to test/speckit_orchestrator/resume_test.exs and resume_scope_test.exs"
Task: "Add mid-implement crash coverage to test/speckit_orchestrator/resume_crash_test.exs"
Task: "Add chunk-write coverage to test/speckit_orchestrator/chunk_runner_test.exs"
Task: "Add implement_chunk round-trip coverage to test/speckit_orchestrator/store/writer_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (T002, T003) — CRITICAL, blocks all stories
3. Complete Phase 3: User Story 1 (T004–T010)
4. **STOP and VALIDATE**: run quickstart.md Scenario 1, 2, 5 — the defect is fixed, both resume paths agree, implement progress is honoured
5. This alone satisfies the spec's stated priority: "Nothing else in this feature matters if this does not hold"

### Incremental Delivery

1. Setup + Foundational → shared decision table ready
2. User Story 1 → validate → the defect (SC-001) is fixed
3. User Story 2 → validate → no regression for checkpoint-less records (SC-004)
4. User Story 3 → validate → contradictions are reported, never guessed (SC-005)
5. Polish → full-suite regression guard + coverage + format gate

### Parallel Team Strategy

Once Foundational (T002/T003) is done:

- Developer A: User Story 1 (`chunk_runner.ex` + its tests)
- Developer B: User Story 3 (`report.ex` + its tests)
- Developer C: User Story 2 (test-only regression coverage)

All three touch disjoint files and integrate independently; Polish (Phase 6) runs only after all three land.

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- T002/T003 and T013/T014 are same-file sequential pairs — never mark them [P] against each other
- Commit after each task or logical group
- `mise exec --` prefixes every Elixir command (plain PATH is a stale global 1.19.5)
- `warnings_as_errors` is ON — a compiler warning fails the build
