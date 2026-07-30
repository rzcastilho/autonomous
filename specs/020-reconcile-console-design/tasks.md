---

description: "Task list for reconciling the console with the design constitution"

---

# Tasks: Reconcile the console with the design constitution

**Input**: Design documents from `/specs/020-reconcile-console-design/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/token-set.md](contracts/token-set.md), [contracts/status-transport.md](contracts/status-transport.md), [contracts/design-guard.md](contracts/design-guard.md), [quickstart.md](quickstart.md)

**Tests**: FR-023–FR-027 require the mechanical guard and its tests as a first-class deliverable of this feature (User Story 4) — those tasks are included. P1–P3 have no separately-requested TDD tests; FR-025 requires existing tests be updated where structure changes, which is folded into each story's implementation tasks.

**Organization**: Tasks are grouped by user story (P1–P4 from spec.md), in the spec's own delivery order. Every command runs through `mise exec --` per the constitution's Quality & Test Discipline (`mise exec -- mix test`, not `mix test`); prefix git/gh with `rtk`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on an incomplete task)
- **[Story]**: US1 (P1 tokens) · US2 (P2 component/type) · US3 (P3 motion/interaction) · US4 (P4 guard)
- File paths are repo-relative

## Path Conventions

Single existing OTP project, no new directories:

- `priv/static/assets/console.css` — the one token declaration + all rules
- `lib/speckit_orchestrator/web/components/` — shared components + layouts
- `lib/speckit_orchestrator/web/live/` — the 8 LiveViews
- `test/support/design_contract.ex` — new pure scanner (test-env only)
- `test/speckit_orchestrator/web/` — driver test + updated view tests
- `specs/020-reconcile-console-design/compliance-inventory.md` — new committed artifact

---

## Phase 1: Setup

**Purpose**: Confirm the starting point matches the measured baseline before any reconciliation begins.

- [X] T001 Run `mise exec -- mix deps.get && mise exec -- mix compile` and `mise exec -- mix test` to confirm the tree compiles clean (`warnings_as_errors`) and the full suite is green before any change lands.
- [X] T002 [P] Re-run research.md §0's measurement commands (`grep -oE '#[0-9a-fA-F]{3,8}' priv/static/assets/console.css | wc -l`, the inline-style/hex-literal greps over `lib/speckit_orchestrator/web/`, the `@keyframes`/`prefers-reduced-motion` greps) and confirm counts still match the recorded baseline (109 CSS color literals, 6 inline styles, 14 hex literals in server code, 0 keyframes) — if they don't, the plan's baseline is stale and must be reconciled before proceeding.

---

## Phase 2: Foundational

**Purpose**: Shared infrastructure blocking all user stories.

None. This feature adds no dependency, schema, route, or shared runtime module ahead of the stories — spec.md states User Story 1 (the token set) *is* the foundation every later story and the guard build on. Proceed directly to Phase 3.

---

## Phase 3: User Story 1 - One authoritative token set (Priority: P1) 🎯 MVP

**Goal**: One `:root` block in `console.css` is the sole source of every color, radius, font-size and spacing literal the contract fixes; every retired/re-valued token name is re-pointed by role, not renamed; every status resolves through one `data-status`-keyed definition; no color is ever emitted from Elixir. Covers FR-001–FR-005, FR-004a, FR-004b.

**Independent Test**: Load each console view; confirm no color/radius/font-size literal exists outside the single token declaration; confirm each §II token exists under its contract name and value; confirm a status (e.g. `escalated`) renders the same color as dot, chip, phase pip, DAG node border and timeline node because all five read one definition; change `--escalated` in `:root` and confirm every representation follows.

### Implementation for User Story 1

- [X] T003 [US1] Rewrite the `:root` block at the head of `priv/static/assets/console.css` per [contracts/token-set.md](contracts/token-set.md) §2–§4: the 24 §II contract colors verbatim (4 surface, 4 border, 4 text, 5 accent, 7 status), 7 radius tokens (`--r-pip:2px` per §V, `--r-chip:5px`, `--r-control:7px`, `--r-input:9px`, `--r-card:10px`, `--r-panel:12px`, `--r-dot:50%`), 9 type-size tokens, 9 spacing tokens on the 2px grid, and 7 derived tokens (`--scrim`, `--shadow-drawer`, `--shadow-toast`, `--glow-accent`, `--gradient-primary`, `--selection`, `--hatch-reserved` with its Complexity Tracking comment). `--border` and `--border-strong` take the contract's *new* values (`#232936`, `#2a3142`); `--muted`, `--accent-2`, `--link`, `--link-hover` are not declared.
- [X] T004 [US1] Update the stylesheet header comment (first 12 lines of `priv/static/assets/console.css`) per [contracts/token-set.md](contracts/token-set.md) §1: cite `docs/design-constitution.md` as governing, name `specs/011-control-plane-ui-redesign/contracts/design-system.md` as historical only, and record the `--hatch-reserved` divergence with its `plan.md` reference (FR-005).
- [X] T005 [US1] Re-point all 10 sites using the old `var(--border)` value (`#1c212c`) in `priv/static/assets/console.css` by role per [data-model.md](data-model.md) §2 / research.md §1a: row divider inside a card → `--hairline`; structural region divider → `--border-subtle`; card/panel border → `--border` (new value); interactive → `--border-strong`.
- [X] T006 [US1] Re-point all 40 sites using the old `var(--border-strong)` value (`#232936`) in `priv/static/assets/console.css` by the same four-way role split; most resolve to `--border` (card borders) or stay `--border-strong` (secondary-button/interactive).
- [X] T007 [US1] Re-point all 42 `var(--muted)` sites in `priv/static/assets/console.css` by role per research.md §1a: uppercase eyebrow/mono metadata → `--text-faint`; description/secondary label → `--text-muted`; value/body → `--text-secondary`. Remove the `--muted` declaration once zero references remain.
- [X] T008 [US1] Re-point the 4 `var(--accent-2)` sites → `--accent-deep` and remove the `--accent-2` declaration; re-point the 3 `var(--link)` sites → `--accent-light` and the 1 `var(--link-hover)` site → `--accent-hover`, then remove both declarations.
- [X] T009 [US1] Map every off-palette literal group in `priv/static/assets/console.css` to its contract token per research.md §1b's table (`#8b93a7`→`--text-muted`, `#12151d`→`--card`, `#2a3142`→`--border-strong`, `#161a23`→`--raised`, `#c3c9d6`→`--text-secondary`, `#14181f`→`--hairline`, `#232936`→`--border`, `#2a2350`→`--accent-shadow`, `#171b25`→`--raised`/`--hairline` by role, `#a5b0c2`→`--text-secondary`, `#4b2fd6` gradient terminus on `.dag-node-mark`→`--accent-deep`, the 7 `#fff` sites→`--text`/`--card`/`--border-strong` by role). Leave the `#6ee7b7`/`#1c5c3a`/`#0f2a1c` `.drawer-pr` greens and the `#f43f5e14` `.field-error` red for removal in User Story 2 (research.md §4b/§4c).
- [X] T010 [US1] Replace the 4 `rgba()`/`hsla()` literals in `priv/static/assets/console.css` with `--scrim`, `--glow-accent`, or `--selection` per research.md §0/§1.
- [X] T011 [US1] Convert every hex alpha suffix in `priv/static/assets/console.css` to the `color-mix(in srgb, var(--x) N%, transparent)` table in [contracts/status-transport.md](contracts/status-transport.md) §3 (`1a`→10%, `22`→13%, `40`→25%, `55`→33%, `66`→40%, `88`→53%, `0d`→5%); remove the retired `20`/`14` suffixes entirely.
- [X] T012 [P] [US1] In `lib/speckit_orchestrator/web/components/core_components.ex`, replace `@palette` (`status => {label, hex}`) with `@labels` (`status => label`) plus `label/1`, `status_class/1` (folds `:never_started` → `"blocked"`, any other unknown atom → `"pending"`), and `statuses/0`, per [contracts/status-transport.md](contracts/status-transport.md) §1. Remove `palette/0`.
- [X] T013 [US1] In `lib/speckit_orchestrator/web/components/core_components.ex`, change the status-chip markup to emit `data-status={status_class(@status)}` instead of `style="background-color: #{color}20; …"` (site `core_components.ex:39`).
- [X] T014 [US1] Add the `[data-status="…"]` → `--sc` rule block (7 blocks, one per status) to `priv/static/assets/console.css` per [contracts/status-transport.md](contracts/status-transport.md) §3, and rewrite `.status-dot` and `.status-chip` to read `var(--sc)`/`color-mix(in srgb, var(--sc) …%, transparent)` instead of any literal or Elixir-supplied color.
- [X] T015 [P] [US1] In `lib/speckit_orchestrator/web/live/escalations_live.ex`, remove `status_color/1` and its 4 color-bearing inline styles (card border at `:372`, card head wash at `:374`, dot at `:375`) — replace with `data-status` on `.escalation-card`, `.escalation-card-head`, `.escalation-dot` per [contracts/status-transport.md](contracts/status-transport.md) §2.
- [X] T016 [P] [US1] In `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`, remove the `palette/0`-based inline legend-swatch color (`:287`) in favor of the existing `[data-legend-status]` selector, and drive the DAG node border from `data-status`/`--sc`.
- [X] T017 [US1] In `lib/speckit_orchestrator/web/components/core_components.ex`, rename `gauge_color/2` to `gauge_band/2` returning `:safe | :warning | :tripped` per [contracts/status-transport.md](contracts/status-transport.md) §4 (`fill >= 100.0` or `tripped?` → `:tripped`; `fill > 80.0` → `:warning`; else `:safe`, using `Ledger.tripped?`); emit `data-band={@band}` on `.cost-gauge`, keeping only the two `width:` inline styles (`@fill`, `@committed_fill`).
- [X] T018 [US1] Add `.cost-gauge[data-band="…"] .cost-gauge-fill` rules to `priv/static/assets/console.css` (`safe`→`--done`, `warning`→`--escalated`, `tripped`→`--failed`) and `.cost-gauge-reserved{background:var(--hatch-reserved)}` per [contracts/status-transport.md](contracts/status-transport.md) §4.
- [X] T019 [US1] Verify zero `var(--muted)` / `var(--accent-2)` / `var(--link)` / `var(--link-hover)` references remain and zero color literals remain outside `:root`, using quickstart.md Scenario 2's 2b–2d commands (`awk`/`rtk grep` over `priv/static/assets/console.css` and `lib/speckit_orchestrator/web/`).
- [X] T020 [P] [US1] Update tests referencing removed functions (`palette/0`, `status_color/1`, `gauge_color/2`) in `test/speckit_orchestrator/web/*_test.exs` to assert `label/1`/`status_class/1`/`gauge_band/2` and `data-status`/`data-band` attributes instead of inline-style colors (FR-025).
- [X] T021 [US1] Manually confirm status propagation (quickstart.md 2f): change `--escalated` in `:root` to `#ff00ff`, reload, confirm the escalations dot, chip, phase pip, DAG node border, timeline node, gauge warning band and legend swatch all turn magenta with none keeping `#fbbf24`; revert.
- [X] T022 [US1] Run `mise exec -- mix test` and `mise exec -- mix format --check-formatted`; fix any warning introduced by T003–T018 (`warnings_as_errors` is on).

