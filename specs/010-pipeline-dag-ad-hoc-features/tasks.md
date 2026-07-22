---

description: "Task list template for feature implementation"
---

# Tasks: Pipeline DAG Ad-Hoc Feature Visibility

**Input**: Design documents from `/specs/010-pipeline-dag-ad-hoc-features/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/dag-ad-hoc-render.md, quickstart.md (all present)

**Tests**: Included as first-class tasks. This repo's pure-core modules (`PipelineDagLayout`) carry a >90% coverage discipline (Constitution: Quality & Test Discipline), and the existing `pipeline_dag_layout_test.exs` / `pipeline_dag_live_test.exs` already test this exact area — tests are written before their corresponding implementation task (TDD), not appended after.

**Organization**: Tasks are grouped by user story (spec.md priorities P1/P2/P3) so each can be implemented, tested, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no unmet dependency)
- **[Story]**: US1 / US2 / US3, per spec.md
- File paths are exact, relative to repo root

## Path Conventions (single project)

- `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` — the LiveView (render)
- `lib/speckit_orchestrator/web/live/pipeline_dag_layout.ex` — the pure layout module
- `test/speckit_orchestrator/web/pipeline_dag_layout_test.exs` — pure-layout tests
- `test/speckit_orchestrator/web/pipeline_dag_live_test.exs` — LiveView render/interaction tests

No other files are touched — `feature_drawer.ex`, `core_components.ex` (status_pill/phase_strip/palette), `run_spec/2`, `SingleSpec`, and `Backlog.load!` are reused unchanged (spec FR-007, plan Structure Decision).

---

## Phase 1: Setup

Not applicable — no new project, dependency, or scaffolding is introduced. The
feature modifies two existing modules already wired into the running app
(`mise exec -- mix compile` / `mise exec -- mix test` already cover them).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure set-difference + lane-positioning helper every user story
renders from. Nothing in Phase 3+ can be implemented correctly without it.

**⚠️ CRITICAL**: Complete before any user-story task.

- [X] T001 Add failing unit tests for the ad-hoc lane helper's contract (C1–C7
  in `contracts/dag-ad-hoc-render.md`) to
  `test/speckit_orchestrator/web/pipeline_dag_layout_test.exs`: empty when live
  ids ⊆ backlog node ids (C1); one orphan node per absent id, `origin: :ad_hoc`,
  `depth: 0`, `prereqs: []` (C2); N absent ids → N nodes at distinct positions
  (C3); an id present in both sets resolves to backlog-only, absent from the
  ad-hoc lane (C4, VR-1); an ad-hoc id numerically adjacent to a backlog id is
  still classified correctly by set membership (C5, VR-3); a `nil` slug is
  tolerated without raising (C6, VR-4); the function takes plain data and makes
  no process/Phoenix call (C7).
- [X] T002 Implement the pure ad-hoc lane helper (e.g.
  `PipelineDagLayout.ad_hoc_nodes/2`) in
  `lib/speckit_orchestrator/web/live/pipeline_dag_layout.ex` to satisfy T001:
  takes the backlog `dag_layout` and the live `per_feature` map, returns
  `%{nodes: [ad_hoc_node()]}` per the type in
  `contracts/dag-ad-hoc-render.md` — computed independently of the existing
  `layout/1`/`position/1` backlog math so backlog geometry is provably
  unaffected (depends on T001).

**Checkpoint**: `mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_layout_test.exs` green. Ready for user-story work.

---

## Phase 3: User Story 1 - See an ad-hoc run on the DAG (Priority: P1) 🎯 MVP

**Goal**: Every feature in the live run's `per_feature` state — backlog or
ad-hoc — renders as a node on `/dag`, with live status and spend.

**Independent Test**: Trigger a single-spec run for a description not in the
backlog; open `/dag` while it runs and again after it finishes; confirm a node
appears in both cases with status/spend matching Mission Control (spec US1).

### Tests for User Story 1

- [X] T003 [US1] Add a failing test to
  `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: start
  `Coordinator` with a `per_feature`-visible id absent from the backlog fixture
  (`@valid_dir`, ids `001`–`007`); mount `/dag`; assert a
  `data-dag-node={id}` element renders inside the ad-hoc lane container (e.g.
  `data-state="ad-hoc-lane"`) showing that id's live `status_pill` and spend;
  update the feature to a terminal status via the existing
  `{:console, :feature_updated, …}` path and assert the node reflects it
  (FR-001, FR-003; spec US1 scenarios 1–2).

