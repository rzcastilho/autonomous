# Tasks: Resume Preserves Backlog Scope

**Input**: Design documents from `/specs/016-resume-backlog-scope/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included — plan.md's Testing section requires pure-core coverage
(`Recovery.Rebuild`, the `RunManifest.write/1` guard, the `ConsoleReadModel`
fold) plus seam-level dispatch tests and one opt-in end-to-end regression
(SC-003); quickstart.md names the exact test files (S1–S7).

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P3).
Each story is independently shippable per plan.md's Sequencing note
(US1 → US2 → US3, each stands alone).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)
- Paths are repo-root relative, matching `lib/speckit_orchestrator/` /
  `test/speckit_orchestrator/` (plan.md "Project Structure")

## Path Conventions

Single Elixir project (Option 1). Source: `lib/speckit_orchestrator/`. Tests:
`test/speckit_orchestrator/`. No new top-level module namespace — this feature
adds one file to the existing `recovery/` submodule and otherwise edits files
already in the tree.

---

## Phase 1: Setup

**Purpose**: Confirm the workspace builds before any change lands.

- [X] T001 Run `mise exec -- mix deps.get && mise exec -- mix compile` from repo
      root and confirm a clean compile (warnings-as-errors) before starting —
      no new dependency is introduced (plan.md Technical Context), this only
      verifies baseline.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one piece of shared plumbing both US1 and US2 need before
either can be verified end-to-end: `run/1`'s ability to skip the unconditional
`RunManifest.clear/0` it currently performs on every call, including every
resume (research.md D3). Without this, the US2 guard (Phase 4) has nothing to
guard — a resume would always clear the record before writing, so no narrowing
write is ever observable.

**⚠️ CRITICAL**: Phase 3+ cannot be verified end-to-end until this phase is
complete (US1's and US2's *unit-level* tests can still be drafted against the
contract in parallel).

- [X] T002 Add a `:supersede` option to `SpeckitOrchestrator.run/1`
      (`lib/speckit_orchestrator.ex`), default `true`: when `true`, keep
      today's unconditional `RunManifest.clear/0` at the top of `run/1`
      (FR-013 — a fresh run still supersedes); when `false`, skip the clear
      entirely so `run/1` writes into whatever record already exists at the
      segment. Per `contracts/manifest-guard.md` "Supersede".

**Checkpoint**: `run(supersede: false)` writes without clearing first — the
guard (Phase 4) now has something to enforce, and the shared continuation path
(Phase 3) has the flag it needs to pass.

---

## Phase 3: User Story 1 - Resuming one feature continues the whole run (Priority: P1) 🎯 MVP

**Goal**: `resume/2` restores the run's full recorded feature set, reconciles
every restored feature against durable evidence (reusing feature 014's
whole-run reconciliation), seeds the Coordinator accordingly, and applies the
operator's phase/prompt/remediation override to the named feature only.
Dependents release automatically as prerequisites reach `:done`.

**Independent Test**: Start a three-feature chained backlog (`001 → 002 →
003`), force `001` to halt, resume it, and verify all three features are
present in the restored run, `001` restarts at its recorded phase, and `002`
then `003` are released and reach terminal states without further operator
action (quickstart.md S1/S2).

### Tests for User Story 1

- [X] T003 [P] [US1] `test/speckit_orchestrator/resume_scope_test.exs`:
      quickstart.md **S1** — fake `:runner`/`:manifest` seams on the
      Coordinator; a manifest recording `001 (halted) → 002 (pending) → 003
      (pending)` with a checkpoint for `001`; call `resume("001", ...)`; assert
      the Coordinator's feature set is `["001", "002", "003"]`, the seeded
      statuses match `data-model.md` Entity 2's table, exactly one dispatch on
      the first wave (`001` at its checkpointed phase), and — as the fake
      runner reports `001 :done` — `002` then `003` dispatch in turn, with the
      final report's `done` list holding all three (FR-001, FR-003, FR-004,
      FR-007).
- [X] T004 [P] [US1] `test/speckit_orchestrator/resume_scope_test.exs`:
      quickstart.md **S2** — same fixture shape but `002: :done` and `003:
      :escalated`; resume `001`; assert `002` is never dispatched and `003`
      stays `:escalated` and is never dispatched (FR-002, FR-005, FR-006).
- [X] T005 [P] [US1] `test/speckit_orchestrator/resume_test.exs`: SC-005
      no-regression — (a) a genuinely single-feature run resumes and dispatches
      identically to pre-016 `resume/2`; (b) a missing/corrupt manifest falls
      back to today's single-feature path unchanged (FR-009). Diff against the
      pre-existing assertions in this file rather than duplicating them.
- [X] T006 [P] [US1] `test/speckit_orchestrator/resume_test.exs`: FR-010a — a
      live unfinished Coordinator causes `resume/2` to return
      `{:error, {:active_run, pid}}` and start no work; `force: true`
      proceeds anyway, matching `resume_run/1`'s existing `guard_active_run/1`
      contract.
- [X] T007 [US1] `test/speckit_orchestrator/resume_run_test.exs`: regression —
      `resume_run/1`'s own dispatch, statuses, and report are unaffected by the
      shared continuation path introduced in T009 (same inputs, same outputs
      as before this feature).

### Implementation for User Story 1

- [X] T008 [US1] In `lib/speckit_orchestrator.ex`, extract the restored-run
      assembly both `resume/2` and `resume_run/1` need into one private
      helper (e.g. `restore_run_scope/2`, per data-model.md Entity 2):
      given a read manifest `record` and opts, return
      `{features, statuses, resume_phases, layout, run_context}` via
      `Recovery.reconcile_run/2` + `RunManifest.reconstruct/1` +
      `RunContext.merge/2` + `Ledger.restore/2` — this is `resume_run/1`'s
      existing steps 1–4 (lines ~442-460), lifted out so `resume/2` can call
      the identical path (research.md D1).
- [X] T009 [US1] In `lib/speckit_orchestrator.ex`, implement the target merge
      (data-model.md Entity 2/3, contracts/resume-scope.md steps 8–9): given
      the restored `{features, statuses, resume_phases}` from T008 and the
      target feature/start_phase/prompt/remediation opts, (a) append the
      target feature when the restored set omits it (FR-008), (b) force the
      target's seed status to `:pending`, (c) delete the target's id from
      `resume_phases` so the operator's resolved start phase (from today's
      `resolve_start_phase/2`) governs instead of the reconciled one
      (research.md D2).
- [X] T010 [US1] In `lib/speckit_orchestrator.ex`, implement the per-feature
      runner split (contracts/resume-scope.md "Dispatch matrix"): a `:runner`
      (or `:executor`, per `pr_workflow?`) that dispatches the target feature
      through today's `resume_runner/7`/`resume_executor/7` unchanged (G5 —
      byte-identical target dispatch), and every other feature through
      `resume_run/1`'s existing `dispatch_resume/6` (checkpoint-driven for a
      mid-run feature, `Worktree.create` fresh for a never-started one).
- [X] T011 [US1] Rewrite `SpeckitOrchestrator.resume/2` in
      `lib/speckit_orchestrator.ex` to the order in
      `contracts/resume-scope.md` "Order of operations": live-run guard
      (T013) → layout → checkpoint read → identity → start phase → model
      validation → run context → **scope restore via T008** (or the
      no-manifest fallback, unchanged) → **target merge via T009** → `run(
      supersede: false, features: …, statuses: …, runner: T010's split, …)`.
      Preserve every existing behaviour the contract lists as unchanged
      (identity recovery, `:from` precedence, remediation, `:from_task_phase`,
      `reset_implement_sessions: true` for the target only).
- [X] T012 [US1] Update `SpeckitOrchestrator.resume_run/1` in
      `lib/speckit_orchestrator.ex` to call `run(supersede: false, …)` (it
      already restores the full set — no behavioural change, just routes
      through the new option added in T002) and to use T008's extracted
      helper internally so both callers share one implementation
      (research.md D1).
- [X] T013 [US1] Add the live-run guard + `:force` option to `resume/2`:
      reuse the existing `guard_active_run/1` (already implemented for
      `resume_run/1`) as the first step, before any manifest/checkpoint read
      (FR-010a).
- [X] T014 [US1] Update `lib/speckit_orchestrator/web/live/escalations_live.ex`
      copy (FR-021) to state that resuming continues the whole run, not only
      the selected feature, and add a `format_resume_error/1` clause (or
      extend the existing one) rendering `{:active_run, pid}` with a hint that
      a run is already live for this repository.
- [X] T015 [US1] Verify (and adjust the template only if needed)
      `lib/speckit_orchestrator/web/live/mission_control_live.ex` renders
      every feature in `Coordinator.status/0`'s `per_feature` map after a
      resume, including ones still `:pending` on prerequisites (FR-022) — the
      Coordinator's state already carries the full restored set post-T011, so
      this is a verification pass over the existing render, not new state.

**Checkpoint**: User Story 1 is independently functional — `mise exec -- mix
test test/speckit_orchestrator/resume_scope_test.exs` passes, and the exact
reported `quickpoll` defect no longer reproduces at the seam level (SC-001,
SC-002).

---

## Phase 4: User Story 2 - A run's recorded scope can never be silently narrowed (Priority: P2)

**Goal**: `RunManifest.write/1` refuses any write that would drop a
currently-recorded feature id — by identity, not count — leaving the existing
record intact and announcing the refusal as a telemetry event the default
logger and console feed both fold.

**Independent Test**: Attempt to record a run state that drops or swaps a
currently-recorded feature; verify the write is refused, the existing record
is untouched, and the refusal is surfaced (quickstart.md S3/S4).

### Tests for User Story 2

- [X] T016 [P] [US2] `test/speckit_orchestrator/run_manifest_test.exs`:
      quickstart.md **S3** decision table against a temp `autonomous_root` —
      `[001,002,003] → [001]` refused (file still names three);
      `[001,002,003] → [001,002,004]` refused (identity swap, not a count
      change — FR-011, SC-004); `[001,002,003] → [001,002,003,004]` allowed
      (growth is not narrowing); `clear/0` then `[001]` allowed (a fresh run
      supersedes, FR-013); a same-ids progress-only write (new statuses) is
      allowed (FR-014 unaffected). Every case returns `:ok` regardless of
      outcome.
- [X] T017 [P] [US2] `test/speckit_orchestrator/run_manifest_test.exs`:
      refusal telemetry — via `:telemetry_test.attach_event_handlers/2`,
      assert `[:speckit, :run, :scope_narrowing_refused]` fires with
      `measurements.dropped_count == 2` and `metadata.dropped == ["002",
      "003"]` (sorted) on the shrinking-write case; assert it does **not**
      fire on any allowed write.
- [X] T018 [P] [US2] `test/speckit_orchestrator/telemetry_test.exs`: extend the
      `attach_default_logger` coverage (same `capture_log` pattern as the
      existing phase/chunk assertions) with
      `:telemetry.execute([:speckit, :run, :scope_narrowing_refused], %{dropped_count: 2}, %{segment: "seg", recorded: ["001","002","003"], attempted: ["001"], dropped: ["002","003"]})`
      and assert the log line names the dropped ids.
- [X] T019 [P] [US2] `test/speckit_orchestrator/console_read_model_test.exs`:
      fold the refusal event and assert one `:warn` feed entry with
      `feature_id: nil` naming the dropped ids is pushed, and `model.features`
      is unchanged (FR-012).
- [X] T020 [US2] `test/speckit_orchestrator/web/mission_control_live_test.exs`:
      extend using the existing `Phoenix.PubSub.broadcast(SpeckitOrchestrator.PubSub, ConsoleProjection.topic(), …)`
      pattern already in this file — broadcast the refusal's feed entry and
      assert the activity feed renders it, with no feature row affected.

### Implementation for User Story 2

- [X] T021 [US2] Add `[:speckit, :run, :scope_narrowing_refused]` to
      `lib/speckit_orchestrator/telemetry.ex`'s `@events` list per
      `contracts/manifest-guard.md` — no other change to `Telemetry` needed
      for the event to reach `ConsoleProjection` (it attaches to
      `Telemetry.events/0` wholesale).
- [X] T022 [US2] Implement the guard in `RunManifest.write/1`
      (`lib/speckit_orchestrator/run_manifest.ex`) per
      `contracts/manifest-guard.md` "Decision table": before
      `File.mkdir_p!`/`File.write!`, read the record currently at the resolved
      `manifest_path(segment)`; if it parses and
      `MapSet.difference(recorded_ids, proposed_ids)` is non-empty, skip the
      file write, `:telemetry.execute/3` the refusal event (Entity 4 shape:
      `dropped_count`, `segment`, `recorded`, `attempted`, `dropped`, all
      sorted), and return `:ok`; otherwise write as today. Keep inside the
      existing `rescue _ -> :ok` so a guard-read failure degrades to
      "write proceeds," never a raise.
- [X] T023 [US2] Add a `Telemetry.handle_event/4` clause in
      `lib/speckit_orchestrator/telemetry.ex` for
      `[:speckit, :run, :scope_narrowing_refused]`:
      `Logger.warning("run scope narrowing refused: dropped=#{inspect dropped} recorded=#{inspect recorded} segment=#{segment}")`.
- [X] T024 [US2] Add an `apply_event/4` clause in
      `lib/speckit_orchestrator/console_read_model.ex` for the refusal event:
      push `entry(nil, nil, :warn, "scope narrowing refused — would drop
      #{Enum.join(dropped, ", ")}")` via the existing `push_feed/2`; do not
      touch `model.features`.
- [X] T025 [US2] Add a `broadcast_diff/4` clause in
      `lib/speckit_orchestrator/console_projection.ex` for
      `[:speckit, :run, :scope_narrowing_refused]`: broadcast
      `{:console, :feed, latest}` only (no `:feature_updated` — this is
      run-level, per `contracts/manifest-guard.md` "Consumers").
- [X] T026 [US2] Confirm (adjust if needed) that `run/1`'s `:supersede` option
      (T002) is the only thing standing between a fresh run and the guard:
      `run(supersede: true)` (the default) still clears first and therefore
      never trips the guard; `resume/2`/`resume_run/1` (now passing
      `supersede: false`, from T011/T012) write into the guarded chain.

**Checkpoint**: User Stories 1 AND 2 both pass independently — a resume can no
longer narrow the record, and the class of defect (not just the one call site)
is closed.

---

## Phase 5: User Story 3 - Recovering a run record that already lost its scope (Priority: P3)

**Goal**: An operator can rebuild a damaged run record from the backlog on
disk plus surviving per-feature evidence, preview it with zero durable effect,
and confirm it explicitly — without rebuilding any feature that already
completed.

**Independent Test**: A run record narrowed to one feature whose backlog on
disk holds three; run recovery; verify it reports the record it would write —
all three, with states consistent with the evidence for each — and leaves the
existing record unchanged until confirmed (quickstart.md S5).

### Tests for User Story 3

- [X] T027 [P] [US3] `test/speckit_orchestrator/recovery/rebuild_test.exs`:
      union rule — backlog `[001,002,003]`, record `[001]`; assert the
      proposal's `features` lists all three in backlog order; per-feature
      status mapping table from `contracts/record-recovery.md` (both-present
      clean reconcile, both-present conflict → `:blocked` +
      `:unreconcilable`, record-only → `:absent_from_backlog`, backlog-only →
      `:absent_from_record`); a restored feature naming a prereq outside the
      union → `:prereq_missing` discrepancy and `propose/3` returns
      `{:error, {:inconsistent, _}}`.
- [X] T028 [P] [US3] `test/speckit_orchestrator/record_recovery_test.exs`:
      quickstart.md S5.1 — the `../quickpoll`-shaped fixture from
      `contracts/record-recovery.md` "Worked example" (record `001: done`
      only, backlog `001 → 002 → 003`, evidence corroborating `001`); call
      `SpeckitOrchestrator.recover_record/1` with no `:confirm`; assert the
      returned proposal matches the worked example table and the manifest
      file on disk is **byte-identical** before and after the call (FR-019a).
- [X] T029 [P] [US3] `test/speckit_orchestrator/record_recovery_test.exs`:
      quickstart.md S5.2 — `recover_record(confirm: true)` on the same
      fixture; assert `{:ok, :written, proposal}`, the manifest now names all
      three features with the proposal's statuses, and a subsequent
      `resume_run/1` (fake runner) dispatches `002` and `003` but never
      re-dispatches `001` (SC-006).
- [X] T030 [P] [US3] `test/speckit_orchestrator/record_recovery_test.exs`:
      quickstart.md S5.3 — an unloadable backlog (dangling prereq or missing
      directory) yields `{:error, {:backlog, reason}}` with no write.
- [X] T031 [P] [US3] `test/speckit_orchestrator/record_recovery_test.exs`:
      quickstart.md S5.4 — a proposal containing a `:prereq_missing`
      discrepancy yields `{:error, {:inconsistent, discrepancies}}` with no
      write (FR-020).
- [X] T032 [US3] `test/speckit_orchestrator/recovery_test.exs`: the
      `plan_run/2`/`reconcile_run/2` split — `plan_run/2` returns the same
      `{:ok, %{statuses, resume_phases, report}}` shape as before but performs
      **no** `RunManifest.write/1` call (assert via a fake `:manifest` seam
      recording call count 0); `reconcile_run/2` still performs exactly one
      write, matching its pre-016 behaviour (regression for
      `resume_run/1`/`resumable_run/0`, which keep calling `reconcile_run/2`).

### Implementation for User Story 3

- [X] T033 [US3] Split `Recovery.reconcile_run/2`
      (`lib/speckit_orchestrator/recovery.ex`) into `Recovery.plan_run/2` (all
      of today's collect-and-reconcile logic, **no** `rewrite_manifest/5`
      call) and `reconcile_run/2` (`plan_run/2` then the existing
      `rewrite_manifest/5`) per research.md D4. Existing callers
      (`resume_run/1`, `resumable_run/0`, and T011/T012's new call sites) keep
      calling `reconcile_run/2` unchanged.
- [X] T034 [US3] Implement `SpeckitOrchestrator.Recovery.Rebuild.propose/3` in
      `lib/speckit_orchestrator/recovery/rebuild.ex` per
      `contracts/record-recovery.md`: union the record's features with
      `backlog` (backlog order first, then record-only features appended),
      reuse `Recovery.Evidence.collect/3` + `Recovery.Reconcile.status/3` for
      each unioned feature's status (no new decision table), build the
      `discrepancies` list (data-model.md Entity 6), and refuse
      (`{:error, {:inconsistent, _}}`) when any `:prereq_missing` discrepancy
      exists.
- [X] T035 [US3] Extend `SpeckitOrchestrator.Recovery.Report`
      (`lib/speckit_orchestrator/recovery/report.ex`) or its `format/1` to
      render discrepancy rows (`:absent_from_backlog` /
      `:absent_from_record` / `:unreconcilable` as a `Note` suffix) matching
      `contracts/record-recovery.md` "Worked example" output.
- [X] T036 [US3] Implement `SpeckitOrchestrator.recover_record/1` in
      `lib/speckit_orchestrator.ex` per `contracts/record-recovery.md`: read
      the manifest (`{:error, :no_manifest | :corrupt_manifest}` propagate
      unchanged), load the backlog via `Backlog.load!/1` over the rebuilt
      layout's `breakdown_root` (or `:backlog_root` opt), catching
      `MissingPrereqError`/`CycleError` into `{:error, {:backlog, reason}}`
      rather than letting them raise into the caller; call
      `Recovery.Rebuild.propose/3`; return `{:ok, proposal}` by default, or on
      `confirm: true` additionally call `RunManifest.write/1` with the
      proposal's features/statuses and return
      `{:ok, :written, proposal}`.

**Checkpoint**: All user stories are independently functional — the full spec
(US1–US3) is complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: The whole-run regression proving the originally observed defect
is fixed end-to-end, operator-surface coverage spanning all three stories, and
the final quality gate.

- [X] T037 [P] `test/speckit_orchestrator/resume_backlog_e2e_test.exs`,
      `@tag :integration`: quickstart.md **S6** — a temp git target repo
      seeded with a three-feature chained backlog, driven by FakeSDK (same
      tmp-dir + `async: false` conventions as
      `recovery_quickpoll_test.exs`); `001` diverts at a gate, the operator
      resumes it once, and the run reaches `001 :done → 002 :done → 003
      :done` with a final report counting three (SC-003). This is the exact
      `../quickpoll` failure from the spec's "Context" section, reproduced
      and proven fixed.
- [X] T038 [P] `test/speckit_orchestrator/web/escalations_live_test.exs`:
      quickstart.md **S7** — the resume panel's copy states that resuming
      continues the whole run (FR-021); a resume attempted while another run
      is live renders the `{:active_run, pid}` refusal instead of starting
      work (FR-010a, T014).
- [X] T039 [P] `test/speckit_orchestrator/web/mission_control_live_test.exs`:
      quickstart.md **S7** — after a resume, every feature in the restored
      run is listed, including ones still waiting on prerequisites (FR-022,
      T015).
- [X] T040 Run `mise exec -- mix format --check-formatted` and fix any
      violations introduced by this feature's files.
- [X] T041 Run `mise exec -- mix compile --warnings-as-errors` and confirm a
      clean build.
- [X] T042 Run `mise exec -- mix test --cover` and confirm the pure-core
      pieces this feature adds/touches — `Recovery.Rebuild`, the
      `RunManifest.write/1` guard branch, and the `ConsoleReadModel` fold —
      hold >90% coverage per the constitution's Quality & Test Discipline; add
      any missing branch tests the report surfaces.
- [X] T043 Run `mise exec -- mix test` (full suite) and confirm green,
      including that `resume_test.exs`, `resume_run_test.exs`,
      `resume_crash_test.exs`, `recovery_test.exs`, `recovery_quickpoll_test.exs`,
      `coordinator_test.exs`, and `facade_e2e_test.exs` are all unaffected by
      the shared-path refactor (T008–T012) beyond what T003–T007/T032
      intentionally changed.
- [X] T044 Execute `quickstart.md`'s full validation block end-to-end (S1–S7
      plus the format/compile/test/cover gate) as the final
      spec-to-implementation confirmation.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS end-to-end verification
  of Phases 3–4 (the `:supersede` flag is what makes the US2 guard observable
  on a resume path at all) — but unit-level tests in both phases can be
  drafted against their contracts before T002 lands.
- **User Story 1 (Phase 3)**: Depends on Phase 2. Delivers the MVP fix
  (SC-001/002/003) and stands up the shared continuation path
  (`restore_run_scope/2`) that Phase 4/5 build alongside, not on top of.
- **User Story 2 (Phase 4)**: Depends on Phase 2 for `:supersede` to exist;
  otherwise independent of Phase 3 — the guard lives entirely in
  `RunManifest.write/1` and its own tests call `write/1`/`clear/0` directly,
  not through `resume/2`. Can be implemented in parallel with Phase 3 by a
  second contributor; T026 is the only task that reads Phase 3's outcome
  (confirming `resume/2`/`resume_run/1` pass `supersede: false`).
- **User Story 3 (Phase 5)**: Depends on `Recovery.reconcile_run/2` existing
  (it does, pre-016) and on T033's split landing before T034
  (`Rebuild.propose/3` reuses `Evidence`/`Reconcile` directly, not
  `plan_run/2`, but T033 documents the seam T036 calls into.). Otherwise
  independent of Phases 3–4.
- **Polish (Phase 6)**: Depends on Phases 3–5 all being complete — T037
  exercises US1+US2 together (a resume that must not narrow the record while
  releasing dependents); T038/T039 exercise US1's operator-surface tasks.

### Within Each User Story

- Tests (T003–T007, T016–T020, T027–T032) are written first and expected to
  fail until their corresponding implementation task lands.
- Within US1: shared-path extraction (T008) → target merge (T009) → runner
  split (T010) → `resume/2` rewrite (T011) → `resume_run/1` wiring (T012) →
  guard (T013) → web copy (T014–T015).
- Within US2: event registration (T021) → guard (T022) → logger (T023) →
  console fold (T024) → projection broadcast (T025) → supersede confirmation
  (T026).
- Within US3: `plan_run/2` split (T033) → `Rebuild.propose/3` (T034) → report
  rendering (T035) → facade verb (T036).
- Story complete before moving to the next priority.

### Parallel Opportunities

- T003–T007 (US1 tests) are independently draftable against
  `contracts/resume-scope.md`, but T003/T004 share
  `resume_scope_test.exs` — land sequentially or merge carefully.
- T016–T020 (US2 tests) touch four different files and are true `[P]`.
- T027–T031 (US3 tests): T027 is a separate file (`rebuild_test.exs`); T028–T031
  share `record_recovery_test.exs` — draft in parallel, merge sequentially.
- Phase 4 (US2) can proceed in parallel with Phase 3 (US1) once Phase 2 lands,
  per a second contributor, since the guard has no dependency on the resume
  rewrite.
- T037/T038/T039 (Polish) touch three different files — true `[P]`.

---

## Parallel Example: Phase 4 (User Story 2)

```bash
# All four independent test files, once T002 (Foundational) lands:
Task: "Guard decision table in test/speckit_orchestrator/run_manifest_test.exs"
Task: "Refusal telemetry assertion in test/speckit_orchestrator/run_manifest_test.exs"
Task: "Default-logger clause in test/speckit_orchestrator/telemetry_test.exs"
Task: "Console fold in test/speckit_orchestrator/console_read_model_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (`:supersede` option — small, unblocks
   everything downstream).
3. Complete Phase 3: User Story 1 — this alone fixes the reported defect at
   the seam level (SC-001, SC-002, SC-003 partially — full SC-003 needs the
   Phase 6 e2e regression, but the mechanism is proven by T003/T004).
4. **STOP and VALIDATE**: `mise exec -- mix test
   test/speckit_orchestrator/resume_scope_test.exs` green.

### Incremental Delivery

1. Setup + Foundational → `:supersede` ready.
2. US1 → the exact reported defect fixed at the seam level → validate → MVP.
3. US2 → the class of defect closed (any future writer is guarded) → validate.
4. US3 → damaged records repairable → validate.
5. Polish → SC-003 end-to-end regression, operator-surface coverage, coverage
   gate, full suite.

### Parallel Team Strategy

With two contributors, after Phase 2:

- Contributor A: Phase 3 (US1) — the resume rewrite.
- Contributor B: Phase 4 (US2) — the manifest guard, independent of A's work
  except for reading A's `supersede: false` call sites at T026.
- Phase 5 (US3) starts once either A or B is free — it depends only on
  existing `Recovery` internals plus the (small) T033 split.

---

## Notes

- `[P]` tasks target different files, or are independently draftable against a
  contract even when a later merge into a shared file is sequential.
- Verify each story's tests fail before implementing.
- Commit after each task or logical group.
- Stop at any checkpoint to validate a story independently.
- No new dependency, no datastore, no new process — every task edits or adds
  files inside `lib/speckit_orchestrator/` and `test/speckit_orchestrator/`
  only (plan.md Constitution Check, Technology Stack).
