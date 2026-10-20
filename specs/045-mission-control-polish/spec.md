# Feature Specification: Mission Control Polish

**Feature Branch**: `045-mission-control-polish`

**Created**: 2026-10-20

**Status**: Draft

**Input**: User description: "Let's improve the UI. Mission Control: must be possible to hide and show telemetry view; the main panel that shows all phases of a running wave and its progress sometimes expands behind the telemetry view; remove the badge `live session` in current running phase; the live session panel must show only header and footer in Mission Control — if the user wants to see the whole conversation they must click `open full view`, so we don't need the toggles `follow conversations` and `show all frames` in this case; style the link `open full view` as a button."

## Clarifications

### Session 2026-10-20

- Q: Which "live session" badge is removed — the backlog row link, the embedded panel's badge, or both? → A: Only the backlog row link; the embedded panel's live/ended badge stays.
- Q: How does the backlog table behave when wider than the main column? → A: Secondary text (slug etc.) truncates with ellipsis, full text on hover; phase strip never truncated; table scrolls horizontally within the main column only if still overflowing.
- Q: Where does the telemetry hide/show control live? → A: A "hide" control in the telemetry feed's header; while hidden, a "show telemetry" control at the top-right of the main panel, beside the status count strip.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Main panel never hides behind telemetry (Priority: P1)

An operator watches a running wave on Mission Control. The main panel — the status count strip, the backlog table with each feature's phase strip and progress, and the embedded live session panel — always stays fully visible in its own column. No part of it (a long phase strip, a wide table, a long header line in the live session panel) slides underneath the telemetry feed, at any supported window width.

**Why this priority**: This is a defect: progress the operator came to read is physically covered. Every other change here is a refinement; this one restores basic legibility.

**Independent Test**: Open Mission Control with a run in flight whose rows carry the longest realistic content (all phases shown, chunk and remediation markers, long feature slug, long session header), at the widest and narrowest two-column widths, and confirm no main-panel content is drawn under the telemetry feed; secondary text truncates (full text on hover), the phase strip stays whole, and the table scrolls inside the main column only as a last resort.

**Acceptance Scenarios**:

1. **Given** a running wave whose backlog table is wider than the main column, **When** Mission Control renders in the two-column layout, **Then** long slugs and other secondary text truncate with an ellipsis (full text on hover), every phase in the phase strip stays fully visible, the table scrolls horizontally inside the main column only if it still does not fit, and it never overlaps the telemetry feed.
2. **Given** the embedded live session panel shows a long header line, **When** it renders, **Then** the line wraps or truncates within the main column rather than extending behind the telemetry feed.
3. **Given** the window is narrowed past the single-column breakpoint, **When** the layout stacks, **Then** the telemetry feed sits below the main panel and nothing overlaps.

---

### User Story 2 - Hide and show the telemetry feed (Priority: P1)

An operator who wants more room for the backlog table and live session panel collapses the telemetry feed with a "hide" control in the feed's header. The main panel then uses the full width, and a "show telemetry" control appears at the top-right of the main panel, beside the status count strip, to bring the feed back. The choice is remembered when the operator reloads or comes back to Mission Control in the same browser.

**Why this priority**: Gives the operator direct control over screen space and is the natural companion to Story 1 — with the feed hidden, nothing can be covered.

**Independent Test**: With a run in flight, hide the telemetry feed, confirm the main panel spans the full width and the feed is gone; reload the page and confirm it is still hidden; show it again and confirm the feed returns with its current entries.

**Acceptance Scenarios**:

1. **Given** Mission Control with the telemetry feed visible, **When** the operator activates the "hide" control in the feed's header, **Then** the feed disappears, the main panel expands to the full content width, and a "show telemetry" control appears beside the status count strip.
2. **Given** the feed is hidden, **When** the operator activates the "show telemetry" control, **Then** the feed reappears showing its current entries (events that arrived while hidden are included, not lost).
3. **Given** the operator hid the feed, **When** they reload Mission Control or navigate away and back in the same browser, **Then** the feed is still hidden.
4. **Given** the feed is hidden and the console flags live status as delayed, **When** the page renders, **Then** the delayed-status notice is still visible to the operator (it is not hidden along with the feed).
5. **Given** a keyboard-only operator, **When** they tab to the "hide" or "show telemetry" control, **Then** it is focusable, operable with the keyboard, and announces whether the feed is currently shown or hidden.

