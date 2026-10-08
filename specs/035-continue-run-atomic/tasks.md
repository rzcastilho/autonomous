# Tasks: Atomic Continue of a Parked Run

**Input**: Design documents in `/specs/035-continue-run-atomic/` (plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md)

**Tests**: Included — the spec's success criteria (SC-001..006) are test-measured, and the constitution requires seam-based hermetic tests.

**Toolchain**: every command via `mise exec -- …`; `warnings_as_errors` is on.

## Format: `- [ ] [TaskID] [P?] [Story?] Description with file path`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: US1 (refused continue leaves run intact), US2 (refusal still names its cause), US3 (Escalations path)

---

## Phase 1: Setup

- [X] T001 Baseline: run `mise exec -- mix test test/autonomous/parked_run_test.exs` and record that it passes on the branch before changes (SC-005 reference); no code change

---

## Phase 2: Foundational (blocks all user stories)

**Purpose**: schema v7 field, store writers, and the reconcile split the continue path depends on.

- [X] T002 Append `:continue_restore_failure` (last field, default `nil`) to `Records.Run` struct and `@type t` in `lib/autonomous/store/records.ex`; ensure `encode/decode` round-trip for `:speckit_run`
- [X] T003 Append `:continue_restore_failure` as the last `:speckit_run` attribute in `lib/autonomous/store/schema.ex`
- [X] T004 Add migration `{7, "append speckit_run.continue_restore_failure", &add_continue_restore_failure/0}`, a pinned `@run_v7_attributes`, and bump `current_version/0` to 7 in `lib/autonomous/store/migrations.ex` (plain `transform_table` append, every v6 row gets `nil`; update moduledoc)
- [X] T005 [P] Expose `continue_restore_failure` in `run_summary/1` in `lib/autonomous/store/query.ex` and include it in `lib/autonomous/store/export.ex`
- [X] T006 Add `Writer.repark_run/2` (`:in_flight -> :parked`, restores `stopped_by`/`stopped_reason`, aborts `:not_in_flight` otherwise), `Writer.annotate_continue_restore_failure/2`, `Writer.clear_continue_restore_failure/1` (skip write when already `nil`) in `lib/autonomous/store/writer.ex`; make `continue_run/1` and `end_run/2` also set the field to `nil` inside their existing transactions. Each is one `run_transaction/1` with `@spec`s per contracts/continue-run.md
- [X] T007 Promote private `write_corrections/3` to public `apply_corrections(run_key, report_features, opts) :: :ok | {:error, term()}` in `lib/autonomous/recovery.ex` — returns the first writer error instead of discarding it; `reconcile_run/2` keeps calling it with its own return shape unchanged (research R8, contracts/continue-run.md § Recovery addition)
- [X] T008 [P] Migration test in `test/autonomous/store/migrations_test.exs`: v6 store boots to v7 with `nil` field on every run row; newer-than-known version still fails loud. Update any attribute/round-trip pins in `test/autonomous/store/records_test.exs` and `test/autonomous/store/export_test.exs` for the new field
- [X] T009 [P] Writer tests in `test/autonomous/store/writer_test.exs` for `repark_run/2` (happy path, non-`:in_flight` abort, absent run), annotate/clear lifecycle, and that `continue_run/1`/`end_run/2` clear the annotation
- [X] T010 [P] Recovery test in `test/autonomous/recovery_test.exs`: `apply_corrections/3` writes the `:done` correction and the awaiting-answers escalation via injected `:writer`, surfaces a writer error; `reconcile_run/2` behaviour and return shape unchanged

**Checkpoint**: `mise exec -- mix test test/autonomous/store test/autonomous/recovery_test.exs` green.

---

## Phase 3: User Story 1 — A refused continue leaves the parked run intact (P1) 🎯 MVP

**Goal**: any refusal on the continue path leaves the run `:parked`, byte-identical, with nothing running; retry after fixing the cause works.

**Independent Test**: park a `permissive` run against a target whose committed pack lags contract 3, `continue_run/1` → refused, `Store.parked_run/1` unchanged, no Coordinator/worker/worktree; fix pack, continue again → `{:ok, pid}`.

### Tests for US1 (all in `test/autonomous/continue_run_atomic_test.exs`; same file — write serially)

