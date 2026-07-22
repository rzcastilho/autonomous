# Feature Specification: Control Plane UI Redesign

**Feature Branch**: `011-control-plane-ui-redesign`

**Created**: 2026-07-22

**Status**: Draft

**Input**: User description: "Redesign UI using as reference @docs/control-plane-design-reference/"

## Clarifications

### Session 2026-07-22

- Q: Should the redesign exactly match the reference file's specific visual details (colors, fonts, layout metrics), or only use it as general style direction? → A: Exact match — adopt reference's specific palette, typography, logo mark, and layout metrics as the definitive design system.
- Q: The reference loads its typography from Google Fonts' CDN at runtime — should the console do the same, or self-host the font files? → A: Self-host font files with the app (bundled asset, no external network call at runtime).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Consistent console shell (Priority: P1)

An operator opens the console and sees a persistent left sidebar (branding, target-repo/connection status, and links to Mission Control, Pipeline DAG, Trigger Run, Escalations, Transcripts, Configuration) plus a top bar showing the active run's state, title, cost gauge, breaker status, and a live clock — all rendered in the new visual design instead of today's unstyled links and plain status line.

**Why this priority**: Every other view is reached through this shell. It establishes the shared visual language (color coding, typography, spacing) that the rest of the redesign depends on, and on its own already replaces the console's current bare-HTML navigation with a legible, professional interface.

**Independent Test**: Load any console route; verify the sidebar highlights the active section, shows an escalation-count badge when escalations are open, and the top bar's cost gauge/breaker chip/clock reflect the live run and ledger state (or an empty/no-run state when nothing is running).

**Acceptance Scenarios**:

1. **Given** a run is active, **When** the operator loads any console page, **Then** the sidebar shows all six navigation destinations with the current one visually marked as active, and the top bar shows the run's title, mode, concurrency, cost gauge (committed vs. budget), and breaker status.
2. **Given** one or more features are escalated, **When** the operator views the sidebar, **Then** the "Escalations" link shows a badge with the current open-escalation count, updating live as escalations are opened or resolved.
3. **Given** no run is active, **When** the operator loads the console, **Then** the top bar shows a clear "no active run" state instead of stale or fabricated run data.

---

### User Story 2 - Mission Control at-a-glance status (Priority: P2)

An operator viewing Mission Control sees status-count summary cards, a backlog table (feature id, slug, colored status, seven-phase progress indicator, elapsed time, spend) and a live telemetry feed, styled consistently with the reference design, so they can assess overall run health in seconds rather than reading a plain HTML table.

**Why this priority**: Mission Control is the primary landing view and the one operators return to most; improving its scannability delivers the largest share of the redesign's value after the shell itself.

**Independent Test**: With a run active, open Mission Control and verify the status-count cards match the current counts per lifecycle status, the backlog table rows are colored/labeled by status and show live-updating phase progress, and the telemetry feed appends new events without a page reload.

**Acceptance Scenarios**:

1. **Given** features in various statuses, **When** the operator opens Mission Control, **Then** one summary card per lifecycle status (pending, blocked, running, escalated, halted, failed, done) shows the correct count with its status color.
2. **Given** a feature is progressing through phases, **When** its phase advances, **Then** its row's phase-progress indicator and elapsed/spend figures update live without a page reload.
3. **Given** the operator clicks a backlog row, **When** the row is selected, **Then** the feature drawer opens showing that feature's detail.
4. **Given** no run is active, **When** the operator opens Mission Control, **Then** a styled empty state directs them to Trigger Run.

---

### User Story 3 - Pipeline DAG visualization (Priority: P3)

An operator viewing the Pipeline DAG page sees feature nodes arranged by dependency wave with connecting edges to their prerequisites, each node showing id, slug, status, phase progress, and spend, plus a status color legend, replacing today's unstyled listing.

**Why this priority**: The DAG view is used less frequently than Mission Control but is the only place operators can see dependency structure and wave shape at a glance; it depends on the shell and status color system already established in P1/P2.

**Independent Test**: Open Pipeline DAG with a multi-feature backlog and verify every feature appears as a node positioned consistently with its dependency wave, edges connect each node to its prerequisites, and the legend's colors match the status colors used elsewhere in the console.

**Acceptance Scenarios**:

1. **Given** features with prerequisite relationships, **When** the operator opens Pipeline DAG, **Then** each feature is rendered as a node with an edge drawn to each of its prerequisites.
2. **Given** a node's status changes, **When** the change occurs, **Then** the node's color and phase-progress indicator update live without a page reload.
3. **Given** the operator clicks a node, **When** the node is selected, **Then** the feature drawer opens showing that feature's detail.

---

### User Story 4 - Escalation review and resolution (Priority: P4)

An operator viewing Escalations sees one structured card per escalated or halted feature with its checkpoint details (last phase, status, session id, reason), run-context values, the specific clarification question(s) that triggered the gate, and clearly labeled actions to resume from checkpoint (optionally overriding the start phase or adding operator guidance) or fully restart, replacing today's unstyled listing.