### Implementation for User Story 1

- [X] T004 [US1] In
  `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`, render the ad-hoc
  lane: call the T002 helper with `@dag_layout` and `@view.per_feature`, and
  `:for`-iterate its nodes in a dedicated section (sibling to the existing
  `data-state="dag"` plane, not nested in it) — each node showing
  `data-dag-node={id}`, `<.status_pill status={node_status(@view, id)}/>`,
  `<.phase_strip .../>`, and the spend cell exactly as the existing backlog
  node markup does, sourced from `@view.per_feature[id]` (depends on T002,
  T003).
- [X] T005 [US1] Guard the whole ad-hoc lane section (and, later, its legend
  entry) on the T002 helper returning a non-empty node list, so a run with no
  ad-hoc feature emits zero additional DOM; add a regression test to
  `test/speckit_orchestrator/web/pipeline_dag_live_test.exs` asserting no
  `data-state="ad-hoc-lane"` element is present when `per_feature` is a subset
  of the backlog, and that the existing backlog node/edge/legend assertions in
  that file still pass unchanged (FR-006, SC-004).

**Checkpoint**: `mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs` green. US1 fully functional and independently demoable.

---

## Phase 4: User Story 2 - Inspect an ad-hoc feature from the DAG (Priority: P2)

**Goal**: Clicking an ad-hoc node opens the same feature drawer, with the same
detail and recovery actions, as any backlog node.

**Independent Test**: With an ad-hoc node visible, click it and confirm the
same drawer component opens with that feature's real detail (spec US2).

**Design note**: `select_feature`/`feature_drawer` already key generically off
a feature id (`lib/speckit_orchestrator/web/live/pipeline_dag_live.ex:104-110,176-181`)
and the ad-hoc node markup added in T004 carries the same
`phx-click="select_feature" phx-value-id={id}` as backlog nodes — so FR-004 is
satisfied by reuse, not new code (research.md Decision 5). This phase is
verification-only.

### Tests for User Story 2

