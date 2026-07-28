---

description: "Task list for feature implementation"
---

# Tasks: Unified Run-State Persistence

**Input**: Design documents from `/specs/018-unified-run-persistence/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/schema.md,
contracts/store-api.md, contracts/persistence-failure.md,
contracts/capacity-and-prune.md, contracts/export-format.md, contracts/console-runs.md

**Tests**: Included. The project constitution requires >90% pure-core coverage, the
existing suite is exhaustive per-module, and quickstart.md names exact test files
(`records_test.exs`, `prune_test.exs`, `capacity_test.exs`, `export_test.exs`,
`mnesia_test.exs`, `boot_test.exs`, `persistence_failure_test.exs`) as the validation
protocol — tests are load-bearing for this feature, not optional.

**Organization**: Phase 2 (Foundational) builds the store engine every user story
needs, including the two read-only facades (`store_capacity/0`, `export_run/3`) that
later phases consume. Phases 3–5 map to spec.md's three user stories (resume /
history / detail). Phase 6 covers the remaining FR-031*/FR-032* lifecycle work
(pruning) and the facade-level lifecycle tests. Phase 7 is the clean break (FR-037)
and cross-cutting polish.

**Clean-break discipline**: FR-037 deletes `RunManifest`, `Checkpoint`, `Transcripts`,
and `Describe`'s PR-file pair. Every call site must be cut over *before* T072 deletes
them, or `mix compile` fails under `warnings_as_errors`. The call sites are enumerated
explicitly below (T032–T048) and the affected existing tests in T049–T053 and T078 —
none is left to be discovered at deletion time.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1/US2/US3); no label on
  Setup/Foundational/Lifecycle/Polish phases
- File paths are exact and repo-relative

---

## Phase 1: Setup

**Purpose**: Toolchain and configuration groundwork the store depends on.

- [X] T001 Add `:mnesia` to `extra_applications` in `mix.exs` (no new Hex dep)
- [X] T002 [P] Add `store_dir/0`, `store_capacity_bytes/0`, `store_headroom_bytes/0` to `lib/speckit_orchestrator/config.ex` (defaults: `<autonomous_root>/mnesia`, `1_500_000_000`, `150_000_000` per research R3, R17)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The persistence boundary itself — pure policy modules, the sole
`:mnesia` caller, boot/health/migrations, the internal Writer/Query API, and the two
read-only facades later phases depend on. No user story can be implemented or tested
until this phase is complete.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Pure modules (no schema, no running node — async: true)

- [X] T003 [P] `Store.Ids` — pure `repo_id`/`run_id`/`attempt_id` derivation in `lib/speckit_orchestrator/store/ids.ex` (research R10, R11; data-model.md Identity and partitioning)
- [X] T004 [P] `Store.Records` — pure structs + `encode/1`/`decode/2` tuple codecs for all 12 tables, returning `{:ok, struct} | {:error, {:damaged, key, reason}}`, never defaulting on a bad row in `lib/speckit_orchestrator/store/records.ex` (contracts/schema.md § Damaged-state reporting)
- [X] T005 [P] `Store.Schema` — the 12 table specs as data (attributes, storage type, indexes) per `contracts/schema.md` § Tables in `lib/speckit_orchestrator/store/schema.ex`
- [X] T006 [P] `Store.Capacity` — pure `check/1` decision table in `lib/speckit_orchestrator/store/capacity.ex` (contracts/capacity-and-prune.md § Capacity)
- [X] T007 [P] `Store.Prune` — pure `plan/3` policy (protected runs never removable, reported with reason) in `lib/speckit_orchestrator/store/prune.ex` (contracts/capacity-and-prune.md § Prune)
- [X] T008 [P] `Store.Export` — pure `encode/1` JSON encoder (utf8/base64 transcript encoding, no store/path references) in `lib/speckit_orchestrator/store/export.ex` (contracts/export-format.md)

### Mnesia boundary and edge modules

- [X] T009 `Store.Mnesia` — the ONLY module calling `:mnesia`; wraps create_schema/start/transaction/dirty_read/table_info from `Store.Schema` specs (depends on T005) in `lib/speckit_orchestrator/store/mnesia.ex`
- [X] T010 `Store.Migrations` — ordered `[{version, description, fun}]` list, `:mnesia.transform_table/3`-based (depends on T009) in `lib/speckit_orchestrator/store/migrations.ex`
- [X] T011 `Store.Boot` — `start!/0` boot sequence: mkdir, set mnesia dir, create schema, verify node ownership against BOTH `:mnesia.table_info(:schema, :disc_copies)` and `speckit_meta`'s `:node` row (aborting with `{:error, {:schema_node_mismatch, expected, found}}` naming both names — this verification is what discharges the recorded node-name deviation in plan.md Complexity Tracking), apply migrations, `wait_for_tables`, write-probe (research R2, R4) (depends on T009, T010) in `lib/speckit_orchestrator/store/boot.ex`
- [X] T012 `Store.Health` — thin GenServer mirroring `Ledger`, holding `:ok | {:failed, reason, at}` with `record_failure/2`, `failed?/1`, `status/1`, `clear/1` (contracts/persistence-failure.md) in `lib/speckit_orchestrator/store/health.ex`
- [X] T013 `Store.Writer` — one transaction per durable boundary (`contracts/schema.md` § Transaction boundaries): `open_run/2`, `record_phase_attempt/2`, `record_remediation_attempt/2`, `record_feature_terminal/4`, `record_escalation/2`, `resolve_escalation/2`, `record_settings_amendment/3`, `close_run/3`, `flag_record_incomplete/2`; every abort reports to `Store.Health.record_failure/2` before returning `{:error, reason}` (depends on T004, T009, T012) in `lib/speckit_orchestrator/store/writer.ex`
- [X] T014 `Store.Query` — `runs/2`, `run/1`, `checkpoint/2`, `transcript/1`, `in_flight_run/1`, `capacity/0`; transactional except the console's non-authoritative dirty reads (depends on T004, T009) in `lib/speckit_orchestrator/store/query.ex`
- [X] T015 `SpeckitOrchestrator.Store` — boundary facade/behaviour module tying Writer/Query together (depends on T013, T014) in `lib/speckit_orchestrator/store.ex`
- [X] T016 `RepoIdentity.partition/1` — `o:`/`l:`-prefixed repo_id derivation (origin, else path-derived fallback); `resolve/1` and the no-origin preflight stay unchanged (research R10) in `lib/speckit_orchestrator/repo_identity.ex`
- [X] T017 Wire `Store.Boot.start!/0` before any child spec (aborting `Application.start/2` on failure) and add `Store.Health` to the supervision tree (depends on T011, T012) in `lib/speckit_orchestrator/application.ex`

### Read-only facades (Foundational because Phases 3–5 consume them)

- [X] T018 Implement `store_capacity/0` facade — measures via `Store.Query.capacity/0`, decides via `Store.Capacity.check/1`, and computes `reclaimable_bytes` via `Store.Prune.plan/3` over `Store.Query.runs/2`; returns the refusal-message shape naming shortfall and reclaimable amount (contracts/capacity-and-prune.md § Refusal message shape). Consumed by T044 (run preflight) and T056 (console banner) in `lib/speckit_orchestrator.ex` (depends on T006, T007, T014)
- [X] T019 Implement `export_run/3` facade — `Store.Export.encode/1` plus a single-file write; read-only transaction, takes no lock that blocks a writer, mutates and prunes nothing, available mid-run and under a capacity refusal. Consumed by T063 (console export action) in `lib/speckit_orchestrator.ex` (depends on T008, T014)

### Test harness

- [X] T020 `test/support/store_case.ex` — shared temp-schema `ExUnit.CaseTemplate`, clears every table between tests (research R14) (depends on T011)
- [X] T021 `test/test_helper.exs` — create one temporary Mnesia store under the system temp dir via `Store.Boot`, remove on exit; default suite never touches `~/.autonomous` (depends on T011, T020)

### Foundational tests

- [X] T022 [P] `test/speckit_orchestrator/store/ids_test.exs` — repo_id prefixing, run_id zero-padding, attempt_id shape
- [X] T023 [P] `test/speckit_orchestrator/store/records_test.exs` — encode/decode round trip per table; damaged-row `{:error, {:damaged, key, reason}}`; absent vs. damaged distinction
- [X] T024 [P] `test/speckit_orchestrator/store/capacity_test.exs` — `:ok` / `{:refuse, %{shortfall_bytes:, ...}}` boundary conditions
- [X] T025 [P] `test/speckit_orchestrator/store/prune_test.exs` — in-flight and resumable runs never removable; `bytes_reclaimable` from stored counts
- [X] T026 [P] `test/speckit_orchestrator/store/export_test.exs` — pure encode: utf8 vs. base64 transcript encoding, no store/path leakage, format/format_version present
- [X] T027 `test/speckit_orchestrator/store/mnesia_test.exs` — schema create on `:nonode@nohost`, storage-type rules (`disc_copies`/`disc_only_copies`, `ordered_set` rejected on `disc_only_copies`), transactional read-modify-write sequence bump, 50 concurrent writers lose nothing (async: false)
- [X] T028 `test/speckit_orchestrator/store/boot_test.exs` — node-ownership check against both sources, `{:error, {:schema_node_mismatch, ...}}`, migrations applied in order, `{:error, {:schema_version_ahead, ...}}`, write-probe proves writability (FR-009)
- [X] T029 `test/speckit_orchestrator/store/health_test.exs` — `ok → failed → ok` transitions, `record_failure/2`/`failed?/1`/`clear/1`
- [X] T030 `test/speckit_orchestrator/store/writer_test.exs` — each boundary writes all-or-nothing (FR-006); parallel writers to disjoint keys lose no update (FR-007, SC-008); N concurrent `open_run/2` calls leave exactly one `:in_flight` row (FR-034, SC-012); an aborted transaction reports to `Store.Health`
- [X] T031 `test/speckit_orchestrator/store/query_test.exs` — `runs/2` ordering and filters, `run/1` absent/damaged/complete three-way return, `checkpoint/2`, `transcript/1`, `capacity/0`

**Checkpoint**: Store engine compiles, boots, and passes its own suite; `store_capacity/0` and `export_run/3` are callable. User story implementation can now begin.

---

## Phase 3: User Story 1 - Resume an interrupted run from one authoritative record (Priority: P1) 🎯 MVP

**Goal**: Every phase attempt, checkpoint, escalation, settings amendment, and cost
entry is recorded through `Store.Writer` in one transaction per boundary, so an
interrupted run resumes from one authoritative record instead of three
independently-written files, and a persistence failure drains rather than kills.

**Independent Test**: Start a run, interrupt it at an arbitrary point (including
between two state writes), then call `resumable/1` and `resume_run/1`. Verify each
incomplete feature restarts at its checkpointed phase, completed features are not
re-run, the resumed run uses the original run settings, and a store-unwritable
mid-run interruption drains between phases rather than aborting mid-phase.

### Write-path cutover (every `RunManifest`/`Checkpoint`/`Transcripts`/`Describe` call site)

- [X] T032 [US1] Cut `FeatureRunner` to record each completed phase's attempt + checkpoint + transcript via `Store.Writer.record_phase_attempt/2`, replacing `Checkpoint.write/1` (lines ~252, ~436) and `Transcripts.write/5` (line ~224) in `lib/speckit_orchestrator/feature_runner.ex`
- [X] T033 [US1] Cut `FeatureRunner` to record feature terminal status via `Store.Writer.record_feature_terminal/4`, the `pr_description` field in that same transaction (replacing `Describe.write_pr/3` at line ~475), and on a diverting outcome `Store.Writer.record_escalation/2` in `lib/speckit_orchestrator/feature_runner.ex` (depends on T032)
- [X] T034 [US1] Add the persistence-failure drain check — `Store.Health.failed?/1` evaluated at the existing inter-phase `{:cont, next}` point, after the breaker check, halting with `{:persistence_failed, reason}` before the next phase starts (FR-010) in `lib/speckit_orchestrator/feature_runner.ex` (depends on T033)
- [X] T035 [US1] Cut `AnalyzeRunner` to record each remediation attempt + its transcript via `Store.Writer.record_remediation_attempt/2`, replacing `Transcripts.write_labelled/6` (lines ~237, ~259) in `lib/speckit_orchestrator/analyze_runner.ex`
- [X] T036 [US1] Cut `ChunkRunner` on **both** sides: writes via `Store.Writer` replacing `Transcripts.write_labelled/6` (lines ~283, ~331), and the chunk-resume **read** at line ~89 from `Checkpoint.read/2` to `Store.Query.checkpoint/2` in `lib/speckit_orchestrator/chunk_runner.ex`
- [X] T037 [US1] Cut `PhaseStep`'s transcript write (line ~108) to go through `Store.Writer` instead of `Transcripts.write_labelled/6`, and update the moduledoc reference at line ~29 in `lib/speckit_orchestrator/phase_step.ex`
- [X] T038 [US1] Delete `Describe.write_pr/3` and `Describe.read_pr/2` (FR-037 — the PR-file pair is deleted, not re-pointed); their data now lives in `feature_run.pr_description`, written by T033 and read by T041 in `lib/speckit_orchestrator/describe.ex`
- [X] T039 [US1] Cut `Coordinator`'s `:manifest` seam to `:store`: `Store.Writer.open_run/2` (superseding any prior in-flight run for the repo in the same transaction), and `Store.Health.failed?/1` checked in `advance/1` releasing nothing new, at the same point `breaker_tripped?/1` is checked, in `lib/speckit_orchestrator/coordinator.ex`
- [X] T040 [US1] Seed `Ledger.restore/2` from the run's `speckit_cost_entry` roll-up (`Store.Query`) instead of a single recorded scalar, so spend stays attributable across a resume in `lib/speckit_orchestrator/ledger.ex`
- [X] T041 [US1] Cut `Recovery.Evidence`'s three file-sourced signals to the store: `checkpoint` (line ~153) → `Store.Query.checkpoint/2`; `pr_record?` (line ~54) → `feature_run.pr_description != nil`; `final_marker?` → `Store.Query.transcript/1` for the converge attempt with the same regex. Git-sourced signals unchanged in `lib/speckit_orchestrator/recovery/evidence.ex`
- [X] T042 [US1] Cut `Recovery.Rebuild` off `RunManifest.rebuild_layout/2` (line ~77) and `RunManifest.reconstruct/1` (line ~81) — layout comes from the stored `run.layout` field, features from `Store.Query.run/1`; the `:layout` test seam and `Reconcile.status/3` stay unchanged in `lib/speckit_orchestrator/recovery/rebuild.ex`
- [X] T043 [US1] Cut `Recovery` off `RunManifest.rebuild_layout/2` (line ~46) and `RunManifest.reconstruct/1` (line ~50) to the stored `run.layout` + `Store.Query.run/1`; retarget the `:manifest` seam (line ~83) to `Store.Writer`; update the moduledoc's absent-manifest note (line ~29) to the store's absent/damaged distinction. `Reconcile.status/3` unchanged in `lib/speckit_orchestrator/recovery.ex`
- [X] T044 [US1] Add a store-writability preflight (FR-009) and a capacity preflight via `store_capacity/0` (FR-031b) to `run/1`, both refusing before any spend in the existing `{:error, {:preflight, problems}}` shape; open the run record via `Store.Writer.open_run/2`; drop `RunManifest.clear/0` (line ~96), the `:supersede` option, and its moduledoc (lines ~54-57) in `lib/speckit_orchestrator.ex` (depends on T018, T039)
- [X] T045 [US1] Add `resumable/1` (reads `Store.Query`, reconciles via unchanged `Recovery`, returns `gap_possible?`), cut `resume/2` and `resume_run/1` off `RunManifest.read/0`/`rebuild_layout/2`/`reconstruct/1`/`resumable?/0` (lines ~416, ~422, ~445, ~604, ~605, ~640, ~747, ~829) and `Checkpoint.read/2` (lines ~897, ~899, ~1002) to `Store.Query`, continuing the same `run_id`; make `resumable_run/0` delegate to `resumable/1`; cut `recover_record/1` to compute its proposal against the store record and write through `Store.Writer` on `:confirm`; cut the `Describe.read_pr/2` call at line ~1527 to `feature_run.pr_description` in `lib/speckit_orchestrator.ex` (depends on T038, T041, T042, T043, T044)
- [X] T046 [US1] Cut `resolve/1` to record the escalation resolution via `Store.Writer.resolve_escalation/2` when freeing an escalated feature (FR-026) in `lib/speckit_orchestrator.ex`
- [X] T047 [US1] Cut `LiveConfig.apply/1` to record a settings amendment via `Store.Writer.record_settings_amendment/3` — changed keys only (old → new), with the current phase-attempt boundary as `effective_after` — so the record explains why later work behaved differently from earlier work (FR-027, second clause) in `lib/speckit_orchestrator/live_config.ex` (depends on T013)
- [X] T048 [US1] Emit `[:speckit, :store, :write_failed]` from `Store.Writer`'s abort path and log it in `Telemetry.attach_default_logger/0`, so the drain of T034 is observable; fix the stale moduledoc at line ~41 that attributes run-level events to `RunManifest.write/1` in `lib/speckit_orchestrator/telemetry.ex` and `lib/speckit_orchestrator/store/writer.ex` (depends on T013, T034)

### Tests for User Story 1

- [X] T049 [P] [US1] Update `test/speckit_orchestrator/feature_runner_test.exs` for store-backed phase-attempt/checkpoint/transcript/escalation/pr_description recording
- [X] T050 [P] [US1] `test/speckit_orchestrator/persistence_failure_test.exs` — halt between phases (0 mid-flight aborts), no new releases across a multi-feature `Coordinator`, `record_complete?: false` in history, resume-after-repair with `gap_possible?: true`, start refused on an unwritable store, `[:speckit, :store, :write_failed]` emitted (contracts/persistence-failure.md § Test plan, SC-013)
- [X] T051 [P] [US1] Update the five resume tests — `resume_test.exs`, `resume_run_test.exs`, `resume_crash_test.exs`, `resume_scope_test.exs`, `resume_backlog_e2e_test.exs` — for store-backed resume: completed features not re-run (FR-017), original run settings reapplied (FR-014), same `run_id` across resume (FR-020), two-repository isolation (US1 acceptance 5)
- [X] T052 [P] [US1] Update the four recovery tests — `recovery/evidence_test.exs`, `recovery/rebuild_test.exs`, `recovery_test.exs`, `recovery_quickpoll_test.exs` — plus `record_recovery_test.exs`, for store-sourced signals and the retargeted `:manifest` → `Store.Writer` seam; disagreement between store and git evidence still surfaces as a `Recovery.Report` conflict (FR-018)
- [X] T053 [P] [US1] Update `test/speckit_orchestrator/coordinator_test.exs` for the `:manifest` → `:store` seam rename, `open_run/2` supersession, and the `Store.Health.failed?/1` release check in `advance/1`
- [X] T054 [US1] `test/speckit_orchestrator/store_boundary_test.exs` — grep guard: `Feature`, `Config`, `Pipeline`, `Ledger`, `Release`, `Backlog`, `Severity`, `Remediation`, and the pure `Store.*` modules never reference `:mnesia` (Constitution Principle I, store-api.md § Boundary rules)

**Checkpoint**: User Story 1 is fully functional and independently testable — a run can be interrupted and resumed from the store alone. Every `RunManifest`/`Checkpoint`/`Transcripts`/`Describe` call site in `lib/` is now cut over, so T072's deletion is safe.

---

## Phase 4: User Story 2 - Review past runs for a repository (Priority: P2)

**Goal**: An operator retrieves a repository's full run history — every prior run,
successful or not, most recent first, undestroyed by later runs.

**Independent Test**: Complete several runs against the same repository with
different outcomes (all-done, halted, escalated, failed), then call
`run_history/1`. Verify every run appears exactly once with correct outcome,
timing, and cost, and that starting a new run does not remove or alter any
earlier one.

### Implementation for User Story 2

- [ ] T055 [US2] Implement `run_history/1` facade — options `:repo`, `:outcome`, `:feature`, `:limit`, `:before`; delegates to `Store.Query.runs/2`; unknown repository returns `{:ok, []}` in `lib/speckit_orchestrator.ex` (depends on T014)
- [ ] T056 [US2] New `RunsLive` — `/runs` history list: run id, state badge, outcome, started/duration/spend, per-feature status chips, incomplete-record marker, outcome/feature filters, capacity banner from `store_capacity/0` when refusing, empty state for a repository with no runs in `lib/speckit_orchestrator/web/live/runs_live.ex` (depends on T018, T055)
- [ ] T057 [US2] Wire `/runs` route and nav link in `lib/speckit_orchestrator/web/router.ex` and `lib/speckit_orchestrator/web/components/layouts.ex`

### Tests for User Story 2

- [ ] T058 [P] [US2] `test/speckit_orchestrator/run_history_test.exs` — most-recent-first ordering (FR-021), outcome/feature filters (FR-024), starting a new run destroys 0 prior records (SC-004), superseded run retained and distinguishable (FR-023), unknown repo → `{:ok, []}` (US2 acceptance 4). **Needs T039** — supersession is written by the Coordinator's `open_run/2`
- [ ] T059 [P] [US2] `test/speckit_orchestrator/web/runs_live_test.exs` — list renders facade data only, filters, capacity banner, empty state

**Checkpoint**: User Stories 1 and 2 both work independently.

---

## Phase 5: User Story 3 - Inspect the full record of one run (Priority: P3)

**Goal**: An operator opens one run and sees every feature's phase sequence,
escalations, remediation attempts, and transcripts from one record, without
hunting across worktree/transcript directories.

**Independent Test**: Take a run that escalated after auto-remediation exhausted
its attempts, call `run_detail/1`, and verify the phase sequence, every
remediation attempt, the escalation reason, effective settings, cost breakdown,
and each phase's transcript (via `transcript/1`) are all reachable from that one
record.

### Implementation for User Story 3

- [ ] T060 [US3] Implement `run_detail/1` facade — assembles `run`, `settings`, `amendments`, and per-feature `phase_attempts`/`escalations`/`remediation_attempts`/`checkpoint` (each attempt carries a `transcript_ref`, never the body) from `Store.Query.run/1` in `lib/speckit_orchestrator.ex` (depends on T014)
- [ ] T061 [US3] Implement `transcript/1` facade — on-demand retrieval via `Store.Query.transcript/1`, verbatim body, works after worktree removal (SC-006) in `lib/speckit_orchestrator.ex`
- [ ] T062 [US3] Implement `resolve_escalation/2` facade wrapping `Store.Writer.resolve_escalation/2` in `lib/speckit_orchestrator.ex`
- [ ] T063 [US3] New `RunDetailLive` — `/runs/:run_id`: settings + amendments with effective point, per-feature phase attempts in execution order, escalations with reason/phase/evidence, remediation attempts with limit/threshold in force, checkpoint, on-demand transcript affordance, export (`export_run/3`) and resolve-escalation actions in `lib/speckit_orchestrator/web/live/run_detail_live.ex` (depends on T019, T060, T061, T062)
- [ ] T064 [US3] Wire `/runs/:run_id` route in `lib/speckit_orchestrator/web/router.ex` (depends on T057)

### Tests for User Story 3

- [ ] T065 [P] [US3] `test/speckit_orchestrator/run_detail_test.exs` — phase sequence in execution order with outcome/model/cost/duration (US3 acceptance 1), escalation reason/phase/evidence (US3 acceptance 2), transcript retrievable after worktree removal (US3 acceptance 3), each remediation attempt individually listed with limit/threshold (US3 acceptance 4), amendments with their effective point (FR-027). **Needs T032/T033/T035/T047** to have populated the rows
- [ ] T066 [P] [US3] `test/speckit_orchestrator/web/run_detail_live_test.exs` — renders facade data only, on-demand transcript fetch, export/resolve actions

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Pruning & Lifecycle Verification (FR-031*, FR-032*)

**Purpose**: The operator's removal path — the only mechanism in the system that
deletes recorded state — plus the facade-level verification of capacity refusal and
export behaviour built in Phase 2.

- [ ] T067 Implement `prune_preview/1` and `prune/1` facades: preview reports without performing (FR-031e); `prune/1` requires `confirm: true`, executes one transaction per removed run deleting every row across all tables, never removes an in-flight or resumable run in `lib/speckit_orchestrator.ex`, plus a `prune_run/2` transaction in `lib/speckit_orchestrator/store/writer.ex` (depends on T007, T013)
- [ ] T068 Emit prune and capacity telemetry events and log them in `Telemetry.attach_default_logger/0` in `lib/speckit_orchestrator/telemetry.ex` (depends on T048, T067)
- [ ] T069 [P] `test/speckit_orchestrator/capacity_test.exs` (facade-level) — a refusal blocks `run/1`/`resume/2`/`resume_run/1` only; history/detail/transcript/export/prune remain available (FR-031c, SC-015); hitting the ceiling mid-run drains and halts, discarding nothing (FR-031d)
- [ ] T070 [P] `test/speckit_orchestrator/prune_test.exs` (facade-level) — a resumable run is never removed regardless of boundary; preview performs nothing; filling the store past headroom and not pruning leaves row counts unchanged (SC-014)
- [ ] T071 [P] `test/speckit_orchestrator/export_test.exs` (facade-level) — exactly one file; store torn down and reconstructed from the file alone with zero external references (SC-016); non-UTF-8 transcript fixture round-trips byte-identically via `"encoding": "base64"`; export mid-run and under a capacity refusal both work and change nothing

**Checkpoint**: Capacity refusal, pruning, and export all verified against the store built in Phases 2–5.

---

## Phase 7: Clean Break & Polish

**Purpose**: FR-037's clean break (delete, not deprecate), re-point the
remaining console views and their tests, and the cross-cutting verification the
constitution and quickstart.md require.

- [ ] T072 Delete `lib/speckit_orchestrator/run_manifest.ex`, `checkpoint.ex`, `transcripts.ex` and their tests `test/speckit_orchestrator/run_manifest_test.exs`, `checkpoint_test.exs`, `transcripts_test.exs` (FR-037) (depends on T032–T048 and T074–T077 having cut over every call site)
- [ ] T073 Stop writing `<worktree>/.speckit_logs/` — remove the live transcript copy from `Worktree.commit/2` (research R15, plan Complexity Tracking) in `lib/speckit_orchestrator/worktree.ex`
- [ ] T074 [P] Re-point `MissionControlLive` off `RunManifest.read/0` (line ~60) and `Checkpoint.read/1` (line ~67) to `run_detail/1` (live `Coordinator` still wins when active) in `lib/speckit_orchestrator/web/live/mission_control_live.ex`
- [ ] T075 [P] Re-point `PipelineDagLive` off `RunManifest.read/0`/`rebuild_layout/2` (lines ~176, ~187) and `Checkpoint.read/2` (line ~194) to `run_detail/1` in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`
- [ ] T076 [P] Re-point `EscalationsLive` off `RunManifest.read/0`/`rebuild_layout/2` (lines ~86, ~87) and `Checkpoint.read/2` (lines ~182, ~183) to `run_detail/1`'s `escalations` — now the authoritative record, including resolved ones (FR-026) — in `lib/speckit_orchestrator/web/live/escalations_live.ex`
- [ ] T077 [P] Re-point `TranscriptsLive` from a directory walk under `<autonomous_root>/transcripts/<segment>/…` to `run_detail/1` for the picker and `transcript/1` to render, and change the feature drawer's transcript link from `?feature=<scope>/<id>&phase=<phase>` to a run-scoped attempt reference in `lib/speckit_orchestrator/web/live/transcripts_live.ex` and `lib/speckit_orchestrator/web/components/feature_drawer.ex`
- [ ] T078 Update the five affected console tests — `web/mission_control_live_test.exs`, `web/pipeline_dag_live_test.exs`, `web/escalations_live_test.exs`, `web/reconcile_test.exs`, `web/layout_test.exs` — for facade-sourced data and the new nav entry (depends on T074–T077)
- [ ] T079 `test/speckit_orchestrator/web/store_boundary_test.exs` — grep guard: no module under `lib/speckit_orchestrator/web/` references `:mnesia`, `Store.Query`, or `Store.Writer`, and none reads a state file from disk (SC-007, FR-030c) (depends on T056, T063, T074–T077)
- [ ] T080 `test/speckit_orchestrator/clean_break_test.exs` — `RunManifest`, `Checkpoint`, `Transcripts`, `Describe.write_pr/3`, `Describe.read_pr/2` no longer exist; a run creates no file under the five paths listed in quickstart.md §10 (FR-037) (depends on T072, T073)
- [ ] T081 [P] Update `docs/runbook.md` for the `/runs`/`/runs/:run_id` operator flow, `resumable/1`/`run_history/1`/`run_detail/1`/`transcript/1`, `prune_preview/1`/`prune/1`, `export_run/3`, `store_capacity/0`'s refusal message, and the node-name failure mode (starting under a different node name is a hard failure naming both names, not a silent new store — research R2)
- [ ] T082 Run `mise exec -- mix format --check-formatted`, `mise exec -- mix compile` (warnings as errors), `mise exec -- mix test --cover` (pure core >90%), and `mise exec -- mix test --include integration`; confirm every public function on the new `Store.*` modules carries an `@spec` (Principle VI); walk quickstart.md end to end

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories and Phases 6–7
- **User Story 1 (Phase 3)**: Depends on Foundational only
- **User Story 2 (Phase 4)**: *Code* depends on Foundational only (T055–T057 need T014 and T018). Its *tests* need US1: T058 asserts supersession, which T039 writes
- **User Story 3 (Phase 5)**: *Code* depends on Foundational only (T060–T064 need T014 and T019). Its *tests* need US1: T065 asserts phase attempts, remediation attempts, and amendments, which T032/T033/T035/T047 write
- **Phase 6 (Pruning & lifecycle verification)**: Depends on Foundational; its tests are meaningful once US1 populates real runs. It is **not** a prerequisite for Phases 3–5 — the two facades those phases consume (`store_capacity/0`, `export_run/3`) are Foundational tasks T018/T019
- **Phase 7 (Clean Break & Polish)**: Depends on Phases 3–6. T072's deletion requires **both** the `lib/` cutover (T032–T048) and the console re-pointing (T074–T077) to be complete

