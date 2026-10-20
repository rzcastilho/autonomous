# Quickstart: Validate Mission Control Polish

## Prerequisites

- `mise trust mise.toml` done once; all commands via `mise exec --`.
- For the manual checks: a running console (`mise exec -- iex -S mix` on the
  host, or `scripts/autonomous console`) with a run in flight against a target
  (any backlog; a long feature slug makes Q1 sharper).

## Automated

```bash
mise exec -- mix compile                     # warnings_as_errors
mise exec -- mix test test/autonomous/web/mission_control_live_test.exs
mise exec -- mix test test/autonomous/web/conversation_live_test.exs
mise exec -- mix test test/autonomous/web/design_contract_test.exs
mise exec -- mix test                        # full suite
```

Expected: all green; the design guard reports no violation and no allowlist
entry was added. Contract selectors: [contracts/mission-control-ui.md](contracts/mission-control-ui.md).

## Manual (browser)

**Q1 — no overlap (US1, SC-001).** Open `/` during a run. Resize from wide
down to just above 1120px. Expected: nothing in the backlog table or live
panel is drawn under the telemetry column; long slugs end in `…` and show
the full slug on hover; every phase pip visible; if the table still does not
fit, a horizontal scrollbar appears on the table only (page never scrolls
sideways). Below 1120px the feed stacks under the main panel.

**Q2 — hide/show (US2).** Click **hide** in the Telemetry header. Expected:
feed gone, main panel full width, **show telemetry** beside the status strip.
Wait for a few feed events, click **show telemetry**: the feed returns with
those events included. Tab to each control: focus ring visible, Enter/Space
operates it, screen reader announces expanded/collapsed.

**Q3 — persistence (US2 AS3, FR-005).** Hide, reload: still hidden (after a
brief connect). Navigate to Runs and back: still hidden. In a private window
with site data blocked: control works for the page view, default is shown on
the next load, no console error.

**Q4 — delayed notice (FR-006).** With the feed hidden, make the Coordinator
slow to answer (as in feature 038's runbook check). Expected: the "live status
delayed" line appears at the top of the main column.

**Q5 — compact panel (US3, US5).** With a session in flight, the panel shows
badge, header line, status footer and the **open full view** button only — no
conversation rows, no follow/frames switches. Hover/focus the button: visible
states. Middle-click it: `/live/<id>` opens in a new tab with its toggles and
full conversation. When the session ends and the next phase starts, the panel
switches on its own.

**Q6 — clean row (US4).** The running feature's row has its status pill (and
awaiting-answers meta when applicable) and no `live session` pill.
