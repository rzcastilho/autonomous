---

description: "Task list for 033 Operator Console UX Polish"
---

# Tasks: Operator Console UX Polish

**Input**: Design documents from `/specs/033-console-ux-polish/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R19), data-model.md, contracts/console-surfaces.md, contracts/design-guard-extensions.md

**Tests**: Included. The plan names a test file per new module, a StreamData property for `TranscriptMarkup`, fires/does-not-fire pairs for each new guard rule, and updated LiveView tests (contracts/console-surfaces.md: "Tests assert on the `data-*` hooks named here").

**Organization**: Grouped by user story. Each story is independently testable after Phase 2.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US7, from spec.md
- Run Elixir through mise: `mise exec -- mix test <file>`. `warnings_as_errors` is on.
- Prefix git commands with `rtk`.

## Path Conventions

Single OTP app. Web code in `lib/autonomous/web/` (`live/`, `components/`, `components/layouts/`), stylesheet `priv/static/assets/console.css`, script `priv/static/assets/app.js`, tests in `test/autonomous/web/`, guard in `test/support/design_contract.ex`.

---

## Phase 1: Setup

**Purpose**: Establish a green baseline before changing anything.

- [X] T001 Run `mise exec -- mix compile` and `mise exec -- mix test test/autonomous/web` on branch `033-console-ux-polish`; record any pre-existing failure in `specs/033-console-ux-polish/quickstart.md` notes so later regressions are attributable.
- [X] T002 [P] Read `test/support/design_contract.ex` and `test/autonomous/web/design_contract_test.exs` to learn the existing rule layout (`@contract_colors`, `@derived_tokens`, `@layout_named_values`, `@surfaces`, "required injections" block) before extending it.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Governance, tokens, shared input style, and guard rules that every story depends on. No story starts before this phase is green.

**CRITICAL**: The design-contract guard stays green at the end of this phase. `G-input` is added here, so the `console-input` migration (T008–T010) lands in the same phase. `G-inspect` is added in US1, where the `inspect/1` sites are fixed.

- [X] T003 Amend `docs/design-constitution.md` §II: change `--text-faint` `#5a6274`→`#7a8296`, `--pending` `#64748b`→`#94a3b8`, `--blocked` `#475569`→`#828ea3` in the tables and the `:root` snippet, with a rationale line citing research R8.
- [X] T004 Prepend a Sync Impact Report to `.specify/memory/constitution.md` and bump 6.0.1 → 6.0.2 (PATCH: no principle or MUST changes; three values move to meet the accessibility floor). Follow the 6.0.1 precedent.
- [X] T005 Edit the `:root` block in `priv/static/assets/console.css`: set the three amended values; add `--border-input: var(--text-faint)`, `--measure-transcript: 96ch`, `--rail-compact: 52px`, `--card-min: 280px`; add `color-scheme: dark`. Where a surface uses `--accent` as text, switch it to `--accent-light`.
- [X] T006 Update `test/support/design_contract.ex`: change the three `@contract_colors` values; add `@layout_tokens ~w(--measure-transcript --rail-compact --card-min)` to the `:root` closed-name list; add `--border-input` to `@derived_tokens`; add `52px` to `@layout_named_values`. Update the moduledoc to cite `contracts/design-guard-extensions.md` alongside the 020 contract.
- [X] T007 In `test/support/design_contract.ex` add rules `G-contrast` (WCAG 2.x relative luminance, alpha fills composited over the surface; text tokens ≥4.5 on every surface, status tokens ≥4.5 in their `1a` fill over `--card` and `--raised`, `--accent` ≥3 on `--bg`) and `G-breakpoint` (every `@media` `max-width`/`min-width` in `~w(1120px 760px)`).
- [X] T008 Rename `.resume-select` to `.console-input` in `priv/static/assets/console.css` (shared with `.resume-textarea`; keep that class separate), set its border to `var(--border-input)`, delete the scoped one-off rules it replaces (`.dag-wave-picker select`, `.config-pr-fields input`). Leave no alias.
- [X] T009 [P] Migrate Runs filters from `resume-select` to `console-input` in `lib/autonomous/web/live/runs_live.ex`, and any other `resume-select` use (`rtk grep resume-select lib priv`).
- [X] T010 [P] Add `class="console-input"` to every `<select>` and text-like `<input>` in `lib/autonomous/web/live/trigger_live.ex` (lines near 439, 529, 542, 555, 607, 619, 645), `lib/autonomous/web/live/config_live.ex` (text inputs near 205-212), and `lib/autonomous/web/live/pipeline_dag_live.ex` (wave picker near 301-316).
- [X] T011 In `test/support/design_contract.ex` add rule `G-input`: in scanned `.ex`/`.heex` surfaces, a `<select` or `<input` whose `type` is absent, `text`, `number` or `search` must carry `console-input` in `class`.
- [X] T012 Extend `test/autonomous/web/design_contract_test.exs` "required injections" block with one fires and one does-not-fire case each for `G-contrast`, `G-input`, `G-breakpoint`. Assert the three new hex values are pinned.
- [X] T013 Run `mise exec -- mix test test/autonomous/web/design_contract_test.exs` and fix until green. Run the full web test directory to confirm no regression.

