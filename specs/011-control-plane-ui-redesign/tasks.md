---

description: "Task list for Control Plane UI Redesign"
---

# Tasks: Control Plane UI Redesign

**Input**: Design documents from `/specs/011-control-plane-ui-redesign/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/design-system.md, quickstart.md

**Tests**: This is a presentation-only change (FR-020) over an already-tested feature (008-control-plane). No new test tasks are added; each user story's tasks include updating the *existing* LiveView tests in lockstep so they assert on the stable hooks in contracts/design-system.md §4 instead of incidental markup, keeping the suite green throughout (per quickstart.md).

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P6) so each story ships and is independently verifiable via its Independent Test.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps task to its user story (US1–US6)
- File paths are exact and relative to repo root

## Path Conventions

Single Elixir app. Web layer: `lib/speckit_orchestrator/web/`. Web tests: `test/speckit_orchestrator/web/`. New static assets: `priv/static/assets/`, `priv/static/fonts/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Land the static asset pipeline the whole redesign depends on — no page can be restyled until `console.css` exists and is served, and fonts are self-hosted.

- [X] T001 Download/vendor IBM Plex Sans (400/500/600/700) and IBM Plex Mono (400/500/600) `.woff2` files (OFL-1.1) into `priv/static/fonts/` (e.g. `ibm-plex-sans-400.woff2` … `ibm-plex-mono-600.woff2`)
- [X] T002 [P] Extend `plug(Plug.Static, at: "/assets", ...)` `only:` list in `lib/speckit_orchestrator/web/endpoint.ex` from `~w(app.js)` to include `console.css`, and add a new `plug(Plug.Static, at: "/fonts", from: :speckit_orchestrator, only: ~w(<the woff2 filenames>))` mount
- [X] T003 Create `priv/static/assets/console.css` with the design-system tokens from contracts/design-system.md §1–§3: `:root` custom properties (`--bg`, `--panel`, `--border`, `--border-strong`, `--text`, `--muted`, `--accent`, `--accent-2`, `--link`, `--selection`), `@font-face` rules for all seven self-hosted woff2 weights, base resets, and the `App frame` / `Content column` / scrollbar rules from contracts/design-system.md §3
- [X] T004 [US1] Update `lib/speckit_orchestrator/web/components/layouts/root.html.heex` to `<link rel="stylesheet" href="/assets/console.css">` and `<link rel="preload" as="font" type="font/woff2" crossorigin>` hints for the two hero weights (IBM Plex Sans 400, IBM Plex Mono 400), per contracts/design-system.md §5

**Checkpoint**: `console.css` and fonts are served with zero external network calls (FR-021); no page markup changed yet.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The single shared status palette and the primitives every page renders through (status pill, phase strip, cost gauge) must move to the reference's colors before any per-page restyle, since INV-1 requires one palette driving every view.

**⚠️ CRITICAL**: No user-story phase (3–8) may start until this phase is complete.

- [X] T005 Replace the seven `@palette` entries in `lib/speckit_orchestrator/web/components/core_components.ex` with the reference `COLORS` values from data-model.md (`pending #64748b`, `blocked #475569`, `running #38bdf8`, `escalated #fbbf24`, `halted #fb7185`, `failed #f43f5e`, `done #34d399`), keeping the same atom keys and labels
- [X] T006 Update `gauge_color/2` thresholds in `lib/speckit_orchestrator/web/components/core_components.ex` to source colors from the new palette family (`>= 90%` or `tripped?` → `#fb7185`/`#f43f5e` family, `70–90%` → `#fbbf24`, `< 70%` → `#34d399`) without changing the threshold percentages (FR-020); and render `reserved` spend as a **visually distinguished** segment in `cost_gauge/1` (FR-003) — the gauge currently lumps `committed + reserved` into one `cost-gauge-fill`, so split it into a committed fill plus a distinct reserved overlay/segment (e.g. `cost-gauge-reserved`) using the already-passed `committed`/`reserved`/`budget` attrs, keeping the existing `cost-gauge`/`cost-gauge-fill`/`cost-gauge-label` hooks intact
- [X] T007 [P] Add `console.css` rules for `.status-pill`, `.phase-strip` / `.phase-cell` (per-state classes matching `phase_cell_state/2` output: `pending`, `active`, `completed`, `escalated`, `halted`, `failed`), `.cost-gauge` / `.cost-gauge-fill` / the distinguished reserved segment (`.cost-gauge-reserved`, FR-003) / `.cost-gauge-label`, `.badge` / `.badge-warn`, and `.toast` in `priv/static/assets/console.css`, preserving the existing class/`data-*` hooks in `core_components.ex` unchanged
- [X] T008 Run `mise exec -- mix test test/speckit_orchestrator/web` and fix any assertion that hard-coded an old hex color; do not relax behavioral assertions (only literal color-value checks may need updating)