**Checkpoint**: One token set is authoritative; every retired name is gone; status color has exactly one source. The console's appearance shifts (intended — spec Assumptions) but every view still shows the same information.

---

## Phase 4: User Story 2 - Surfaces obey the color, type and component specs (Priority: P2)

**Goal**: Every rendered element matches the contract's §II–§V component specs — text roles, mono/sans split, chip/pip/record-block/toast/timeline shape, and zero §VIII prohibitions. Covers FR-006–FR-014, FR-010a.

**Independent Test**: Walk every console view and check each element against the contract's §II–§V specs (chip fill/border alphas, mono-vs-sans role split, identifier ellipsis, ordinal zero-padding, phase pip track, record blocks, toasts) with no absolute prohibition present.

### Implementation for User Story 2

- [X] T023 [US2] Audit and fix the mono-vs-sans role split across `priv/static/assets/console.css`, the 8 LiveViews and `core_components.ex`/`feature_drawer.ex`: machine-produced/operator-typed values (IDs, slugs, phases, statuses, paths, branches, counts, money, durations, timestamps) render `var(--font-mono)`; human prose renders `var(--font-sans)`; no element mixes both. Record every judgment call in `specs/020-reconcile-console-design/compliance-inventory.md` (surface / element / rule / verdict) per [data-model.md](data-model.md) §6.
- [X] T024 [US2] Add `text-overflow:ellipsis; white-space:nowrap; overflow:hidden` to every constrained-identifier column/chip rule in `priv/static/assets/console.css`; zero-pad every ordinal (feature number, attempt, phase index) at its render site across the relevant `lib/speckit_orchestrator/web/live/*.ex` and `feature_drawer.ex` files.
- [X] T025 [US2] Verify `.status-chip`, `.escalation-card-head` and `.cost-gauge` active-state rules in `priv/static/assets/console.css` use exactly the alpha percentages in [contracts/status-transport.md](contracts/status-transport.md) §3 (fill 10%, border 25%, active fill 13%, header wash 5%) — not an opaque border, not a `999px` pill.
- [X] T026 [US2] Rebuild the phase pip track as one equal-width fixed-length track, identical in mission control, DAG node and drawer contexts (`core_components.ex`, `feature_drawer.ex`, `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`, `priv/static/assets/console.css`); add a `title` attribute naming both phase and state to every pip.
- [X] T027 [US2] Add `record_block/1` to `lib/speckit_orchestrator/web/components/core_components.ex` per FR-010a (accent eyebrow naming the artifact path over mono key/value pairs) and adopt it in `feature_drawer.ex`'s checkpoint block, transcript-path block and PR block (replacing `.drawer-pr`'s off-palette greens `#6ee7b7`/`#1c5c3a`/`#0f2a1c` — research.md §4c) and in `lib/speckit_orchestrator/web/live/run_detail_live.ex`'s run-record block.
- [X] T028 [P] [US2] Wire the `scBlink` live indicator in `lib/speckit_orchestrator/web/live/transcripts_live.ex` to "the phase attempt has no finish record" (research.md §3a) via `.transcript-live[data-live="true"]`.
- [X] T029 [P] [US2] Update toast markup/CSS to echo the underlying call and its arguments rather than a generic success message; use `--raised` background with a 1px accent border; remove any status-colored toast border (FR-011).
- [X] T030 [US2] Remove `.field-error`'s status-red styling (`#f43f5e14`) from `lib/speckit_orchestrator/web/live/trigger_live.ex`, `config_live.ex`, and `pipeline_dag_live.ex`'s form-refusal surfaces; rebuild each as a record-block-style refusal (inset `--bg` well, `--border-strong` border, accent eyebrow, mono `--text-secondary` message) per research.md §4b.
- [X] T031 [P] [US2] In `lib/speckit_orchestrator/web/live/mission_control_live.ex` (`:170`), replace the parked-run banner's reuse of `.field-error` with its own `data-state="parked"` rule that draws color from the run's status token (research.md §4b).
- [X] T032 [US2] Remove pictographic nav glyphs: delete `@nav_glyphs`/`nav_glyph/1` from `lib/speckit_orchestrator/web/components/layouts.ex` and their use in `lib/speckit_orchestrator/web/components/layouts/app.html.heex`; remove the three button glyphs (`&#9654;`, `&#8635;`, `&#8801;`) in `escalations_live.ex`, keeping real-identifier labels. Keep the `✓ ● ! ✕` timeline marks in `feature_drawer.ex` (§V-prescribed) and the mono `" ✓"` task-phase mark in `escalations_live.ex:554` (research.md §4d).
- [X] T033 [US2] Fix the runtime/CLI health indicators in the app chrome (`lib/speckit_orchestrator/web/components/layouts/app.html.heex` / `layouts.ex`, research.md §4a): remove `.status-dot[data-ok="true"]`'s green glow; render health as mono `available`/`not found`, `up`/`down` text in `--text-secondary`, dot in `--text-faint` when healthy, `--text-muted` when not — no status color, no glow.
- [X] T034 [US2] Sweep `priv/static/assets/console.css` for remaining §VIII prohibitions per [contracts/design-guard.md](contracts/design-guard.md) §3.6: pure `#000`/`#fff` outside the three shadow tokens, background gradients outside `--gradient-primary`/`--hatch-reserved`, `text-align:center` on body-copy rules, any `--fs-*` below `10px` (promote the two `9px` sites — eyebrows → `--fs-eyebrow`, prose → `--fs-meta`), `box-shadow` outside `--shadow-drawer`/`--shadow-toast`/`--glow-accent`.
- [X] T035 [P] [US2] Update existing tests for the structural changes in T023–T034 (glyph removal, toast markup, record-block markup, field-error replacement) in the relevant `test/speckit_orchestrator/web/*_live_test.exs` files (FR-025).
- [X] T036 [US2] Run `mise exec -- mix test` and manually walk all 8 views against quickstart.md Scenario 3's table, confirming SC-009 information parity (same data, same routes as before).