**Checkpoint**: Tokens amended, guard extended, every control themed. Stories can start.

---

## Phase 3: User Story 1 - Every view shows only real, readable run data (Priority: P1) 🎯 MVP

**Goal**: No leaked bookkeeping keys, each setting once, transcripts rendered as inert formatted markup, readable state chips.

**Independent Test**: Open Run Detail for a completed run whose settings include `__given__`, the Transcripts view for an active feature, and the Runs list. Each setting appears once, no `__given__` or `%{`, markup rendered, every state chip legible.

### Tests for User Story 1

- [X] T014 [P] [US1] Write `test/autonomous/web/run_settings_view_test.exs`: allowlist only, `__given__`/`__`-prefixed keys dropped, `containment_profile` never emitted, atom and string key forms collapse to one row, stable order, unique keys, `format_value/1` table from research R3 (binary unquoted, atom, nil `—`, number, boolean, list, map without `__` keys), never calls `inspect/1`.
- [X] T015 [P] [US1] Write `test/autonomous/web/run_state_view_test.exs`: `status/1` mapping (`:in_flight`→`running`, `:completed`→`done`, `:parked`→`escalated`, `:superseded`→`blocked`, outcome `:interrupted`→`blocked`, `:ended_by_operator`→`pending`, feature status atoms, unknown→`pending`, never raises), `label/1` returns the real atom text, `status_counts/1` omits zeros and follows `CoreComponents.statuses/0` order.
- [X] T016 [P] [US1] Write `test/autonomous/web/transcript_markup_test.exs`: headings, `**strong**`, `*em*`/`_em_`, inline code, fenced code (unclosed fence runs to end), nested lists by indent, unmatched delimiter stays literal, embedded `<script>` rendered as escaped text. Add a StreamData property over arbitrary binaries: `render/1` never raises, output tags are only `h1–h6 p ul ol li pre code strong em`, and stripping tags then unescaping returns every non-markup input character in order. Add a timing check: 200 KB input renders in under 50 ms.
- [X] T017 [P] [US1] Add a `G-inspect` fires/does-not-fire pair to `test/autonomous/web/design_contract_test.exs` (fires on `inspect(` inside a HEEx `{…}` in a `~H` or `.heex`; does not fire in an Elixir function body).

### Implementation for User Story 1

