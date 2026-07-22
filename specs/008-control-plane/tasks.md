---

description: "Task list for the Control Plane console (008)"
---

# Tasks: Control Plane

**Input**: Design documents from `/specs/008-control-plane/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/routes.md, contracts/console_projection.md, contracts/live_config.md, quickstart.md

**Tests**: Included — Constitution "Quality & Test Discipline" requires the pure fold and wave/breaker-adjacent logic be tested via injected seams; plan.md's Constitution Check commits to `console_read_model_test.exs`, `live_config_test.exs`, and per-LiveView tests under `--include integration`-free defaults.

**Organization**: Tasks are grouped by user story (US1–US6, spec.md priorities P1/P2/P2/P3/P3/P3) so each is independently implementable and testable, per plan.md's `lib/speckit_orchestrator/web/` structure.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps task to US1–US6
- File paths are exact per plan.md's Project Structure section

## Path Conventions

Single Mix project. New code under `lib/speckit_orchestrator/web/` (LiveView tree) plus three new root modules (`console_projection.ex`, `console_read_model.ex`, `live_config.ex`); two tiny additive setters on existing `coordinator.ex` / `ledger.ex`. Tests mirror under `test/speckit_orchestrator/` and `test/speckit_orchestrator/web/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Add the Phoenix/LiveView/Bandit stack to the existing Mix project — no pipeline logic yet.

- [X] T001 Add `{:phoenix, "~> 1.7"}`, `{:phoenix_live_view, "~> 1.0"}`, `{:bandit, "~> 1.0"}`, and promote `{:phoenix_pubsub, "~> 2.1"}` from transitive to direct in `mix.exs`; run `mise exec -- mix deps.get`
- [X] T002 Add `config :speckit_orchestrator, SpeckitOrchestrator.Web.Endpoint` (loopback bind `ip: {127, 0, 0, 1}`, LiveView signing salt, PubSub server name) to `config/config.exs`, plus `config/dev.exs`/`config/test.exs` overrides as needed
- [X] T003 [P] Create `lib/speckit_orchestrator/web/endpoint.ex` — Bandit-backed `Phoenix.Endpoint`, socket for LiveView, no auth pipeline (FR-035)
- [X] T004 [P] Create `lib/speckit_orchestrator/web/router.ex` with the six empty-shell LiveView routes from `contracts/routes.md` (`/`, `/dag`, `/trigger`, `/escalations`, `/transcripts`, `/config`) — placeholder modules created in later phases
- [X] T005 Verify `mise exec -- mix compile` succeeds with `warnings_as_errors` on and the endpoint boots via `mise exec -- mix phx.server` per `quickstart.md`

