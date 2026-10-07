# Quickstart: Validate Operator Console UX Polish (033)

Run from the repo root. Every Elixir command goes through mise.

## 1. Automated gates

```bash
mise exec -- mix compile                      # warnings_as_errors
mise exec -- mix test                         # full default suite
mise exec -- mix test test/autonomous/web/    # console surfaces + guard
mise exec -- mix test test/autonomous/web/design_contract_test.exs
```

Expected: all green. `design_contract_test.exs` includes the four new rules
(G-contrast, G-input, G-breakpoint, G-inspect), each with a firing and a
non-firing case (`contracts/design-guard-extensions.md`). SC-009.

Pure modules have their own unit tests, including a StreamData property for
the transcript renderer (data-model §6 invariants):

```bash
mise exec -- mix test test/autonomous/web/transcript_markup_test.exs
mise exec -- mix test test/autonomous/web/run_settings_view_test.exs
mise exec -- mix test test/autonomous/web/start_confirm_test.exs
mise exec -- mix test test/autonomous/web/config_diff_test.exs
```

## 2. Live walkthrough

Start the console with a run in flight against a target (container path:
`scripts/autonomous console`; host: `mise exec -- iex -S mix`, then
`Autonomous.run/1`). Open the console URL printed at boot. Compare against the
audit baseline `.playwright-mcp/ui-0*.png` (2026-10-07).

| # | Where | Do | Expect | Covers |
|---|---|---|---|---|
| 1 | Run Detail of a permissive run | open | settings record block; no `__given__`, no `%{`, no quoted strings; `containment_profile` only in the CONTAINMENT block | US1, SC-001, SC-002 |
| 2 | Runs | look at state chips | `:in_flight` / `:completed` / `:parked` in status color; feature column shows per-status counts | FR-008, FR-031 |
| 3 | Transcripts | pick a run in `run_id`; open a phase with lists and code | formatting rendered, mono, ~96ch measure; a `<script>` string in a transcript shows as text | FR-004–007 |
| 4 | Trigger Run, either tab | look at every control | dark themed selects and number inputs | SC-006 |
| 5 | Trigger Run, run in flight | click start once | button reads `Supersede <run_id> and start`, mono hint, Cancel; nothing started | SC-007 |
| 6 | same | click Cancel; then arm again and let the run finish | button returns to normal both times | FR-010 edge case |
| 7 | Trigger Run, no run in flight | click start | starts immediately | FR-011 |
| 8 | Trigger Run | toggle `interactive_clarify` | `answer_timeout_min`/`max_rounds` appear only when on | FR-012 |
| 9 | Topbar | look | gauge label `$c + $r / $b`, no breaker word in it; clock `HH:MM:SS UTC` | FR-017, FR-018 |
| 10 | Mission Control @1440×900 | load | one status strip; first feature row visible; each row shows `phase · n/7` | SC-004, SC-005 |
| 11 | Configuration | change a model, type `12.34` in budget | `n unsaved` bar with Apply/Reset visible; Apply toast echoes `LiveConfig.apply(%{...})` and the forward-only line | US5, SC-010 |
| 12 | Configuration | type `12.345` | refused next to the field, still dirty | FR-023 edge case |
| 13 | Pipeline Chain @1440 | load | multi-column cards, no ordinal, legend lists only present states, labelled wave picker | FR-027 |

## 3. Narrow width (SC-003)

Use browser devtools (or the Playwright MCP `browser_resize`) at **390×844**
and load all 8 views. For each:

```js
document.documentElement.scrollWidth <= window.innerWidth   // must be true
```

Expect: compact rail with all 7 destinations and badges; topbar state and
gauge visible; Mission Control rows show id, status, phase position and spend.

## 4. Clean load (SC-008)

Open each of the 8 views with the browser console cleared. Expect zero
errors, zero warnings, and no 404 in the network panel (no `/favicon.ico`
request at all).

## 5. Contrast (SC-011)

Covered mechanically by G-contrast for tokens. Spot-check with devtools'
contrast picker on: a `:pending` chip, a `:blocked` chip, an eyebrow
(`--text-faint`), and an input border. Text ≥4.5:1, input border ≥3:1.

## Implementation notes — phases 5–6 (T044 / T053)

Verified live on a fresh second container instance (port 4001, throwaway target, seeded 4-feature run; the ledgerlite instance on 46789 was left running):

- 390×844: `scrollWidth == innerWidth` on `/ /dag /trigger /escalations /runs /transcripts /config` and Run Detail (`/runs/r000001`). Rail 52px; short labels `MC PC TR ES RU TX CF` visible; every nav item tappable. Drawer 390px wide, inside the viewport.
- 1440×900: first feature row bottom at 334px of 900 (SC-005 met); `#console-clock` = `HH:MM:SS UTC`; `[data-status-strip]` and `data-phase-position` (`specify · 1/7`) present.
- Console had one 404 resource error (favicon) — fixed by T073 (US7). Gauge not exercised live (no active run); covered by unit tests.

## Implementation notes — phase 9 (T075)

Fresh console container (port 4001, rebuilt from current tree). Loaded `/ /dag /trigger /escalations /runs /runs/r000001 /transcripts /config` with Playwright: `browser_console_messages` reports 0 errors, 0 warnings per page after navigation. Pre-fix baseline (favicon 404, 2 unused font-preload warnings) no longer appears.

## Implementation notes — T079 walkthrough

Walked on a ledgerlite console at 1440×900 and 390×844; instance was idle (two completed runs, no run in flight). Screenshots: `.playwright-mcp/walk-*.png`.

- Pass: #2 (`:completed` chips, per-status counts), #3 (formatting rendered, mono, no script elements), #4 (all selects/number inputs dark, border `#7a8296`), #8 (`answer_timeout_min`/`max_rounds` only when `interactive_clarify` on), #11 (dirty bar `1 unsaved`, Reset/Apply enabled), #12 (`12.345` refused beside the field, still dirty), #13 (multi-column cards, no ordinal, legend `Done` only, labelled Wave picker), strict-run #1 (no `__given__`, `%{`, quotes, containment key). SC-003: `scrollWidth == 390` on all 8 views, rail shows `MC PC TR ES RU TX CF`.
- Completed on the throwaway `uitarget` console (:4001) with a seeded in-flight run (4 features, a live named `Coordinator` with a no-op runner — no `claude` call, no spend): #9 gauge `$0.00 + $0.00 / $2000.00` with a separate `breaker armed` chip; #10 single status strip, first row visible, `specify · 1/7`; #5 Start arms to `Supersede r000001 and start` + `drains and supersedes r000001` + Cancel, nothing started; #6 Cancel restores `Start run`, and re-armed then run ended also restores it; #11 Apply toast echoes `LiveConfig.apply(%{budget_usd: 12.34, model_specify: "opus"})`, plus `applies forward-only to r000001 · not saved as default` when a run is in flight; #1 permissive run shows `containment_profile=permissive` once, only in the CONTAINMENT block.
- Not walked live: #7 (start with no run in flight — would launch a real `claude` session and spend); covered by `start_confirm_test.exs` and `trigger_live_test.exs` only.
- Observations (all resolved after the walk): budget input/slider `value` rendered `2.0e3` (now `2000.00`); empty `plan_stack` rendered blank (now `—`); nav items 34px at 390px (now 50px); Wave picker showing `002-improvements` was not a bug (the run was scoped to that package).
