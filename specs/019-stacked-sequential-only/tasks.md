---

description: "Task list for feature 019-stacked-sequential-only"
---

# Tasks: Stacked Sequential Runs as the Only Behaviour

**Input**: Design documents from `/specs/019-stacked-sequential-only/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included — the plan and contracts name specific test files and
obligations (e.g. release-policy.md's "Test obligations", quickstart.md's
scenarios), so test tasks are generated alongside implementation.

**Organization**: Tasks are grouped by user story per spec.md. The pure core
and store schema are Foundational because all four user stories compile
against their shapes (plan.md's Project Structure sequencing note:
`Feature → Backlog → Release`, then the store schema, then the facade/
Coordinator, then the console, then docs).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps task to US1–US4
- Exact file paths included in every task

## Path Conventions

Single Elixir/OTP application. Source under `lib/speckit_orchestrator/`, tests
under `test/speckit_orchestrator/` (mirroring structure), config under
`config/`, docs under `docs/`.

---

## Phase 1: Setup

**Purpose**: Fixtures the Foundational backlog tests need; no new dependency,
no project init (existing app).

- [X] T001 [P] Create `test/fixtures/breakdown_duplicate/` with two files whose
      numbers are numerically equal (e.g. `002-categories.md` and
      `0002-categories-v2.md`) for `Backlog.DuplicateNumberError` coverage
- [X] T002 [P] Delete `test/fixtures/breakdown_cyclic/` and
      `test/fixtures/breakdown_missing/` — the dangling-prerequisite and
      dependency-cycle cases they exist for are retired (FR-010)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure core shapes (`Feature`, `Backlog`, `Release`,
`RunContext`) and the store schema v2 that every user story compiles against.

**⚠️ CRITICAL**: No user story work can begin until this phase compiles clean
under `warnings_as_errors`.

- [X] T003 Rewrite `lib/speckit_orchestrator/feature.ex`: remove `prereqs` and
      the `:blocked` status; add `number :: pos_integer()` (parsed from the
      `NNN` filename prefix, compared numerically), `group ::
      :backlog | :ad_hoc` (default `:backlog`), `created_at :: DateTime.t() |
      nil` (non-nil only for `:ad_hoc`)
- [X] T004 Rewrite `lib/speckit_orchestrator/backlog.ex` (depends on T003):
      delete `extract_prereqs/1`, `dependents/1`, `validate_prereqs!/1`,
      `detect_cycles!/1`, `topo_resolve/3`, `MissingPrereqError`,
      `CycleError`; add `Backlog.DuplicateNumberError` raised when two files'
      numbers are numerically equal, naming every conflicting file; `load!/1`
      returns features sorted by `number` ascending, all `group: :backlog`; a
      `## Prerequisites` section becomes inert prose
- [X] T005 Rewrite `lib/speckit_orchestrator/release.ex` (depends on T003):
      replace `next_wave/4`, `releasable?/2`, `blocked?/2`,
      `sequential_order/1` with `order/1` (backlog by `number` ascending, then
      ad-hoc by `{created_at, number}` ascending) and `next/3` returning
      `{:release, feature} | :none | {:stopped, id, status}` per the rule
      order in contracts/release-policy.md (breaker ⇒ `:none`; any
      non-done terminal ⇒ `{:stopped, id, status}`; any `:running` ⇒ `:none`;
      lowest-ordered `:pending` ⇒ `{:release, feature}`; otherwise `:none`) —
      no `cap` parameter anywhere
- [X] T006 [P] Edit `lib/speckit_orchestrator/run_context.ex`: delete
      `pr_workflow` and `max_concurrency` fields, `stacked?/1`, and
      `effective_max_concurrency/2`; keep `capture/1`/`to_map/1`/`from_map/1`/
      `merge/2` shapes and precedence for the remaining eight fields
- [X] T007 Edit `lib/speckit_orchestrator/store/schema.ex`: `speckit_run`
      gains `state: :parked` (union becomes `:in_flight | :parked |
      :completed | :superseded`), `stopped_by`, `stopped_reason`, and
      `outcome: :ended_by_operator`; `speckit_feature` loses `prereqs`, gains
      `number`, `group`, `created_at`, and status union loses `:blocked`
      gains `:never_started`