**Checkpoint**: Empty Phoenix app compiles and serves on loopback; no view has content yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared read-model plumbing every view depends on — `Phoenix.PubSub` in the supervision tree, the pure `ConsoleReadModel` fold, the `ConsoleProjection` GenServer, shared UI chrome, and the two backend setters. **No view can be built until this phase is done.**

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T006 Add `{Phoenix.PubSub, name: SpeckitOrchestrator.PubSub}` and `SpeckitOrchestrator.Web.Endpoint` to the supervision tree in `lib/speckit_orchestrator/application.ex`
- [X] T007 [P] Implement pure fold `SpeckitOrchestrator.ConsoleReadModel.apply_event/4` in `lib/speckit_orchestrator/console_read_model.ex` per `contracts/console_projection.md`'s telemetry-event table (phase `:start`/`:stop`/`:exception`, feature `:terminal`) — no GenServer, no PubSub, pure `model -> model`
- [X] T008 [P] Implement `SpeckitOrchestrator.ConsoleReadModel.merge/3` (pure merge of `Coordinator.status/0` + `Ledger.snapshot/1` + projection state) used by both seed-on-mount and reconcile, in the same file as T007
- [X] T009 [US-shared] Contract test for the pure fold: synthetic `[:speckit, :phase, :start/:stop/:exception]` and `[:speckit, :feature, :terminal]` events → expected read-model deltas, in `test/speckit_orchestrator/console_read_model_test.exs` (write first per Constitution test discipline; depends on T007/T008 existing as stubs)
- [X] T010 Implement `SpeckitOrchestrator.ConsoleProjection` GenServer in `lib/speckit_orchestrator/console_projection.ex` — boot-started, attaches to `SpeckitOrchestrator.Telemetry.events/0`, folds via `ConsoleReadModel.apply_event/4`, holds a bounded 200-entry feed ring, broadcasts `{:console, :feature_updated, …}` / `{:console, :feed, …}` on topic `"console:run"`, exposes `read/0` (depends on T007, T006)
- [X] T011 Add `ConsoleProjection` to the supervision tree in `lib/speckit_orchestrator/application.ex` (depends on T010)
- [X] T012 Implement the reconcile tick in `ConsoleProjection` — `:timer.send_interval(2000, :reconcile)` re-reading `Coordinator.status/0` + `Ledger.snapshot/1`, broadcasting `{:console, :reconciled, …}` (FR-033/SC-005), tolerating an absent `Coordinator` (`Process.whereis/1 == nil` → no-active-run) (depends on T010)
- [X] T013 [P] Add `Coordinator.set_cap/2` — additive `GenServer.call` updating `state.cap`, mirrored to app env — in `lib/speckit_orchestrator/coordinator.ex` per `contracts/live_config.md`
- [X] T014 [P] Add `Ledger.set_budget/2` — additive `GenServer.call` updating `state.budget` — in `lib/speckit_orchestrator/ledger.ex` per `contracts/live_config.md`
- [X] T015 [P] Unit tests for `Coordinator.set_cap/2` (next `Release.next_wave` sees new cap) in `test/speckit_orchestrator/coordinator_test.exs`
- [X] T016 [P] Unit tests for `Ledger.set_budget/2` (subsequent `reserve`/`breaker_tripped?` use new budget; invariant `committed < budget + max single reservation` holds) in `test/speckit_orchestrator/ledger_test.exs`
- [X] T017 [P] Shared UI components in `lib/speckit_orchestrator/web/components/core_components.ex` — status pill (one shared lifecycle→color palette, FR-034), phase strip (fixed `Pipeline.phases/0` order), cost gauge (proximity color), badge, toast primitives
- [X] T018 [US-shared] Root/app layout in `lib/speckit_orchestrator/web/components/layouts.ex` + `layouts/` — fixed left nav (six items + active indicator, FR-001), Escalations count badge (hidden at zero, FR-002), context strip (target repo, CLI auth health, runtime health, FR-003), persistent status bar (run title/mode, cost gauge, armed/tripped, live clock, FR-004), toast slot (FR-005), drawer slot (depends on T017)
- [X] T019 LiveView test asserting nav renders six items, Escalations badge hides at zero and shows a count otherwise, and status bar renders no-active-run vs active-run shells, in `test/speckit_orchestrator/web/layout_test.exs` (depends on T018)

**Checkpoint**: PubSub + projection + reconcile tick + shared chrome exist and are tested; every subsequent LiveView can mount, subscribe, seed, and render inside the shared layout.

---

## Phase 3: User Story 1 - Watch a live run at a glance (Priority: P1) 🎯 MVP

**Goal**: Mission Control shows status counts, per-feature seven-phase progress, cost gauge, and a live telemetry feed, updating without reload; clicking a row opens the feature drawer.

**Independent Test**: Start a run, open Mission Control, confirm the feature table/status counts/gauge/feed reflect true state and refresh as phases advance with no page reload (quickstart.md US1).

### Tests for User Story 1

- [X] T020 [P] [US1] LiveView test: mount seeds status-count strip + backlog table (id, slug, status, seven-phase progress, elapsed, spend) from `Coordinator.status/0` + `ConsoleProjection.read/0`, in `test/speckit_orchestrator/web/mission_control_live_test.exs`
- [X] T021 [P] [US1] LiveView test: a `{:console, :feature_updated, …}` broadcast updates a row's phase/status within the same render cycle, and a `{:console, :feed, …}` broadcast prepends a feed entry — no reload — in the same test file as T020
- [X] T022 [P] [US1] LiveView test: status bar reflects run title/mode, gauge (committed/reserved/budget) and armed/tripped indicator, in the same test file as T020

