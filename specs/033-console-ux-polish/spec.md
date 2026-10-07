# Feature Specification: Operator Console UX Polish

**Feature Branch**: `033-console-ux-polish`

**Created**: 2026-10-07

**Status**: Draft

**Input**: User description: "Operator console UI/UX improvements (usability + modern minimalist design), from a live audit of all views. Source: ~/.claude/plans/you-are-a-ui-ux-partitioned-goblet.md (28 ranked findings). P1: mobile layout broken at 390px; Trigger Run native unstyled form controls; Start run enabled while a run is in flight with no explanation; Run Detail leaks raw `__given__=%{...}` map and repeats settings 3x; Transcripts render markdown raw. P2: budget meter, clock, KPI tiles, progress labels, DAG layout, Trigger option layout, Runs pills, Run Detail chips/rows, transcript width/run selector, Config legend/budget input/Apply. P3: sidebar path, favicon/font warnings, label consistency, telemetry, wave picker, copy, empty-state hierarchy, runs feature summary, read-only config info. Constraints: design literals stay in the console stylesheet's token block, status color only via status names, design-contract guard stays green, docs/design-constitution.md governs."

## Context

A live walkthrough of every console view (Mission Control, Pipeline Chain, Trigger Run, Escalations, Runs, Run Detail, Transcripts, Configuration) during an active run surfaced 28 issues. Some are defects: internal data leaks onto the page, controls clash with the theme, and narrow screens are unusable. Others are clarity problems that slow an operator reading the state of a run.

The **design constitution (`docs/design-constitution.md`) governs every change**. Where the audit's "modern minimalist" direction conflicts with it, the constitution wins. Three conflicts are resolved up front:

- **No friendly renames.** The audit suggested humanizing atoms such as `:in_flight` and `:ok` (§I.3, §VIII). This spec fixes their *legibility* (contrast, status color) and keeps the real identifiers.
- **Density over whitespace** (§I.1). "Minimalist" here means removing noise, duplication and dead space. It does not mean adding whitespace or decoration.
- **The nav stays one persistent, flat rail** (§VII.1). Narrow-screen behaviour must keep it persistent.

## Clarifications

### Session 2026-10-07

- Q: What form should the nav take at narrow widths? → A: Keep the left rail, collapsed to a compact strip (icons or short labels, with attention badges) below a breakpoint. No constitution amendment.
- Q: What text contrast target applies? → A: WCAG AA: 4.5:1 for normal text, 3:1 for large text and non-text UI (chip borders, gauge, focus rings).
- Q: How is starting during an in-flight run confirmed? → A: Inline two-step. The first click turns the start button into "Supersede <run id> and start" with a mono consequence hint and a Cancel. The second click starts.
- Q (plan): Shipped tokens fail WCAG AA in places (`--text-faint`, `--pending`, `--blocked` as text; chip borders and default borders as non-text). How is FR-038 met? → A: Amend the three text-bearing token values in the design constitution. Apply the non-text 3:1 rule only where a border or fill is the only carrier of state or affordance (WCAG 1.4.11 scope). Chip borders and future pips are exempt.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Every view shows only real, readable run data (Priority: P1)

An operator opens Run Detail, Transcripts or Runs and reads the run's settings, a phase transcript, or a run's state without decoding internal data structures or squinting at invisible labels.

**Why this priority**: The console exists to report state truthfully at a glance (§I.2). A raw internal map, triplicated settings, unrendered transcript markup and near-invisible state chips each make the operator work harder or misread the run.

**Independent Test**: Open Run Detail for a completed run, the Transcripts view for an active feature, and the Runs list. Every setting appears exactly once, with no internal bookkeeping keys. Transcript formatting (emphasis, code, lists) is rendered. Every run state is readable in its status color.

**Acceptance Scenarios**:

1. **Given** a recorded run whose settings include internal bookkeeping keys, **When** the operator opens its Run Detail, **Then** no internal key and no raw data-structure literal is shown, and each real setting appears exactly once.
2. **Given** a run with `containment_profile` permissive, **When** Run Detail renders, **Then** the profile appears in one place only, with its pointer to the enforcement docs.
3. **Given** a transcript containing emphasis, inline code, code blocks and nested lists, **When** the operator views it, **Then** those structures render as formatting, the text stays in the machine (mono) family, and lines wrap at a readable width of about 80–100 characters.
4. **Given** runs in states `:in_flight`, `:completed`, `:parked` and others, **When** the Runs list renders, **Then** each state chip uses its real identifier, its status color, and meets WCAG AA contrast (4.5:1).
5. **Given** a setting value that is a string, **When** shown in Run Detail, **Then** it is shown without language-level quoting artefacts.