- [X] T008 [P] Edit `lib/speckit_orchestrator/store/records.ex`: update the
      state/outcome/status typespecs and any record-shape helpers to match
      schema v2 (T007)
- [X] T009 Edit `lib/speckit_orchestrator/store/migrations.ex`: bump
      `current_version/0` to `2`; register version 2 as a refusal migration
      (`fn -> {:error, {:incompatible_record, 1}} end`) in the same ordered
      list as every other migration, naming the incompatibility on a v1
      directory at boot
- [X] T010 Edit `lib/speckit_orchestrator/store/writer.ex` (depends on T007):
      add `park_run(run_key, %{stopped_by:, status:, reason:})`
      (`:in_flight → :parked`, one transaction), `continue_run(run_key)`
      (`:parked → :in_flight`, clears `stopped_by`/`stopped_reason`),
      `end_run(run_key, outcome)` (`:parked → :completed`, writes every
      still-`:pending` feature as `:never_started` in the same transaction);
      give `open_run/2`'s `supersede_in_flight!/2` a guard that aborts the
      transaction with `{:parked_run, run_id}` when `Query.parked_run/1` finds
      one, instead of superseding it
- [X] T011 [P] Edit `lib/speckit_orchestrator/store/query.ex` (depends on
      T007): add `parked_run/1`, mirroring `in_flight_run/1`
- [X] T012 [P] Edit `lib/speckit_orchestrator/store/export.ex`: update
      exported fields for the schema-v2 attribute changes (T007)
- [X] T013 [P] Rewrite `test/speckit_orchestrator/release_test.exs` for
      `next/3` + `order/1` per contracts/release-policy.md's Test
      obligations: ascending order over a gapped backlog (001/005/020); any
      `:running` feature ⇒ always `:none`; stop on each of `:escalated`,
      `:halted`, `:failed`; breaker tripped ⇒ `:none` even with releasable
      features; `order/1` independent of input list order; a fixture's prose
      `## Prerequisites` has no effect on order
