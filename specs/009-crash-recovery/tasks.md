---

description: "Task list for Crash Recovery (per-phase checkpoint/commit + run manifest + resume_run)"
---

# Tasks: Crash Recovery

**Input**: Design documents from `/specs/009-crash-recovery/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/run_manifest.md, contracts/checkpoint-progress.md,
contracts/worktree-squash-restore.md, contracts/ledger-restore.md,
contracts/resume_run.md, quickstart.md

**Tests**: Included — quickstart.md's eight scenarios (A–H) are the primary
validation path (Constitution: pure/seam tests, >90% coverage on core); the five
contracts define the exact shapes `checkpoint_test.exs`, `worktree_test.exs`,
`ledger_test.exs`, `run_manifest_test.exs`, `coordinator_test.exs`,
`feature_runner_test.exs`, and `resume_run_test.exs` must cover. Real-git and
full-run scenarios are tagged `@tag :integration` so the default suite stays
hermetic.

**Organization**: Three user stories in spec priority order. US1 (P1, per-feature
resume — MVP) is self-contained: it only touches `Checkpoint`, `Worktree`, and
`FeatureRunner`, with no dependency on the run manifest. US2 (P2, whole-run
resume) introduces `RunManifest` and the facade's `resume_run/1` — its resume-aware
runner (T034) reuses US1's `Worktree.restore/1` (T013) at the per-feature level.
US2's `resume_run/1` contract (step 4) calls `Ledger.restore/2` unconditionally, so
that function is implemented in Phase 2 (tagged `[US2]` for the call-site need) with
its full breaker-interaction test coverage completing in Phase 3 under `[US3]` —
the spec's own US3 "Independent Test" exercises `resume_run/1` directly, so US3 is
a verification/completeness pass over US2's already-built plumbing rather than new
control-plane code.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

## Path Conventions

Single Elixir project (existing). All paths are repo-root-relative. Run everything
through `mise exec --` (see CLAUDE.md — `warnings_as_errors` is ON).

---

## Phase 1: User Story 1 - Resume a crashed feature from its last completed phase (Priority: P1) 🎯 MVP

**Goal**: `FeatureRunner.loop/7` writes a `Checkpoint` (`status: :in_progress`,
`last_phase:` the phase that just completed) and commits the worktree after
**every** successful phase, not only on a gate divert. `Worktree.squash/3`
collapses the per-phase commits into one clean commit at `:done`;
`Worktree.restore/1` discards any uncommitted partial output before a resumed
phase re-runs. `SpeckitOrchestrator.resume/2` (feature 007, unchanged signature)
now restores the worktree before re-running the interrupted phase.

**Independent Test**: Run a feature through `plan`, kill the process mid-`tasks`
(leaving an uncommitted partial file in the worktree), call
`SpeckitOrchestrator.resume(feature_id)`, and confirm it restarts at `tasks`, the
`specify…plan` artifacts are byte-unchanged, the partial file is gone, and the
feature reaches a terminal state.

### Tests for User Story 1

- [X] T001 [P] [US1] Extend `test/speckit_orchestrator/checkpoint_test.exs`:
      `write/1` given `status: :in_progress` round-trips it through `read/1`
      unchanged (no schema change — the existing string-keyed record already
      accepts any status value) (contracts/checkpoint-progress.md — no signature
      change)
- [X] T002 [P] [US1] Add test to `test/speckit_orchestrator/feature_runner_test.exs`:
      after each successful phase in `loop/7` (the `{:cont, next}` branch), a
      checkpoint exists with `last_phase ==` the just-completed phase,
      `status == "in_progress"`, and a `context` object; reading again after the
      next phase shows the checkpoint **overwritten** (not appended) with the new
      `last_phase` (contracts/checkpoint-progress.md write timing + test contract;
      quickstart Scenario A steps 1–2)
- [X] T003 [P] [US1] Add test to `feature_runner_test.exs` (`@tag :integration`,
      real worktree fixture): `Worktree.commit/2` is called once per phase (not
      only at the terminal) — after phase N a phase-boundary commit exists on the
      feature branch with message `"speckit: <id> checkpoint after <phase>"`
      (data-model.md Entity 2; quickstart Scenario A step 3)
- [X] T004 [P] [US1] Add test to `test/speckit_orchestrator/worktree_test.exs`
      (`@tag :integration`): `squash/3` — create a branch, make N per-phase
      commits, `squash/3` to the fork point →
      `git rev-list --count <base>..HEAD == 1`; `git diff <pre-squash-HEAD> HEAD`
      is empty; a feature with nothing staged returns `:noop`
      (contracts/worktree-squash-restore.md squash test contract)
- [X] T005 [P] [US1] Add test to `worktree_test.exs` (`@tag :integration`):
      `restore/1` — commit a clean tree, write an uncommitted partial file,
      `restore/1` removes it, tracked files match the last commit, and a
      `.speckit_logs/`-style gitignored file survives (contracts/
      worktree-squash-restore.md restore test contract)
- [X] T006 [US1] Add test to `feature_runner_test.exs` (`@tag :integration`): on
      `:done`, `handle_worktree/3` produces exactly one commit since the fork
      point (via the new `squash/3` call) — no `"checkpoint after <phase>"`
      commits remain in the branch history (quickstart Scenario C steps 1–2;
      FR-004) — depends on T004
- [X] T007 [US1] Add test to `feature_runner_test.exs` (`@tag :integration`): on a
      kept terminal (force `:escalated`), the per-phase checkpoint commits remain
      in place as the post-mortem trail — `squash/3` is **not** called (quickstart
      Scenario C step 3; data-model.md Entity 2 lifecycle) — depends on T004
- [X] T008 [US1] Add test (`@tag :integration`) to
      `test/speckit_orchestrator_test.exs` or a new `resume_crash_test.exs`: a
      feature that completed `specify…plan` and then crashed mid-`tasks` (an
      `in_progress` checkpoint at `last_phase: "plan"`, plus an uncommitted
      partial file in the worktree) — `resume(feature_id)` restores the worktree
      via `Worktree.restore/1` before re-running, the `specify…plan` artifacts are
      byte-unchanged, the partial file is gone, and the feature reaches a terminal
      state (quickstart Scenario B; US1 AS1–AS2; SC-002) — depends on T005

### Implementation for User Story 1

- [X] T009 [US1] Thread a `run_context` parameter through
      `FeatureRunner.loop/7` and its recursive calls
      (`lib/speckit_orchestrator/feature_runner.ex` ~lines 92, 128, 148) — today
      `run_context` (already a local in `run/2`, line 74) is only passed to the
      terminal `checkpoint/5` call site; the per-phase write below needs it too —
      depends on T002
- [X] T010 [US1] In `loop/7`'s `{:cont, next}` branch
      (`lib/speckit_orchestrator/feature_runner.ex` ~lines 143–148), before
      recursing, call `Checkpoint.write/1` with `feature_id: feature.id,
      last_phase: phase, status: :in_progress, reason: nil, session_id:
      agent.state.session_id, slug: feature.slug, path: feature.path,
      run_context: run_context` (contracts/checkpoint-progress.md new write
      timing) — depends on T009, T002
- [X] T011 [US1] In the same `{:cont, next}` branch, after the T010 write, call
      `Worktree.commit/2` with message `"speckit: #{feature.id} checkpoint after
      #{phase}"`, guarded by `worktree != nil` (mirrors the existing
      `handle_worktree/3` nil-guard pattern at line 236) (FR-003) — depends on
      T010, T003