---

### User Story 2 - Trigger Run is consistent and honest about consequences (Priority: P1)

An operator configures and starts a run from Trigger Run. Every control matches the console theme, related options are grouped, and starting a run while one is in flight states plainly what will happen to the current run.

**Why this priority**: Starting a run is the most expensive action in the console. A fresh start drains and supersedes the active run, and today the button gives no hint of that (§I.5, §VII.4). The bright native controls also break the dark surface and read as a different app.

**Independent Test**: With a run in flight, open Trigger Run on both tabs. Every select and number input is themed. Options sit in labelled groups. The start action shows the in-flight run's id and the consequence before it takes effect.

**Acceptance Scenarios**:

1. **Given** Trigger Run on either tab, **When** it renders, **Then** every select, number and text input uses the console's input styling, the same as the Runs filters.
2. **Given** a run is in flight, **When** the operator views the start action, **Then** the first click turns the button into "Supersede <run id> and start" with a mono consequence hint and Cancel, and only a second click starts the run.
3. **Given** no run is in flight, **When** the operator starts a run, **Then** no confirmation step is added and the behaviour matches today.
4. **Given** interactive clarify is off, **When** Trigger Run renders, **Then** its dependent fields (answer timeout, max rounds) are hidden, not shown disabled. Turning it on reveals them with their defaults.
5. **Given** the options section, **When** it renders, **Then** auto-remediation, clarify and containment options each sit in their own labelled group, one control per row, labelled with the real option names, with consistent label and control sizes.

---

### User Story 3 - The console is usable on a narrow screen (Priority: P1)

An operator checks a run from a phone-width screen (about 390px wide). The run state, budget and feature list are readable without horizontal page scrolling, and navigation remains available.

**Why this priority**: At 390px the nav rail keeps its full width, content is clipped and the budget gauge is cut off. The console is effectively unusable there.

**Independent Test**: Load every view at 390×844. There is no horizontal page scroll, the topbar state and budget are visible, all nav destinations are reachable, and tables are readable.

**Acceptance Scenarios**:

1. **Given** a 390px-wide viewport, **When** any view loads, **Then** the page has no horizontal scroll and no content is clipped.
2. **Given** a 390px-wide viewport, **When** the operator wants to change views, **Then** the left rail is shown as a compact strip, every destination is one tap away, and the attention-count badges stay visible.
3. **Given** a 390px-wide viewport on Mission Control, **When** the feature table renders, **Then** each feature's id, status, current phase and spend are readable without sideways scrolling.

---

### User Story 4 - Above-the-fold state is concise and precise (Priority: P2)

An operator glances at the topbar and Mission Control and immediately knows run state, spend against budget, and which phase each feature is in, without noise.

**Why this priority**: The topbar and Mission Control answer "what is happening right now" (§I.2). Today the budget gauge is unreadable, the clock shows microseconds, eight tiles mostly show zero, and progress tracks are unlabelled.

**Independent Test**: With a run in flight, the gauge shows committed and reserved spend separately with threshold coloring. The clock shows seconds precision. Status counts take one compact strip. Each feature row names its current phase.

**Acceptance Scenarios**:

1. **Given** a run in flight, **When** the topbar renders, **Then** the budget gauge shows committed (solid) and reserved (hatched) spend separately, colored safe, warning (>80%) or tripped, with the numeric figures legible. The breaker state is not repeated inside the gauge text.
2. **Given** the topbar clock, **When** it renders, **Then** it shows time to the second, with no sub-second digits.
3. **Given** a run where most status counts are zero, **When** Mission Control renders, **Then** all status counts sit in one compact row, zero counts are de-emphasized, and the feature table appears within the first viewport at 1440×900.
4. **Given** a feature mid-pipeline, **When** its row renders, **Then** the phase pips are accompanied by the current phase name and position (for example `clarify · 2/7`). Pips keep a per-pip title (§V).
5. **Given** the telemetry feed, **When** events arrive, **Then** each row follows the event-feed pattern: time, status dot, mono feature id, then predicate.