- [X] T014 [P] Rewrite `test/speckit_orchestrator/backlog_test.exs`: drop the
      dangling-prereq/cycle cases; add numerically-equal duplicates (using
      T001's fixture, including differing zero-padding e.g. `002` vs `0002`)
      and gapped-numbering (legal, no error) cases
- [X] T015 [P] Extend `test/speckit_orchestrator/store/migrations_test.exs`
      for the v2 refusal migration: fresh directory boots at v2 (run number
      one); a recorded v1 aborts startup naming the incompatibility; `> 2`
      still aborts (unchanged)
- [X] T016 [P] Extend `test/speckit_orchestrator/store/writer_test.exs` and
      `test/speckit_orchestrator/store/query_test.exs` for `park_run/2`,
      `continue_run/1`, `end_run/2`, `parked_run/1`, and the `open_run/2`
      parked-guard abort (race-free: two concurrent `open_run/2` calls against
      a parked run both fail)
- [X] T017 Rename `test/speckit_orchestrator/pr_workflow_test.exs` to
      `test/speckit_orchestrator/stacked_run_test.exs`, dropping the
      toggle-off cases and keeping the stacked-always assertions

**Checkpoint**: `mise exec -- mix compile` is clean; `Feature`, `Backlog`,
`Release`, `RunContext`, and the store schema are ready for every story above.

---

## Phase 3: User Story 1 - Every run is a stacked sequential run (Priority: P1) 🎯 MVP

**Goal**: No run-mode or concurrency setting exists on any surface; retired
settings are refused loudly everywhere; the PR-remote/target-pack preflight is
unconditional; every operator-facing view describes one run shape.

**Independent Test**: Start a run with no options against a prepared target
repo; observe it preflights the PR remote, releases one feature at a time,
and refuses `:pr_workflow`/`:max_concurrency` on every surface — with no
setting anywhere that could have produced different behaviour.

- [X] T018 [US1] Edit `lib/speckit_orchestrator/config.ex`: delete
      `pr_workflow?/0` and `max_concurrency/0`
- [X] T019 [US1] Edit `config/config.exs`: delete the `:pr_workflow` and
      `:max_concurrency` keys
- [X] T020 [US1] Edit `config/runtime.exs`: delete the `SPECKIT_PR_WORKFLOW`
      and `SPECKIT_MAX_CONCURRENCY` mappings; `raise` at config load when
      either environment variable is set at all, naming the retired setting
- [X] T021 [US1] Edit `lib/speckit_orchestrator/application.ex`: add a
      boot-time check, before the supervision tree's first child, that reads
      `Application.get_env` for `:pr_workflow` and `:max_concurrency` and
      aborts startup naming the retired setting when either is present
- [X] T022 [US1] Edit `lib/speckit_orchestrator.ex`: add a `@retired_opts`
      allow-list check on `run/1`, `run_spec/2`, `resume/2`, `resume_run/1`
      that refuses `:pr_workflow`/`:max_concurrency` with
      `{:error, {:preflight, [{:retired_option, key}]}}` (and any other
      unknown key with `{:retired_option: key}` per contracts/run-start.md)
      before any side effect — before the remediation preflight, the layout
      resolution, and the store run opening
- [X] T023 [US1] Edit `lib/speckit_orchestrator.ex` (depends on T022): make
      the `TargetPack.verify(repo, check_remote: pr_remote)` preflight step
      unconditional rather than gated on `Config.pr_workflow?/0`, for both
      `run/1` and `run_spec/2`; skip only when a `:runner`/`:executor` seam is
      injected (test mode), unchanged
- [X] T024 [US1] Edit `lib/speckit_orchestrator/live_config.ex`: delete
      `pr_workflow` and `max_concurrency` from the live-config change type,
      validation, and dispatch
- [X] T025 [P] [US1] Edit `lib/speckit_orchestrator/web/components/layouts.ex`:
      delete `run_mode/1` and `run_cap/1` and their call sites in the status
      bar — no mode label, no cap number
- [X] T026 [P] [US1] Edit `lib/speckit_orchestrator/web/live/trigger_live.ex`:
      remove the stacked-PR toggle and the effective-concurrency line; render
      the run-shape summary as static descriptive text
- [X] T027 [P] [US1] Edit `lib/speckit_orchestrator/web/live/config_live.ex`:
      remove the concurrency slider and the PR-workflow toggle; keep
      `pr_base`, `pr_remote`, budget, and models editable
- [X] T028 [US1] Edit `lib/speckit_orchestrator/coordinator.ex`: delete the
      `cap` field and `set_cap/2` — no live operation may change how many
      features run at once
- [X] T029 [P] [US1] New `test/speckit_orchestrator/retired_settings_test.exs`:
      assert `run/1`, `run_spec/2` refuse `:pr_workflow`/`:max_concurrency`
      with `{:error, {:preflight, [{:retired_option, key}]}}`; assert the
      `Application.start/2` boot check aborts when either app-env key is
      present
- [X] T030 [P] [US1] Update `test/speckit_orchestrator/web/trigger_live_test.exs`:
      assert zero run-shape inputs render on the trigger screen (SC-001)
- [X] T031 [P] [US1] Update `test/speckit_orchestrator/web/config_live_test.exs`:
      assert no concurrency slider or PR-workflow toggle renders
- [X] T032 [P] [US1] Update `test/speckit_orchestrator/web/layout_test.exs`:
      assert the status bar renders no mode label and no cap
- [X] T033 [US1] Grep verification (quickstart Scenario 3): confirm
      `grep -rn "pr_workflow\|max_concurrency" lib config | grep -v retired`
      returns nothing outside the refusal paths in T018–T024; fold the check
      into `test/speckit_orchestrator/stacked_run_test.exs` (T017) or a CI
      script

**Checkpoint**: US1 is independently testable — no run-shape setting exists
anywhere, and every attempt to supply one is refused loudly.

---

## Phase 4: User Story 2 - The backlog runs in the order the operator numbered it (Priority: P1)

**Goal**: Execution order is ascending feature number, one at a time; gaps
are legal; prose prerequisites have no effect; the Ad-hoc group orders by
creation time and stays chain-neutral.

**Independent Test**: Prepare a backlog numbered 001/002/003 (and a gapped
001/005/020 variant) and start a run; observe features released strictly in
ascending numeric order, never more than one in flight, regardless of any
prose prerequisite declaration.

- [X] T034 [US2] Edit `lib/speckit_orchestrator/single_spec.ex`:
      `SingleSpec.build/3` stamps `group: :ad_hoc` and
      `created_at: DateTime.utc_now()` on every ad-hoc feature
- [X] T035 [US2] Edit `lib/speckit_orchestrator/stack_tracker.ex`: doc-only
      change — the tracker is advanced only by a `:done` **backlog** feature;
      an ad-hoc feature reads `Config.pr_base()` directly and never calls
      `set_top/2` (FR-028, R6)
- [X] T036 [P] [US2] Edit `lib/speckit_orchestrator/console_read_model.ex`:
      remove the `prereqs` projection; add `group`; project the two ordered
      groups (numbered backlog by `number`, Ad-hoc by `created_at`)
- [X] T037 [P] [US2] Rewrite `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`:
      replace the dependency-depth DAG with a linear chain view — one column
      per group (numbered backlog, Ad-hoc), features in `Release.order/1`
      order, each rendered as a chain link with its base branch (FR-027)
- [X] T038 [US2] Delete `lib/speckit_orchestrator/web/live/pipeline_dag_layout.ex`
      — its subject (prerequisite depth) no longer exists
- [X] T039 [P] [US2] Edit `docs/breakdown-format.md`: document the numbering
      contract (FR-013) per contracts/backlog-order.md — the number
      determines order, renumbering changes it, gaps are legal, numeric
      equality (not string equality) defines a duplicate, and prose
      `## Prerequisites` sections are inert
- [X] T040 [P] [US2] Rewrite `test/speckit_orchestrator/single_spec_test.exs`:
      assert `group: :ad_hoc` with a non-nil `created_at` on every built
      ad-hoc feature
- [X] T041 [US2] Extend `test/speckit_orchestrator/release_test.exs` (T013)
      with ad-hoc ordering: backlog features first by `number`, then ad-hoc
      by `{created_at, number}`; two ad-hoc features sharing a timestamp
      order by `number` (stable, total order)
- [X] T042 [US2] Extend `test/speckit_orchestrator/single_spec_test.exs` or
      `test/speckit_orchestrator/coordinator_test.exs`: via the injected
      `:publisher` seam, assert an ad-hoc feature branches from
      `Config.pr_base()` and the stack top is unchanged after it reaches
      `:done`
- [X] T043 [P] [US2] Update `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`:
      assert two ordered groups render (numbered backlog, Ad-hoc), not a
      dependency graph; delete `test/speckit_orchestrator/web/pipeline_dag_layout_test.exs`
      to match T038

**Checkpoint**: US2 is independently testable — ordering is numeric and
total, gaps are legal, and ad-hoc features are a distinct, chain-neutral
group.

---

## Phase 5: User Story 3 - A broken link stops the chain (Priority: P1)

**Goal**: The run stops releasing as soon as any feature reaches a non-done
terminal state; later features are never started; the report names the
stopper; a completed feature's local branch still becomes the next base even
when publication fails.

**Independent Test**: Prepare a backlog where the second of seven features is
forced to escalate; confirm the run stops after it, 003–007 are reported
`not_started`, and the report names `002` and its reason.

- [X] T044 [US3] Edit `lib/speckit_orchestrator/coordinator.ex` (depends on
      T005, T010, T028): add a `stopped_by` field
      (`{feature_id, status, reason} | nil`); when `Release.next/3` returns
      `{:stopped, id, status}` and `inflight` is empty, call
      `Store.Writer.park_run/2`, set `stopped_by`, and notify the owner
      instead of draining silently
- [X] T045 [US3] Edit `lib/speckit_orchestrator/report.ex`: remove `blocked`
      from `build_report/1`'s iex table; add `stopped_by`
      (`%{feature_id:, status:, reason:} | nil`); `not_started` means every
      `:pending` feature at drain
- [X] T046 [P] [US3] Edit `lib/speckit_orchestrator/recovery/reconcile.ex`:
      drop `:blocked` handling
- [X] T047 [P] [US3] Edit `lib/speckit_orchestrator/recovery/rebuild.ex`:
      drop the prereq consistency check
- [X] T048 [P] [US3] Edit `lib/speckit_orchestrator/recovery/report.ex`:
      remove `:blocked`
- [X] T049 [US3] Verify FR-018 at the chain-base resolution call site (where
      the Coordinator/executor picks the next feature's base branch): a
      completed feature's local branch becomes the next base even when its
      PR publication fails, and the publication failure is recorded on the
      run rather than swallowed
- [X] T050 [P] [US3] Rewrite `test/speckit_orchestrator/coordinator_test.exs`:
      stop-on-first-failure for `:escalated`/`:halted`/`:failed` over a
      seven-feature backlog (002 forced to fail via the injected `:runner`
      seam); assert the report shape
      `%{done:, escalated/halted/failed:, not_started:, stopped_by:}` with no
      `blocked` key; assert no `cap` field anywhere in Coordinator state
- [X] T051 [P] [US3] Add a coordinator test: cost breaker trips mid-chain —
      the in-flight feature halts between phases, the next `Release.next/3`
      call reports it as the stopper, and no later feature is released
- [X] T052 [P] [US3] Add a coordinator test: a completed feature's PR
      publication fails — the next feature still stacks on the completed
      local branch, and the publication failure is recorded on the run, not
      swallowed

**Checkpoint**: US3 is independently testable — the chain stops at exactly
the first broken link and the report is unambiguous about what happened.

---

## Phase 6: User Story 4 - Continue or end a parked chain (Priority: P2)

**Goal**: A run that stopped on a broken link is parked; new work for that
repository is refused until the operator decides; resolving the stopping
feature requires an explicit continue-or-end choice; continuing carries the
chain to completion, ending closes it out with never-started features
recorded as such.

**Independent Test**: Take a run stopped at feature 002 (from US3); resolve
it choosing `:continue` and confirm 002 re-runs and 003 onward follow in
order; repeat choosing `:end` and confirm nothing further is released and
never-started features are recorded.

- [X] T053 [US4] Edit `lib/speckit_orchestrator.ex` (depends on T010, T044):
      implement `continue_run/1` — guard a live unfinished Coordinator
      (`{:error, {:active_run, pid}}` unless `:force`); locate the
      repository's `:parked` run (`{:error, :no_parked_run}` if none); store
      capacity preflight; `Store.Writer.continue_run/1`
      (`:parked → :in_flight`, same `run_id`); reset only the stopping
      feature to `:pending`; `Recovery.reconcile_run/2`; re-seed
      `StackTracker` from the branch of the highest-ordered `:done` backlog
      feature (falling back to `Config.pr_base()`); start the Coordinator
      with the same `run_key` and restored context
- [X] T054 [US4] Edit `lib/speckit_orchestrator.ex`: implement `end_run/1` —
      one transaction via `Store.Writer.end_run/2`
      (`:parked → :completed`, `outcome: :ended_by_operator`, every
      still-`:pending` feature written `:never_started`, `stopped_by`/
      `stopped_reason` retained); returns the final report; releases nothing
- [X] T055 [US4] Edit `lib/speckit_orchestrator.ex` (depends on T053, T054):
      `resolve/2` gains a required `:decision` option (`:continue | :end`)
      when the repository has a parked run — frees the feature's worktree and
      records the escalation resolution, then dispatches to `continue_run/1`
      or `end_run/1`; absent decision ⇒ `{:error, :decision_required}`,
      nothing changes; with no parked run, `resolve/1` behaves exactly as
      today
- [X] T056 [US4] Edit `lib/speckit_orchestrator.ex`: `run/1` and
      `run_spec/2` surface `{:error, {:parked_run, run_id, [:continue, :end]}}`
      from the `open_run/2` guard (T010) as preflight step 3, before layout
      resolution (FR-020a, FR-020b)
- [X] T057 [P] [US4] Edit `lib/speckit_orchestrator/console_read_model.ex`
      (depends on T036): add the parked-run projection — `state`,
      `stopped_by`, `stopped_reason`
- [X] T058 [P] [US4] Edit `lib/speckit_orchestrator/web/live/mission_control_live.ex`:
      add the parked banner — stopping feature, its status, its reason, and
      both `continue`/`end` actions (FR-019, SC-008)
- [X] T059 [P] [US4] Edit `lib/speckit_orchestrator/web/live/runs_live.ex` and
      `lib/speckit_orchestrator/web/live/run_detail_live.ex`: render
      `:parked` distinctly from `:in_flight`/`:completed`; show `stopped_by`/
      `stopped_reason` and list never-started features as such (SC-004)
- [X] T060 [P] [US4] Edit `docs/runbook.md`: document the parked-run
      lifecycle (park/continue/end) and the store-reset procedure for schema
      v2 (contracts/store-schema-v2.md §6)
- [X] T061 [P] [US4] New `test/speckit_orchestrator/parked_run_test.exs`: full
      lifecycle — park at stop; `run/1` and `run_spec/2` refused while
      parked; `resolve/1` without `:decision` returns `{:error,
      :decision_required}`; `resolve(id, decision: :continue)` re-runs the
      stopping feature and resumes order under the same `run_id`;
      `resolve(id, decision: :end)` closes out with `outcome:
      :ended_by_operator` and every unattempted feature `:never_started`;
      continuing a run whose stopping feature breaks again parks it a second
      time with the new reason recorded distinctly; a parked run whose
      stopper was the last feature reaches the same closed-out result via
      either decision
- [X] T062 [P] [US4] Update `test/speckit_orchestrator/web/mission_control_live_test.exs`:
      assert the parked banner renders with both actions when the run is
      parked
- [X] T063 [P] [US4] Update `test/speckit_orchestrator/web/runs_live_test.exs`
      and `test/speckit_orchestrator/web/run_detail_live_test.exs`: assert
      `:parked` renders distinctly and never-started features are listed

**Checkpoint**: All four user stories are independently functional — single
run shape, numeric ordering, stop-on-first-break, and the park/continue/end
lifecycle.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, whole-suite verification, and the long tail of
fixture/assertion cleanup the plan calls out as touching ~40 further files.

- [X] T064 [P] Update `CLAUDE.md`: `Release`/`Backlog`/`Feature` descriptions,
      the single run shape, no worktree parallelism across features
- [X] T065 [P] Update `docs/workflow.md`: one run shape — a chain, not a DAG
- [X] T066 [P] Update `docs/speckit-orchestrator-implementation-plan.md`:
      record feature 019 as done
- [X] T067 Sweep the remaining test files for `prereqs`/`cap`/`pr_workflow`
      fixtures and assertions and drop them (e.g.
      `test/speckit_orchestrator/feature_test.exs`,
      `run_context_test.exs`, `console_read_model_test.exs`,
      `record_recovery_test.exs`, `recovery_test.exs`,
      `recovery/reconcile_test.exs`, `store_capacity_test.exs`,
      `facade_e2e_test.exs`, `resume_*_test.exs`, `run_history_test.exs`,
      `run_detail_test.exs`, `export_test.exs`, `export_run_test.exs`,
      `clean_break_test.exs`) so none references a retired field or the old
      wave shape
- [X] T068 Run `mise exec -- mix compile` and confirm zero warnings
      (`warnings_as_errors` is ON)
- [X] T069 Run `mise exec -- mix test` (full suite) and
      `mise exec -- mix test --cover` (target >90% on the pure core)
- [X] T070 Run quickstart.md Scenarios 1–6 (hermetic) and record results;
      Scenario 7 (live end-to-end) stays opt-in per
      `docs/phase7-ledgerlite-runbook.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup (T001 fixture feeds T014).
  BLOCKS all user stories — `Feature`, `Backlog`, `Release`, `RunContext`, and
  the store schema v2 are load-bearing for every story below.
- **User Story 1 (Phase 3)**: Depends on Foundational. Independent of US2–US4.
- **User Story 2 (Phase 4)**: Depends on Foundational. Independent of US1,
  US3, US4 (T041/T042 extend shared test files from T013/T040 but do not
  block on US1/US3 code).
- **User Story 3 (Phase 5)**: Depends on Foundational (T005, T010).
  Independent of US1, US2.
- **User Story 4 (Phase 6)**: Depends on Foundational (T010) and on US3
  (T044 — parking must exist before continuing/ending it makes sense).
- **Polish (Phase 7)**: Depends on all four user stories being complete.

### Within Each Phase

- Foundational: T003 → T004, T005 (Backlog and Release both read `Feature`'s
  new shape); T007 → T008, T009, T010, T011, T012 (schema before the
  attribute/writer/query work that reads it); T013–T017 depend on the
  modules they test.
- US1: T022 → T023 (allow-list before making the preflight unconditional);
  T018–T024 before T029 (tests assert the refusals exist).
- US2: T034 before T042 (build the ad-hoc feature before asserting its
  behaviour); T037 depends on T005's `order/1` and T038's deletion.
- US3: T044 depends on T005 (`{:stopped, …}`) and T010 (`park_run/2`); T050
  depends on T044, T045.
- US4: T053, T054 depend on T010; T055 depends on T053, T054; T056 depends
  on T010's `open_run/2` guard; T061 depends on T053–T056.

### Parallel Opportunities

- T001, T002 (Setup) — different directories.
- T006, T008, T011, T012 (Foundational, different files, no interdependency).
- T013–T016 (Foundational tests, different files).
- T025, T026, T027 (US1 console files, different files).
- T029–T032 (US1 tests, different files).
- T036, T037, T039 (US2, different files, both depend only on T034/T005).
- T040, T043 (US2 tests, different files).
- T046, T047, T048 (US3 recovery files, different files).
- T050, T051, T052 (US3 tests, different files, all read-only against T044).
- T057, T058, T059, T060 (US4 console/docs, different files).
- T061, T062, T063 (US4 tests, different files).
- T064, T065, T066 (Polish docs, different files).

---

## Parallel Example: User Story 3

```bash
# Launch the three recovery edits together (different files):
Task: "Edit lib/speckit_orchestrator/recovery/reconcile.ex — drop :blocked handling"
Task: "Edit lib/speckit_orchestrator/recovery/rebuild.ex — drop prereq consistency check"
Task: "Edit lib/speckit_orchestrator/recovery/report.ex — remove :blocked"

# Launch the three coordinator test additions together (different assertions,
# same file — run sequentially against coordinator_test.exs, or split into
# separate `describe` blocks written by one agent):
Task: "Stop-on-first-failure scenarios for :escalated/:halted/:failed"
Task: "Cost breaker trips mid-chain"
Task: "Publication fails for a completed feature"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — blocks everything)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: `mise exec -- mix test test/speckit_orchestrator/retired_settings_test.exs test/speckit_orchestrator/stacked_run_test.exs`
5. This alone delivers SC-001 and SC-005 — zero run-shape decisions, no
   surface accepts a retired setting.

### Incremental Delivery

1. Setup + Foundational → pure core and schema v2 ready.
2. Add US1 → single run shape, no retired settings → validate independently.
3. Add US2 → numeric ordering, ad-hoc group → validate independently.
4. Add US3 → stop-on-first-broken-link → validate independently.
5. Add US4 → park/continue/end → validate independently (needs US3's
   parking to exist first).
6. Polish → docs, whole-suite verification, quickstart run.

### Note on story independence here

Unlike a typical CRUD feature, US1–US3 share almost no code with each other
at the story level — each touches a disjoint slice of surfaces (config/CLI
refusal for US1, ordering/console for US2, Coordinator/report for US3) once
Foundational has landed. US4 is the one genuine exception: parking (US3) must
exist before continuing or ending a parked run means anything, so US4 is
correctly sequenced last and at P2.