### Implementation for User Story 1

- [X] T023 [US1] Implement `SpeckitOrchestrator.Web.MissionControlLive` in `lib/speckit_orchestrator/web/live/mission_control_live.ex` — route `/`; on mount (connected) `Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, "console:run")`; seed via `ConsoleReadModel.merge/3`; handle `{:console, :feature_updated}` / `{:console, :feed}` / `{:console, :reconciled}` / `{:console, :run_finished}` (depends on T010, T012, T018)
- [X] T024 [US1] Render status-count strip aggregating features by lifecycle state (FR-006) in the same LiveView/template
- [X] T025 [US1] Render backlog table — id, slug, status, seven-phase progress (fixed order, active phase distinguished by running/escalated/halted/failed — FR-008), elapsed, spend (FR-007) reusing the phase-strip component from T017
- [X] T026 [US1] Render telemetry feed — feature id, event text, timestamp, newest first, bounded (FR-009)
- [X] T027 [US1] Wire row click to open `FeatureDrawerComponent` (stub acceptable here; full drawer content lands in T028) passing the selected feature id
- [X] T028 [US1] Implement `FeatureDrawerComponent` in `lib/speckit_orchestrator/web/components/feature_drawer.ex` — per-phase timeline (outcome/meta + short phase description), elapsed, spend, prerequisites (FR-011); dismissible without obstructing the underlying view (FR-013)
- [X] T029 [US1] Render drained/completed run state (`finished?: true` + `report`) instead of a still-live screen when the run finishes while watched (edge case, SC-006)
- [X] T030 [US1] Render explicit no-active-run empty state when `Coordinator` is absent (FR-036, SC-006)

**Checkpoint**: Mission Control is fully functional and independently testable — the MVP slice.

---

## Phase 4: User Story 2 - Trigger a run from the console (Priority: P2)

**Goal**: Operator starts a backlog run or a single-spec run from a form, with DAG validation and PR-workflow toggle, landing on Mission Control with a confirmation.

**Independent Test**: From Trigger, start a backlog run and confirm it appears in Mission Control; submit a free-text description and confirm a new feature is created with auto-id/derived slug (quickstart.md US2).

### Tests for User Story 2

- [X] T031 [P] [US2] LiveView test: Backlog mode shows breakdown source, feature count, DAG-validated?, max concurrency, budget; Start disabled when `Backlog.load!/1` raises (dangling prereq/cycle) — FR-019, in `test/speckit_orchestrator/web/trigger_live_test.exs`
- [X] T032 [P] [US2] LiveView test: Single-spec mode previews auto-assigned id + derived slug as the operator types; empty description shows a field error and does not call `run_spec/2` (FR-016), in the same test file
- [X] T033 [P] [US2] LiveView test: enabling the stacked PR toggle before Start reflects PR-workflow mode + effective concurrency 1 in the confirmation/status bar (FR-017), in the same test file
- [X] T034 [P] [US2] LiveView test: successful Start navigates to `/` and shows a toast confirmation (FR-018), in the same test file

### Implementation for User Story 2

- [X] T035 [US2] Implement `SpeckitOrchestrator.Web.TriggerLive` in `lib/speckit_orchestrator/web/live/trigger_live.ex` — route `/trigger`; mode toggle Backlog vs Single-spec (FR-014) (depends on T018)
- [X] T036 [US2] Backlog mode: call `Backlog.load!/1` for preview (source, count, DAG-valid?), catch `MissingPrereqError`/`CycleError` to disable Start with the surfaced reason (FR-015, FR-019)
- [X] T037 [US2] Single-spec mode: live-preview auto-assigned id + `SingleSpec` slug derivation as the operator types; reject empty/whitespace description with a field error before calling `run_spec/2` (FR-016)
- [X] T038 [US2] Stacked PR-workflow toggle wired to `:pr_workflow` opt on Start, constraining to one-feature-at-a-time / one PR per feature and reflecting in the post-start status bar (FR-017)
- [X] T039 [US2] Wire Start action to `SpeckitOrchestrator.run/1` (backlog) or `run_spec/2` (single-spec) per `contracts/routes.md`'s command mapping; on success navigate to `/` + toast; on `{:error, {:preflight, problems}}` or `{:error, :empty_description}` show an error toast/field error (FR-018)

