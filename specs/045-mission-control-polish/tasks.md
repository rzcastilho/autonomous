# Tasks: Mission Control Polish

**Input**: Design documents from `/specs/045-mission-control-polish/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/mission-control-ui.md, quickstart.md

**Tests**: Included — plan.md lists LiveViewTest updates per story and the contract defines stable selectors. The `TelemetryPref` JS hook has no JS test runner (constitution forbids a build step); it is verified manually via quickstart Q3.

**Organization**: Grouped by user story. All commands run through `mise exec --` (`warnings_as_errors` is on). Source root: `lib/autonomous/web/`; tests: `test/autonomous/web/`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1..US5 from spec.md
- Several stories edit `mission_control_live.ex` and `console.css`; tasks touching the same file are NOT marked [P] and must run in listed order.

---

## Phase 1: Setup

**Purpose**: Establish a green baseline.

- [X] T001 Run `mise exec -- mix compile` and `mise exec -- mix test test/autonomous/web/` from repo root; confirm green before any edit, and note which tests in `test/autonomous/web/mission_control_live_test.exs` and `test/autonomous/web/conversation_live_test.exs` reference `data-live-session`, `live_sessions`, `table.backlog-table + section[data-live-panel]`, `.conv-follow`, `.conv-frames`, `#conversation-rows` (these are updated in later tasks)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared CSS tokens/classes used by several stories.

**⚠️ CRITICAL**: Complete before user stories.

- [X] T002 In `priv/static/assets/console.css`, add two layout tokens to the single `:root` block beside the feature-033 layout tokens: `--cell-truncate-max: 28ch;` and `--phase-strip-min: 168px;` (research R9)
- [X] T003 In `priv/static/assets/console.css`, add `.btn-compact { padding: var(--sp-6) var(--sp-12); }` (padding only, no font-size change) and `.btn-secondary:focus-visible, .btn-link:focus-visible { outline: 1px solid var(--accent); outline-offset: 2px; }` (research R7; `--accent` as outline, not text, so G-contrast holds)
- [X] T004 Run `mise exec -- mix test test/autonomous/web/design_contract_test.exs`; confirm still green with no allowlist entry added

**Checkpoint**: Tokens and button styles ready.

---

## Phase 3: User Story 1 - Main panel never hides behind telemetry (Priority: P1) 🎯 MVP

**Goal**: Backlog table, phase strip and embedded panel header never paint under the telemetry feed.

**Independent Test**: Open `/` with a run in flight with long slugs at widths down to 1120px; nothing under the feed, slugs ellipsize with `title`, pips intact, scroll only inside the table container (quickstart Q1).

### Tests for User Story 1

- [X] T005 [P] [US1] In `test/autonomous/web/mission_control_live_test.exs`, add tests: backlog table is wrapped (`.mission-main .backlog-scroll > table.backlog-table`); slug cell has `td.cell-secondary .cell-truncate[title]` equal to the full slug; `td.cell-progress .phase-strip` present; `.mc-live-panel .conv-header[title]` equals the header text; update the structural selector to `.mission-main .backlog-scroll + section[data-live-panel]`

### Implementation for User Story 1

- [X] T006 [US1] In `lib/autonomous/web/live/mission_control_live.ex`, wrap the backlog `<table class="backlog-table">` in `<div class="backlog-scroll">` and render the slug cell content as `<span class="cell-truncate" title={slug}>…</span>` inside `td.cell-secondary`
- [X] T007 [US1] In `lib/autonomous/web/live/conversation_live.ex`, add `title={header_line}` (full header text) to the `.conv-header` element so the ellipsized line reveals full text (used by both embedded and `/live`; `/live` markup otherwise unchanged)
- [X] T008 [US1] In `priv/static/assets/console.css`, add: `.backlog-scroll { overflow-x: auto; }`; `.cell-truncate { display: block; max-width: var(--cell-truncate-max); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }`; `.cell-progress { min-width: var(--phase-strip-min); }`; `.mc-live-panel .conv-header { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }` (research R1)
- [X] T009 [US1] Run `mise exec -- mix test test/autonomous/web/mission_control_live_test.exs test/autonomous/web/conversation_live_test.exs test/autonomous/web/design_contract_test.exs`; fix until green