- [X] T012 [US1] Add `squash/3` to `lib/speckit_orchestrator/worktree.ex`:
      `git -C <path> reset --soft <base_ref>` (keeps working tree + index) then
      one commit with `message` using the existing orchestrator author (mirrors
      `commit/2`'s author flags); `:noop` when nothing is staged after the reset,
      `{:error, term}` on a git failure (contracts/worktree-squash-restore.md
      squash/3) — depends on T004
- [X] T013 [US1] Add `restore/1` to `lib/speckit_orchestrator/worktree.ex`:
      `git -C <path> reset --hard HEAD` then `git -C <path> clean -fd`
      (contracts/worktree-squash-restore.md restore/1) — depends on T005
- [X] T014 [US1] In `FeatureRunner.handle_worktree/3`'s `:done` clause
      (`lib/speckit_orchestrator/feature_runner.ex` ~lines 244–249), replace the
      terminal `Worktree.commit/2` call with `Worktree.squash/3`, computing
      `base_ref` via `git merge-base HEAD <ref>` against the branch's fork point
      (the ref the worktree was created from — `"HEAD"` default or the stacked
      workflow's `base`), reusing the existing `authored_or_template/2` message —
      depends on T012, T006
- [X] T015 [US1] In `SpeckitOrchestrator`'s `resume_runner/3` and
      `resume_executor/3` (`lib/speckit_orchestrator.ex` ~lines 324–374), call
      `Worktree.restore/1` on the located/recreated worktree **before** invoking
      `FeatureRunner.run/2`, discarding any uncommitted partial output the crash
      left behind (FR-003; quickstart Scenario B step 3) — depends on T013, T008

**Checkpoint**: User Story 1 is independently functional — a cleanly-running
feature leaves a resume pointer after every phase, `resume(id)` restores the
worktree and re-runs only the interrupted phase, and a completed feature's branch
shows one clean squashed commit. `mise exec -- mix test` and
`mise exec -- mix test --include integration` pass.

---

## Phase 2: User Story 2 - Resume an entire crashed run (Priority: P2)

**Goal**: A new pure `RunManifest` module persists a single-slot run record
(`features`, `statuses`, `context`, `spend`, `updated_at`) that the `Coordinator`
writes on `init`, each `spawn_feature`, and `{:finished}`. The facade gains
`resume_run/1` (reconstruct + continue a crashed run) and `resumable_run/0`
(detect/report only). `resume_run/1`'s contract also restores the `Ledger`'s
committed spend (step 4) — `Ledger.restore/2` is implemented here so
`resume_run/1` compiles and runs; its full breaker-interaction test suite lands
in Phase 3 (US3).

**Independent Test**: Start a multi-feature run with a fake runner/manifest,
drive features to mixed states (some `:done`, one `:running`, some `:pending`),
capture the manifest, stop the `Coordinator` (simulated crash), then
`resume_run/1` against that manifest. Confirm `:done` features are not re-run,
the `:running` feature resumes at its checkpointed phase, and `:pending` features
release in dependency order under the recorded cap.

### Tests for User Story 2

- [X] T016 [P] [US2] Create `test/speckit_orchestrator/run_manifest_test.exs`:
      `write/1` persists `features`/`statuses`/`context`/`spend`/`updated_at`
      (string-keyed, atoms serialized via `Atom.to_string/1`); `read/0` is
      three-way — `{:ok, map}` / `{:error, :no_manifest}` (absent file) /
      `{:error, :corrupt}` (undecodable JSON); `clear/0` deletes the slot and is a
      no-op on a missing file (contracts/run_manifest.md write/1, read/0, clear/0)
- [X] T017 [P] [US2] Add to `run_manifest_test.exs`: `resumable?/0` is `true` when
      the manifest holds at least one `:running` (interrupted) or `:pending`
      (never released) feature status; `false` when every feature is `:done` or a
      gate divert (`:escalated`/`:halted`/`:failed`) (contracts/run_manifest.md
      resumable?/0)
- [X] T018 [P] [US2] Add to `run_manifest_test.exs`: `reconstruct/1` maps a read
      record to `{features, statuses}` applying the crash→resume mapping —
      `:done`/`:escalated`/`:halted`/`:failed` kept as-is; `:running`/`:pending` →
      `:pending` (contracts/run_manifest.md reconstruct/1; data-model.md State
      transitions table)
- [X] T019 [P] [US2] Extend `test/speckit_orchestrator/ledger_test.exs`:
      `restore/2` sets `committed = max(committed, recorded)`; calling it twice
      (once with a lower value) never lowers committed (idempotent/monotonic);
      `restore(L, budget)` trips `breaker_tripped?/1` and a subsequent
      `reserve/2` returns `{:error, :budget_exceeded}` (contracts/ledger-restore.md
      test contract) — needed because `resume_run/1` (T033) calls
      `Ledger.restore/2` unconditionally
- [X] T020 [P] [US2] Extend `test/speckit_orchestrator/coordinator_test.exs`: a
      supplied `:statuses` init option seeds `state.statuses` instead of the
      all-`:pending` default — a feature seeded `:done` is never released even
      when its prereqs are also `:done`; a feature seeded `:pending` releases
      normally through `Release.next_wave/4` (contracts/resume_run.md Coordinator
      `:statuses` init option)
- [X] T021 [P] [US2] Extend `coordinator_test.exs`: a fake injected via a new
      `:manifest` opt receives `write/1` calls on `init`, on each
      `spawn_feature`, and on `{:finished}`, each carrying the current
      `features`/`statuses`/`context`/`Ledger.spent/1`; the default seam (when
      `:manifest` is omitted) is `RunManifest` (contracts/resume_run.md
      Coordinator manifest seam)
- [X] T022 [US2] Create `test/speckit_orchestrator/resume_run_test.exs`: a
      mixed-state manifest (done/running/pending, fakes for runner/manifest/
      ledger) — `resume_run/1` does not re-run the `:done` feature, resumes the
      `:running` feature at its checkpointed next phase, and releases `:pending`
      features in prereq order under the recorded cap (quickstart Scenario D;
      US2 AS1) — depends on T016–T018, T020–T021
- [X] T023 [US2] Add to `resume_run_test.exs`: no manifest on disk →
      `{:error, :no_manifest}`, no `Coordinator` process started; a corrupted
      manifest file → `{:error, :corrupt_manifest}` (quickstart Scenario H1;
      FR-016)
- [X] T024 [US2] Add to `resume_run_test.exs`: a live unfinished `Coordinator`
      already running → `resume_run/1` without `:force` returns
      `{:error, {:active_run, pid}}` and does not clobber it; with `force: true`
      it proceeds (quickstart Scenario H3; FR-017; US2 AS4)
- [X] T025 [US2] Add to `resume_run_test.exs`: the resumed run re-executes under
      the manifest's recorded context (`pr_workflow`, `max_concurrency`,
      `budget_usd`, `plan_stack`, `pr_base`, `pr_remote`) via `RunContext.merge/2`
      rather than live `Config` defaults (US2 AS2; FR-007)
- [X] T026 [US2] Add to `resume_run_test.exs`: `resumable_run/0` reports a
      summary of the resumable run and starts no `Coordinator` process; returns
      `:none` when the manifest holds only terminal/diverted features (quickstart
      Scenario E; FR-008, SC-006)
- [X] T027 [US2] Add to `resume_run_test.exs` (`@tag :integration`): a
      checkpointed feature whose branch/worktree is missing — the resume-aware
      runner calls `notify(id, :failed, {:worktree, :branch_missing})` without
      crashing the rest of the run (US1 s4 semantics reused at run level;
      quickstart Scenario H2)

### Implementation for User Story 2

- [X] T028 [P] [US2] Add `restore/2` to `lib/speckit_orchestrator/ledger.ex`:
      client function `restore(server \\ __MODULE__, recorded)` +
      `handle_call({:restore, recorded}, _from, state)` setting
      `committed = max(state.committed, recorded)`, leaving `reservations`/
      `budget` untouched (contracts/ledger-restore.md) — depends on T019
- [X] T029 [P] [US2] Create `lib/speckit_orchestrator/run_manifest.ex`: pure
      module with `write/1`, `read/0`, `clear/0`, `resumable?/0`,
      `reconstruct/1` per contracts/run_manifest.md — string-keyed JSON at
      `<Config.transcript_root()>/run.json`, best-effort write (rescue → `:ok`),
      three-way read, never fabricates fields (mirrors `Checkpoint`'s
      conventions) — depends on T016–T018
- [X] T030 [US2] Add a `:statuses` init option to `Coordinator.init/1`
      (`lib/speckit_orchestrator/coordinator.ex` ~lines 87–102):
      `Keyword.get(opts, :statuses, Map.new(features, &{&1.id, :pending}))` —
      default unchanged so `run/1` behavior is identical — depends on T020
- [X] T031 [US2] Add a `:manifest` seam to `Coordinator`
      (`lib/speckit_orchestrator/coordinator.ex`): new struct field `manifest`
      (default `RunManifest`), init option, and calls to `manifest.write/1`
      (passing `features`/current `statuses`/`context`/`Ledger.spent/1`) from
      `init/1` (before/alongside the `:continue, :release`), `spawn_feature/2`
      (~line 141), and `maybe_finish/1`'s `{:finished}` branch (~line 155) —
      best-effort, never affects wave logic — depends on T021, T029, T030
- [X] T032 [US2] Add `resumable_run/0` to `lib/speckit_orchestrator.ex`:
      `RunManifest.read/0` → classify via `RunManifest.resumable?/0` → a summary
      map, `:none`, `{:error, :no_manifest}`, or `{:error, :corrupt_manifest}`;
      starts no work (contracts/resume_run.md resumable_run/0) — depends on T029,
      T026
- [X] T033 [US2] Add `resume_run/1` to `lib/speckit_orchestrator.ex`
      implementing the 6-step contract: (1) guard an active `Coordinator` unless
      `opts[:force]`; (2) `RunManifest.read/0`, loud error on
      `:no_manifest`/`:corrupt`; (3) `RunManifest.reconstruct/1` →
      `{features, statuses}`; (4) `Ledger.restore(Ledger, manifest.spend)`
      (T028); (5) `RunContext.merge/2` reapply of the manifest `context`; (6)
      `Coordinator.start_link/1` with the reconstructed `:statuses` (T030) and
      the resume-aware runner (T034) (contracts/resume_run.md resume_run/1) —
      depends on T029, T028, T030, T031
- [X] T034 [US2] Implement the resume-aware runner dispatched by `resume_run/1`'s
      `:runner` (`lib/speckit_orchestrator.ex`): per released feature,
      `Checkpoint.read/1` returning `{:ok, _}` routes through the existing
      `resume_runner/3`/`resume_executor/3` path (worktree reuse/recreate,
      `Worktree.restore/1` from T015, `start_phase:` = phase after
      `last_phase`, reapplied context); `{:error, :no_checkpoint}` routes a
      never-started `:pending` feature through the normal fresh runner from
      `Pipeline.first()`; the reapplied `pr_workflow` selects the plain-runner vs
      stacked-executor strategy exactly as `resume/2` already does — depends on
      T033, T015
- [X] T035 [US2] In `SpeckitOrchestrator.run/1` (`lib/speckit_orchestrator.ex`
      ~lines 61–75), call `RunManifest.clear/0` before starting the run so the
      fresh `Coordinator`'s first manifest write supersedes any prior run
      (single-slot rule, FR-005) — depends on T029

**Checkpoint**: User Stories 1 AND 2 both work independently — a crashed run's
manifest reconstructs which features were done/in-flight/pending, and
`resume_run/1` continues the run releasing only what's left, without re-running
completed work. `mise exec -- mix test` and
`mise exec -- mix test --include integration` pass.

---

## Phase 3: User Story 3 - Preserve cost accounting across a crash (Priority: P3)

**Goal**: Verify the cost-continuity guarantee that Phase 2's `Ledger.restore/2`
(T028) and manifest `spend` recording (T031) already deliver: a resumed run's
breaker restores from the recorded committed spend (not zero), and a restored
figure at/above budget trips the breaker so `resume_run/1` releases zero new
features (drain, not kill).

**Independent Test**: Run until a known committed spend `S`, simulate a crash,
resume, and confirm the breaker's committed spend resumes from (at least) `S`
rather than zero, and that a resumed run whose restored spend is already at
budget releases no new work.

### Tests for User Story 3

- [X] T036 [P] [US3] Add to `resume_run_test.exs`: a manifest recording `spend`
      at or above budget — after `resume_run/1`'s `Ledger.restore/2` call,
      `breaker_tripped?/1` is `true` and `resume_run/1` releases **zero** new
      features; the invariant `committed < budget + max_single_reservation`
      continues to hold (quickstart Scenario F step 3; FR-013; US3 AS2) —
      depends on T033
- [X] T037 [US3] Add to `resume_run_test.exs`: a manifest with `spend == S`
      (`S < budget`) — after `resume_run/1`, `Ledger.spent(Ledger) >= S`,
      confirming the breaker bounds the resumed run using the recorded (not
      zero) committed figure (quickstart Scenario F steps 1–2; US3 AS1; SC-003) —
      depends on T033

### Verification for User Story 3

- [X] T038 [US3] Run T036–T037 and confirm they pass against Phase 2's existing
      implementation with no new production code; if the manifest's recorded
      `spend` is stale (e.g. Coordinator's `:manifest` seam in T031 records spend
      from before the last phase's cost was committed), fix the write-site
      ordering in `lib/speckit_orchestrator/coordinator.ex` so `spend` reflects
      `Ledger.spent/1` at the time of each write — depends on T036, T037
      (verified: `write_manifest/1`'s `spend(state)` helper calls
      `Ledger.spent(ledger)` live at every write site — no staleness, no
      production code change needed)

**Checkpoint**: All three user stories are independently functional — a crash
never lets a resumed run silently exceed its original budget.
`mise exec -- mix test --include integration` passes.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and full-suite validation across all three stories.

- [X] T039 [P] Update `docs/runbook.md`: document `resume_run/1`,
      `resumable_run/0`, the single-manifest-slot rule (a new `run/1` supersedes
      the prior manifest), and the operator flow (boot → `resumable_run/0`
      reports → operator explicitly calls `resume_run/1`) — cross-reference
      feature 007's per-feature `resume/2` for the single-feature case
- [X] T040 [P] Update moduledocs for `RunManifest`, `Ledger.restore/2`,
      `Worktree.squash/3`/`restore/1`, and `SpeckitOrchestrator.resume_run/1`/
      `resumable_run/0` to cross-reference `specs/009-crash-recovery`
      (mirrors the existing `specs/002-resume-checkpoint`/
      `specs/007-resume-self-sufficient` cross-references in `checkpoint.ex`)
- [X] T041 Run `mise exec -- mix compile` (must stay clean under
      `warnings_as_errors`) and `mise exec -- mix test --cover`, confirming
      `RunManifest` and the reconstruction/restore logic sit above the project's
      >90% core-coverage target (verified: clean compile, 0 warnings; added
      four `RunManifest` edge-case tests — non-enoent read error, pre-stringed
      statuses, nil context, unrecognized status fallback — bringing
      `RunManifest` to 97.3%, `Worktree` 90.6%, `Ledger` 94.4%, `Coordinator`
      97.5%, `FeatureRunner` 96.7% under `--include integration`; the
      project-wide 90% total is pulled down only by pre-existing `Web.*`/
      `PullRequest`/`Application` coverage from features 008/010/011, unrelated
      to this feature's core logic)
- [X] T042 Run `mise exec -- mix test --include integration` and walk through
      quickstart.md's Scenarios A–H end-to-end, confirming SC-001 through SC-006
      (verified: 424/425 pass; the one failure is
      `run_phase_test.exs`'s pre-existing paid opt-in LIVE test requiring
      `SPECKIT_FIXTURE_REPO`, unrelated to this feature — Scenarios A–H each map
      to passing tests in `checkpoint_test.exs`, `feature_runner_test.exs`,
      `worktree_test.exs`, `run_manifest_test.exs`, `ledger_test.exs`,
      `coordinator_test.exs`, and `resume_run_test.exs`)
- [X] T043 Grep `mix.exs`/`mix.lock` and confirm no datastore dependency was
      introduced by this feature (SC-007; quickstart Scenario H4) — all recovery
      state is git commits + `checkpoint.json`/`run.json` (verified: only
      transitive *optional* `ecto` deps of unrelated hex packages `crontab`/
      `uniq` appear in `mix.lock`; no datastore dependency added by 009)

---

## Dependencies & Execution Order

### Phase Dependencies

- **User Story 1 (Phase 1)**: No dependencies — start immediately. Extends
  `Checkpoint` call sites, `Worktree` (new `squash/3`/`restore/1`), and
  `FeatureRunner.loop/7`'s per-phase behavior.
- **User Story 2 (Phase 2)**: Its resume-aware runner (T034) reuses US1's
  `Worktree.restore/1` (T013) and the existing `resume_runner/3`/
  `resume_executor/3` (T015) — start Phase 2's `RunManifest`/`Ledger.restore/2`
  work (T016–T021, T028–T029) in parallel with Phase 1; T034 itself needs T015
  done first.
- **User Story 3 (Phase 3)**: Its tests (T036–T037) call `resume_run/1`
  directly — depends on Phase 2's T033 being complete. No new production code is
  expected; T038 is a fix-if-needed verification step.
- **Polish (Phase 4)**: Depends on all three user stories being complete.

### Within Each User Story

- Tests before implementation (write first, confirm they fail, then implement)
- `Worktree.squash/3`/`restore/1` (pure git plumbing) before the
  `FeatureRunner`/facade call sites that invoke them
- `RunManifest` (pure, no Coordinator dependency) and `Ledger.restore/2` before
  the `Coordinator` seams and `resume_run/1` that call them
- `Coordinator` `:statuses`/`:manifest` seams before `resume_run/1`, which
  starts the `Coordinator` with both

### Parallel Opportunities

- T001–T005 (US1 tests, four different files/concerns) in parallel
- T016–T021 (US2 tests: `run_manifest_test.exs`, `ledger_test.exs` extension,
  `coordinator_test.exs` extensions — three files) in parallel
- T028 (`Ledger.restore/2`) and T029 (`RunManifest`) — independent new/extended
  modules — in parallel
- T039, T040 (docs) independent of T041–T043 (validation) and of each other

---

## Parallel Example: User Story 2 foundation

```bash
# RunManifest and Ledger.restore/2 have no dependency on each other or on the
# Coordinator seams that will consume them — draft together:
Task: "run_manifest_test.exs — write/1, read/0, clear/0 three-way contract"
Task: "run_manifest_test.exs — resumable?/0 classification"
Task: "run_manifest_test.exs — reconstruct/1 crash→resume status mapping"
Task: "ledger_test.exs — restore/2 idempotent/monotonic + breaker interaction"
Task: "lib/speckit_orchestrator/run_manifest.ex — write/read/clear/resumable?/reconstruct"
Task: "lib/speckit_orchestrator/ledger.ex — restore/2"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: User Story 1 (per-feature crash resume)
2. **STOP and VALIDATE**: kill a run mid-phase, `resume(id)` picks up at the
   interrupted phase with no regenerated earlier artifacts (SC-002, SC-005)
3. This alone fixes the primary crash-recovery gap — a single expensive feature
   no longer restarts from zero after an unlucky crash — even before whole-run
   resume lands

### Incremental Delivery

1. User Story 1 → per-feature crash resume works → validate → (optional
   intermediate checkpoint)
2. User Story 2 → whole-run resume reconstructs mixed-state backlogs → validate
   → both stories together satisfy SC-001/SC-002/SC-004/SC-005/SC-006
3. User Story 3 → cost-continuity verification closes the budget-doubling gap →
   validate → SC-003 confirmed
4. Polish → docs + full-suite + integration validation + no-datastore check
   (SC-007)

---

## Notes

- [P] tasks = different files, no dependencies (or genuinely independent
  additions to a shared new file, called out per-task above)
- [Story] label maps task to specific user story for traceability; T028
  (`Ledger.restore/2`) is labeled `[US2]` because `resume_run/1` needs it to
  exist and compile, even though it fulfills US3's functional requirements
  (FR-012/013) — see the Organization note above
- No `String.to_atom/1` on any file-sourced value (atom-table safety) —
  `RunManifest.reconstruct/1` and `resume_run/1` reuse the existing
  `Pipeline.phase?/1` + `String.to_existing_atom/1` guard pattern from `resume/2`
- Both `squash/3` and `restore/1` operate only on the feature's own
  worktree/branch, which is unpublished until the PR workflow pushes it —
  never touch any other branch
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at each phase checkpoint to validate that story independently before
  starting the next