**Checkpoint**: Both run-trigger paths work independently of Mission Control's live-update internals (though they land the operator there).

---

## Phase 5: User Story 3 - Clear an escalation or halt (Priority: P2)

**Goal**: Escalations view lists diverted/halted/failed features with checkpoint + clarify context and drives `resume/2` (with guidance/phase override) or full restart via `resolve/2` + `run/1`.

**Independent Test**: With one escalated feature, open Escalations, read checkpoint + clarify questions, enter guidance, resume; confirm re-entry at the expected phase and the escalation clears (quickstart.md US3).

### Tests for User Story 3

- [X] T040 [P] [US3] LiveView test: lists every `:escalated`/`:halted`/`:failed` feature with divert reason + checkpoint pointer (last phase, status, session id, reason) (FR-020), in `test/speckit_orchestrator/web/escalations_live_test.exs`
- [X] T041 [P] [US3] LiveView test: escalated feature shows clarify questions/options from `spec.md`'s `## NEEDS HUMAN` block and the recorded run context (FR-021), in the same test file
- [X] T042 [P] [US3] LiveView test: guidance + start-phase override submit calls `resume/2` with `:prompt`/`:from` (default = checkpoint last phase) and clears the escalation on success (FR-022, FR-023), in the same test file
- [X] T043 [P] [US3] LiveView test: full-restart action calls `resolve/2` then `run/1`, restarting from phase 1 and freeing the worktree (FR-023), in the same test file
- [X] T044 [P] [US3] LiveView test: missing/corrupt checkpoint (`{:error, :no_checkpoint}` / `{:error, :corrupt}`) steers to full restart only, no resume option offered (edge case, FR-023), in the same test file
- [X] T045 [P] [US3] LiveView test: empty escalation set renders the all-clear empty state (FR-024), in the same test file

### Implementation for User Story 3