**Checkpoint**: Overlap defect fixed; MVP deliverable.

---

## Phase 4: User Story 2 - Hide and show the telemetry feed (Priority: P1)

**Goal**: Operator can collapse/restore the feed; choice persists per browser; delayed notice stays visible.

**Independent Test**: Hide → main panel full width, "show telemetry" beside status strip; show → feed returns with buffered events; reload keeps choice (quickstart Q2–Q4).

### Tests for User Story 2

- [X] T010 [P] [US2] In `test/autonomous/web/mission_control_live_test.exs`, add tests per contract §2: default shown (`.mission-grid[data-telemetry="shown"]`, `#mission-feed`, `[data-telemetry-toggle="hide"][aria-expanded="true"]` in `.mission-feed-header`, no show control); `telemetry_hide` → hidden state (`[data-telemetry-toggle="show"][aria-expanded="false"]` in `.mission-main-head`, no `#mission-feed`, no hide control, `data-telemetry="hidden"`) and `assert_push_event "telemetry_pref", %{hidden: true}`; `telemetry_show` restores; feed entries received while hidden appear after show (FR-004); `telemetry_restore` with `%{"hidden" => true}` hides without push, any other params leave state unchanged; `[data-console-delayed]` is inside `#mission-feed` when shown and inside `.mission-main` before `.mission-main-head` when hidden; `#mission-live` carries `phx-hook="TelemetryPref"`

### Implementation for User Story 2

- [X] T011 [US2] In `lib/autonomous/web/live/mission_control_live.ex`, add assign `telemetry_hidden?: false` at mount; add `handle_event("telemetry_hide", …)`, `("telemetry_show", …)` (flip assign + `push_event(socket, "telemetry_pref", %{hidden: bool})`), and `("telemetry_restore", %{"hidden" => true}, …)` plus a fall-through `("telemetry_restore", _, …)` no-op (data-model state transitions); keep `view.feed` accumulation untouched (R3)
- [X] T012 [US2] In `lib/autonomous/web/live/mission_control_live.ex` render: add `phx-hook="TelemetryPref"` and `id="mission-live"` on `.run-live`; set `data-telemetry={if @telemetry_hidden?, do: "hidden", else: "shown"}` on `.mission-grid`; give the feed column `id="mission-feed"` and render it only when shown, with the **hide** button (`type="button" class="btn-link mission-feed-toggle" phx-click="telemetry_hide" aria-expanded="true" aria-controls="mission-feed" data-telemetry-toggle="hide"`) at the right of `.mission-feed-header`; when hidden render a `.mission-main-head` flex row containing the status strip and the **show telemetry** button (`btn-secondary btn-compact`, `aria-expanded="false"`, `data-telemetry-toggle="show"`); move the `[data-console-delayed]` paragraph to the top of `.mission-main` (before `.mission-main-head`) while hidden, feed column otherwise (R4, R5)
- [X] T013 [US2] In `priv/static/assets/console.css`, add `.mission-grid[data-telemetry="hidden"] { grid-template-columns: minmax(0, 1fr); }`, `.mission-main-head { display: flex; align-items: center; gap: var(--sp-12); }` with the status strip `flex: 1`, button right-aligned, and `.mission-feed-header` flex layout placing `.mission-feed-toggle` at the right (use existing spacing tokens only)
- [X] T014 [P] [US2] In `priv/static/assets/app.js`, add hook `TelemetryPref` next to `FollowTail`: `mounted()` reads `localStorage.getItem("autonomous.mc.telemetry")` in `try/catch` and, if `"hidden"`, `this.pushEvent("telemetry_restore", {hidden: true})`; `this.handleEvent("telemetry_pref", ({hidden}) => …)` writes `"hidden"`/`"shown"` in `try/catch`; register it in the `hooks` map passed to `LiveSocket` (contract §2 Hook)
- [X] T015 [US2] Run the mission control and design-contract test files; fix until green. Manual: quickstart Q2, Q3, Q4 (JS hook storage round-trip)

**Checkpoint**: US1 + US2 both work independently.