---

### User Story 5 - Configuration changes are precise and safe to apply (Priority: P2)

An operator changes per-phase models or the budget on Configuration, sees that there are unsaved changes, and applies them knowing what they affect.

**Why this priority**: The budget can only be set by a slider, which is imprecise for money. The Apply button sits below the fold with no unsaved-changes signal, and the first section's title collides with its border.

**Independent Test**: Change one model and type an exact budget. An unsaved-changes indicator appears with Apply and Reset reachable without scrolling. After Apply, the confirmation echoes the call and states whether the active run is affected.

**Acceptance Scenarios**:

1. **Given** the Configuration view, **When** the operator edits any field, **Then** an unsaved-changes indicator appears, and Apply and Reset stay visible without scrolling.
2. **Given** the budget control, **When** the operator types an exact amount, **Then** the value is accepted with cent precision, and the slider (if kept) reflects it.
3. **Given** a run in flight, **When** the operator applies a change, **Then** the confirmation echoes the call and its arguments (§V Toast) and states whether the change affects the in-flight run or only the next one.
4. **Given** the read-only served repository and instance node, **When** they render, **Then** they appear as a record block (§V), not as a form section.
5. **Given** every section title, **When** it renders, **Then** it does not overlap its section border.

---

### User Story 6 - Secondary views use space and copy well (Priority: P3)

The Pipeline Chain, Runs, Escalations and sidebar views use the available width, consistent labels and a clear hierarchy.

**Why this priority**: These are polish items. They improve scanning speed but do not block any task.

**Independent Test**: Review each view at 1440×900 against the acceptance scenarios below.

**Acceptance Scenarios**:

1. **Given** Pipeline Chain at 1440px, **When** it renders, **Then** feature cards use the available width (not a single narrow column), each feature carries one identifier (no separate positional ordinal), and the legend lists only states present in the chain.
2. **Given** the wave picker on Pipeline Chain, **When** it renders, **Then** it has a visible label.
3. **Given** the nav and page titles, **When** compared, **Then** each nav label matches its page title ("Pipeline Chain" in both places), and status labels share one casing rule.
4. **Given** the sidebar footer, **When** the target path is long, **Then** it shows the repository name on one line (ellipsized, never wrapped, §III), with the full path available on hover and copyable.
5. **Given** the Escalations empty state, **When** no escalations exist, **Then** the title outranks the body copy in size and weight.
6. **Given** a run with many features in the Runs list, **When** its row renders, **Then** the feature column shows a per-status count summary, with per-feature detail on the run's detail page.
7. **Given** the Trigger backlog summary, **When** it renders, **Then** labels are statements (for example "DAG validated"), not questions, and the source path is shown without a leading ellipsis truncation that hides the package root.
8. **Given** Run Detail phase rows, **When** they render, **Then** rows use the standard data-table density (the shipped data-table cell padding; §IV's "13px" is off its own 2px grid), and the transcript link does not inflate row height.

---

### User Story 7 - The console loads cleanly (Priority: P3)

The browser console shows no errors or warnings when any view loads.

**Why this priority**: The favicon 404 and font-preload warnings are noise that can hide real errors during debugging.

**Independent Test**: Load each view with a clean browser console. Zero errors and zero warnings are reported.

**Acceptance Scenarios**:

1. **Given** any view, **When** it loads, **Then** no request returns 404 (including the favicon).
2. **Given** any view, **When** it loads, **Then** no "preloaded but not used" font warning appears.

### Edge Cases

- **Very long identifiers** (slugs, paths, branch names): ellipsize on one line, with the full value on hover. Identifiers never wrap (§III).
- **Budget at or over 100%**: the gauge shows the tripped color, and committed may exceed the track without overflowing the layout.
- **In-flight run ends while the confirmation is armed**: the button returns to its normal one-click state.
- **No run in flight**: Trigger Run shows no supersede hint or confirmation, and the topbar shows the idle state.
- **A settings value that is a nested structure or list**: render it compactly in machine text without internal bookkeeping keys, and never as a raw language literal.
- **Transcripts with malformed or unclosed markup**: render what parses and show the rest as plain text. Never drop content.
- **Transcript containing raw HTML-like text**: shown as text, never interpreted as markup on the page.
- **Narrow screen with a drawer open**: the drawer fits the viewport width.
- **Config Apply rejected by validation**: the unsaved-changes indicator stays, and errors appear next to their fields.

## Requirements *(mandatory)*

### Functional Requirements

**Truthful, readable data (US1)**

- **FR-001**: Run Detail MUST NOT display internal bookkeeping keys of the recorded settings (for example the record of which options were given explicitly) or any raw language-level data literal.
- **FR-002**: Run Detail MUST show each recorded setting exactly once. `containment_profile` MUST appear in a single place.
- **FR-003**: Run Detail MUST render settings as a key/value record block (§V) using the real config key names. String values MUST appear without quoting artefacts.
- **FR-004**: The Transcripts view MUST render transcript markup (emphasis, inline code, code blocks, lists, headings) as formatting, in the mono family, at no less than 12.5px.
- **FR-005**: Transcript markup rendering MUST treat embedded HTML as inert text. Unparseable fragments MUST appear verbatim.
- **FR-006**: Transcript body text MUST wrap at a readable measure of about 80–100 characters.
- **FR-007**: The Transcripts view MUST let the operator choose the run whose transcripts are shown, defaulting to the active (or latest) run.
- **FR-008**: Run state and outcome chips on Runs and Run Detail MUST show the real identifiers in their status color and MUST meet WCAG AA contrast against their background (4.5:1 for text).

**Trigger Run (US2)**

- **FR-009**: Every form control in the console MUST use the console's themed input styling. No control may render with the platform's default light styling.
- **FR-010**: When a run is in flight, both start actions MUST use an inline two-step confirmation. The first activation changes the button in place to "Supersede <active run id> and start", shows a mono hint stating the consequence (the active run is drained and superseded), and offers Cancel. Only the second activation starts the run. Cancel, navigating away, or the in-flight run ending MUST return the button to its normal state. No modal dialog is used.
- **FR-011**: When no run is in flight, the start actions MUST behave exactly as today, with no extra step.
- **FR-012**: Fields that depend on a toggle (interactive clarify's answer timeout and max rounds) MUST be hidden while the toggle is off.
- **FR-013**: Trigger options MUST be grouped into labelled sections (auto-remediation, clarify, containment), with one control per row, labelled with the real option names, and consistent label and control sizes.

**Narrow screens (US3)**

- **FR-014**: Every view MUST render at a 390px viewport width without horizontal page scroll or clipped content.
- **FR-015**: Below a narrow-width breakpoint the nav MUST stay a persistent, single-level left rail collapsed to a compact strip (icons or short labels). Every destination stays reachable in one tap, the active item stays marked, and attention-count badges stay visible. The full-width rail returns above the breakpoint. Each compact item MUST expose its full label (tooltip or accessible name).
- **FR-016**: At narrow widths, feature tables MUST present each feature's id, status, current phase and spend without sideways scrolling.

**Above the fold (US4)**

- **FR-017**: The topbar budget gauge MUST show committed spend (solid) and reserved spend (hatched) separately, MUST change color at the warning (>80%) and tripped thresholds, and MUST show legible figures. Breaker state MUST NOT be repeated inside the gauge text.
- **FR-018**: The topbar clock MUST display time to whole seconds.
- **FR-019**: Mission Control MUST present all status counts in one compact row, de-emphasize zero counts, and show the feature table within the first viewport at 1440×900.
- **FR-020**: Every phase-pip track that represents a feature's progress MUST be accompanied by the current phase name and its position in the pipeline. Pips MUST keep per-pip titles.
- **FR-021**: The telemetry feed MUST follow the event-feed pattern (time · status dot · mono id · predicate), newest first, keeping real phase and outcome identifiers.

**Configuration (US5)**

- **FR-022**: Configuration MUST show an unsaved-changes indicator whenever any field differs from the applied configuration. Apply and Reset MUST remain visible without scrolling while changes are pending.
- **FR-023**: The budget MUST be enterable as an exact amount with cent precision.
- **FR-024**: After Apply, the confirmation MUST echo the call and its arguments. When a run is in flight, it MUST state that the change applies forward-only to that run's not-yet-started work (never retroactively) and is not saved as a cross-run default. This is the existing apply behaviour, made visible.
- **FR-025**: Read-only instance information (served repository, instance node) MUST render as a record block, not as editable-looking form sections.
- **FR-026**: Section titles MUST NOT overlap section borders anywhere in the console.

**Secondary views (US6)**

- **FR-027**: Pipeline Chain MUST use the available width at desktop sizes, show one identifier per feature, label the wave picker, and list in its legend only the states present.
- **FR-028**: Nav labels MUST match page titles, and status labels MUST follow one casing rule across the console.
- **FR-029**: The sidebar target-repository display MUST show the repository name on one line, with the full path available on hover and copyable.
- **FR-030**: Empty-state titles MUST outrank their body copy in visual hierarchy.
- **FR-031**: The Runs feature column MUST summarize per-status counts.
- **FR-032**: The Trigger backlog summary MUST use statement labels and show the source path without hiding its root.
- **FR-033**: Run Detail phase rows MUST use the standard data-table row density.

**Clean load (US7)**

- **FR-034**: No console view may produce a 404 or a browser console warning on load, including the favicon and font preloads.

**Design governance (all stories)**

- **FR-035**: Every visual value introduced or changed MUST come from the console's single design-token block. Status color MUST travel only as a status name. The existing design-contract guard MUST pass unchanged or be extended, never relaxed.
- **FR-036**: No change may rename a real system identifier (atom, config key, function, path) to a friendly synonym (§I.3, §VIII).
- **FR-037**: Any rule in `docs/design-constitution.md` that this feature needs to change MUST be amended in the same change, with rationale. The default is to change no rule. Known amendment: three §II token values (FR-038).
- **FR-038**: All operator-facing text (including secondary and faint steps, field labels and chip text) MUST meet 4.5:1 contrast against its background, or 3:1 for large text. Non-text UI MUST meet 3:1 where it is the only carrier of state or affordance: focus indicators, gauge fills, toggle and checkbox state, and input boundaries. Chip borders and future phase pips are exempt, because the chip text and the pip title and phase label carry that state. Disabled controls are exempt. Meeting this changes three token values (`--text-faint`, `--pending`, `--blocked`); see plan research R8.

### Key Entities

- **Run settings record**: the settings recorded with a run (config keys and values, plus internal bookkeeping such as which options were given explicitly). Only the config keys and values are operator-facing.
- **Transcript document**: one phase session's model output for a feature. Machine-produced text with lightweight markup.
- **Budget ledger snapshot**: committed spend, reserved spend, budget and breaker state for the active run.
- **Pending configuration change**: the difference between the fields as edited and the applied configuration.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero raw internal data literals or bookkeeping keys appear on any console view, checked against a run whose settings include them.
- **SC-002**: Each recorded run setting appears exactly once on Run Detail (today `containment_profile` appears 3 times).
- **SC-003**: All 8 views render at 390×844 with no horizontal page scroll and no clipped content, and every nav destination is reachable from each.
- **SC-004**: An operator can identify a feature's current phase from Mission Control without hovering, for 100% of in-flight features.
- **SC-005**: On Mission Control at 1440×900, the first feature row is visible without scrolling.
- **SC-006**: Every form control across the console uses themed styling (0 light-styled native controls).
- **SC-007**: With a run in flight, 0 of 2 start actions can start a new run without an explicit confirmation that names the in-flight run.
- **SC-008**: Loading each of the 8 views produces 0 browser console errors and 0 warnings.
- **SC-009**: The design-contract guard and the full test suite pass. No design literal exists outside the token block.
- **SC-010**: A budget can be set to an exact cent amount in one edit.
- **SC-011**: 100% of operator-facing text and stateful non-text UI across the 8 views meets the FR-038 contrast ratios.

## Assumptions

- The design constitution governs. The audit's "modern minimalist" goal is read as removing noise and duplication, not adding whitespace or decoration.
- Desktop (1440×900) is the primary operator viewport. Narrow-width support aims at status checking, not at running every workflow comfortably.
- Starting a run while one is in flight stays a legitimate action (it drains and supersedes the prior run). It gains a consequence hint and a confirmation, but is not forbidden.
- Transcript rendering stays within the mono family because transcripts are machine-produced (§III mono rule).
- Applying a configuration change already retunes only the live run's not-yet-started work, forward-only, and is not persisted as a cross-run default. The console only states this.
- The console keeps its current constraint of hand-authored styling with no frontend build tooling.
- The audit screenshots (`.playwright-mcp/ui-0*.png`, 2026-10-07) are the baseline for before/after comparison.