**Checkpoint**: One palette drives every status color; shared primitives render in the reference colors. Per-page restyle can now begin.

---

## Phase 3: User Story 1 - Consistent console shell (Priority: P1) 🎯 MVP

**Goal**: Persistent left sidebar (branding, connection status, six nav links with active-state and escalation badge) and top bar (run state/title/mode/concurrency, cost gauge, breaker chip, live clock), all in the reference visual design.

**Independent Test**: Load any console route; sidebar highlights the active section and shows an escalation-count badge when escalations are open; top bar cost gauge/breaker chip/clock reflect live state (or a "no active run" state).

- [X] T009 [US1] Add `console.css` rules for the sidebar (`236px` fixed width, `--panel` background, `--border` right divider, `18px 14px` padding, full-height non-scrolling column), the gradient logo mark (`30×30`, `8px` radius, `linear-gradient(140deg, #7c5cff, #4b2fd6)`, inner rotated square, shadow per contracts/design-system.md §3), and nav-item styling (`.nav-active` = accent) in `priv/static/assets/console.css`
- [X] T010 [US1] Add `console.css` rules for the top bar (run title/mode/concurrency layout, breaker chip states, live clock) matching the reference's top-bar structure in `priv/static/assets/console.css`
- [X] T011 [US1] Rewrite `lib/speckit_orchestrator/web/components/layouts/app.html.heex` sidebar markup to the reference structure: logo mark, product name, `Layouts.context/0`-driven connection/target-repo status, `Layouts.nav_items/0`-driven links with nav glyphs (`◧ ⊟ ▷ ⚠ ≡ ⚙` per contracts/design-system.md §3) and `class="nav-active"` on the current route, and the Escalations link's `class="badge-warn"` count badge driven by `Layouts.escalations_count/0` — preserving all existing hooks (contracts/design-system.md §4)
- [X] T012 [US1] Rewrite the top-bar markup in `lib/speckit_orchestrator/web/components/layouts/app.html.heex` to render `Layouts.run_view/0`'s run title/mode/concurrency, the `cost_gauge` component, breaker chip, and live clock, with the "No active run" state when `active? == false` (FR-004), preserving the `cost-gauge`/`cost-gauge-fill`/`cost-gauge-label` hooks
- [X] T013 [US1] Update `test/speckit_orchestrator/web/layout_test.exs` in lockstep: keep all assertions on `nav-active`, `badge-warn`, `cost-gauge`/`cost-gauge-label`, and the "No active run"/"Active run"/"armed"/"tripped" text hooks (contracts/design-system.md §4); adjust only assertions that keyed off markup structure the rewrite changed
- [X] T014 [US1] Run `mise exec -- mix test test/speckit_orchestrator/web/layout_test.exs` and `mise exec -- mix phx.server` to manually verify quickstart.md Scenario 1 (shell, badge, gauge, no-active-run state, no font-CDN request)

**Checkpoint**: Shell (sidebar + top bar) matches the reference design system on every route. This is independently shippable and establishes the visual language for all remaining stories.

---

## Phase 4: User Story 2 - Mission Control at-a-glance status (Priority: P2)

**Goal**: Status-count summary cards, a colored/labeled backlog table with seven-phase progress, and a live telemetry feed, styled to the reference.