---

## Phase 5: User Story 3 - Compact live session panel (Priority: P2)

**Goal**: Embedded panel shows badge + header + status footer + open-full-view only; no rows, no follow/frames toggles; `/live` unchanged.

**Independent Test**: With a session in flight, `/` panel has no conversation rows/toggles; **open full view** reaches `/live/<id>` with toggles intact; panel auto-switches to next session (quickstart Q5).

### Tests for User Story 3

- [X] T016 [P] [US3] In `test/autonomous/web/conversation_live_test.exs`, add embedded-mode tests per contract §3: present `[data-live-badge]`, `[data-conversation-header]`, `section[data-conv-status]`; absent `.conv-follow`, `input[data-follow]`, `.conv-frames`, `input[data-frames]`, `#conversation-rows`, `.conv-row`, `[data-notice="truncated"]`, `[data-next-session]`; status footer still updates when entries arrive; panel attaches to a new session when the shown one ends (FR-011); no-session state shows `[data-state="nothing-in-flight"]` and no `.conv-open-full`. Confirm existing non-embedded (`/live`) cases pass unmodified (FR-013)
- [X] T017 [P] [US3] In `test/autonomous/web/mission_control_live_test.exs`, add test using `find_live_child(view, "mc-conversation")` asserting the same absent/present selectors through the Mission Control page

### Implementation for User Story 3

- [X] T018 [US3] In `lib/autonomous/web/live/conversation_live.ex` render/1, gate on `@embedded?`: embedded keeps badge, open-full-view, `.conv-header`, `status_line/1`, `not_reachable?` notice and empty/not-found states; embedded omits follow/frames toggles, the `#conversation-rows` stream container, the truncated notice and the `next session:` link. Non-embedded markup must stay byte-identical (R6)
- [X] T019 [US3] In `lib/autonomous/web/live/conversation_live.ex`, make `attach/2` and the `:entry` handler skip `ConversationRows.rows/2` and stream inserts when embedded while still running `SessionStatus.apply/2`; keep `stream(:rows, [])` configured; confirm `follow?: embedded?` at mount still drives auto-switch (R6)
- [X] T020 [P] [US3] In `lib/autonomous/web/live/conversation_panel_live.ex`, update moduledoc only: follow is implicit in the embedded panel
- [X] T021 [US3] Run `conversation_live_test.exs`, `mission_control_live_test.exs`, and `test/autonomous/web/conversation_coverage_test.exs` if present (`mise exec -- mix test --only` not needed; run files directly); fix until green

**Checkpoint**: Compact panel done; `/live` verified unchanged.

---

## Phase 6: User Story 4 - Cleaner running row (Priority: P3)

**Goal**: No inline `live session` link in backlog rows.

**Independent Test**: Running feature row shows status pill (and awaiting meta) but no `[data-live-session]` (quickstart Q6).

### Tests for User Story 4

- [X] T022 [P] [US4] In `test/autonomous/web/mission_control_live_test.exs`, replace any assertion that expects `[data-feature-row] [data-live-session]` with `refute`; add test that `.awaiting-meta` still renders for an awaiting-answers feature; keep Run Detail's `a[data-live-session]` test (in the Run Detail test file) untouched

### Implementation for User Story 4

- [X] T023 [US4] In `lib/autonomous/web/live/mission_control_live.ex`, delete the `<a class="live-session-link" data-live-session>` from the status cell and the `live_sessions` assign (mount, update logic); turn the `handle_info({:console, :conversation_opened | :conversation_closed, _}, socket)` clause into `{:noreply, socket}` — do NOT remove it (no catch-all, would crash; R8). Leave `.live-session-link` CSS in place
- [X] T024 [US4] Run `mission_control_live_test.exs` and the Run Detail LiveView test; fix until green

**Checkpoint**: Row decluttered.

---

## Phase 7: User Story 5 - "open full view" reads as a button (Priority: P3)

**Goal**: Link styled as console secondary button, still a real link.

**Independent Test**: Button visuals/hover/focus; middle-click opens `/live/<id>` in new tab (quickstart Q5).

### Tests for User Story 5