- [X] T046 [US3] Implement `SpeckitOrchestrator.Web.EscalationsLive` in `lib/speckit_orchestrator/web/live/escalations_live.ex` — route `/escalations`; list terminal-diverted features from `Coordinator.status/0` (depends on T018)
- [X] T047 [US3] Build `CheckpointView` read from `Checkpoint.read/1` — `{:ok, map}` renders pointer fields; `{:error, :no_checkpoint | :corrupt}` renders the steer-to-restart state instead of a resume option (data-model.md CheckpointView)
- [X] T048 [US3] Parse `## NEEDS HUMAN` clarify questions/options from the feature's `spec.md` for escalated features (FR-021)
- [X] T049 [US3] Guidance form (free-text prompt + start-phase override select, default = checkpoint's `last_phase`) submitting `resume(id, prompt: guidance, from: phase)`; toast + clear escalation on success; surface `{:error, :no_checkpoint | :corrupt_checkpoint | {:unknown_phase, _} | {:unknown_feature, _}}` per `contracts/routes.md`'s command table
- [X] T050 [US3] Full-restart action calling `resolve(id)` then `run(features: [feature])`; toast + worktree-freed confirmation
- [X] T051 [US3] All-clear empty state when no feature is `:escalated`/`:halted`/`:failed` (FR-024)
- [X] T052 [US3] Extend `FeatureDrawerComponent` (from T028) to surface the same resume/full-restart actions + phase-transcript link for any diverted/halted feature (FR-012, US3 Acceptance Scenario 5) — depends on T028
- [X] T053 [US3] Wire the nav Escalations count badge (built as a stub in T018) to the true count of `:escalated | :halted | :failed` features (FR-002) — depends on T018, T046

**Checkpoint**: Escalations independently resolves diverted features via the console; MVP + trigger + recovery now cover the three P1/P2 stories.

---

## Phase 6: User Story 4 - Inspect the dependency DAG (Priority: P3)

**Goal**: Pipeline DAG view renders features as nodes placed by dependency depth with prereq→dependent edges, a shared-palette legend, and drawer-on-click.

**Independent Test**: Open Pipeline DAG, confirm nodes placed by dependency depth, edges connect prereqs to dependents, node status/phase/spend match Mission Control (quickstart.md US4).

### Tests for User Story 4

- [X] T054 [P] [US4] Unit test for the layered-layout function (node depth = longest prereq chain; features with no prereqs at layer 0) against `test/fixtures/breakdown/` LedgerLite DAG, in `test/speckit_orchestrator/web/pipeline_dag_layout_test.exs`
- [X] T055 [P] [US4] LiveView test: each feature renders as a node with id/slug/phase progress/status/spend, edges from prereqs to dependents, legend maps colors to lifecycle states matching the shared palette (FR-025, FR-026, FR-034), in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`
- [X] T056 [P] [US4] LiveView test: clicking a node opens the same `FeatureDrawerComponent` as the Mission Control table row (FR-026), in the same test file

### Implementation for User Story 4

- [X] T057 [US4] Implement the pure layered-layout function (depth by longest prereq chain, edges from `prereqs`/`Backlog.dependents/1`) in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` or a small helper module alongside it
- [X] T058 [US4] Implement `SpeckitOrchestrator.Web.PipelineDagLive` in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` — route `/dag`; render nodes/edges as inline SVG/HTML, legend, node click opens `FeatureDrawerComponent` (depends on T057, T028, T018)

**Checkpoint**: DAG view works standalone, reusing the same drawer and palette as Mission Control.

---

## Phase 7: User Story 5 - Read phase transcripts (Priority: P3)

**Goal**: Transcripts view lets the operator pick a feature+phase and read the durable transcript with its source path, or see an explicit not-yet-written state.

**Independent Test**: Open Transcripts, pick a feature and phase, confirm the transcript renders with its source path shown (quickstart.md US5).

### Tests for User Story 5

- [X] T059 [P] [US5] LiveView test: selecting a feature+phase with an existing transcript renders its body + source path (FR-027), in `test/speckit_orchestrator/web/transcripts_live_test.exs`
- [X] T060 [P] [US5] LiveView test: selecting a phase the feature hasn't reached shows an explicit "not yet written" state, never a blank document (FR-028), in the same test file

### Implementation for User Story 5

- [X] T061 [US5] Implement a small read-only filesystem helper that globs `<transcript_root>/<feature_id>/*.md`, maps `NN-<phase>` filenames to phases, in `lib/speckit_orchestrator/web/live/transcripts_live.ex` or a sibling helper module (no change to write-only `Transcripts`)
- [X] T062 [US5] Implement `SpeckitOrchestrator.Web.TranscriptsLive` in `lib/speckit_orchestrator/web/live/transcripts_live.ex` — route `/transcripts`; feature+phase picker, renders markdown body + path, or the explicit not-yet-written state (depends on T061, T018)

**Checkpoint**: Transcripts browsable in-console without filesystem hunting.

---

## Phase 8: User Story 6 - Tune run configuration (Priority: P3)

**Goal**: Config view lets the operator set per-phase model routing, budget, max concurrency, and PR-workflow mode, applying forward-only to the live run.

**Independent Test**: Change budget and concurrency in Config, confirm the console reflects new values and the change affects only work not yet started (quickstart.md US6).

### Tests for User Story 6

- [X] T063 [P] [US6] Unit tests for `LiveConfig.apply/1` — bounds validation (budget ≥ 0, concurrency ≥ 1, model ∈ `{opus, sonnet}` per phase), reject → field error with no setter call (Fail Loud, Constitution II), in `test/speckit_orchestrator/live_config_test.exs`
- [X] T064 [P] [US6] Unit test: a valid model-routing change updates app env only (forward-only via `Config.model_for/1`'s call-time read), never alters a completed phase's recorded model (FR-032/FR-037), in the same test file
- [X] T065 [P] [US6] Unit test: a valid budget change calls `Ledger.set_budget/2` and a valid concurrency change calls `Coordinator.set_cap/2`, both forward-only per the invariants in `contracts/live_config.md`, in the same test file
- [X] T066 [P] [US6] LiveView test: Config view renders current model routing/budget/concurrency/PR settings, submits edits, and reflects them in the status bar/gauge post-apply with a toast (FR-029, FR-030, FR-005), in `test/speckit_orchestrator/web/config_live_test.exs`
- [X] T067 [P] [US6] LiveView test: enabling stacked PR workflow forces displayed effective concurrency to 1 and shows PR base/remote (FR-031), in the same test file

### Implementation for User Story 6

- [X] T068 [US6] Implement `SpeckitOrchestrator.LiveConfig.apply/1` in `lib/speckit_orchestrator/live_config.ex` — validates bounds, dispatches to the mechanism table in `contracts/live_config.md` (app-env put for models/PR settings, `Ledger.set_budget/2`, `Coordinator.set_cap/2`), returns `{:ok, change} | {:error, field_errors}` (depends on T013, T014)
- [X] T069 [US6] Implement `SpeckitOrchestrator.Web.ConfigLive` in `lib/speckit_orchestrator/web/live/config_live.ex` — route `/config`; renders `Config.*` + `Ledger.snapshot/1`; submits through `LiveConfig.apply/1`; broadcasts a reconcile + toast on success (FR-029..FR-032) (depends on T068, T018)
- [X] T070 [US6] Display PR base/remote (`Config.pr_base/0`, `Config.pr_remote/0`) and force effective-concurrency display to 1 when PR workflow is enabled (FR-031)

**Checkpoint**: All six views functional; operator never needs `iex` for the common cases.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Cross-view state-fidelity guarantees and final validation.

- [X] T071 [P] Cross-view test: change run state from a raw `Coordinator`/`Ledger` call (simulating an outside actor) while a LiveView is mounted, assert it converges to the true state within the reconcile tick (FR-033, SC-005), in `test/speckit_orchestrator/web/reconcile_test.exs`
- [X] T072 [P] Cross-view test: trip the breaker (low budget) and assert no new releases render, in-flight features drain to phase-end then halt between phases, and no view ever depicts a mid-phase kill (SC-007, Constitution IV), in the same test file
- [X] T073 [P] Cross-view test: no-active-run, empty backlog, invalid DAG, missing transcript, and missing/corrupt checkpoint each render a coherent state on their respective view — no broken layout, no silent blank (SC-006), in the same test file
- [X] T074 [P] Verify lifecycle colors and seven-phase order are identical across status strip, table, DAG, drawer, and escalations by asserting all consume the shared palette/`Pipeline.phases/0` from `core_components.ex` (FR-034) — add/extend an assertion in `test/speckit_orchestrator/web/layout_test.exs`
- [X] T075 Run `mise exec -- mix test` (full hermetic suite) and confirm `warnings_as_errors` compile stays clean — 357 passed, 0 failures, 4 excluded (integration)
- [X] T076 Run `mise exec -- mix test --include integration` if any integration-tagged tests were added, per quickstart.md — none of Phase 7-9's new tests are integration-tagged, so this is a no-op; skipped
- [X] T077 Walk through every scenario in `quickstart.md` manually against a real `mix phx.server` run (US1–US6 + cross-cutting) and record any gaps as follow-up tasks rather than silently accepting drift — see note below

**T077 note**: an `iex -S mix phx.server` node was already running on port 4000
from an earlier session (predating this implementation), so a fresh
`mix phx.server` bind failed with `:eaddrinuse`. Curl smoke-tested all six
routes (`/`, `/dag`, `/trigger`, `/escalations`, `/transcripts`, `/config`)
against that node — all returned `200`, and the no-active-run / all-clear
empty states rendered correctly — but the node has no `config/dev.exs`
`code_reloader`, so it was still serving pre-Phase-7 code for the
Transcripts/Config views (the old placeholder shells). The full `mix test`
suite (T075) exercises the real compiled Phase 7-9 modules end-to-end via
`Phoenix.LiveViewTest` and is the authoritative verification here.
**Follow-up**: restart the dev node (or add `config/dev.exs` with
`code_reloader: true`) and manually click through `quickstart.md`'s US5/US6
scenarios in a browser.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (PubSub, projection, reconcile, setters, shared chrome)
- **User Stories (Phase 3–8)**: All depend on Foundational completion
  - US1 (Phase 3) has no dependency on other stories — the MVP
  - US2 (Phase 4) and US3 (Phase 5) are independent of each other and of US1's internals, though both land the operator on Mission Control
  - US3 (Phase 5) extends the `FeatureDrawerComponent` built in US1 (T028) — sequence T028 before T052, or stub the drawer's resume/restart slot in T028 and fill it in T052
  - US4 (Phase 6) and US6 (Phase 8) reuse `FeatureDrawerComponent` (T028) and `LiveConfig`/setters (T013/T014) respectively
  - US5 (Phase 7) is fully independent (filesystem-only, no facade calls)
- **Polish (Phase 9)**: Depends on all six user stories being complete

### Within Each User Story

- Tests written first, expected to fail before implementation (Constitution test discipline)
- Read-model / pure helpers before the LiveView that renders them
- LiveView skeleton (mount/subscribe/seed) before its specific renders
- Story's checkpoint = independently functional and testable

### Parallel Opportunities

- T003/T004 (Setup) in parallel
- T007/T008 (pure fold + merge) in parallel; T013/T014 (setters) in parallel; T015/T016 (setter tests) in parallel
- All test tasks within a story marked [P] run in parallel (different assertions, same or sibling files — verify no file-write collision before parallelizing within one file)
- US2, US3, US5 implementation can proceed in parallel by different developers once Phase 2 is done (US4/US6 additionally need T028/T013/T014 respectively)

---

## Parallel Example: User Story 1

```bash
# Tests for US1 together:
Task: "LiveView test: mount seeds status-count strip + backlog table in test/speckit_orchestrator/web/mission_control_live_test.exs"
Task: "LiveView test: broadcast updates row without reload in test/speckit_orchestrator/web/mission_control_live_test.exs"
Task: "LiveView test: status bar reflects gauge/mode/armed-tripped in test/speckit_orchestrator/web/mission_control_live_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (PubSub, projection, reconcile tick, shared chrome — CRITICAL)
3. Complete Phase 3: User Story 1 (Mission Control)
4. **STOP and VALIDATE**: quickstart.md US1 scenario end-to-end against a real run
5. Demo: an operator watches a live backlog run with no `iex`

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 (Mission Control) → validate → demo (MVP)
3. US2 (Trigger) + US3 (Escalations) → validate each → demo (console is now self-sufficient for start + recover)
4. US4 (DAG) → US5 (Transcripts) → US6 (Config) → validate each → demo (full six-view console)
5. Polish (Phase 9) → cross-cutting fidelity + full quickstart walkthrough

### Parallel Team Strategy

1. Team completes Setup + Foundational together (shared plumbing, high-conflict surface)
2. Once Foundational is done:
   - Developer A: US1 (Mission Control) — unblocks the drawer for B/D
   - Developer B: US3 (Escalations) — coordinate on `FeatureDrawerComponent` (T028/T052)
   - Developer C: US2 (Trigger) — independent
   - Developer D: US5 (Transcripts) — fully independent, can start immediately after Foundational
3. US4 (DAG) and US6 (Config) follow once T028 / T013+T014 land

---

## Notes

- [P] tasks = different files or independently-verifiable assertions, no shared-state dependency
- [Story] label maps every phase-3+ task to US1–US6 for traceability back to spec.md
- Constitution I (Pure Core, Isolated Contracts): `ConsoleReadModel` and the DAG layout function stay pure — no Phoenix import — so T007/T008/T057 must not gain a LiveView dependency
- Constitution IV (drain, don't kill): T072 is the one test that directly proves this against the console layer
- Commit after each task or logical group per repository convention
- Avoid: vague tasks, same-file write conflicts inside a single [P] batch, cross-story dependencies that break independent testability (the one deliberate exception is the shared `FeatureDrawerComponent`, called out explicitly above)