**Independent Test**: With a run active, open Mission Control; status-count cards match live counts per status, backlog rows show live-updating phase progress/elapsed/spend, and the telemetry feed appends events without reload.

- [X] T015 [US2] Add `console.css` rules for the status-count card grid, the backlog table (row coloring/labels, phase-progress cell layout), the telemetry feed panel, the two-column layout, and its `@media (max-width: 1120px)` single-column collapse (Edge Cases) in `priv/static/assets/console.css`
- [X] T016 [US2] Rewrite `lib/speckit_orchestrator/web/live/mission_control_live.ex` templates: one summary card per lifecycle status with live count and palette color, a backlog table row per feature (id, slug, `status_pill`, `phase_strip`, elapsed, spend) that opens the feature drawer on click, and a scrollable live telemetry feed bounded to its fixed max entries — preserving all existing assigns/events (FR-020)
- [X] T017 [US2] Add the styled empty state to `lib/speckit_orchestrator/web/live/mission_control_live.ex` for when no run is active, directing the operator to Trigger Run
- [X] T018 [US2] Update `test/speckit_orchestrator/web/mission_control_live_test.exs` in lockstep: assert on `status_pill`/`data-status`, `phase_strip`/`data-phase`, and row-click-opens-drawer behavior rather than incidental table markup
- [X] T019 [US2] Run `mise exec -- mix test test/speckit_orchestrator/web/mission_control_live_test.exs` and manually verify quickstart.md Scenario 2

**Checkpoint**: Mission Control (the primary landing view) is fully restyled and independently verifiable.

---

## Phase 5: User Story 3 - Pipeline DAG visualization (Priority: P3)

**Goal**: Feature nodes arranged by dependency wave with bezier edges to prerequisites, each node showing id/slug/status/phase progress/spend, plus a status color legend.

**Independent Test**: Open Pipeline DAG with a multi-feature backlog; every feature is a node positioned by wave, edges connect to prerequisites, and the legend matches the shared status colors.

- [X] T020 [US3] Add `console.css` rules for the SVG DAG canvas and the status legend (color swatch + label per status, using the shared palette) in `priv/static/assets/console.css`
- [X] T021 [P] [US3] Extend `lib/speckit_orchestrator/web/live/pipeline_dag_layout.ex` (if needed) to expose explicit pixel coordinates per node so the template can draw bezier edges (`M x1,y1 C mx,y1 mx,y2 x2,y2`) without changing the existing wave/column math
- [X] T022 [US3] Rewrite `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` to render an inline SVG: one node per feature (id, slug, `status_pill` color as fill/stroke, phase progress, spend) positioned by dependency wave, one bezier edge per prerequisite relationship, a status legend, and click-to-open-drawer behavior — preserving existing assigns/events
- [X] T023 [US3] Update `test/speckit_orchestrator/web/pipeline_dag_live_test.exs` and `test/speckit_orchestrator/web/pipeline_dag_layout_test.exs` in lockstep to assert on the SVG node/edge/legend structure and the stable `data-status`/`data-phase` hooks rather than the prior unstyled listing markup
- [X] T024 [US3] Run `mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs test/speckit_orchestrator/web/pipeline_dag_layout_test.exs` and manually verify quickstart.md Scenario 3

**Checkpoint**: Pipeline DAG renders the reference's node/edge/legend visualization.

---

## Phase 6: User Story 4 - Escalation review and resolution (Priority: P4)

**Goal**: One structured card per escalated/halted feature with checkpoint fields, run-context values, the triggering clarification question(s), and resume/full-restart actions.

**Independent Test**: With ≥1 escalated feature, open Escalations; checkpoint fields, run-context values, and clarification question(s)/options render correctly, and resume/resolve trigger the existing underlying actions unchanged.