- [X] T018 [P] [US1] Create `lib/autonomous/web/run_settings_view.ex` with `rows/1` and `format_value/1` per data-model §1 and research R3. Add `@spec` to public functions.
- [X] T019 [P] [US1] Create `lib/autonomous/web/run_state_view.ex` with `status/1`, `label/1`, `status_counts/1` per data-model §2 and research R7. Add `@spec`.
- [X] T020 [P] [US1] Create `lib/autonomous/web/transcript_markup.ex`: `render/1 :: Phoenix.HTML.safe()`, line-based block pass then inline pass, `Phoenix.HTML.html_escape/1` on every text run before any tag (research R4, data-model §6). Add `@spec`.
- [X] T021 [US1] Add `TranscriptMarkup` to the guard's `@surfaces` list in `test/support/design_contract.ex` and enable rule `G-inspect` there (depends on T017). Run the guard; it will fail on existing `inspect/1` sites until T022–T025 and T027 land.
- [X] T022 [US1] In `lib/autonomous/web/live/run_detail_live.ex` move the three `attr` declarations at lines 408-410 from above `settings_chips/1` onto `run_header/1` (research R1).
- [X] T023 [US1] In `lib/autonomous/web/live/run_detail_live.ex` replace the settings chip loop (around :449) with one `<.record_block label="run settings">` fed by `RunSettingsView.rows/1`. Keep the CONTAINMENT block (:454-464) as the only place `containment_profile` appears, only when permissive, with its `docs/enforcement.md` pointer. Replace `inspect/1` in the amendment chips (:470-471) with `RunSettingsView.format_value/1`.
- [X] T024 [US1] In `lib/autonomous/web/live/run_detail_live.ex` render the run state and outcome (around :439) as `<span class="status-chip" data-status={RunStateView.status(state)}>` with text `RunStateView.label(state)`. Replace the inline transcript `<pre>` (:250-264) with `TranscriptMarkup.render/1`.
- [X] T025 [P] [US1] In `lib/autonomous/web/live/runs_live.ex` replace `badge badge-neutral|badge-warn` (:170) with the same `status-chip` + `RunStateView` markup.
- [X] T026 [US1] In `lib/autonomous/web/live/transcripts_live.ex` add the run selector: `<select name="run_id" class="console-input">` from `Autonomous.run_history(limit: 20)`, default active run else latest, `handle_event` change → `push_patch` to `?run_id=`. Render the body with `TranscriptMarkup.render/1` inside `.transcript-body` (replace the `<pre>` at :217).
- [X] T027 [P] [US1] In `lib/autonomous/web/live/escalations_live.ex` replace `inspect(v)` at :647, :664, :678 with `RunSettingsView.format_value/1`.
- [X] T028 [US1] In `priv/static/assets/console.css` style `.transcript-body`: `--font-mono`, `--fs-transcript` (≥12.5px), `max-width: var(--measure-transcript)`, prose blocks `white-space: normal`, fenced blocks `pre` with inner horizontal scroll; add `.status-chip` rules for the run-state chips if missing. Tokens only, no literals.
- [X] T029 [US1] Update `test/autonomous/web/run_detail_live_test.exs`, `runs_live_test.exs`, `transcripts_live_test.exs`, `escalations_live_test.exs`: run settings contain `__given__` yet page has no `__given__`, no `%{`, each key once, `containment_profile` once (permissive) and absent (strict, byte-identical); chip `data-status` values; selector present and `?run_id=` patch works; `<script>` in a transcript appears escaped.
- [X] T030 [US1] Run `mise exec -- mix test test/autonomous/web` and fix until green, including the guard.

**Checkpoint**: US1 fully functional and testable alone (MVP).

---

## Phase 4: User Story 2 - Trigger Run is consistent and honest about consequences (Priority: P1)

**Goal**: Grouped options, hidden dependents, and a two-step confirmation that names the in-flight run.

**Independent Test**: With a run in flight, both start buttons need two clicks and name the run. With none in flight, one click starts.

### Tests for User Story 2

- [X] T031 [P] [US2] Write `test/autonomous/web/start_confirm_test.exs` covering every row of the data-model §3 transition table, including re-arm on a different run, `:cancel`, `{:active_run, nil}`, and `:tab_switch`.
- [X] T032 [P] [US2] Extend `test/autonomous/web/trigger_live_test.exs`: three `fieldset[data-option-group]` (`auto_remediation`, `interactive_clarify`, `containment_profile`); `answer_timeout_min` and `max_rounds` absent while `interactive_clarify` off, present with defaults when on; armed button text `Supersede <run_id> and start` with `data-confirm-armed`, hint `drains and supersedes <run_id>`, Cancel returns to idle; no active run → one click dispatches; a click from idle with an active run never dispatches; no `data-confirm` attribute; both start actions.

### Implementation for User Story 2