- [X] T011 [US1] Create `test/autonomous/continue_run_atomic_test.exs` with shared helpers: park a run; snapshot the full run record + feature rows + checkpoints + phase_attempt/cost/escalation row counts; `assert_intact/1` (snapshot-equal); `assert_nothing_running/1` — no Coordinator, `Workers.in_flight/1 == []`, **and the stopping feature's `Worktree.locate/2` path is absent (or unchanged, if it existed before the attempt)** (FR-004)
- [X] T012 [US1] Incident test — temp git target with outdated committed pack, run recorded `permissive`, no `:runner`/`:executor` seam and no explicit `:containment_profile` opt (so refusal comes from `preflight_stacked/2`); assert `{:error, {:preflight, [{:pack_outdated, ".claude/hooks/scope_guard.py", _} | _]}}`, `assert_intact`, `assert_nothing_running`
- [X] T013 [US1] Retry-after-fix test (US1-AS3) — commit contract-3 pack (or switch to seam runner), second `continue_run/1` returns `{:ok, pid}`, run `:in_flight`, `stopped_by` nil
- [X] T014 [US1] Per-cause refusal matrix (FR-002, FR-003, FR-005/SC-004) — each case asserts **both** `assert_intact`/`assert_nothing_running` **and** the exact reason term:

  | Cause | Expected `{:error, reason}` |
  |---|---|
  | store capacity refusing | `{:preflight, [{:store_capacity, %{status: :refusing}}]}` (match the map) |
  | `:containment_profile` differs from recorded | `{:preflight, [{:containment_profile_locked, recorded}]}` |
  | invalid `:containment_profile` value | `{:preflight, [reason]}` from `Containment.normalize/1` |
  | stopping feature has no checkpoint | `:no_checkpoint` |
  | stored run damaged | `:corrupt_manifest` |
  | `:from` not a pipeline phase | `{:unknown_phase, from}` |
  | unknown `:remediation_model` | `{:unknown_model, alias}` |
  | publish-failed stopping feature + `:prompt` | `{:publish_only, feature_id}` |
  | retired option (`:pr_workflow`) | `{:preflight, [{:retired_option, :pr_workflow}]}` |
  | invalid remediation setting (attempt limit 0) | `{:preflight, [{:invalid_attempt_limit, 0}]}` |
  | reconciliation conflict/corrupt | reason from `Recovery.plan_run/2`, unchanged |

  Plus one case where a reconciliation `:done` correction **would** fire (evidence says done, store says not) and a later preflight refuses: assert the feature row is unchanged (research R8)
- [X] T015 [US1] `:coordinator_start` seam → `{:error, :boom}`: returns `{:error, :boom}`, run re-parked field-for-field equal to snapshot, no Coordinator, stack tracker not left running
- [X] T016 [US1] Restore-failure tests (FR-009, SC-006): (a) `:coordinator_start` error + `:repark` → `{:error, :disk}` ⇒ `{:error, {:continue_restore_failed, :boom, :disk}}`, error log contains both reasons (`ExUnit.CaptureLog`), annotation present with both reasons and timestamp; cleared by later `end_run/1` and, separately, by successful `resume/2`. (b) same plus `:annotate` → `{:error, :ro}` ⇒ result still `{:continue_restore_failed, :boom, :disk}` and the error log still carries both reasons
- [X] T017 [US1] Race tests (FR-010): two concurrent `continue_run/1` with seam runner — exactly one `{:ok, pid}`, loser `{:error, :not_parked}`, **winner's Coordinator and stack tracker both still alive** after the loser returns (proves the loser never reached `start_stack_tracker/2`); `end_run/1` racing a refused continue ends consistent (parked or ended, never orphan `:in_flight`)

### Implementation for US1 (all `lib/autonomous.ex` — sequential)

- [X] T018 [US1] `continue_run/1`: stop calling `Writer.continue_run/1` up front; capture snapshot `%{run_key, stopped_by, stopped_reason}` (extend `find_parked_run/1` to return `stopped_reason`) and pass it to `resume/2` as internal opt `:continue_parked`; keep steps 1–3 order (guard, find, capacity)
- [X] T019 [US1] `resume/2`: when `:continue_parked` present, read the run via `Store.run(snapshot.run_key)` instead of `read_current_run/0`, mapping `{:error, {:damaged, _, _}}` to `:corrupt_manifest` exactly as `read_current_run/0` does; leave every other check and its order unchanged; forward the option through `dispatch_resume_route/7` (both `:phase` and `:publish_only` clauses) into `run/1`
- [X] T020 [US1] `restore_run_scope/2`: when `:continue_parked` present, use read-only `Recovery.plan_run/2` instead of `Recovery.reconcile_run/1` and return the plan's `report.features` in the scope map for later application; without the marker, unchanged
- [X] T021 [US1] `preflight_parked_run/0` → `/1` taking `opts`: do not refuse when the parked run's key equals `opts[:continue_parked].run_key` (any other parked run still refuses); update the `run/1` call site and the stale comment above it
- [X] T022 [US1] `run_stacked/4`, contract steps 8–12: after `preflight_stacked/2`, when `:continue_parked` present: `Writer.continue_run/1` **first** (loser → return `{:error, :not_parked}` before any process side effect); then `Recovery.apply_corrections/3` with the deferred report; then `start_stack_tracker/2` (convert `{:ok, tracker} =` into a `with` branch); then `start_run/2`. On any of those three failing: stop a tracker this attempt started, call `repark_run/2` (or `:repark` seam), return the original `{:error, reason}`. Do not add `:continue_parked` to the `extra` keyword passed to `start_run/2`
- [X] T023 [US1] Seams and clearing: `:coordinator_start` (replaces `start_coordinator/1` inside `start_run/2`), `:repark`, `:annotate` — honoured only alongside the existing `:runner`/`:executor` seams; after a successful `start_run/2` for any run with `:run_key`, call `Writer.clear_continue_restore_failure/1`
- [X] T024 [US1] FR-009 branch (step 13): on repark `{:error, e}` → `Logger.error` naming run id, original reason, `e`; best-effort annotate (`Writer.annotate_continue_restore_failure/2` or `:annotate` seam) with `inspect`ed strings and UTC `at`, ignoring its failure; return `{:error, {:continue_restore_failed, reason, e}}`; update `continue_run/1` `@spec`/`@doc` step list (flip now after pack preflight, before tracker)
- [X] T025 [P] [US1] `lib/autonomous/web/live/run_detail_live.ex`: render `data-marker="continue-restore-failure"` block (refusal, restore error, at, `resume/2` hint) only when the field is non-nil, per contracts/operator-surfaces.md — mono for machine values, existing tokens only, no inline style, no raw `inspect/1`
- [X] T026 [P] [US1] `test/autonomous/web/run_detail_live_test.exs`: block shown with annotation, absent without. `test/autonomous/web/mission_control_live_test.exs`: after a refused continue, `data-action="continue-run"` and `data-action="end-run"` still render and nothing is shown running (FR-006)

