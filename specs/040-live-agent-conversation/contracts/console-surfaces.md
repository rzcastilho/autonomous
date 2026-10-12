# Contract: Console surfaces

All surfaces obey `docs/design-constitution.md`; new files are added to
`test/support/design_contract.ex` `@surfaces`.

## Routes

| Route | LiveView | Purpose |
|---|---|---|
| `/live` | `ConversationLive` | follows the repository's in-flight session (`Conversation.in_flight/1`, newest) |
| `/live/:conversation_id` | `ConversationLive` | one session, pinned; live while its recorder runs, else redirects to its Transcripts entry |
| `/transcripts?run_id=&feature=&attempt=&session=` | `TranscriptsLive` (extended) | `session` = index into the attempt's `conversations` (default: last) |

## `ConversationLive`

- **Header** (mono): `run_id` · feature number · phase atom · `ordinal` ·
  chunk/attempt when present · `conversation_id` · agent `session_id` once
  known. Live dot (`.transcript-live[data-live=true]`, existing `scBlink`)
  only while the recorder runs.
- **Body**: `phx-update="stream"` list of rows from
  `ConversationRows.rows/2`. Row kinds: prompt, assistant text (sans, via
  `TranscriptMarkup`), thinking (muted, collapsed by default), tool call
  (mono: name + JSON input), tool result (mono; error flag shown as
  `is_error: true`, not a status color), system, result, end marker.
- **Truncation**: rows over 40 lines / 4,000 chars show the head and
  `… <n> lines / <m> chars omitted` plus an `expand` control
  (`phx-click="expand" phx-value-seq`), replacing the row in place.
- **Catch-up notice** when `truncated?`: "Showing the most recent 500
  entries; earlier entries are in the full conversation once the session
  ends."
- **End marker**: outcome term in mono, with the session's status color only
  on the outcome chip (`completed` → done, `deadline_exceeded`/`session_died`
  → failed, error → failed). Live dot stops.
- **Unfinished tool call** (no result at `:end`): row tagged `unfinished`.
- **Follow mode** (`/live`): on `:ended`, if `in_flight/1` now returns
  another session, show `next session: <conversation_id>` link; with the
  toggle below off, never auto-navigate away from an end marker the operator
  is reading.
- **`follow next sessions` toggle** (FR-027, `.conv-follow` switch,
  `phx-click="toggle_follow"`): one follow mode covering the current
  conversation (tail scroll) and the next sessions (moving on); off by default; `?follow=1` turns it on and
  every move keeps the flag in the URL. On: `:ended` with another session in
  flight ⇒ `push_patch` to `/live/<next>?follow=1`; ended (or nothing shown)
  and `{:console, :conversation_opened, …}` ⇒ same. Turning it on while an
  end marker offers a next session jumps there. Applies to pinned views too.
  While on, the view also keeps its scroll container (the page, or the
  Mission Control panel) at the newest entry — `phx-hook="FollowTail"` on
  `#conversation-rows`, reading `data-follow`; scrolling up pauses it until
  the reader is back at the bottom; turning the toggle on jumps to the bottom.
- **Sticky toolbar** (`[data-conv-toolbar]`): always visible at the top of the
  view's scroll container (page or Mission Control panel) — the live badge
  (`[data-live-badge]`, `live session` with the live dot, `session ended`
  muted once the session ends), the follow toggle, the session ids line, and
  `open full view` when embedded.
- **Empty states** (status reports, no call to action):
  - nothing in flight: `No agent session in flight`;
  - pinned id not live and no saved ref found: `Conversation <id> is not
    live and has no saved record`.
- **Run-state chrome**: the layout's global run state uses
  `ConsoleProjection.last_known/1`; delayed status shows the 038 line. The
  view never calls the Coordinator.

## Mission Control

The in-flight feature card gains `live session` (mono link to
`/live/<conversation_id>`) while a conversation is open for it; updated on
`{:console, :conversation_opened | :conversation_closed, …}`. Otherwise no
link (SC-001: ≤ 2 clicks). The link is a `--running` pill carrying the shared
live dot (`.live-session-link`).

Below the feature table, while a run is in flight, Mission Control embeds the
live view (FR-028): `section[data-live-panel]` holding
`live_render(ConversationPanelLive, id: "mc-conversation")`, a child LiveView
delegating to `ConversationLive` in embedded mode — follow toggle **on** by
default, sessions switched in place (no URL patch, never navigates the page),
an `open full view` link to `/live/<id>`, its own scroll
(`.mc-live-panel`).

## Run Detail

- The in-flight row gains the same `live session` link.
- Every attempt row gains a `conversation` column: `captured` link, `partial`
  link + reason, `not_captured` + reason, or `not recorded (pre-040)` for
  `conversations: nil`. Multiple refs ⇒ one link per session (`session 1`,
  `session 2`) — FR-020.
- `:describe` rows render like any other attempt.

## Transcripts

- Selecting an attempt with a `:captured`/`:partial` ref renders
  `ConversationRows` (same component as live) from `ConversationFile.page/3`,
  500 entries at a time with `load next 500`.
- `:partial`: rows, then `ended without an end marker — <reason>`.
- `:not_captured`: the final-text transcript (`TranscriptMarkup`) under the
  note `No full conversation captured: <reason>`.
- `conversations: nil`: final text under `No full conversation was recorded
  for this attempt (recorded before feature 040).`
- Recorded file missing/unreadable: `Saved conversation missing at
  <relative path>` (or `unreadable: <posix>`), then the final text (US2-4).
- Listings and the attempt sidebar read refs only — no file I/O (FR-021).

## Design-contract notes

- New CSS in `console.css` uses tokens only; no new keyframe; animated
  selectors contain `live` and are listed under
  `prefers-reduced-motion: reduce`.
- Outcome and status text in HEEx goes through `ConversationRows` /
  `Report.format_reason/1` — no raw `inspect/1` (G-inspect).
