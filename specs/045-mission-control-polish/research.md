# Research: Mission Control Polish

No `NEEDS CLARIFICATION` remained after `/speckit-clarify`; the items below
record the design decisions the plan rests on.

## R1 — Why the main panel slides under the telemetry feed

**Finding**: `.mission-grid` is `grid-template-columns: minmax(0, 1fr) 320px`
and `.mission-main` has `min-width: 0`, so the *column* shrinks correctly — but
`.backlog-table` (`width: 100%`, auto table layout, `overflow: hidden` on the
table itself only) cannot shrink below its min-content width (unbroken mono
slugs, `.cell-status` pill + meta, phase strip). The table overflows
`.mission-main` (overflow visible) into the feed column, and `.mission-feed` is
`position: sticky` with an opaque `--card` background, so it paints on top. The
embedded panel's `.conv-header` (one long mono line of ids) overflows the same
way.

**Decision**:
- Wrap the table in `<div class="backlog-scroll">` with `overflow-x: auto` —
  the last-resort horizontal scroll *inside* the main column (FR-001).
- Slug cell content goes in `<span class="cell-truncate" title={slug}>`:
  `display: block; max-width: var(--cell-truncate-max); overflow: hidden;
  text-overflow: ellipsis; white-space: nowrap`. Ellipsis in an auto-layout
  table needs a bounded inner block, not the `td`.
- `.cell-progress` gets `min-width: var(--phase-strip-min)` so `.phase-cell`
  (`flex: 1`) never collapses — the strip is never truncated; if the row still
  does not fit, the scroll container takes the remainder.
- `.mc-live-panel .conv-header`: `white-space: nowrap; overflow: hidden;
  text-overflow: ellipsis` with the full line in `title` (Principle VII:
  constrained identifiers ellipsize, not wrap).