---

### User Story 3 - Compact live session panel with a clear way to the full view (Priority: P2)

On Mission Control, the embedded live session panel shows only the session's header (run, feature, phase, session identifiers, model) and its footer (the sticky status line: current activity, token figures, done/failed state). It does not show the conversation body. A prominent **open full view** button takes the operator to the full conversation page when they want to read the exchange. Because the panel no longer shows a conversation body, its **follow conversations** and **show all frames** toggles are removed from the embedded panel; the panel keeps tracking whichever session is currently in flight on its own.

**Why this priority**: Reduces visual noise and vertical space on the overview page and removes controls that have no effect there; the full conversation remains one click away.

**Independent Test**: With a session in flight, open Mission Control and confirm the panel shows header and status footer only, with no conversation rows and no follow/frames toggles; click **open full view** and confirm the full conversation page opens for that session with its own toggles intact; let the session end and the next begin and confirm the panel switches to the new session without operator action.

**Acceptance Scenarios**:

1. **Given** a session in flight, **When** Mission Control renders the live session panel, **Then** it shows the live/ended badge, the session header and the status footer, and no conversation entries.
2. **Given** the embedded panel, **When** it renders, **Then** neither a "follow conversations" nor a "show all frames" control is present.
3. **Given** the embedded panel shows a session, **When** the operator clicks **open full view**, **Then** the full conversation page for that same session opens, where follow-conversations and show-all-frames remain available exactly as before.
4. **Given** the shown session ends and a new one starts, **When** the panel updates, **Then** it moves to the new in-flight session automatically, as it does today with following on.
5. **Given** no session is in flight, **When** the panel renders, **Then** it shows the existing "no agent session in flight" empty state and no **open full view** button.
6. **Given** the full conversation page (not embedded), **When** it renders, **Then** it is unchanged by this feature.

---

### User Story 4 - Cleaner running row (Priority: P3)

In the backlog table, the row of the feature currently running no longer carries the inline **live session** badge/link beside its status. The live session is reached through the embedded panel and its **open full view** button instead.

**Why this priority**: Pure de-cluttering; the badge duplicates the panel directly below and its button.

**Independent Test**: With a session in flight, confirm the running feature's row shows its status pill (and awaiting-answers meta when applicable) but no live session badge, and that the full view is still reachable from the panel's button.

**Acceptance Scenarios**:

1. **Given** a feature with a live session, **When** its backlog row renders, **Then** no "live session" badge or link appears in the row.
2. **Given** a feature awaiting answers, **When** its row renders, **Then** the awaiting-answers meta is still shown.

---

### User Story 5 - "open full view" reads as a button (Priority: P3)

The **open full view** control in the embedded panel is styled as a button consistent with the console's existing secondary buttons, so operators recognise it as the primary action of the panel rather than a stray text link.

**Why this priority**: Visual affordance; makes Story 3's single path to the conversation obvious.

**Independent Test**: Inspect the panel and confirm the control uses the console's established button appearance (border/fill, padding, hover and focus states) and still navigates like a link (opens the full page, can be opened in a new tab).

**Acceptance Scenarios**:

1. **Given** the embedded panel with a session, **When** it renders, **Then** **open full view** has the same visual treatment as the console's secondary buttons, including visible hover and keyboard-focus states.
2. **Given** the operator middle-clicks or uses "open in new tab", **When** they do so on **open full view**, **Then** the full conversation page opens in a new tab (it remains a real navigation target).

---

### Edge Cases