**Why this priority**: Escalation review is a human-in-the-loop gate central to the orchestrator's design, but it is exercised less often than Mission Control/DAG viewing, so it follows those in priority while still depending on the shell/status system.

**Independent Test**: With at least one escalated feature, open Escalations and verify the checkpoint fields, run-context values, and clarification question(s)/options render correctly, and that triggering "resume" or "resolve" invokes the existing underlying actions unchanged.

**Acceptance Scenarios**:

1. **Given** a feature escalated at a gate, **When** the operator opens Escalations, **Then** a card shows the checkpoint's last phase, status, session id, reason, run-context values, and the clarification question(s)/options that caused the escalation.
2. **Given** the operator enters resume guidance and/or picks a start phase, **When** they trigger "Resume", **Then** the existing resume behavior runs unchanged, using the entered guidance/phase.
3. **Given** the operator triggers "Full restart", **When** confirmed, **Then** the existing resolve behavior runs unchanged.
4. **Given** no escalations are open, **When** the operator opens Escalations, **Then** a styled empty/success state is shown instead of a blank list.

---

### User Story 5 - Feature drawer detail (Priority: P5)

An operator who opens a feature's drawer (from Mission Control or Pipeline DAG) sees a phase-by-phase timeline with consistent status coloring, elapsed/spend/prerequisite summary, and context-appropriate actions (open transcript; resume/resolve when applicable; view PR when done), replacing today's unstyled drawer.

**Why this priority**: The drawer is a supporting detail view reached from higher-priority pages; it rounds out the redesign once the primary list/board views are done.

**Independent Test**: Open the drawer for features in different statuses (running, escalated, done) and verify the timeline, summary stats, and the specific action set shown match that feature's actual state.

**Acceptance Scenarios**:

1. **Given** a feature with completed and pending phases, **When** its drawer opens, **Then** the timeline shows each phase's status with consistent coloring and per-phase metadata.
2. **Given** an escalated/halted feature, **When** its drawer opens, **Then** resume and open-escalation actions are shown alongside the checkpoint summary.
3. **Given** a done feature, **When** its drawer opens, **Then** a "view PR" action is shown instead of resume/resolve controls.

---

### User Story 6 - Trigger, Transcripts, and Configuration pages (Priority: P6)

An operator using Trigger Run (backlog run vs. single free-text spec), Transcripts (per-feature, per-phase transcript browsing), or Configuration (per-phase model routing, budget, concurrency, PR workflow toggle) sees each page restyled to match the reference's forms, tabs, sliders, and toggles, replacing today's unstyled forms and lists.

**Why this priority**: These pages are used less frequently (setup and audit tasks rather than continuous monitoring), so their restyle is valuable but lowest priority; each is independently small and can ship last without blocking the higher-value monitoring views.

**Independent Test**: Open each of the three pages independently and verify existing functionality (starting a run in either mode, selecting a feature/phase transcript, changing model routing/budget/concurrency/PR toggle) still works, now with the new styled controls.

**Acceptance Scenarios**:

1. **Given** the operator is on Trigger Run, **When** they switch between "Backlog run" and "Single-spec" tabs, **Then** the corresponding styled form is shown and existing start-run behavior is unchanged.
2. **Given** the operator is on Transcripts, **When** they select a feature and a phase tab, **Then** that phase's transcript body renders in the content pane.
3. **Given** the operator is on Configuration, **When** they change a per-phase model, the budget, the concurrency, or the PR workflow toggle, **Then** the existing live-config update behavior fires unchanged and the control's new visual state reflects the change.

---

### Edge Cases