- [X] T025 [US4] Add `console.css` rules for the escalation card layout (checkpoint field list, run-context value list, clarification question/options block, resume form, full-restart control) and the empty/success state in `priv/static/assets/console.css`
- [X] T026 [US4] Rewrite `lib/speckit_orchestrator/web/live/escalations_live.ex` templates: one card per escalated/halted feature showing last phase, status, session id, reason, run-context values, and clarification question(s)/options (FR-011), a resume action (optional guidance text + start-phase override) and full-restart action invoking the existing handlers unchanged, plus a link to the relevant phase transcript
- [X] T027 [US4] Add the styled empty/success state to `lib/speckit_orchestrator/web/live/escalations_live.ex` for zero open escalations (FR-013)
- [X] T028 [US4] Update `test/speckit_orchestrator/web/escalations_live_test.exs` in lockstep to assert on the card's data hooks and unchanged resume/resolve event names rather than the prior unstyled listing markup
- [X] T029 [US4] Run `mise exec -- mix test test/speckit_orchestrator/web/escalations_live_test.exs` and manually verify quickstart.md Scenario 4

**Checkpoint**: Escalations page fully restyled; the human-in-the-loop gate keeps its exact behavior.

---

## Phase 7: User Story 5 - Feature drawer detail (Priority: P5)

**Goal**: Phase-by-phase timeline with consistent status coloring, elapsed/spend/prerequisite summary, and context-appropriate actions (transcript always; resume/open-escalation when escalated/halted; view-PR when done).

**Independent Test**: Open the drawer for features in different statuses (running, escalated, done); timeline, summary stats, and action set match that feature's actual state.

- [X] T030 [US5] Add `console.css` rules for the drawer panel (timeline layout using the shared status palette, summary stat row, action button row) in `priv/static/assets/console.css`
- [X] T031 [US5] Rewrite `lib/speckit_orchestrator/web/components/feature_drawer.ex` to render the phase-by-phase timeline (using `phase_strip`/palette coloring), elapsed/spend/prerequisite summary, and the context-appropriate action set (open transcript always; resume + open-escalation when escalated/halted; view-PR when done) — preserving existing assigns/events (FR-020)
- [X] T032 [US5] Update drawer assertions in `test/speckit_orchestrator/web/pipeline_dag_live_test.exs` and `test/speckit_orchestrator/web/layout_test.exs` (wherever the drawer is currently exercised) in lockstep to assert on the timeline's status-color hooks and the correct action set per status
- [X] T033 [US5] Run the affected test files and manually verify quickstart.md Scenario 5 across running/escalated/done features

**Checkpoint**: Feature drawer restyled and consistent with Mission Control/DAG/Escalations status coloring.

---

## Phase 8: User Story 6 - Trigger, Transcripts, and Configuration pages (Priority: P6)

**Goal**: Trigger Run (backlog vs. single-spec tabs), Transcripts (per-feature/per-phase browsing), and Configuration (model routing, budget, concurrency, PR toggle) restyled to the reference's forms/tabs/sliders/toggles.

**Independent Test**: Open each of the three pages independently; existing functionality (start run in either mode, select feature/phase transcript, change model routing/budget/concurrency/PR toggle) still works with the new styled controls.

- [X] T034 [P] [US6] Add `console.css` rules for tabs/mode-switch controls, forms, sliders, and toggles matching the reference in `priv/static/assets/console.css`
- [X] T035 [P] [US6] Rewrite `lib/speckit_orchestrator/web/live/trigger_live.ex` templates: styled Backlog/Single-spec tab switch preserving existing start-run event handlers for each mode
- [X] T036 [P] [US6] Rewrite `lib/speckit_orchestrator/web/live/transcripts_live.ex` templates: styled feature list + per-phase tabs, preserving existing selection events and transcript-body rendering
- [X] T037 [P] [US6] Rewrite `lib/speckit_orchestrator/web/live/config_live.ex` templates: styled per-phase model routing controls, budget/concurrency controls, and PR-workflow toggle, preserving existing live-config update events
- [X] T038 [US6] Update `test/speckit_orchestrator/web/trigger_live_test.exs`, `test/speckit_orchestrator/web/transcripts_live_test.exs`, and `test/speckit_orchestrator/web/config_live_test.exs` in lockstep to assert on unchanged event names/behavior rather than the prior unstyled markup
- [X] T039 [US6] Run `mise exec -- mix test test/speckit_orchestrator/web/trigger_live_test.exs test/speckit_orchestrator/web/transcripts_live_test.exs test/speckit_orchestrator/web/config_live_test.exs` and manually verify quickstart.md Scenario 6