- [X] T033 [US2] Create `lib/autonomous/web/start_confirm.ex` with `next/3` per data-model §3 (pure, `@spec`).
- [X] T034 [US2] In `lib/autonomous/web/live/trigger_live.ex` subscribe to `ConsoleProjection.topic()`; compute `active_run_id` on mount and on every `{:console, :reconciled, _}` from `Autonomous.current_run_id/0` gated on a live Coordinator or non-empty `Autonomous.workers/0` (research R10). Keep `assigns.confirm = %{backlog: :idle, single_spec: :idle}`.
- [X] T035 [US2] In `lib/autonomous/web/live/trigger_live.ex` route `start_backlog` and `start_single_spec` through `StartConfirm.next/3`, re-checking `active_run_id` server-side on every click. Add `cancel_start` event and reset to `:idle` on tab switch. Render the armed button, mono hint and secondary-style Cancel per contracts/console-surfaces.md.
- [X] T036 [US2] In `lib/autonomous/web/live/trigger_live.ex` restructure options into three `<fieldset data-option-group>` blocks with visible titles using `.config-toggle-title`, one control per row, real option names as labels. Render `answer_timeout_min` and `max_rounds` only when `interactive_clarify` is on.
- [X] T037 [US2] In `lib/autonomous/web/live/trigger_live.ex` fix the backlog summary labels (`Breakdown package`, `Source`, `Feature count`, `DAG validated`, `Run shape`, `Budget`) and show `Source` relative to the served repo with the full path in `title`, replacing `truncate_path/1` (FR-032).
- [X] T038 [US2] In `priv/static/assets/console.css` add styles for `.option-group` rows, the armed button state and consequence hint (mono). Tokens only.
- [X] T039 [US2] Run `mise exec -- mix test test/autonomous/web/start_confirm_test.exs test/autonomous/web/trigger_live_test.exs test/autonomous/web/design_contract_test.exs` until green.

**Checkpoint**: US1 and US2 work independently.

---

## Phase 5: User Story 3 - The console is usable on a narrow screen (Priority: P1)

**Goal**: 390px renders without horizontal page scroll; the rail stays persistent as a compact strip.

**Independent Test**: Load all 8 views at 390×844: no horizontal scroll, every nav item reachable with badges.

### Tests for User Story 3

- [X] T040 [P] [US3] Extend `test/autonomous/web/layout_test.exs`: each nav item renders a short label (`MC PC TR ES RU TX CF`), `aria-label` and `title` equal the full label, active item keeps `nav-active`, badges present, labels equal page titles.

### Implementation for User Story 3

- [X] T041 [US3] In `lib/autonomous/web/components/layouts.ex` and `layouts/app.html.heex` add a short label span plus `aria-label`/`title` to each nav item. Rename nav label "Pipeline DAG" to "Pipeline Chain" (`layouts.ex:21-29`).
- [X] T042 [US3] Add one `@media (max-width: 760px)` block in `priv/static/assets/console.css`: `.console-sidebar` `flex: 0 0 var(--rail-compact)` with short labels and badges visible, full labels hidden; topbar wraps to two rows with gauge full width, clock hidden, breaker chip kept; `.topbar-gauge` loses its fixed 280px; feature tables switch `<tr>` to a grid (id + status chip on line one, phase position and spend on line two, slug and elapsed `display: none`); feature drawer `width: min(460px, 100vw)`; sidebar path no longer `word-break: break-all`.
- [X] T043 [US3] Add the markup hooks the 760px block needs in `lib/autonomous/web/live/mission_control_live.ex`, `lib/autonomous/web/live/runs_live.ex`, `lib/autonomous/web/components/feature_drawer.ex` (classes/`data-` attributes for hidden and stacked cells). Keep the DAG's horizontal scroll inside its panel.
- [X] T044 [US3] Verify at 390×844 with Playwright against the running console (`127.0.0.1:46789`): all 8 views, `document.documentElement.scrollWidth <= innerWidth`, every nav item tappable, drawer fits. Record the result in `specs/033-console-ux-polish/quickstart.md` notes.
- [X] T045 [US3] Run `mise exec -- mix test test/autonomous/web` until green (guard passes: breakpoint `760px` is allowlisted).

**Checkpoint**: P1 stories (US1–US3) complete.

---

## Phase 6: User Story 4 - Above-the-fold state is concise and precise (Priority: P2)

**Goal**: Legible gauge, seconds-precision clock, one status strip, phase name beside pips, event-feed rows.

**Independent Test**: With a run in flight, see gauge `$committed + $reserved / $budget`, clock `HH:MM:SS UTC`, one status row, `phase · n/7` on every in-flight row.

### Tests for User Story 4

- [X] T046 [P] [US4] Write `phase_position/1` tests in `test/autonomous/web/core_components_test.exs`: active cell wins, else last completed, else first with `n = 1`; `total = length(Pipeline.phases())`. Confirm `phase_strip_test.exs` (015 golden) still passes unchanged.
- [X] T047 [P] [US4] Extend `test/autonomous/web/layout_test.exs` and `mission_control_live_test.exs`: `#console-clock` matches `^\d{2}:\d{2}:\d{2} UTC$`; gauge `data-band` and label format, no `armed`/`tripped` inside the gauge; `[data-status-strip]` with one cell per status, `data-zero` on zero counts; `data-phase-position` on each feature row; feed row order time, dot, `data-feature-id`, predicate.

