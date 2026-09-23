# Tasks: Publish Integrity

**Input**: Design documents from `/specs/027-publish-integrity/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — quickstart.md and the contracts specify exact test files/scenarios; tests are part of this feature's acceptance criteria (SC-001..SC-006).

**Organization**: Tasks are grouped by user story per plan.md's delivery order — US1 (P1, MVP) first, then US2 (P1), then US3 (P2), then docs.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1, US2, US3 — maps to spec.md user stories
- All paths are relative to repository root

## Phase 1: Setup

**Purpose**: No new dependencies, no schema migration (data-model.md). Nothing to scaffold before Foundational.

- [X] T001 Confirm `mise exec -- mix test` is green on `main` before touching code (baseline for the incident replay in quickstart.md §2)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The two new pure modules and their extraction helpers that every user story's call sites depend on.

**⚠️ CRITICAL**: US1 and US2 both call into `Worktree` helpers added here; US1's surfaces depend on `PublishOutcome`. Complete this phase first.

- [X] T002 [P] Add `Worktree.current_branch/1` in `lib/speckit_orchestrator/worktree.ex` — `git symbolic-ref --quiet --short HEAD`, fallback `git rev-parse --short HEAD` for `{:detached, sha}`, `{:error, reason}` if both fail (contracts/branch-guard.md §2)
- [X] T003 [P] Add `Worktree.commits_beyond/3` in `lib/speckit_orchestrator/worktree.ex` — `git rev-list --count <base>..<branch>` in the base repo, returns `{:ok, count, %{branch_sha, base_sha}}` or `{:error, term}` (contracts/publish-outcome.md §1, data-model.md)
- [X] T004 [P] Add `Worktree.branch_name/1` in `lib/speckit_orchestrator/worktree.ex` — single source of truth `"feature/#{Feature.spec_id(feature)}-#{slug}"`, reused by `locate/2` and the specify prompt (contracts/specify-branch-pin.md)
- [X] T005 [P] Create `SpeckitOrchestrator.BranchGuard` in `lib/speckit_orchestrator/branch_guard.ex` — pure `check/2`: `:ok` on match, `{:drift, %{expected, observed}}` otherwise, no side effects (contracts/branch-guard.md §1)
- [X] T006 [P] Create `SpeckitOrchestrator.PublishOutcome` in `lib/speckit_orchestrator/publish_outcome.ex` — pure `describe/1` for `{:publish_failed, kind, detail}` and `{:branch_drift, phase, d}` per the exact-string table, `nil` for anything else (contracts/operator-surfaces.md)
- [X] T007 [P] `branch_guard_test.exs` — exhaustive table: same branch → `:ok`; different branch / `{:detached, sha}` → `{:drift, …}` (quickstart.md)
- [X] T008 [P] Extend `worktree_test.exs` against a real temp git repo — `current_branch/1` (named branch, detached), `commits_beyond/3` (count 0, count >0, unreadable ref) (quickstart.md)
- [X] T009 [P] `publish_outcome_test.exs` — exact-string table for all four tags plus `nil` fallback (quickstart.md, contracts/operator-surfaces.md)

**Checkpoint**: `BranchGuard`, `PublishOutcome`, and the three `Worktree` helpers exist and are unit-green. US1 and US2 work can now proceed in parallel.

---

## Phase 3: User Story 1 - A failed or empty publish stops the chain (Priority: P1) 🎯 MVP

**Goal**: A backlog feature's publish failure (empty branch, push rejection, PR-creation failure) stops the stacked chain, parks the run with a normalized, verbatim-carrying reason, and is resumable via a publish-only continue route with zero re-run phases.

**Independent Test**: Drive a stacked run through the `:publisher` seam; make the publisher fail (or make the branch identical to its base) for feature A. Verify no feature B release, run parked, `stopped_by` names A with a publish-failure reason, stack not advanced onto A's branch.

### Implementation for User Story 1

- [X] T010 [US1] Normalize the real publisher in `publish_feature/3` (`lib/speckit_orchestrator.ex`): short-circuit on an already-recorded `pr_url`; call `Worktree.commits_beyond/3` first and return `{:error, {:publish_failed, :empty_branch, %{branch, base, branch_sha, base_sha}}}` on zero, before any push or `gh` call (contracts/publish-outcome.md §1, data-model.md)
- [X] T011 [US1] In the same function, normalize `Worktree.push/2` failures to `{:error, {:publish_failed, :push_failed, %{branch, remote, output}}}` and `PullRequest.open/2`'s `{:gh_failed, code, out}` to `{:error, {:publish_failed, :pr_failed, %{branch, base, exit: code, output: out}}}` (contracts/publish-outcome.md §1)
- [X] T012 [US1] In `pr_notify/5` (`lib/speckit_orchestrator.ex`), on a backlog feature's `{:error, pf}`: normalize a non-tagged seam error via the `:publish_failed :pr_failed` wrap, `record_feature_terminal(id, :failed, pf)` (keep `pr_description`), skip `StackTracker.push/2`, forward `(id, :failed, pf)`, log a warning, emit `[:speckit, :publish, :failed]` with `%{feature_id, kind, reason}` (contracts/publish-outcome.md §2, FR-002, FR-003, FR-004)
- [X] T013 [US1] In `pr_notify/5`, preserve ad-hoc behavior unchanged: publish failure logs + emits `[:speckit, :publish, :failed]`, forwards `(id, :done, reason)`, no store rewrite, no parking (FR-007, contracts/publish-outcome.md §2 row 4)
- [X] T014 [US1] Fix `stack_seed/1` (`lib/speckit_orchestrator.ex`) to map each chain feature through `Worktree.locate(feature, opts).branch` (spec_id-based) instead of the backlog `number` (contracts/publish-outcome.md §5, data-model.md, research.md R8)
- [X] T015 [US1] Add the publish-only continue route in `resume/2` (`lib/speckit_orchestrator.ex`): detect `feature_record.status == :failed` with `terminal_reason` matching `{:publish_failed, _, _}`; return `{:error, {:publish_only, feature_id}}` if `:from`/`:prompt`/`:from_task_phase`/`:remediation_prompt`/`:remediation_model` supplied; otherwise skip `resolve_start_phase/2`, restore run scope, inject the publish-only executor (`Workers.spawn/3` notifying `:done, :republish`) so `run_stacked/4`'s `pr_notify` wrapper drives the ordinary publish path (contracts/publish-outcome.md §4, R7)
- [X] T016 [US1] `stacked_run_test.exs`: publisher returns `{:error, _}` for feature 1 → feature 2 never released, run parked, `stopped_by.reason` is `{:publish_failed, …}`, tracker chain excludes feature 1 (quickstart.md)
- [X] T017 [P] [US1] `stacked_run_test.exs`: ad-hoc feature publish failure → run continues, ad-hoc feature is `:done` (quickstart.md, FR-007)
- [X] T018 [P] [US1] `stacked_run_test.exs` with a real temp repo: branch == base → `{:publish_failed, :empty_branch, _}`, no push attempted (quickstart.md, FR-001)
- [X] T019 [US1] `resume_test.exs` / parked-run tests: `continue_run/1` after a publish park with publisher now ok → 0 phase sessions for the parked feature, row back to `:done` with `pr_url`, next feature's base is the parked branch (quickstart.md, SC-006)
- [X] T020 [P] [US1] `resume_test.exs`: `continue_run/1` with `pr_url` pre-recorded via `record_pr/3` → publisher never called (quickstart.md, R7)
- [X] T021 [P] [US1] `resume_test.exs`: `resume/2` with `:from` on a publish-failed feature → `{:error, {:publish_only, id}}` (quickstart.md, R7)
- [X] T022 [P] [US1] Stacked test: `stack_seed/1` with `spec_number ≠ number` → chain entries are `feature/<spec_id>-<slug>` (quickstart.md, R8)
- [X] T023 [US1] Wire operator surfaces for publish failures: `Report.format_reason/1` delegates to `PublishOutcome.describe/1 || inspect/1` (`lib/speckit_orchestrator/report.ex`); `Telemetry.attach_default_logger/0` logs `describe/1` of the reason (`lib/speckit_orchestrator/telemetry.ex`) (contracts/operator-surfaces.md, FR-004)
- [X] T024 [US1] Wire the three console `inspect(stopped_reason)` sites to describe-or-inspect: `MissionControlLive` parked banner, `RunDetailLive` run header, `RunsLive` row (`lib/speckit_orchestrator/web/live/{mission_control,run_detail,runs}_live.ex`) — reuse the existing mono span, no new CSS literal (contracts/operator-surfaces.md, design-contract discipline)
- [X] T025 [US1] Wire `RunDetailLive`'s local feature-row `format_reason/1` to try `PublishOutcome.describe/1` first, then its existing clauses (`lib/speckit_orchestrator/web/live/run_detail_live.ex`) (contracts/operator-surfaces.md, FR-005)

**Checkpoint**: User Story 1 is fully functional and independently testable — the incident's chain-corruption path (steps 4-7 of Background) is closed even without US2.

---

## Phase 4: User Story 2 - Branch drift fails the phase that caused it (Priority: P1)

**Goal**: Any session (phase, implement chunk, remediation attempt) that ends off the orchestrator's branch fails that phase immediately with a branch-drift reason, is never retried, and writes no further git state to either branch.

**Independent Test**: Stub a phase session that runs `git checkout -b other` inside the worktree. Verify the phase fails with a drift reason naming both branches, the feature ends `:failed` with worktree kept, and no later phase runs.

### Implementation for User Story 2

- [X] T026 [US2] Add the drift check in `Actions.RunFeaturePhase.run/2` (`lib/speckit_orchestrator/actions/run_feature_phase.ex`): after `PhaseSession.reduce/2` returns, when `state.worktree` is a `%Worktree{}` with a path, call `Worktree.current_branch/1` + `BranchGuard.check/2` as the **first** clause of `classify/4`, ahead of the incomplete-session gate; on `{:error, _}` from `current_branch/1` treat as drift with `observed: {:detached, "unknown"}`; on drift set `last_outcome: :error`, `last_signals: %{branch_drift: d}` (contracts/branch-guard.md §1-§3, FR-009, FR-010, FR-012)
- [X] T027 [P] [US2] Add the same post-`reduce/2` drift check to `Actions.RunAutoRemediation.run/2` (`lib/speckit_orchestrator/actions/run_auto_remediation.ex`) — attempt recorded failed, loop ends `{:failed, {:branch_drift, :analyze, d}}` (contracts/branch-guard.md §3, FR-009)
- [X] T028 [P] [US2] Add the same post-`reduce/2` drift check to `Actions.RunRemediation.run/2` (`lib/speckit_orchestrator/actions/run_remediation.ex`) — `FeatureRunner` ends `{:failed, {:branch_drift, :remediation, d}}` (contracts/branch-guard.md §3, FR-009)
- [X] T029 [US2] `PhaseStep.retry_reason/1` (`lib/speckit_orchestrator/phase_step.ex`): `branch_drift` present → `nil`, checked before any other retry test including `transient?` (contracts/branch-guard.md §4, FR-011)
- [X] T030 [US2] `Pipeline.next/3` (`lib/speckit_orchestrator/pipeline.ex`): new clause `next(phase, :error, %{branch_drift: d}) when phase in @ordered -> {:failed, {:branch_drift, phase, d}}`, ahead of the incomplete-session clause (contracts/branch-guard.md §4)
- [X] T031 [US2] `ChunkRunner.dispatch/4` (`lib/speckit_orchestrator/chunk_runner.ex`): when `agent1.state.last_signals[:branch_drift]` is present, skip `maybe_commit_boundary/4` and add `branch_drift: d` to the chunk signals (contracts/branch-guard.md §4)
- [X] T032 [US2] `Chunking.next/2` (`lib/speckit_orchestrator/chunking.ex`): new first row `Map.has_key?(signals, :branch_drift) -> {:failed, {:branch_drift, :implement, d}, state}` (contracts/branch-guard.md §4)
- [X] T033 [US2] `FeatureRunner.handle_worktree/5` (`lib/speckit_orchestrator/feature_runner.ex`): when reason is `{:branch_drift, _, _}`, skip `Worktree.commit/2` and only call `keep_for_inspection/1` (contracts/branch-guard.md §4, FR-011)
- [X] T034 [US2] `run_feature_phase_test.exs`: stubbed harness session runs `git checkout -b other` → `last_outcome: :error`, `last_signals.branch_drift` names both branches (quickstart.md)
- [X] T035 [P] [US2] `phase_step_test.exs`: drift is not retried, exactly one session (quickstart.md)
- [X] T036 [P] [US2] `pipeline_test.exs`: `Pipeline.next(:specify, :error, %{branch_drift: d})` → `{:failed, {:branch_drift, :specify, d}}` (quickstart.md)
- [X] T037 [P] [US2] `chunking_test.exs` and `chunk_runner_test.exs`: chunk drift → `{:failed, {:branch_drift, :implement, d}, _}`, no boundary commit on either branch (quickstart.md)
- [X] T038 [P] [US2] `feature_runner_test.exs`: drift terminal writes no commit — stray branch tip and orchestrator branch tip unchanged after terminal, worktree kept (quickstart.md)
- [X] T039 [US2] Wire the drift reason into operator surfaces already touched in T023-T025 (`PublishOutcome.describe/1` already covers `{:branch_drift, phase, d}` — confirm `Report.format_reason/1` and the three console sites render it) (contracts/operator-surfaces.md, FR-010)

**Checkpoint**: User Stories 1 AND 2 both work independently — the incident's root cause (Background step 2) is now detected, not just contained.

---

## Phase 5: User Story 3 - The orchestrator's branch is pinned for spec tooling (Priority: P2)

**Goal**: The `specify` request tells the target's spec tooling to reuse the orchestrator's exact branch name instead of inventing one, making US2's gate a rare fallback rather than the common case on targets carrying the speckit git extension.

**Independent Test**: Build the specify request and verify it carries the orchestrator's branch as an exact, reuse-semantics override alongside the spec-directory pin; against a scratch target with the branch-creating hook, verify worktree HEAD after `specify` is still `feature/NNN-slug`.

### Implementation for User Story 3

- [X] T040 [US3] `PhaseRequest.build(feature, :specify, opts)` (`lib/speckit_orchestrator/phase_request.ex`): append the `GIT_BRANCH_NAME=feature/<spec_id>-<slug>` reuse sentence immediately after `SPECIFY_FEATURE_DIRECTORY`, using `Worktree.branch_name/1` (T004) as the single source of truth; no change to any other phase (contracts/specify-branch-pin.md)
- [X] T041 [US3] `phase_request_test.exs`: specify prompt contains `GIT_BRANCH_NAME=feature/<spec_id>-<slug>` and the reuse sentence; no other phase's prompt changes (quickstart.md)

**Checkpoint**: All three user stories are independently functional — US1 contains, US2 detects, US3 prevents.

---

## Phase 6: Docs & Polish

**Purpose**: Cross-cutting documentation required by the plan; final full-suite and manual validation.

- [X] T042 [P] Add "Publish failure parked the run" and "Branch drift" recovery sections to `docs/runbook.md` (plan.md Project Structure)
- [X] T043 [P] Add one paragraph under Control plane / Pipeline gates in `CLAUDE.md` summarizing US1-US3 (plan.md Project Structure)
- [X] T044 Confirm `design_contract_test.exs` stays green after the console changes in T024, T025, T039 (contracts/operator-surfaces.md)
- [X] T045 Run the full suite: `mise exec -- mix test` (quickstart.md §1) — zero regressions, all new tests from T007-T009, T016-T022, T034-T038, T041 pass
- [ ] T046 Run the manual live-replay protocol against a scratch target carrying the speckit git extension (quickstart.md §2): pin (US3), drift (US2), publish stop (US1), continue — covers SC-001, SC-003, SC-004

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS US1 and US2 (both call `Worktree` helpers / `BranchGuard` / `PublishOutcome`). US3 only needs `Worktree.branch_name/1` (T004).
- **US1 (Phase 3)**: Depends on Foundational (T002, T003, T006). Independent of US2 and US3.
- **US2 (Phase 4)**: Depends on Foundational (T002, T005). Independent of US1 and US3.
- **US3 (Phase 5)**: Depends on Foundational (T004) only. Independent of US1 and US2, but US2's gate is what makes US3 safe if the model ignores the pin (spec.md Acceptance Scenario 3).
- **Docs & Polish (Phase 6)**: Depends on US1, US2, US3 all complete.

### User Story Dependencies

- **US1 (P1)**: No dependency on US2/US3. Alone, bounds the incident to one feature (plan.md Delivery order).
- **US2 (P1)**: No dependency on US1/US3. Alone, detects drift but a publish could still advance on incomplete data without US1's stop.
- **US3 (P2)**: No dependency on US1/US2, but is a no-op safety net without US2's gate as the backstop.

### Within Each User Story

- `Worktree`/`BranchGuard`/`PublishOutcome` extraction/decision code before call-site wiring
- Call-site wiring before its tests
- Real-publisher normalization (T010-T011) before `pr_notify` wiring (T012-T013), which both precede the continue route (T015)
- `stack_seed/1` fix (T014) is independent of T010-T013 but required before T019/T022's continue-route tests

### Parallel Opportunities

- T002-T006 (five new pure functions/modules, different files) run in parallel
- T007-T009 (new test files) run in parallel once their subjects exist
- Within US1: T017, T018, T020, T021, T022 are independent test additions once T010-T015 land
- Within US2: T027, T028 (the two remediation actions) run in parallel with each other and with T026
- T035-T038 (US2 test files) run in parallel once T029-T033 land
- US1 and US2 implementation phases (3 and 4) can run in parallel once Foundational completes, since they touch disjoint files except the shared surfaces work (T023-T025 vs T039, sequence those two within a story but the stories themselves don't conflict)
- T042, T043 (docs) run in parallel with each other and with final test runs

---

## Parallel Example: Foundational Phase

```bash
# Launch the five new pure additions together (different files):
Task: "Add Worktree.current_branch/1 in lib/speckit_orchestrator/worktree.ex"
Task: "Add Worktree.commits_beyond/3 in lib/speckit_orchestrator/worktree.ex"
Task: "Add Worktree.branch_name/1 in lib/speckit_orchestrator/worktree.ex"
Task: "Create SpeckitOrchestrator.BranchGuard in lib/speckit_orchestrator/branch_guard.ex"
Task: "Create SpeckitOrchestrator.PublishOutcome in lib/speckit_orchestrator/publish_outcome.ex"
```

## Parallel Example: User Story 2 remediation actions

```bash
Task: "Add drift check to Actions.RunAutoRemediation.run/2"
Task: "Add drift check to Actions.RunRemediation.run/2"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (T002, T003, T006, T009 — skip T004/T005/T007/T008 if deferring US2/US3, though building them together is cheap since they're independent files)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: `stacked_run_test.exs` + `resume_test.exs` new cases green; this alone would have bounded the 2026-09-23 incident to one feature (plan.md Summary)

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. Add US1 → validate independently → chain-corruption path closed (MVP)
3. Add US2 → validate independently → root cause now detected, not just contained
4. Add US3 → validate independently → prevention on speckit-git-extension targets
5. Docs & Polish → runbook, CLAUDE.md, full suite, manual replay

### Parallel Team Strategy

1. Team completes Setup + Foundational together (five independent files)
2. Once Foundational is done:
   - Developer A: US1 (Phase 3) — `speckit_orchestrator.ex` + `report.ex`/`telemetry.ex`/console
   - Developer B: US2 (Phase 4) — `run_feature_phase.ex`, remediation actions, `pipeline.ex`, `chunking.ex`, `chunk_runner.ex`, `feature_runner.ex`
   - Developer C: US3 (Phase 5) — `phase_request.ex`, then docs (Phase 6) once US1-US3 land
3. Stories integrate independently since they touch disjoint file sets (only `PublishOutcome.describe/1`'s console wiring is shared surface — T023-T025 and T039 both render through it but don't conflict on lines)

---

## Notes

- No new operator-configurable setting (FR-015); no schema migration (FR-016, data-model.md) — every new fact lives in an existing term column
- `warnings_as_errors` is on; run everything through `mise exec --`
- The design-contract guard (`design_contract_test.exs`) must stay green — no new CSS literal, no new status atom, no inline style (T024, T044)
- Commit after each task or logical group; verify new tests fail before their implementation task lands
