# UI Contract: Mission Control Polish

Selectors and attributes below are the test surface (`Phoenix.LiveViewTest`)
and must stay stable.

## 1. Layout (US1)

| Element | Contract |
|---------|----------|
| `.mission-grid[data-telemetry="shown"\|"hidden"]` | always carries the attribute while the live layout renders |
| `.mission-main .backlog-scroll > table.backlog-table` | table wrapped; scroll container is the only horizontal scroller |
| `td.cell-secondary .cell-truncate[title]` (slug) | `title` equals the full slug |
| `td.cell-progress` | contains `.phase-strip` unchanged |
| `.mc-live-panel .conv-header[title]` | `title` equals the full header line text |

Structural test kept: the live panel still follows the table —
`.mission-main .backlog-scroll + section[data-live-panel]` (was
`table.backlog-table + section[data-live-panel]`).

## 2. Telemetry toggle (US2)

| State | Present | Absent |
|-------|---------|--------|
| shown | `#mission-feed`, `[data-telemetry-toggle="hide"][aria-expanded="true"]` inside `.mission-feed-header` | `[data-telemetry-toggle="show"]` |
| hidden | `[data-telemetry-toggle="show"][aria-expanded="false"]` inside `.mission-main-head` | `#mission-feed`, `[data-telemetry-toggle="hide"]` |

Both controls are `<button type="button">` with `aria-controls="mission-feed"`.

Delayed notice `[data-console-delayed]`: inside `#mission-feed` when shown;
inside `.mission-main` (before `.mission-main-head`) when hidden.

### Server events (client → server)

| Event | Params | Effect |
|-------|--------|--------|
| `telemetry_hide` | — | `telemetry_hidden? = true`; push `telemetry_pref` `%{hidden: true}` |
| `telemetry_show` | — | `telemetry_hidden? = false`; push `telemetry_pref` `%{hidden: false}` |
| `telemetry_restore` | `%{"hidden" => true}` | `telemetry_hidden? = true`; no push |
| `telemetry_restore` | anything else | no change |

### Push event (server → client)

| Event | Payload | Hook action |
|-------|---------|-------------|
| `telemetry_pref` | `%{hidden: boolean}` | `localStorage["autonomous.mc.telemetry"] = hidden ? "hidden" : "shown"` in `try/catch` |

### Hook

`phx-hook="TelemetryPref"` on `.run-live` (`id="mission-live"`), defined in
`priv/static/assets/app.js` next to `FollowTail`. Every storage access wrapped
in `try/catch`; failure ⇒ no-op.

## 3. Embedded live session panel (US3, US5)

Inside `find_live_child(view, "mc-conversation")` with a session in flight:

| Present | Absent |
|---------|--------|
| `[data-live-badge]` | `.conv-follow`, `input[data-follow]` |
| `[data-conversation-header]` | `.conv-frames`, `input[data-frames]` |
| `section[data-conv-status]` | `#conversation-rows`, `.conv-row` |
| `a.btn-secondary.conv-open-full[href="/live/<id>"]` | `[data-notice="truncated"]`, `[data-next-session]` |

No session: `[data-state="nothing-in-flight"]` and no `.conv-open-full`.

`/live` and `/live/:id` (not embedded): markup unchanged — `.conv-follow`,
`.conv-frames`, `#conversation-rows`, `[data-next-session]` behave as before;
no `.conv-open-full`.

## 4. Backlog row (US4)

`[data-feature-row] [data-live-session]` never present on Mission Control.
`.awaiting-meta` unchanged. Run Detail's `a[data-live-session]` unchanged.

## 5. Styling (FR-014)

- `.btn-compact` modifier on `.btn-secondary`; `:focus-visible` outline on
  `.btn-secondary` and `.btn-link` using `--accent`.
- New tokens in `:root`: `--cell-truncate-max`, `--phase-strip-min`.
- No new breakpoint, keyframe, colour, font-size or inline style;
  `design_contract_test.exs` passes with no new allowlist entry.
