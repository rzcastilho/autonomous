# Quickstart: Control Plane UI Redesign

Validation guide proving the redesign renders the reference design system across all
six console pages + the shell + drawer, with **no** behavior change (FR-020) and **no**
runtime font-CDN request (FR-021). Design tokens: [contracts/design-system.md](./contracts/design-system.md).
Unchanged view-models: [data-model.md](./data-model.md).

## Prerequisites

- Toolchain via mise (per constitution): `mise exec -- mix deps.get`
- IBM Plex woff2 files committed under `priv/static/fonts/` (self-hosted, FR-021)
- `console.css` present at `priv/static/assets/console.css`

## Automated checks (must stay/return green)

```bash
mise exec -- mix compile                              # warnings_as_errors must pass
mise exec -- mix test test/speckit_orchestrator/web   # all web LiveView tests
mise exec -- mix test                                 # full suite
```

Expected: the existing web tests pass unchanged except where a markup-structure
assertion was updated in lockstep to a stable hook from the design-system contract
(§4). No test relaxes a behavioral assertion.

## Manual validation (run the console)

```bash
mise exec -- mix phx.server        # binds loopback; open the printed URL
```

### Scenario 1 — Shell (US1 / FR-001..004, FR-019)
1. Open any route. **Expect**: dark `#0b0d12` app, `236px` left sidebar with the
   gradient logo mark + "speckit_orchestrator / CONTROL PLANE · v1", six nav items in
   IBM Plex Sans, the current one marked active (`nav-active`).
2. With escalations open. **Expect**: the Escalations nav item shows a `badge-warn`
   count badge; it disappears at zero (FR-002).
3. Top bar. **Expect**: run title/mode/concurrency, a `cost-gauge` (committed vs budget,
   reserved distinguished), breaker chip (armed/tripped), live clock.
4. With no run active. **Expect**: "No active run" state, no fabricated data (FR-004).

### Scenario 2 — Mission Control (US2 / FR-005..007)
1. **Expect**: one status-count card per lifecycle status, each in its palette color.
2. Advance a feature's phase. **Expect**: its backlog-table row's phase strip + elapsed
   + spend update live, no page reload.
3. Click a row. **Expect**: feature drawer opens for that feature.
4. No run. **Expect**: styled empty state pointing to Trigger Run.

### Scenario 3 — Pipeline DAG (US3 / FR-008..010)
1. Open with a multi-feature backlog. **Expect**: each feature is an SVG node placed by
   dependency wave, a bezier edge drawn to each prerequisite, node color = status color.
2. **Expect**: a legend whose colors match the same palette used everywhere else.
3. A node's status changes → its color/phase progress update live.

### Scenario 4 — Escalations (US4 / FR-011..013)
1. With ≥1 escalated feature. **Expect**: one card showing last phase, status, session
   id, reason, run-context values, and the triggering clarification question(s)/options.
2. Enter resume guidance / pick a start phase, trigger Resume. **Expect**: the existing
   resume runs unchanged with that input.
3. Trigger Full restart (confirmed). **Expect**: existing resolve runs unchanged.
4. Zero escalations. **Expect**: styled empty/success state.

### Scenario 5 — Feature drawer (US5 / FR-014..015)
Open the drawer for running / escalated / done features. **Expect**: phase timeline in
palette colors, elapsed/spend/prereq summary, and the correct action set — open
transcript always; resume/open-escalation when escalated/halted; view-PR when done.

### Scenario 6 — Trigger / Transcripts / Configuration (US6 / FR-016..018)
1. Trigger Run: switch Backlog ↔ Single-spec tabs; each styled form starts a run
   exactly as before.
2. Transcripts: select a feature + a phase tab → that phase's transcript body renders.
3. Configuration: change a per-phase model / budget / concurrency / PR toggle → the
   existing live-config update fires unchanged; the control's new visual state reflects it.

### Cross-cutting checks
- **No font CDN (FR-021)**: with the network panel open (or offline), reload — the page
  renders in IBM Plex with **zero** requests to `fonts.googleapis.com` /
  `fonts.gstatic.com`; fonts load from `/fonts/*.woff2`.
- **Color coding (SC-001)**: a feature's status is identifiable by color alone, and the
  same status is the same color in Mission Control, DAG, and the drawer (SC-002).
- **Live nav (SC-004)**: moving between all six areas never full-reloads away an
  in-progress run's live updates.
- **Responsive (Edge Cases)**: narrow the window below ~1120px → the two-column layout
  collapses to one column; long slugs/session ids truncate with ellipsis; lists scroll
  within their container.

## Done when

- [X] Full `mix test` green; `mix compile` warning-free.
- [X] All six pages + shell + drawer render the reference design system (SC-002).
- [X] No route/event/assign/PubSub change (INV-2); every prior action still works (SC-005).
- [X] No runtime external font request (INV-3 / FR-021).