- [X] T006 [US2] Add a test to
  `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: with an ad-hoc
  node on `/dag`, `render_click(view, "select_feature", %{"id" => ad_hoc_id})`
  and assert the same `id="feature-drawer"` / `data-feature-id={ad_hoc_id}`
  markup renders as it does for a backlog id, showing that feature's phase
  timeline, elapsed time, and spend (FR-004; spec US2 scenario 1).
- [X] T007 [P] [US2] Add a test to the same file: an ad-hoc feature seeded with
  `status: :escalated` (or `:halted`) exposes the same resume/restart actions
  in its drawer as an escalated/halted backlog feature does today (FR-004;
  spec US2 scenario 2).

**Checkpoint**: US1 + US2 both independently functional; no production code changed in this phase.

---

## Phase 5: User Story 3 - Tell ad-hoc and backlog nodes apart at a glance (Priority: P3)

**Goal**: An operator can visually distinguish an ad-hoc node from a backlog
node without opening its drawer, via both a per-node marker and a legend
entry distinct from the lifecycle-status colors.

**Independent Test**: With both backlog and ad-hoc nodes on `/dag`, confirm the
legend explains the ad-hoc marker and each node is identifiable by origin
without clicking in (spec US3).

### Tests for User Story 3

- [X] T008 [US3] Add failing tests to
  `test/speckit_orchestrator/web/pipeline_dag_live_test.exs`: every backlog
  node carries `data-node-origin="backlog"`; every ad-hoc node carries
  `data-node-origin="ad-hoc"` plus a visible marker element (e.g.
  `data-adhoc-badge`); the legend contains a `data-legend-origin="ad-hoc"`
  entry separate from the `data-legend-status` swatches; none of the above
  (marker attribute aside) appear when no ad-hoc feature is present (FR-005;
  spec US3 scenarios 1–2; contracts/dag-ad-hoc-render.md §2).

### Implementation for User Story 3

- [X] T009 [US3] In
  `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`, add
  `data-node-origin="backlog"` to the existing backlog node markup and
  `data-node-origin="ad-hoc"` plus a visible badge/border element to the
  ad-hoc node markup added in T004 (depends on T004, T008).
- [X] T010 [US3] In the same file, add a dedicated ad-hoc legend entry
  (`data-legend-origin="ad-hoc"`) rendered after/outside the existing
  `palette/0` status-swatch loop, guarded on the ad-hoc lane being non-empty
  (same guard as T005) so it is absent when no ad-hoc feature is live (depends
  on T005, T008).

**Checkpoint**: All three user stories independently functional. `mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs` green.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T011 [P] Run `mise exec -- mix test` (full suite, `warnings_as_errors`)
  to confirm zero regressions outside the DAG modules.
- [X] T012 Walk through the manual validation steps in `quickstart.md`
  (trigger a real single-spec run via the console, confirm the ad-hoc node
  appears/updates/is clickable on `/dag` matching Mission Control) to close
  SC-001–SC-004 end-to-end. Live browser walkthrough skipped (port 4000 held
  by an unrelated running beam process — left untouched); SC-001–SC-004 are
  each independently asserted by the automated LiveView tests instead
  (node-per-`per_feature`-id, live status/spend, click-to-drawer, ad-hoc vs
  backlog distinguishability), which is the manual section's own stated
  fallback ("optional").

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 2)**: No dependencies (Setup is not applicable) — BLOCKS all user stories.
- **User Story 1 (Phase 3)**: Depends on Phase 2 (T002). MVP — deliver first.
- **User Story 2 (Phase 4)**: Depends on Phase 3 (T004's node markup carries the click wiring US2 verifies). No new implementation of its own.
- **User Story 3 (Phase 5)**: Depends on Phase 3 (T004, T005's guard). Independent of Phase 4.
- **Polish (Phase 6)**: Depends on whichever stories are in scope for the release being validated.

### Task-Level Dependencies

- T002 depends on T001 (test-first).
- T004 depends on T002 (helper must exist) and T003 (test-first).
- T005 depends on T004 (guards the section T004 renders).
- T006, T007 depend on T004 (click wiring lives in the node markup it adds).
- T009 depends on T004 and T008 (test-first); T010 depends on T005 and T008.
- T011, T012 depend on all preceding phases in scope.

### Parallel Opportunities

- T007 can run alongside T006 (same file, additive assertions, no shared mutable state within the test).
- T011 can run in parallel with T012 (automated suite vs. manual walkthrough).
- Phase 4 (US2) and Phase 5 (US3) can proceed in parallel once Phase 3 is done — different concerns (drawer reuse vs. marker/legend) in the same file, so coordinate edit order to avoid merge conflicts if staffed by two people.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 2: Foundational (T001–T002).
2. Phase 3: User Story 1 (T003–T005).
3. **STOP and VALIDATE**: `mise exec -- mix test test/speckit_orchestrator/web/`; confirm SC-001/SC-002 manually with a single-spec run.
4. This alone closes the reported gap (spec's primary complaint).

### Incremental Delivery

1. Foundational → US1 (MVP: ad-hoc nodes visible with live status/spend).
2. US2 (verification only — drawer already works via reuse).
3. US3 (marker + legend — polish for at-a-glance distinction).
4. Polish (T011–T012).

---

## Notes

- [P] tasks touch different files or additive, non-conflicting regions of the same test file.
- Tests precede their implementation task within each phase (TDD), per this repo's existing convention in `pipeline_dag_layout_test.exs` / `pipeline_dag_live_test.exs`.
- Commit after each task or logical group; stop at any checkpoint to validate independently.
- No task touches `feature_drawer.ex`, `core_components.ex`, `run_spec/2`, `SingleSpec`, `Backlog`, or the `docs/breakdown/` directory (FR-007).