**Alternatives considered**: `table-layout: fixed` (forces fixed column widths,
breaks the density of short columns); `overflow: hidden` on `.mission-main`
(hides content rather than revealing it — violates FR-001's "fully visible");
raising `z-index` of the main column (main would then cover the feed — wrong
direction, still clipped).

## R2 — Where the telemetry preference lives

**Decision**: Server-authoritative assign `telemetry_hidden?` (default `false`)
on `MissionControlLive`, plus a client hook `TelemetryPref` in `app.js`:
- `mounted()`: read `localStorage["autonomous.mc.telemetry"]` inside
  `try/catch`; if `"hidden"`, `pushEvent("telemetry_restore", {hidden: true})`.
- server events: `"telemetry_hide"` / `"telemetry_show"` flip the assign and
  `push_event("telemetry_pref", %{hidden: bool})`.
- `handleEvent("telemetry_pref")`: write the key inside `try/catch`.

Rendering stays in HEEx, so FR-002 ("exactly one control") and FR-004/FR-006
are asserted with `Phoenix.LiveViewTest`; only the storage round-trip is
manual (quickstart Q3).

**Rationale**: Per-browser and not shared (spec Key Entities) ⇒ not Mnesia, not
`LiveConfig`. Pure-client `JS.toggle` would make the visible state invisible to
tests and drift against server patches of the same elements.

**Alternatives considered**: a cookie read at mount (needs a plug + session
plumbing for one boolean; still per-browser); `JS.set_attribute` only (no
server knowledge, untestable in LiveViewTest); storing in the run record
(violates "not stored server-side").

**Known trade-off**: on reload with the feed hidden, the static (dead) render
shows the feed until the socket connects and the hook restores — a sub-second
flash. Accepted: the spec requires persistence, not first-paint state, and
avoiding it needs the cookie plumbing rejected above.

## R3 — Hiding without losing events (FR-004)

**Decision**: Hiding only gates the `<ul class="telemetry-feed">` render;
`handle_info({:console, :feed, entry}, …)` keeps prepending to `view.feed`
(bounded at 200) regardless. Showing re-renders the same list.

## R4 — Delayed-status notice while hidden (FR-006)

**Decision**: The `[data-console-delayed]` paragraph renders in the feed column
when the feed is shown (unchanged), and at the top of `.mission-main` (above
the strip/controls row) when hidden. Same markup and attribute, one location
at a time.

## R5 — Control placement and accessibility (FR-002, FR-007)

**Decision**:
- **hide**: `<button type="button" class="btn-link mission-feed-toggle"
  phx-click="telemetry_hide" aria-expanded="true" aria-controls="mission-feed"
  data-telemetry-toggle="hide">hide</button>` at the right of
  `.mission-feed-header` (feed column gets `id="mission-feed"`).
- **show telemetry**: `<button type="button" class="btn-secondary btn-compact"
  phx-click="telemetry_show" aria-expanded="false" aria-controls="mission-feed"
  data-telemetry-toggle="show">show telemetry</button>`, in a new
  `.mission-main-head` flex row with the status strip (`flex: 1`), button
  right-aligned.
- `<button>` gives keyboard operation for free; `aria-expanded` announces the
  shown/hidden state.
- Grid: `.mission-grid[data-telemetry="hidden"] { grid-template-columns:
  minmax(0, 1fr); }` — the stacked `≤1120px` layout needs no extra rule
  because the feed element is simply absent.

## R6 — Compact embedded panel (FR-009..FR-012)

**Decision**: In `ConversationLive.render/1`, gate on `@embedded?`:
- embedded keeps: live/ended badge, **open full view**, `.conv-header`,
  `status_line/1`, the `not_reachable?` notice (a one-line status report of the
  panel's own state, not conversation content), and the empty/not-found states.
- embedded drops: follow and frames toggles, `#conversation-rows` stream,
  truncated notice, `next session:` link (follow is always on embedded, so a
  next session is attached in place — FR-011).
- `attach/2` and the `:entry` handler skip `ConversationRows.rows/2` and stream
  inserts when embedded; `SessionStatus.apply/2` still runs (footer stays live).
  `stream(:rows, [])` stays configured so shared code paths are unchanged.
- `follow?: embedded?` at mount already implements FR-011; `toggle_follow` /
  `toggle_frames` remain for `/live` only (unreachable from the embedded DOM).
- `/live` render path: identical markup (FR-013) — guarded by existing
  `conversation_live_test.exs` cases staying green unmodified.

**Alternatives considered**: hiding rows with CSS (`.mc-live-panel .conv-rows
{display:none}`) — still streams every frame over the socket and keeps the
dead toggles in the DOM, failing FR-010/SC-004's intent.

## R7 — "open full view" as a button (FR-012, US5)

**Decision**: `<a href={"/live/" <> id} class="btn-secondary btn-compact
conv-open-full">open full view</a>` — a real link (middle-click/new tab work).
`a.btn-secondary` already removes underline. Add:
- `.btn-compact { padding: var(--sp-6) var(--sp-12); }` — only the padding
  shrinks to fit a toolbar row; the font stays `.btn-secondary`'s `--fs-body`
  (12px, the design-constitution type-scale row for secondary buttons). No new
  font-size.
- `.btn-secondary:focus-visible, .btn-link:focus-visible { outline: 1px solid
  var(--accent); outline-offset: 2px; }` — `--accent` is the single accent hue,
  allowed for interactive emphasis (G-contrast forbids it only as *text*).
- Drop the old `.conv-open-full` mono/meta rule (the button is a sans label).

## R8 — Removing the backlog-row link (FR-008)

**Decision**: Delete the `<a class="live-session-link" data-live-session>` from
the status cell and the `live_sessions` assign. `MissionControlLive` still
receives `{:console, :conversation_opened | :conversation_closed, _}` on the
console topic, so the existing clause becomes a no-op (`{:noreply, socket}`) —
removing it would crash the view (there is no catch-all `handle_info`).
`.live-session-link` CSS stays (Run Detail and the panel badge use it).

## R9 — Tokens

**Decision**: Two new `:root` layout tokens beside the 033 layout tokens:
`--cell-truncate-max: 28ch;` and `--phase-strip-min: 168px;` (≈ 7 pips at
`--sp-4` gap with a usable pip width). Width/min-width are not under the
spacing-grid guard, but values live in one place (Operator Surface Design).
No colour, font-size, radius, keyframe or breakpoint change ⇒ no
`docs/design-constitution.md` amendment and no constitution bump.