**Checkpoint**: User Stories 1 and 2 both hold — the token layer is correct and every surface reads as one system at the component level.

---

## Phase 5: User Story 3 - Motion and the interaction law (Priority: P3)

**Goal**: Exactly the contract's four keyframes exist, attached only to live referents; reduced motion degrades to static markers, never to status text; recovery decisions rank cheapest-correct over expensive-alternative with consequence hints and every real API override exposed. Covers FR-015–FR-022.

**Independent Test**: Observe a run with one active and several resting features and confirm animation appears only on the active referent, with and without reduced motion; open each recovery decision point and confirm ranking, consequence hints and override controls; confirm the gauge distinguishes committed from reserved; confirm every empty state reads as a status report.

### Implementation for User Story 3

- [X] T037 [US3] Add the four keyframes (`scPulse`, `scBlink`, `scSlide`, `scFade`) to `priv/static/assets/console.css` per [contracts/status-transport.md](contracts/status-transport.md) §5, attached only to `.status-dot[data-status="running"]`/`.phase-cell-active`/`.dag-node[data-status="running"] .status-dot` (`scPulse`), `.transcript-live[data-live="true"]` (`scBlink`), `.drawer` (`scSlide`), `.scrim, .toast` (`scFade`). Remove the `.status-dot[data-ok="true"]` glow entirely (already covered by T033).
- [X] T038 [US3] Add one `@media (prefers-reduced-motion: reduce)` block to `priv/static/assets/console.css` naming every animated selector from T037 with `animation:none` per [contracts/status-transport.md](contracts/status-transport.md) §5.
- [X] T039 [US3] Confirm the `--glow-accent` ring renders on the active DAG node (`lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`, `priv/static/assets/console.css`) and the current phase pip renders in the status color against `--border` future pips (`feature_drawer.ex`, `core_components.ex`) — the two reduced-motion static markers required by FR-015a.
- [X] T040 [P] [US3] Audit `lib/speckit_orchestrator/web/components/layouts/app.html.heex` to confirm the run-state chip, subject, budget gauge and breaker status stay visible on all 8 views (FR-016).
- [X] T041 [P] [US3] In `lib/speckit_orchestrator/web/live/escalations_live.ex`, rank recovery actions: `resume/2` as the gradient primary, `resolve/1` as a bordered secondary in the same row, each with a mono consequence hint; expose `:from` and `:prompt` overrides under their real option names, defaulting to what the system would choose unaided (FR-017, FR-018).
- [X] T042 [P] [US3] In `lib/speckit_orchestrator/web/live/mission_control_live.ex`, rank the parked-run decision: `continue_run/1` and `end_run/1` visually ranked and consequence-labelled, never one ambiguous button (FR-017).
- [X] T043 [US3] Audit labels across all 8 views for real system identifiers (function names, atoms, paths, config keys); remove any friendly rename of a real identifier (FR-019).
- [X] T044 [US3] Audit click targets across all 8 views: confirm a backlog row, a DAG node and a drawer card for the same entity all open that entity's single detail surface (FR-021); fix any surface where they diverge.
- [X] T045 [P] [US3] Rebuild the escalations empty state in `lib/speckit_orchestrator/web/live/escalations_live.ex` to state the healthy condition and why, left-aligned, no call to action, no decorative icon — remove the 28px `done`-green check glyph (FR-022).
- [X] T046 [P] [US3] Update existing tests for the recovery-ranking, parked-run banner and empty-state markup changes (FR-025) in `escalations_live_test.exs` / `mission_control_live_test.exs`.
- [X] T047 [US3] Run `mise exec -- mix test` and manually validate quickstart.md Scenario 4 (motion enabled + reduced, live transcript blink, recovery ranking, parked run, gauge threshold, empty state, click targets).