### Within Each Phase

- Pure modules before the Mnesia boundary before Boot/Health before Writer/Query before the facades (Phase 2 sequencing above)
- Tests for a phase follow that phase's implementation tasks
- A phase's checkpoint gates moving to the next only for **sequential** delivery; with enough capacity, Phases 3–5 can proceed in parallel once Phase 2 completes, with the test-level dependencies above respected

### Parallel Opportunities

- All `[P]` tasks within Phase 1 and within Phase 2's pure-module and test groups
- Once Phase 2 completes, Phases 3, 4, and 5 can be staffed in parallel. Note the shared files: `lib/speckit_orchestrator.ex` is edited by T018/T019 (Phase 2), T044/T045/T046 (US1), T055 (US2), T060–T062 (US3), and T067 (Phase 6); `web/router.ex` by T057 and T064. Respect the task order in this document on those two files to avoid conflicting edits
- Phase 7's `[P]` re-pointing tasks (T074–T077) touch disjoint LiveView files

---

## Parallel Example: Phase 2 pure modules

```bash
Task: "Store.Ids in lib/speckit_orchestrator/store/ids.ex"
Task: "Store.Records in lib/speckit_orchestrator/store/records.ex"
Task: "Store.Schema in lib/speckit_orchestrator/store/schema.ex"
Task: "Store.Capacity in lib/speckit_orchestrator/store/capacity.ex"
Task: "Store.Prune in lib/speckit_orchestrator/store/prune.ex"
Task: "Store.Export in lib/speckit_orchestrator/store/export.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — the store engine every story reads and writes through)
3. Complete Phase 3: User Story 1 — resume works end to end
4. **STOP and VALIDATE**: run quickstart.md §2–3 and §6 (boot, resume, persistence-failure drain)

Note: the build is green throughout Phase 3 — the old modules still exist and are
deleted only at T072, after every call site and console view has been cut over.

### Incremental Delivery

1. Setup + Foundational → store boots and passes its own suite
2. + User Story 1 → resume from the store alone (MVP)
3. + User Story 2 → run history, undestroyed by new runs
4. + User Story 3 → full single-run detail, transcripts on demand
5. + Phase 6 → pruning, and capacity/export verified at the facade
6. + Phase 7 → old files deleted, console fully re-pointed, quickstart passes end to end

### Parallel Team Strategy

Once Phase 2 is done: one developer on US1's write-path cutover (the largest,
most sequential chunk — FeatureRunner/AnalyzeRunner/ChunkRunner/PhaseStep/
Coordinator/Recovery/LiveConfig), one on US2's history facade + `RunsLive`, one
on US3's detail facade + `RunDetailLive`. US2's and US3's *tests* land after US1
populates real rows. Phase 6 and Phase 7 follow once every write-path call site
and every console view is cut over.

---

## Notes

- [P] tasks touch different files with no dependency between them
- [Story] labels trace each task to spec.md's US1/US2/US3
- No gate, breaker, or pipeline decision changes anywhere in this task list —
  `Pipeline.next/3`, `Remediation.next/2`, `Release.next_wave/4`, `Reconcile.status/3`,
  and `Ledger`'s arithmetic are read from or seeded by the store, never altered by it
- Public functions on the new `Store.*` modules carry `@spec` (Principle VI); T082 gates it
- Commit after each task or logical group
- Verify tests fail before implementing where a test task precedes its
  implementation task in the same phase
