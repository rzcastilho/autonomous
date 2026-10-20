# Implementation Plan: Mission Control Polish

**Branch**: `045-mission-control-polish` | **Date**: 2026-10-20 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/045-mission-control-polish/spec.md`

## Summary

Four presentation-only changes to Mission Control (`/`), no store, recorder or
control-plane change:

1. **Overlap fix (US1, P1).** The backlog table's auto layout grows past the
   `minmax(0, 1fr)` main column and, with `overflow: visible`, paints under the
   sticky telemetry column. Wrap the table in a horizontal scroll container,
   truncate secondary cells (slug) with an ellipsis plus a `title` carrying the
   full text, give the phase-strip cell a floor so pips never collapse, and
   ellipsize the embedded panel's session header line.
2. **Hide/show telemetry (US2, P1).** Server-side `telemetry_hidden?` assign
   on `MissionControlLive`, toggled by a `"hide"` button in the feed header or a
   `"show telemetry"` button beside the status strip (exactly one present). A
   tiny vendored-JS hook (`TelemetryPref`, in `app.js`) restores the per-browser
   choice from `localStorage` on connect and stores it on change. The feed
   assign keeps accumulating while hidden; the delayed-status notice moves into
   the main column while the feed is hidden.
3. **Compact embedded panel (US3/US5).** `ConversationLive` in embedded mode
   renders badge + header + status footer only: no rows stream, no follow /
   frames toggles, no truncation notice; follow stays implicitly on.
   **open full view** becomes `a.btn-secondary.conv-open-full` with a
   `:focus-visible` ring. `/live` (not embedded) is byte-identical.
4. **Cleaner running row (US4).** The inline `live session` link in the backlog
   status cell is removed (and with it the `live_sessions` assign Mission
   Control kept only for it). Run Detail's link is untouched.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (via `mise exec --`), OTP 28.5.0.6

**Primary Dependencies**: Phoenix ~> 1.7, Phoenix LiveView ~> 1.0 (vendored JS, no bundler), Bandit

**Storage**: N/A server-side. Per-browser `localStorage` key for the telemetry preference (client only, never sent to the store)

**Testing**: ExUnit + `Phoenix.LiveViewTest` (`mission_control_live_test.exs`, `conversation_live_test.exs`), `design_contract_test.exs` (mechanical design guard). JS hook verified manually (quickstart) — the repo has no JS test runner and the constitution forbids adding a build step

**Target Platform**: Operator console served by the orchestrator (container or host), modern desktop browsers

**Project Type**: Web operator console inside an Elixir/OTP application (single project)

**Performance Goals**: No new server work per event; the embedded panel does *less* (no `ConversationRows` building, no stream diffs)

**Constraints**: Tokens only, no inline styles, breakpoints limited to `1120px`/`760px`, no new keyframes, no new hue; `/live` unchanged; no store/schema change

**Scale/Scope**: 2 LiveView modules + 1 component tweak, `console.css`, `app.js` (~20 lines), 2–3 test files, CLAUDE.md/runbook note

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| I. Pure Core, Isolated Contracts | ✅ No core module touched. Visibility toggle is assign state in the LiveView; no decision logic worth extracting beyond a two-value parse (kept as a private function clause). |
| II. Fail Loud at Boundaries | ✅ The only new input is the client's restore event; unknown values are ignored (default shown, FR-005) — a UI preference, not a boundary contract. Storage failure is caught client-side and falls back to the default. |
| III. Container-Bounded Execution | ✅ N/A. |
| IV. Cost Transparency | ✅ Spend cells and topbar unchanged; hiding telemetry never hides spend. |
| V. Human-in-the-Loop | ✅ N/A. Awaiting-answers meta and row navigation unchanged (US4 AS2). |
| VI. Idiomatic Elixir/OTP | ✅ Multi-clause `handle_event`, pattern-matched embedded/non-embedded render branches, no blocking work. |
| VII. Operator Surfaces Tell the Truth | ✅ State stays above the fold (status strip and table now never covered). Machine values mono and **ellipsized, not wrapped** (slug, session header) with full text on hover. No status colour on the new controls (they use `btn-secondary`/`btn-link`). No new animation; the delayed notice is never hidden (FR-006). Empty state unchanged ("No agent session in flight"). |
| Technology Stack → Frontend | ✅ No Node/npm/bundler; hook added to the existing hand-written `app.js`, as `FollowTail` was in 040. |
| Operator Surface Design | ✅ New layout values become `:root` tokens; design guard (`G-breakpoint`, `G-input`, inline-style, spacing grid) must pass unchanged — no guard exception added. |

**Result**: PASS, no violations. Post-design re-check (after Phase 1): PASS — the
design adds one hook, one assign, CSS rules on existing breakpoints and two layout
tokens; nothing in data-model or contracts introduces a deviation.

## Project Structure

### Documentation (this feature)

```text
specs/045-mission-control-polish/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── mission-control-ui.md   # DOM/event/hook contract
├── checklists/          # from /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
lib/autonomous/web/
├── live/
│   ├── mission_control_live.ex      # telemetry_hidden? assign, hide/show/restore events,
│   │                                # backlog-scroll wrapper, slug truncation + title,
│   │                                # live-session link + live_sessions assign removed,
│   │                                # delayed notice relocated when hidden
│   ├── conversation_live.ex         # embedded render: badge + header + status only;
│   │                                # rows/toggles/truncated notice gated on not embedded;
│   │                                # embedded skips ConversationRows work
│   └── conversation_panel_live.ex   # moduledoc only (follow is implicit)
└── components/
    └── conversation_components.ex   # unchanged API (frames_toggle used by /live only)

priv/static/assets/
├── console.css                      # mission-grid hidden variant, backlog-scroll,
│                                    # cell truncation, phase-strip floor, panel header
│                                    # ellipsis, btn-secondary compact + focus-visible,
│                                    # 2 layout tokens in :root
└── app.js                           # TelemetryPref hook

test/autonomous/web/
├── mission_control_live_test.exs    # hide/show/restore, exactly-one control, feed kept,
│                                    # delayed notice while hidden, no data-live-session,
│                                    # compact panel, open-full-view button
├── conversation_live_test.exs       # embedded panel: no rows/toggles; /live unchanged
└── design_contract_test.exs         # unchanged; must stay green

docs/runbook.md, CLAUDE.md           # one paragraph each (feature 045)
```

**Structure Decision**: Single Elixir project; all changes live in the existing
console modules, stylesheet and vendored `app.js`. No new module is needed.

## Complexity Tracking

No constitution violations — section intentionally empty.
