# Implementation Plan: Control Plane UI Redesign

**Branch**: `011-control-plane-ui-redesign` | **Date**: 2026-07-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-control-plane-ui-redesign/spec.md`

## Summary

Restyle all six console pages (Mission Control, Pipeline DAG, Trigger Run,
Escalations, Transcripts, Configuration) plus the shared shell (sidebar + top
bar) and the feature drawer to exactly match the dark-theme design system in
`docs/control-plane-design-reference/` — its `#7c5cff` accent, per-status color
palette, IBM Plex Sans/Mono typography, logo mark, and layout metrics.

This is a **presentation-only** change (FR-020): no route, LiveView data flow,
PubSub handling, or user-facing behavior changes. Technical approach: deliver one
hand-authored static stylesheet (`console.css`) served through the existing
`Plug.Static` (the console has **no** esbuild/tailwind/npm build step), self-host
the IBM Plex woff2 files under `priv/static/fonts`, update the shared
`CoreComponents.@palette` from the current colors to the reference's status
palette, and rewrite the HEEx markup of the shell, core components, drawer, and
seven LiveViews to the reference's structure while preserving the class/data
hooks the existing LiveView tests assert on.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned in `.tool-versions`; run via `mise exec --`)

**Primary Dependencies**: Phoenix `~> 1.7`, Phoenix LiveView `~> 1.0`, Bandit `~> 1.0`, phoenix_pubsub `~> 2.1`. No CSS/JS toolchain (no esbuild, tailwind, or npm).

**Storage**: N/A — console reads live in-memory state from `Coordinator`, `Ledger`, `Config`; no persistence added.

**Testing**: ExUnit + `Phoenix.LiveViewTest` (`mise exec -- mix test`). Existing web tests under `test/speckit_orchestrator/web/` must stay green.

**Target Platform**: Desktop-width browsers pointed at the loopback-bound Bandit endpoint (`mix phx.server`).

**Project Type**: Web application — single Elixir app with an embedded Phoenix LiveView console under `lib/speckit_orchestrator/web/`.

**Performance Goals**: Live updates continue to arrive over the existing LiveView socket without full page reload (SC-004). No new performance budget; the redesign must not add an asset build step or a runtime external network call (FR-021).

**Constraints**: Dark theme only; desktop widths, degrading gracefully to a narrow desktop min-width (two-column layouts collapse to one column — Edge Cases). Typography and every visual asset self-hosted; **no** font-CDN or other external request at runtime (FR-021). Exact match to the reference palette/typography/logo/metrics (FR-019).

**Scale/Scope**: 6 LiveView routes + shared shell layout + feature drawer + core components. ~10 HEEx/component files restyled, 1 new stylesheet, self-hosted fonts, `Plug.Static` wiring for css + fonts.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The constitution governs the orchestrator's control/data plane (pure core, fail-loud
boundaries, containment, cost breaker, human-in-the-loop). This feature touches only
the **web presentation layer**, which is not the pure core and introduces no
orchestration logic. Evaluated against each principle:

- **I. Pure Core, Isolated Contracts** — PASS. No change to `Feature`, `Config`,
  `Pipeline`, `Ledger`, `Release`, `Backlog`. The web layer's existing (allowed)
  reads of `Coordinator`/`Ledger`/`Config` are unchanged; no new coupling is added.
- **II. Fail Loud at Boundaries** — PASS / N/A. No new input boundary or parser.
  Missing checkpoint fields render a neutral placeholder (Edge Cases), which is a
  presentation concern, not a swallowed bad state.
- **III. Least-Privilege Containment** — PASS / N/A. No change to the scope-guard
  hook, `settings.json`, or per-phase permissions. Self-hosting fonts *removes* an
  external network dependency, consistent with fail-closed defaults.
- **IV. Cost-Bounded Autonomy** — PASS / N/A. The `Ledger` breaker is untouched; the
  cost gauge is a read-only view of `Ledger.snapshot/1`.
- **V. Human-in-the-Loop Escalation** — PASS. The Escalations page and drawer restyle
  the human gate; FR-012 requires resume/resolve to invoke the **existing** behaviors
  unchanged, so the escalation path keeps its semantics.

**Quality & Test Discipline** — All commands via `mise exec --`; `warnings_as_errors`
stays on; existing web tests must remain green (FR-020 gives no license to change
behavior). The pure-core >90% coverage rule is unaffected (no core change).

**Result**: No violations. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/011-control-plane-ui-redesign/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── design-system.md # Exact palette/typography/logo/metrics tokens + class/data-hook contract
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/web/
├── endpoint.ex                       # +Plug.Static routes for console.css and /fonts
├── router.ex                         # unchanged (FR-020)
├── web.ex                            # unchanged (shared imports already in place)
├── components/
│   ├── core_components.ex            # @palette → reference colors; restyle status_pill,
│   │                                 #   phase_strip, cost_gauge, badge, toast
│   ├── feature_drawer.ex             # restyle drawer: timeline, summary, action set
│   ├── layouts.ex                    # unchanged data helpers (nav/context/run_view)
│   └── layouts/
│       ├── root.html.heex            # link console.css + font preloads; self-hosted fonts
│       └── app.html.heex             # restyle sidebar + top bar shell to reference
│   └── live/                         # (rendered by the LiveViews below)
├── live/
│   ├── mission_control_live.ex       # restyle: status cards, backlog table, telemetry feed
│   ├── pipeline_dag_live.ex          # restyle: SVG node/edge DAG + legend
│   ├── pipeline_dag_layout.ex        # layout math reused; unchanged unless SVG needs coords
│   ├── escalations_live.ex           # restyle: per-feature checkpoint cards + actions
│   ├── transcripts_live.ex           # restyle: feature list + per-phase tabs
│   ├── trigger_live.ex               # restyle: backlog vs single-spec mode switch
│   └── config_live.ex                # restyle: model routing, budget, concurrency, PR toggle
priv/static/
├── assets/
│   └── console.css                   # NEW — hand-authored design-system stylesheet
└── fonts/
    ├── ibm-plex-sans-*.woff2         # NEW — self-hosted IBM Plex Sans (400/500/600/700)
    └── ibm-plex-mono-*.woff2         # NEW — self-hosted IBM Plex Mono (400/500/600)

test/speckit_orchestrator/web/        # existing tests must stay green; update only the
                                      #   markup-structure assertions the restyle changes
```

**Structure Decision**: Single Elixir app with an embedded Phoenix LiveView console
(the "web application" project type realized in-tree, not a separate frontend/ dir).
All work lives under the existing `lib/speckit_orchestrator/web/` tree plus new static
assets under `priv/static/`. No new routes, LiveViews, or backend modules are created
(FR-020) — the redesign is a markup + stylesheet + palette-token layer over the shipped
`008-control-plane` views.

## Complexity Tracking

> No constitution violations. Section intentionally empty.