### Implementation for User Story 4

- [X] T048 [P] [US4] In `lib/autonomous/web/components/core_components.ex` add `phase_position/1` (pure function per data-model §5 plus a sibling function component rendering mono `{phase} · {n}/{total}`). Do not touch `phase_strip/1`.
- [X] T049 [P] [US4] In `lib/autonomous/web/components/core_components.ex` change the `cost_gauge/1` label (lines 215-266) to `$committed + $reserved / $budget`, mono, outside the bar, no breaker word; clamp bar width at 100% when committed exceeds budget (research R12).
- [X] T050 [P] [US4] In `lib/autonomous/web/components/layouts.ex:74` use `Time.truncate(:second)` before `Time.to_string/1`; in `layouts/app.html.heex` append ` UTC`.
- [X] T051 [US4] In `lib/autonomous/web/live/mission_control_live.ex` replace the eight KPI tiles with one `[data-status-strip]` row (`dot · :status · count`, `data-zero` de-emphasis in `--text-muted`); render `phase_position/1` beside `phase_strip/1` in the feature table; rebuild feed rows as time, `.status-dot[data-status]` (from `status_class/1` of the entry's feature status), mono id, sans predicate, newest first (:303-310).
- [X] T052 [P] [US4] Render `phase_position/1` beside `phase_strip/1` in `lib/autonomous/web/components/feature_drawer.ex` and in the Pipeline Chain card in `lib/autonomous/web/live/pipeline_dag_live.ex`.
- [X] T053 [US4] In `priv/static/assets/console.css` style `.status-strip`, `[data-zero]`, `.phase-position`, the gauge label and the feed row. Tokens only. Check SC-005 at 1440×900 with Playwright: the first feature row is visible without scroll.
- [X] T054 [US4] Run `mise exec -- mix test test/autonomous/web` until green.

**Checkpoint**: US1–US4 independently functional.

---

## Phase 7: User Story 5 - Configuration changes are precise and safe to apply (Priority: P2)

**Goal**: Dirty tracking, cent-precise budget, sticky Apply/Reset, honest apply echo, record block.

**Independent Test**: Edit a model and type `12.34` as the budget: `n unsaved` shows with Apply and Reset visible; Apply echoes the call and, with a run in flight, the forward-only line.

### Tests for User Story 5

- [X] T055 [P] [US5] Write `test/autonomous/web/config_diff_test.exs`: `diff/2` omits equal fields after normalization, `dirty?`, `parse_cents/1` accepts `12`, `12.3`, `12.34` and returns `:invalid` for `12.345`, `-1`, `abc`, `apply_echo/2` line 1 lists only changed keys, line 2 only with an active run.
- [X] T056 [P] [US5] Extend `test/autonomous/web/config_live_test.exs`: form root `data-dirty="true"` iff changed; sticky bar shows `<n> unsaved`, Apply, Reset; Reset clears dirty; number input `step="0.01"` with `console-input` and no `oninput`; rejected apply keeps `data-dirty` and shows `.form_refusal` beside the field; toast text; served repository and instance node inside a `record_block`.

### Implementation for User Story 5

- [X] T057 [US5] Create `lib/autonomous/web/config_diff.ex` with `diff/2`, `dirty?/1`, `parse_cents/1`, `apply_echo/2` per data-model §4 (pure, `@spec`). Fields: `model_<phase>`, `budget_usd`, `pr_base`, `pr_remote`, matching `LiveConfig.apply/1` (`lib/autonomous/live_config.ex:88-102`).
- [X] T058 [US5] In `lib/autonomous/web/live/config_live.ex` add `phx-change="edit"` keeping `edited`/`applied`; add `reset` event; set `data-dirty` on the form root; compute `changes` via `ConfigDiff`.
- [X] T059 [US5] In `lib/autonomous/web/live/config_live.ex` replace the budget range-only control (:178-187) with `<input type="number" name="budget_usd" step="0.01" min="0" class="console-input">` as the authority, range slider mirrored from the same assign, inline `oninput` removed.
- [X] T060 [US5] In `lib/autonomous/web/live/config_live.ex` add the sticky action bar (`n unsaved`, Apply, Reset); build the apply toast from `ConfigDiff.apply_echo/2` with `active_run_id`; show `.form_refusal` for `budget_usd`, `pr_base`, `pr_remote` and models; keep `edited` on rejection.
- [X] T061 [US5] In `lib/autonomous/web/live/config_live.ex` move served repository and instance node into one `<.record_block>`; replace visible `<legend>` titles with `.config-toggle-title` and make legends `sr-only` (FR-026).
- [X] T062 [US5] In `priv/static/assets/console.css` add the sticky action bar (`position: sticky; bottom: 0`), fix `fieldset` padding-top so no title overlaps a border console-wide, remove the scoped rule for the old budget slider script. Tokens only.
- [X] T063 [US5] Run `mise exec -- mix test test/autonomous/web/config_diff_test.exs test/autonomous/web/config_live_test.exs test/autonomous/web/design_contract_test.exs` until green.

**Checkpoint**: US1–US5 independently functional.

---

## Phase 8: User Story 6 - Secondary views use space and copy well (Priority: P3)

**Goal**: Width-aware Pipeline Chain, consistent labels, sidebar path, empty-state hierarchy, run feature summary, phase row density.

**Independent Test**: Review each view at 1440×900 against the US6 acceptance scenarios.

### Tests for User Story 6

- [X] T064 [P] [US6] Extend `test/autonomous/web/pipeline_dag_live_test.exs`: no positional ordinal element, one identifier per card, legend only lists present statuses (ad-hoc item only when an ad-hoc feature exists), wave picker has `<label for>`.
- [X] T065 [P] [US6] Extend `layout_test.exs`, `escalations_live_test.exs`, `runs_live_test.exs`, `run_detail_live_test.exs`: sidebar `data-repo-path` full, visible text `Path.basename/1`, `title` full path, `data-copy` button; `.empty-state-title` hierarchy hook; Runs `data-status-counts` with one dot+count per non-zero status in `statuses/0` order and no per-feature chip list; Run Detail transcript toggle is `.btn-link`.

### Implementation for User Story 6

- [X] T066 [P] [US6] In `lib/autonomous/web/live/pipeline_dag_live.ex` make `.dag-chain` a grid (`repeat(auto-fill, minmax(var(--card-min), 1fr))`) in `Release.order/1` reading order, drop the connector and `pad_ordinal(link.position)` (:452), render the legend only for statuses present (:390-404), add a visible `<label for>` on the wave picker (:301-316). Update `.dag-chain` rules in `priv/static/assets/console.css` (remove `max-width: 460px` and `::before` connector).
- [X] T067 [P] [US6] In `lib/autonomous/web/components/layouts/app.html.heex` and `layouts.ex` show `Path.basename(repo)` on one line (ellipsis, `data-repo-path`, `title`), with a copy button using `JS.dispatch("phx:copy")`; add the five-line `phx:copy` listener to `priv/static/assets/app.js` calling `navigator.clipboard.writeText`.
- [X] T068 [P] [US6] In `lib/autonomous/web/live/escalations_live.ex` give `.empty-state-title` `--fs-card-title` weight 600 and the body `--fs-body` `--text-muted` (copy unchanged); adjust rules in `priv/static/assets/console.css`.
- [X] T069 [P] [US6] In `lib/autonomous/web/live/runs_live.ex` replace the per-feature chip list with `data-status-counts` from `RunStateView.status_counts/1` (dot + mono count per non-zero status).
- [X] T070 [US6] In `lib/autonomous/web/live/run_detail_live.ex` make the phase-row transcript toggle a `.btn-link` and use the standard data-table cell padding (`padding: var(--sp-14) var(--sp-18)`); add `.btn-link` to `priv/static/assets/console.css`.
- [X] T071 [US6] Apply the casing rule from contracts/console-surfaces.md across labels (status values atom text in mono; view names title case; other labels sentence case) in `lib/autonomous/web/live/*.ex` and components. Grep for stragglers.
- [X] T072 [US6] Run `mise exec -- mix test test/autonomous/web` until green.

**Checkpoint**: US1–US6 independently functional.

---

## Phase 9: User Story 7 - The console loads cleanly (Priority: P3)

**Goal**: Zero 404s and zero browser console warnings on every view.

**Independent Test**: Load each of the 8 views with a clean browser console.

- [X] T073 [P] [US7] In `lib/autonomous/web/components/layouts/root.html.heex` add `<link rel="icon" href="data:,">` and remove both `rel="preload"` font links (research R17).
- [X] T074 [P] [US7] Extend `layout_test.exs`: root layout contains the icon link and no `rel="preload"` font link.
- [X] T075 [US7] Load all 8 views with Playwright (`browser_console_messages`) and confirm 0 errors and 0 warnings (SC-008). Record the result in the quickstart notes.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [X] T076 [P] Update the "Console (Phase 8, feature 020 reconciliation)" paragraph in `CLAUDE.md`: three amended tokens, new guard rules (`G-contrast`, `G-input`, `G-breakpoint`, `G-inspect`), 033 pure view modules.
- [X] T077 [P] Add a note to `docs/runbook.md` that Trigger Run now confirms supersession of an in-flight run (inline two-step).
- [X] T078 Contrast sweep (SC-011): confirm no surface uses `--accent` as text and `--text-faint`/`--pending`/`--blocked` render on the intended surfaces; the guard's `G-contrast` is the mechanical check.
- [X] T079 Walk `specs/033-console-ux-polish/quickstart.md` end to end at 1440×900 and 390×844 against the audit screenshots in `.playwright-mcp/ui-0*.png`.
- [X] T080 Run `mise exec -- mix compile --warnings-as-errors` and the full `mise exec -- mix test`; the design-contract guard and every web test must pass (SC-009).
- [X] T081 Confirm strict-run surfaces are byte-identical for containment (030 contract) and the 015 `phase_strip` golden test still passes.

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 → Phase 2 → Phases 3–9 → Phase 10.
- Phase 2 blocks every story. T008–T010 must precede T011 (G-input), and T005 must precede T006–T007.

### User Story Dependencies

- **US1 (P1)**: after Phase 2. No dependency on other stories. MVP.
- **US2 (P1)**: after Phase 2. Independent of US1.
- **US3 (P1)**: after Phase 2. T043 touches `runs_live.ex` and `mission_control_live.ex` markup, so sequence it after T025 (US1) and before T051 (US4) if run serially.
- **US4 (P2)**: after Phase 2. T052 and T066 both edit `pipeline_dag_live.ex` — sequence them.
- **US5 (P2)**: after Phase 2. Independent.
- **US6 (P3)**: T069 uses `RunStateView` from US1 (T019).
- **US7 (P3)**: after Phase 2. Independent. Touches `root.html.heex`.

### Within Each Story

- Tests first (they fail), then pure modules, then LiveView wiring, then CSS, then run the story's tests.
- `console.css` is a shared file: tasks that edit it (T028, T038, T042, T053, T062, T066, T068) must not run in parallel with each other.

### Parallel Opportunities

- Phase 2: T009 ∥ T010 after T008.
- US1: T014–T017 together; T018–T020 together (three new files); T025 ∥ T027.
- US2: T031 ∥ T032.
- US4: T046 ∥ T047; T048 ∥ T049 ∥ T050.
- US5: T055 ∥ T056.
- US6: T064 ∥ T065; T066–T069 touch different files except `console.css` edits (serialize those edits).
- With separate developers, US1, US2, US5 and US7 can proceed at once after Phase 2.

### Parallel Example: User Story 1

```text
Task: T014 test/autonomous/web/run_settings_view_test.exs
Task: T015 test/autonomous/web/run_state_view_test.exs
Task: T016 test/autonomous/web/transcript_markup_test.exs
Task: T018 lib/autonomous/web/run_settings_view.ex
Task: T019 lib/autonomous/web/run_state_view.ex
Task: T020 lib/autonomous/web/transcript_markup.ex
```

---

## Implementation Strategy

### MVP First

1. Phase 1 and Phase 2 (governance + guard + themed inputs).
2. Phase 3 (US1). Stop and validate: no leaked keys, rendered transcripts, legible chips.
3. Ship if ready, then continue.

### Incremental Delivery

US1 → US2 → US3 (all P1), then US4 → US5 (P2), then US6 → US7 (P3). Each story ends with a green `mix test test/autonomous/web`, so any checkpoint is shippable.

### Notes

- No dependency, build step or persisted state is added (plan Constitution Check).
- Never relax a guard rule; allowlist growth is limited to what `contracts/design-guard-extensions.md` §B names.
- Never rename a real identifier to a friendly synonym (FR-036).
- Commit after each task or logical group.