**Checkpoint**: All three delivery-order stories (P1–P3) hold — the console is fully reconciled visually and behaviorally; only the guard remains.

---

## Phase 6: User Story 4 - Divergence cannot come back (Priority: P4)

**Goal**: A pure scanner fails the default test suite when any of the four guarded divergence classes returns, naming file and line; the judgment rules a scanner cannot decide are recorded in a committed compliance inventory. Covers FR-023–FR-027.

**Independent Test**: Introduce each class of divergence in turn (raw color literal, duplicated status value, fifth keyframe, prohibited inline style) and confirm the default suite fails and names the offending location; revert and confirm it passes.

### Implementation for User Story 4

- [X] T048 [US4] Create `test/support/design_contract.ex` defining `SpeckitOrchestrator.Web.DesignContract` with the `Violation` struct, `surfaces/0` (the enumerated 13-entry list per [contracts/design-guard.md](contracts/design-guard.md) §2 — the CSS file, `app.js`, 3 component modules, 2 layout templates, 8 named `live/*.ex` files, none globbed), `load/1`, `scan/1` and `format/1` stubs per [contracts/design-guard.md](contracts/design-guard.md) §1.
- [X] T049 [US4] Implement the token-integrity rules in `DesignContract.scan/1`: `:missing_token`, `:token_value_mismatch`, `:retired_token`, `:undeclared_token`, `:unexpected_token` ([contracts/design-guard.md](contracts/design-guard.md) §3.1), embedding the 24 §II names/values as module attributes transcribed from `docs/design-constitution.md` §II.
- [X] T050 [US4] Implement the literal rules: `:color_literal`, `:offscale_radius`, `:offscale_font_size`, `:offgrid_spacing`, `:illegal_alpha_suffix` ([contracts/design-guard.md](contracts/design-guard.md) §3.2), including the layout allowlist (`width`/`height`/`min-*`/`max-*`/`flex-basis`/`grid-template-*`/`letter-spacing`/`line-height`/`border-width`/`z-index`/`236px`/`460px`/`280px`/`22px`).
- [X] T051 [US4] Implement the status-duplication rules: `:duplicate_status_value`, `:unknown_status_selector`, `:status_color_in_elixir` ([contracts/design-guard.md](contracts/design-guard.md) §3.3).
- [X] T052 [US4] Implement the inline-style rule `:inline_style_color` ([contracts/design-guard.md](contracts/design-guard.md) §3.4) with the exact two-locus allowlist (`cost_gauge/1`'s `style={"width: #{@fill}%;"}` and `style={"width: #{@committed_fill}%;"}`).
- [X] T053 [US4] Implement the motion rules: `:unknown_keyframe`, `:missing_keyframe`, `:undefined_animation`, `:animation_without_referent`, `:unstoppable_keyframe` ([contracts/design-guard.md](contracts/design-guard.md) §3.5).
- [X] T054 [US4] Implement the §VIII prohibition rules: `:pure_black_white`, `:background_gradient`, `:second_accent_hue`, `:centered_body_text`, `:sub_floor_type`, `:pictograph` (with the `✓ ● ! ✕` codepoint allowlist, HTML numeric entities decoded before matching), `:shadow_on_resting`, `:governing_source`, `:frozen_artifact` ([contracts/design-guard.md](contracts/design-guard.md) §3.6).
- [X] T055 [US4] Create `test/speckit_orchestrator/web/design_contract_test.exs` with: the clean-tree test (`DesignContract.load(".") |> DesignContract.scan() == []`), the coverage test (`surfaces/0` equals the on-disk console surface set), and the doc-transcription test (the embedded §II token table matches the fenced CSS block parsed out of `docs/design-constitution.md`) per [contracts/design-guard.md](contracts/design-guard.md) §4.
- [X] T056 [US4] Add the four `--only injection` tests to `design_contract_test.exs`: a color literal appended to a CSS surface (expect `:duplicate_status_value` + `:color_literal`), `defp c, do: "#7c5cff"` in a view source (expect `:color_literal`), `@keyframes scWobble {…}` (expect `:unknown_keyframe`), `style={"background: #{@c};"}` in a view source (expect `:inline_style_color`) — each against a crafted `%{path => source}` map, asserting rule **and** reported line per [contracts/design-guard.md](contracts/design-guard.md) §4.4.
- [X] T057 [US4] Add a positive and a negative unit test case for every remaining rule in `DesignContract` to reach the >90% pure-core coverage bar ([contracts/design-guard.md](contracts/design-guard.md) §4.5), and confirm the test file declares no `@tag :integration`, starts no Coordinator, and opens no socket (hermeticity, FR-024).
- [X] T058 [US4] Author `specs/020-reconcile-console-design/compliance-inventory.md` covering every judgment rule from [contracts/design-guard.md](contracts/design-guard.md) §5's inventory list — one row per surface × element × rule × verdict — drawing on every judgment call recorded during T023 (mono/sans), T005–T009 (border/text re-pointing), and T030/T033/T039/T044/T045 (status-on-non-status, shadow, reduced-motion, click targets, empty-state wording); the single `divergence` verdict (reserved-spend hatch) cites `plan.md` § Complexity Tracking, per [data-model.md](data-model.md) §6.
- [X] T059 [US4] Run `mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs` and confirm 0 violations on the reconciled tree (SC-007); run quickstart.md 1d's manual probe (append a stray color literal to `console.css`, confirm the guard fails naming file and line, `rtk git checkout -- priv/static/assets/console.css`, confirm green again).

**Checkpoint**: All four user stories complete. The reconciliation is both real (P1–P3) and self-defending (P4).

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final documentation and full-suite gate.

- [X] T060 [P] Update `CLAUDE.md`'s Frontend/observability description to name the design contract, per the constitution 2.2.0 Sync Impact Report's "Update when the reconciliation feature lands" obligation (plan.md Project Structure).
- [X] T061 Run quickstart.md's full 5-scenario walkthrough end-to-end as a final human check.
- [X] T062 Run `mise exec -- mix test --cover` and confirm the pure core stays above the 90% bar.
- [X] T063 Run `mise exec -- mix format --check-formatted` and `mise exec -- mix test` as the final gate; confirm `rtk git diff main -- mix.exs mix.lock` and `rtk git diff main -- specs/011-control-plane-ui-redesign/contracts/design-system.md` are both empty (SC-008, FR-005).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — run first.
- **Foundational (Phase 2)**: Empty — nothing blocks all stories except User Story 1 itself.
- **User Story 1 (Phase 3)**: Depends on Setup. Blocks User Stories 2, 3 and 4 — spec.md states explicitly that P2's component rules and P3's motion/interaction rules "are all expressed in these tokens," and P4's guard "cannot pass until P1–P3 land."
- **User Story 2 (Phase 4)**: Depends on User Story 1 (re-points onto tokens User Story 1 declares; several T023–T034 tasks touch the same CSS regions T003–T018 rewrote).
- **User Story 3 (Phase 5)**: Depends on User Story 1 (status tokens) and User Story 2 (the phase pip and record-block treatments T037–T039 build on).
- **User Story 4 (Phase 6)**: Depends on User Stories 1–3 being fully landed — the guard's clean-tree assertion (T059) requires zero violations on the *reconciled* tree, and the compliance inventory (T058) draws on judgment calls recorded throughout T023–T045.
- **Polish (Phase 7)**: Depends on all four stories.

This feature's stories are **strictly sequential**, not independently parallelizable across stories — each is independently testable in isolation (per its own Independent Test), but the console has exactly one `console.css` and one set of view files, so US2 cannot start meaningfully until US1's token layer exists under it, and so on.

### Within Each User Story

- CSS token/re-pointing tasks touching `priv/static/assets/console.css` run in file order (T003 → T011, T014, T018, T037, T038) since they share one file.
- Elixir view/component edits in different files (marked `[P]`) can run in parallel once their story's CSS foundation lands.
- Each story ends with a test-update task and a `mise exec -- mix test` gate task before moving to the next story.

### Parallel Opportunities

- T002 (baseline re-measurement) is independent of T001.
- Within User Story 1: T012 (`core_components.ex` labels/status_class) can run parallel to T003–T011 (pure CSS); T015 and T016 (different LiveView files) can run parallel to each other once T014 lands.
- Within User Story 2: T028, T029, T031 (different files, narrow scope) can run parallel to each other and to T023–T027.
- Within User Story 3: T040, T041, T042, T045, T046 (different files) can run parallel to each other once T037–T039 land.
- Within User Story 4: T049–T054 all edit the same new file (`design_contract.ex`) and must run in sequence; T055–T057 similarly share `design_contract_test.exs`.
- T060 (Polish, CLAUDE.md) is independent of T061–T063.

---

## Parallel Example: User Story 1

```bash
# Once T003 (token block) lands, these can proceed together:
Task: "core_components.ex: @labels/label/status_class/statuses (T012)"
Task: "escalations_live.ex: remove status_color/1 + inline styles (T015)"
Task: "pipeline_dag_live.ex: legend swatch + DAG node border (T016)"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 3: User Story 1 — one authoritative token set, status transport wired through `data-status`.
3. **STOP and VALIDATE**: run quickstart.md Scenario 2 in full, including the manual `--escalated` propagation check (T021).
4. This alone discharges the recorded amendment debt (the name-collision hazard) even though Principle VII is not fully satisfied until US2–US4 land.

### Incremental Delivery

1. Setup → User Story 1 → validate (token layer safe to build on).
2. + User Story 2 → validate (surfaces read as one system) → the console looks and reads as reconciled.
3. + User Story 3 → validate (motion and interaction law correct) → Principle VII's highest-stakes rules hold.
4. + User Story 4 → validate (guard + inventory) → divergence cannot silently return; feature complete.

Per spec.md Assumptions, all four stories are in scope for this feature — none is deferred — but they land in this order so each increment leaves the console in a coherent, reviewable state.

---

## Notes

- No `[Story]` label on Setup, Foundational or Polish tasks, per format rules.
- Every task names its exact file(s); several US1/US2 CSS tasks share `priv/static/assets/console.css` and are intentionally *not* marked `[P]`.
- FR-025 (update existing tests) is folded into each story's own test-update task rather than a separate end-of-feature sweep, since the churn is structural and story-local (research.md: no existing test pins a color, glyph or inline style).
- Commit after each task or logical group; stop at any checkpoint to validate a story independently.
- Avoid: reverting a re-pointed token to its old name for convenience, keeping a removed inline style "temporarily," or writing a guard rule that can't localize `path`/`line` (contracts/design-guard.md G-2).