**Checkpoint**: US1 independently green; `parked_run_test.exs` unmodified and passing (SC-005); `design_contract_test.exs` clean.

---

## Phase 4: User Story 2 — The refusal still names its cause (P2)

**Goal**: reasons identical to pre-035 on every entry point. The `continue_run/1` terms are pinned in T014; this phase pins the console entry point.

**Independent Test**: Mission Control flash for a refused continue names the same reason as before.

- [X] T027 [US2] `test/autonomous/web/mission_control_live_test.exs`: refusal flash equals `"Continue failed: " <> inspect(reason)` for the pack-outdated case and one resume-route case (`{:unknown_phase, _}`); `lib/autonomous/web/live/mission_control_live.ex` unchanged

**Checkpoint**: if any pin fails, fix in `lib/autonomous.ex`, not in the test.

---

## Phase 5: User Story 3 — Same guarantee from Escalations (P3)

**Goal**: Escalations resume form for the stopping feature inherits the guarantee.

**Independent Test**: park run, arrange refusal, submit Escalations resume form for `stopped_by` → run stays `:parked`, error shown.

- [X] T028 [P] [US3] `test/autonomous/web/escalations_live_test.exs`: refused continue via the resume form (with and without `:prompt` / remediation options) leaves run `:parked` with original `stopped_by`/`stopped_reason` and shows the cause; no production change expected in `lib/autonomous/web/live/escalations_live.ex`

**Checkpoint**: all three stories green.

---

## Phase 6: Polish & Cross-Cutting

- [X] T029 [P] Update `docs/runbook.md`: continue refusal leaves run parked; restore-failure annotation meaning and `resume/2` recovery; crash-mid-continue window (research R6); `:force` remains an override outside the race guarantee (R3); pre-035 orphans still recover via `resume/2`
- [X] T030 [P] Update `CLAUDE.md` parked-run description (feature 035: flip after preflight and before tracker, deferred reconcile corrections, `:continue_restore_failure`, schema v7)
- [X] T031 Run full gates: `mise exec -- mix format --check-formatted`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix test` (SC-005 whole suite)
- [ ] T032 Walk `quickstart.md` §2 manual scenario against a scratch target and record the outcome in `specs/035-continue-run-atomic/quickstart.md`

---

## Dependencies & Order

- Phase 1 → Phase 2: T002→T003→T004; T005 after T002/T003; T006 after T002; T007 independent; T008 after T004; T009 after T006; T010 after T007.
- Phase 3: tests T011→T012…T017 (one file, serial). Implementation T018→T019→T020→T021→T022→T023→T024 (one file, serial; needs T006, T007). T025 needs only T005. T026 after T025 and T024.
- US2 (T027) and US3 (T028) after US1 implementation; T027 shares `mission_control_live_test.exs` with T026 — run after it.
- Polish after all stories.

## Parallel Examples

- After T002/T006/T007: T005 ‖ T008 ‖ T009 ‖ T010.
- T025 ‖ T018–T024 (different file).
- T028 ‖ T027; T029 ‖ T030.

## Implementation Strategy

- **MVP = Phase 1–3 (US1)**: fixes the incident, the race, the reconcile-write leak, and FR-009. Validate with quickstart §1 before US2/US3.
- US2 and US3 are assertion tasks pinning behaviour US1 delivers; production fixes only if a pin fails.
- Behaviour is a new spec'd feature (035); do not amend earlier specs in place.