- Telemetry hidden while the run finishes or parks: the finished report and parked banner render as today; the hide preference persists for the next run.
- Telemetry hidden and browser storage unavailable (private window, blocked site data): the control still works for the current page view; the feed simply defaults to shown on the next load.
- Recovered (no live Coordinator) runs that still show the live layout: the hide/show control and compact panel behave identically.
- Narrow (single-column) layout: hiding the feed removes it from the stacked layout; showing it puts it back below the main panel.
- The embedded panel was pinned to a session that is no longer live (ended, not found): it shows the existing ended/not-found states with header/footer only; **open full view** appears only when there is a session to open.
- A session whose header is missing (pre-040 or not-captured record): the panel shows whatever header and footer data exist, without falling back to rendering conversation entries.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Mission Control's main panel (status strip, backlog table, embedded live session panel) MUST never render underneath or overlap the telemetry feed at any window width. In the backlog table, secondary text (slug and other secondary cells) MUST truncate with an ellipsis and reveal the full text on hover; the phase strip MUST never be truncated; if the table still exceeds the main column, it MUST scroll horizontally within the main column. Long lines in the live session panel header MUST wrap or truncate within the main column.
- **FR-002**: Whenever the live run layout is shown, Mission Control MUST provide a "hide" control in the telemetry feed's header while the feed is visible, and a "show telemetry" control at the top-right of the main panel, beside the status count strip, while the feed is hidden. Exactly one of the two is present at any time.
- **FR-003**: When the telemetry feed is hidden, the main panel MUST expand to the full content width; when shown, the two-column (or stacked, on narrow screens) layout MUST be restored.
- **FR-004**: Hiding the telemetry feed MUST NOT discard events; showing it again MUST display the same entries it would have shown had it never been hidden.
- **FR-005**: The telemetry hide/show choice MUST persist across reloads and navigation in the same browser, defaulting to shown when no choice is stored or storage is unavailable.
- **FR-006**: The delayed-status notice currently shown in the telemetry column MUST remain visible to the operator while the feed is hidden.
- **FR-007**: Both the "hide" and "show telemetry" controls MUST be keyboard operable and expose its current state (shown/hidden) to assistive technology.
- **FR-008**: The backlog table MUST NOT show the inline "live session" badge/link in any feature row. The embedded live session panel's own live/ended badge MUST remain.
- **FR-009**: The embedded live session panel on Mission Control MUST show only the live/ended badge, the session header and the status footer, and MUST NOT render conversation entries.
- **FR-010**: The embedded live session panel MUST NOT show the "follow conversations" or "show all frames" controls.
- **FR-011**: The embedded live session panel MUST continue to move automatically to the newest in-flight session when the shown one ends (today's follow-on behaviour, now implicit).
- **FR-012**: The embedded panel MUST show an **open full view** control, styled as a console secondary button with hover and focus states, whenever it has a session to open, and it MUST navigate to that session's full conversation page as a normal link.
- **FR-013**: The full conversation page (`/live`, not embedded) MUST be unchanged: header, footer, conversation body, follow-conversations and show-all-frames controls behave as before.
- **FR-014**: All new and changed styling MUST comply with the console design constitution and pass the existing mechanical design guard (tokens only, no inline styles, shared input/button classes, single narrow-screen breakpoint).

### Key Entities

- **Telemetry visibility preference**: a per-browser shown/hidden flag for Mission Control's telemetry feed; default shown; not shared between operators or stored server-side.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At every window width from the narrowest supported to the widest, 0 pixels of main-panel content are drawn under the telemetry feed for a run with the longest realistic row content.
- **SC-002**: An operator can hide or show the telemetry feed with exactly 1 action, and the choice survives 100% of page reloads in the same browser (when storage is available).
- **SC-003**: With the feed hidden, the backlog table and live session panel gain the full width previously used by the feed.
- **SC-004**: The embedded live session panel occupies no more vertical space than its header plus status footer, regardless of conversation length.
- **SC-005**: The full conversation for the in-flight session is reachable from Mission Control in 1 click, via a control visually identifiable as a button.
- **SC-006**: Mission Control shows 0 "live session" badges in backlog rows and 0 follow/frames toggles in the embedded panel; the full conversation page keeps both toggles.
- **SC-007**: The console's design guard and existing test suite pass with no new exceptions.

## Assumptions

- "Remove the badge `live session` in current running phase" refers to the inline live-session badge/link in the running feature's backlog row only (confirmed in Clarifications). The embedded panel's own live/ended badge is kept.
- "Header and footer" of the live session panel means the existing session identification header (run · feature · phase · ordinal · session id · model) and the sticky status line introduced by feature 042; no new fields are added.
- The telemetry preference is per browser (operator convenience), not a server-side setting; the console has a single operator surface with no user accounts.
- Hiding the feed is a presentation choice only; the telemetry subscription and buffer continue unchanged.
- Default state for the telemetry feed is shown, preserving today's first impression.
- Only Mission Control is in scope; Run Detail, Transcripts and the full `/live` page are not changed (beyond the shared button style becoming available).
- No change to stored run records, conversation files, or the control plane.