**Checkpoint**: All six console pages + shell + drawer now render the reference design system (SC-002).

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Final verification that the redesign is complete, behavior-preserving, and free of external network dependencies.

- [X] T040 Run `mise exec -- mix compile` and confirm zero warnings (`warnings_as_errors`)
- [X] T041 Run `mise exec -- mix test` (full suite) and confirm all tests green, including `test/speckit_orchestrator/web/reconcile_test.exs`
- [X] T042 [P] Manually load the console with the browser network panel open (or offline) and confirm zero requests to `fonts.googleapis.com`/`fonts.gstatic.com` (INV-3/FR-021)
- [X] T043 [P] Manually narrow the browser window below ~1120px and confirm Mission Control's two-column layout collapses to one column, long slugs/session ids truncate with ellipsis, and lists scroll within their container (Edge Cases)
- [X] T044 Walk quickstart.md's full "Done when" checklist end-to-end and confirm every item

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (single shared palette/primitives)
- **User Stories (Phase 3–8)**: All depend on Foundational; may then proceed in priority order (P1→P6) or in parallel across developers, each independently testable
- **Polish (Phase 9)**: Depends on all desired user stories being complete

### User Story Dependencies

- **US1 (P1)**: After Foundational — no dependency on other stories; establishes the shell every other page renders inside
- **US2 (P2)**: After Foundational — independent of US1's page content, but visually sits inside the US1 shell
- **US3 (P3)**: After Foundational — independent; reuses the shared palette/legend
- **US4 (P4)**: After Foundational — independent
- **US5 (P5)**: After Foundational — the drawer is opened from US2/US3, but its own restyle is independent
- **US6 (P6)**: After Foundational — three independent pages, can be split across developers (all marked `[P]`)

### Within Each User Story

- CSS rules before template rewrite (so classes exist when referenced)
- Template rewrite before its lockstep test update
- Test update before the story's verification run

### Parallel Opportunities

- T002 (endpoint static config) can run in parallel with T003 (console.css authoring)
- T007 (shared-primitive CSS) can run in parallel with the palette/gauge code edits (T005/T006) since they touch different files
- T021 (DAG layout coords) can run in parallel with T020 (DAG CSS)
- US6's three pages (T035, T036, T037) are fully parallel — different files, no shared state
- Once Foundational is done, US1–US6 phases can be staffed and executed in parallel by different developers

---

## Parallel Example: User Story 6

```bash
# Launch all three page restyles together (different files, no dependencies):
Task: "Rewrite lib/speckit_orchestrator/web/live/trigger_live.ex templates"
Task: "Rewrite lib/speckit_orchestrator/web/live/transcripts_live.ex templates"
Task: "Rewrite lib/speckit_orchestrator/web/live/config_live.ex templates"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — blocks all stories)
3. Complete Phase 3: User Story 1 (shell)
4. **STOP and VALIDATE**: quickstart.md Scenario 1 passes, `layout_test.exs` green
5. Demo: every route now shows the restyled shell even though inner pages are still old markup

### Incremental Delivery

1. Setup + Foundational → shared tokens/palette ready
2. US1 (shell) → validate → demo (MVP)
3. US2 (Mission Control) → validate → demo
4. US3 (Pipeline DAG) → validate → demo
5. US4 (Escalations) → validate → demo
6. US5 (Feature drawer) → validate → demo
7. US6 (Trigger/Transcripts/Configuration) → validate → demo
8. Polish → full suite green, quickstart.md fully checked off

---

## Notes

- `[P]` tasks touch different files with no dependency on an incomplete task in the same phase
- `[Story]` label maps each task to its user story for traceability
- No new tests are added (presentation-only feature); existing tests are updated in lockstep to assert on the stable hooks in contracts/design-system.md §4, per FR-020/INV-2
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently before moving to the next
- Avoid: touching route/event/assign/PubSub code (INV-2), reintroducing a second palette map (INV-1), any runtime font-CDN request (INV-3)