- What happens when no run is active? Mission Control and the top bar MUST show a clear styled empty state rather than blank or stale content (carried over from current behavior, restyled).
- What happens when there are zero escalations? Escalations MUST show a styled success/empty state rather than an empty list.
- How does the layout handle a large number of features in the backlog table, DAG, or transcript feature list? Lists MUST remain scrollable within their container without breaking the overall page layout.
- How does the layout handle long feature slugs or long transcript/session identifiers? Text MUST truncate (e.g., with ellipsis) rather than overflow or break the layout.
- How does the layout behave at narrower desktop window widths? The two-column layouts (e.g., Mission Control's backlog + telemetry feed) MUST collapse to a single column below a reasonable minimum width rather than clipping content.
- What happens while an escalated feature's checkpoint data is incomplete or a field is missing? The affected field MUST show a neutral placeholder rather than an error or broken layout.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The console MUST present a persistent sidebar with product branding, connection/target-repo status indicators, and links to Mission Control, Pipeline DAG, Trigger Run, Escalations, Transcripts, and Configuration, with the current section visually marked as active.
- **FR-002**: The sidebar's Escalations link MUST show a live count badge whenever one or more escalations are open, and MUST show no badge when there are none.
- **FR-003**: The console MUST present a persistent top bar showing: run state, run title/mode/concurrency, a cost gauge (committed spend vs. budget, with reserved spend visually distinguished), a cost-breaker status indicator, and a live clock, all reflecting the actual run/ledger state.
- **FR-004**: When no run is active, the top bar and Mission Control MUST show a distinct "no active run" state instead of empty or fabricated data.
- **FR-005**: Mission Control MUST show one summary card per feature lifecycle status (pending, blocked, running, escalated, halted, failed, done) with the live count for each.
- **FR-006**: Mission Control MUST show a backlog table with, per feature: id, slug, status (color + label), a seven-phase progress indicator, elapsed time, and spend; rows MUST remain clickable to open that feature's drawer.
- **FR-007**: Mission Control MUST show a live telemetry feed of recent events that appends new entries without a page reload, bounded to a fixed maximum number of visible entries.
- **FR-008**: Pipeline DAG MUST render every feature as a node positioned according to its dependency wave, with an edge drawn from each feature to each of its prerequisites.
- **FR-009**: Pipeline DAG nodes MUST show id, slug, status, phase progress, and spend, and MUST update live as the underlying feature state changes.
- **FR-010**: Pipeline DAG MUST include a legend mapping each status to its color, using the same status-color mapping as Mission Control and the feature drawer.
- **FR-011**: Escalations MUST show one card per escalated or halted feature containing its checkpoint fields (last phase, status, session id, reason), its recorded run-context values, and the clarification question(s)/options that triggered the gate.
- **FR-012**: Escalations MUST provide a resume action (supporting optional operator guidance text and an optional start-phase override) and a full-restart action, both invoking the existing underlying behaviors unchanged, plus a link to open the relevant phase transcript.
- **FR-013**: Escalations MUST show a styled empty/success state when no escalations are open.
- **FR-014**: The feature drawer MUST show elapsed time, spend, and prerequisite summary, plus a phase-by-phase timeline using the same status color mapping as the rest of the console.
- **FR-015**: The feature drawer MUST show context-appropriate actions: open transcript always; resume/open-escalation actions when the feature is escalated or halted; a view-PR action when the feature is done.
- **FR-016**: Transcripts MUST list features for selection and, per selected feature, show per-phase tabs; selecting a phase MUST render that phase's transcript body.
- **FR-017**: Configuration MUST show per-phase model routing controls, budget and concurrency controls, and a PR-workflow toggle, all reflecting and updating the live configuration exactly as today.
- **FR-018**: Trigger Run MUST support both existing modes (backlog run; single free-text spec) via a styled mode switch, preserving existing start-run behavior for each mode.
- **FR-019**: The visual design MUST match `docs/control-plane-design-reference/` exactly — its specific color palette (including status colors), typography, logo mark, and layout metrics are the definitive design system, applied consistently across all six console pages and the feature drawer, adapted only to the console's real data (per Assumptions).
- **FR-020**: The redesign MUST NOT change any existing route, LiveView data flow, PubSub event handling, or user-facing behavior beyond presentation — it is a visual/markup layer change only.
- **FR-021**: Typography (and any other visual asset the design system requires) MUST be bundled/self-hosted with the application; the console MUST NOT depend on an external network request (e.g., a font CDN) at runtime to render correctly.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can identify a feature's lifecycle status (pending/blocked/running/escalated/halted/failed/done) at a glance via consistent color coding, without reading text labels, from any of Mission Control, Pipeline DAG, or the feature drawer.
- **SC-002**: All six console pages and the feature drawer present a visually consistent design system (shared color palette, typography, and spacing) after the redesign, with zero pages left in the prior unstyled state.
- **SC-003**: An escalated feature's full checkpoint context (phase, reason, session, run context, and clarification question) is visible directly from the Escalations page without requiring navigation to another page.
- **SC-004**: An operator can move between all six console areas via the persistent sidebar without a full page reload interrupting an in-progress run's live updates.
- **SC-005**: Every operator action available before the redesign (select feature, resume, resolve, toggle PR workflow, adjust budget/concurrency/model routing, switch trigger mode, start run, browse transcripts) remains available and functionally unchanged after the redesign.

## Assumptions

- The console is used on desktop-width browser windows by operators running/monitoring orchestrator jobs; phone-width layouts are out of scope, but the layout should degrade gracefully down to a reasonably narrow desktop window (per the Edge Cases above).
- The visual language in `docs/control-plane-design-reference/` — its exact dark theme colors (including the `#7c5cff` accent and per-status palette), typography, logo mark, and layout metrics — is adopted as-is as the definitive design system for this redesign (confirmed via clarification), adapted only from the reference's simulated demo data to the console's real, live data sources.
- No new routes, LiveViews, backend endpoints, or data are introduced; this feature only changes the presentation layer of the existing Mission Control, Pipeline DAG, Trigger Run, Escalations, Transcripts, Configuration, and feature-drawer views delivered in `008-control-plane`.
- The existing feature lifecycle statuses and their current color semantics are preserved; only their visual treatment (styling) changes to match the reference's palette.
- Iconography can use simple text/symbol glyphs, consistent with the reference, rather than requiring an icon font or image asset library.
- The reference's typography (IBM Plex Sans/Mono) is self-hosted as a bundled application asset rather than fetched from an external font CDN at runtime (confirmed via clarification).