- [X] T025 [P] [US5] In `test/autonomous/web/conversation_live_test.exs`, assert embedded panel renders `a.btn-secondary.btn-compact.conv-open-full[href="/live/<id>"]` (real `<a href>`, not a button/JS-only) and `/live` (not embedded) has no `.conv-open-full` (contract §3)

### Implementation for User Story 5

- [X] T026 [US5] In `lib/autonomous/web/live/conversation_live.ex`, change the **open full view** element to `<a href={"/live/" <> id} class="btn-secondary btn-compact conv-open-full">open full view</a>`, rendered only when a session id exists and only in embedded mode
- [X] T027 [US5] In `priv/static/assets/console.css`, remove the old `.conv-open-full` mono/meta text rule (button is a sans label per R7); leave layout positioning only if needed, using tokens
- [X] T028 [US5] Run `conversation_live_test.exs` and `design_contract_test.exs`; fix until green

**Checkpoint**: All five stories complete.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T029 [P] Add a feature-045 paragraph to `docs/runbook.md` (telemetry hide/show + per-browser localStorage key `autonomous.mc.telemetry`, compact embedded panel, row link removal)
- [X] T030 [P] Add a feature-045 paragraph to `CLAUDE.md` Console section (Mission Control polish: `telemetry_hidden?` assign + `TelemetryPref` hook, compact embedded `ConversationLive`, `live_sessions` assign removed, two new layout tokens, `specs/045-mission-control-polish/`)
- [X] T031 Run full gates: `mise exec -- mix compile` (warnings_as_errors) and `mise exec -- mix test`; confirm design guard clean with no new allowlist entries (SC-007)
- [ ] T032 Run `quickstart.md` manual checks Q1–Q6 against a running console and record any deviation

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (1)** → **Foundational (2)** → user stories → **Polish (8)**
- Stories share files, so run them in priority order: US1 → US2 → US3 → US4 → US5. US3, US5 both edit `conversation_live.ex`; US1, US2, US4 all edit `mission_control_live.ex`; US1/US2/US5 edit `console.css`.

### User Story Dependencies

- **US1 (P1)**: after Foundational. Standalone MVP.
- **US2 (P1)**: after Foundational; needs T003 (`btn-compact`). Independent of US1 behaviour, but sequence after T006 (same file/render region).
- **US3 (P2)**: independent of US1/US2 behaviour; T007 (title on header) precedes T018 (same file).
- **US4 (P3)**: independent; sequence after US2 on `mission_control_live.ex`.
- **US5 (P3)**: after US3 (the link lives in the render T018 reshapes) and T003.

### Within Each Story

Tests first (expect failure), then implementation, then the story's test run.

### Parallel Opportunities

- T005 ∥ nothing else on the same file; test tasks in different files (T016 `conversation_live_test.exs` ∥ T017 `mission_control_live_test.exs`) can run together
- T014 (`app.js`) ∥ T011–T013 (different files)
- T020 (`conversation_panel_live.ex`) ∥ T018–T019
- T029 ∥ T030

```text
# US2 parallel pair:
Task: T014 TelemetryPref hook in priv/static/assets/app.js
Task: T011 telemetry events in lib/autonomous/web/live/mission_control_live.ex

# US3 test pair:
Task: T016 embedded tests in test/autonomous/web/conversation_live_test.exs
Task: T017 embedded-via-Mission-Control test in test/autonomous/web/mission_control_live_test.exs
```

---

## Implementation Strategy

### MVP First

1. Phases 1–2, then Phase 3 (US1 overlap fix) → validate quickstart Q1 → shippable defect fix.

### Incremental Delivery

2. US2 (hide/show) → Q2–Q4.
3. US3 (compact panel) → Q5 (button still plain link until US5).
4. US4 (row cleanup) → Q6.
5. US5 (button style) → Q5 visuals.
6. Polish: docs, full suite, quickstart.

## Notes

- No store, schema, recorder or control-plane change; do not touch `ConversationRows`, `SessionStatus`, or `/live` markup.
- Never add inline styles, new breakpoints, keyframes, colours or font-sizes (design guard).
- Commit after each task or logical group; prefix git with `rtk`.
