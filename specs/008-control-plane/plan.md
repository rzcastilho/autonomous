# Implementation Plan: Control Plane

**Branch**: `008-control-plane` | **Date**: 2026-07-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-control-plane/spec.md`

## Summary

Build an operator-facing web console for `speckit_orchestrator` that replaces the
`iex` workflow (`run/1`, `run_spec/2`, `status/0`, `resume/2`, `resolve/1`) with a
single live screen. Six views behind a fixed left nav — Mission Control, Pipeline
DAG, Trigger Run, Escalations, Transcripts, Configuration — plus a persistent
status bar with the cost-breaker gauge, a slide-in feature drawer, and toast
confirmations.

**Technical approach**: A Phoenix LiveView app (`SpeckitOrchestrator.Web`) added
to the existing OTP application as a **presentation/control layer** over the
existing facade and runtime — it reimplements no pipeline logic (Constitution I).
Live updates flow from the existing `:telemetry` phase events through a new
`ConsoleProjection` GenServer that (a) fills the one gap in the authoritative
snapshot — Coordinator's `status/0` carries per-feature *status* and *elapsed* but
not *current phase* — by folding `[:speckit, :phase, :start/:stop]` into a
per-feature phase/spend read-model, and (b) broadcasts diffs over `Phoenix.PubSub`.
LiveViews subscribe on mount, seed from `Coordinator.status/0` + `Ledger.snapshot/1`
+ `ConsoleProjection`, and reconcile to authoritative state on a periodic tick
(FR-033 / SC-005). No database, no persistence — the console reflects the single
in-memory run (FR-036) and reads transcripts/checkpoints from their existing
on-disk locations. Bound to loopback, no auth (FR-035).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned `.tool-versions`; all commands via `mise exec --`)

**Primary Dependencies**: Phoenix `~> 1.7`, Phoenix LiveView `~> 1.0`, Bandit
(HTTP server, loopback bind), `Phoenix.PubSub` (already present transitively via
`jido_signal` — promote to a direct dep), Jason (present). Existing:
`jido`, `jido_harness`, `jido_claude`, `:telemetry`. **No Ecto / no database.**

**Storage**: N/A — no persistence (FR-036). Run state is in-memory (Coordinator /
Ledger / ConsoleProjection); transcripts and checkpoints are **read** from their
existing on-disk locations (`<transcript_root>/<id>/NN-<phase>.md`,
`<transcript_root>/<id>/checkpoint.json`) written by the orchestrator.

**Testing**: ExUnit + `Phoenix.LiveViewTest`. Real-harness / real-CLI runs stay
behind `--include integration`; console tests drive the facade through its
injected `:runner`/`:publisher` seams so the default suite stays hermetic. The
`ConsoleProjection` fold is a pure function, unit-tested against synthetic
telemetry events (no LiveView, no CLI).

**Target Platform**: A single BEAM node on the operator's machine/trusted host;
HTTP server bound to `127.0.0.1` (or a configured trusted interface), one trusted
operator, no login.

**Project Type**: Web console added to the existing single Mix project — a new
`lib/speckit_orchestrator/web/` tree (endpoint, router, LiveViews, components)
alongside the existing pure core and runtime. Not a separate app.

**Performance Goals**: Reflect a phase transition on screen within 5 s (SC-002);
converge to authoritative state within 5 s of an outside change (SC-005); full
run status readable within 10 s of opening (SC-001). Push-based PubSub delivery
plus a ≤2 s reconcile tick meets all three with wide margin at this scale.

**Constraints**: Loopback bind, no auth, no accounts (FR-035); single live
in-memory run, no history/switcher (FR-036); config edits apply **forward-only**
to the live run — never retroactive (FR-032 / FR-037); telemetry feed length
bounded (edge case); every view renders a coherent empty/error state (SC-006);
never depict a mid-phase kill (SC-007).

**Scale/Scope**: 6 views + drawer + status bar; a typical backlog of ~7 features;
1 operator; at most 1 active run. DAG of a handful of nodes — no graph-layout
library required.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | ✅ The web layer is a new isolated boundary (peer to the CLI adapter). LiveViews and `ConsoleProjection` call the existing facade (`run/1`, `run_spec/2`, `resume/2`, `resolve/1`, `status/0`) and read `Ledger`/`Checkpoint`/`Transcripts`/telemetry. **No** pure-core module (`Feature`, `Config`, `Pipeline`, `Ledger`, `Release`, `Backlog`) gains a Phoenix dependency; no pipeline decision logic is reimplemented in the UI. |
| **II. Fail Loud at Boundaries** | ✅ Trigger rejects a backlog whose DAG fails to validate (`Backlog.load!` raises → surface, block Start — FR-019); empty single-spec description → `run_spec/2` returns `{:error, :empty_description}` surfaced as a field error (FR-016). Missing/corrupt checkpoint → steer to full restart, never offer an impossible resume (edge case / FR-023). The console surfaces backend errors; it does not paper over them. |
| **III. Least-Privilege Containment** | ✅ The console runs no CLI itself; existing containment (scope-guard hook, per-phase permissions) is unchanged. New surface is minimized: bound to loopback, no remote exposure, no auth attack surface added (FR-035). |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | ✅ The console reads the `Ledger` breaker; it never bypasses it. It must **depict** drain-not-kill (a tripped breaker halts new releases on screen; in-flight features finish their phase then halt between phases) and never show a mid-phase kill (SC-007). Budget edits are forward-only (FR-037). |
| **V. Human-in-the-Loop Escalation** | ✅ The Escalations view **is** the human-in-the-loop surface: it reads clarify questions + checkpoint + run context and drives `resume/2` (checkpoint resume, optional `:prompt` guidance, `:from` override) and `resolve/1` (full restart, frees worktree), preserving existing worktree-retention semantics. |

**Quality gates**: All commands via `mise exec --`; `warnings_as_errors` stays on;
the pure `ConsoleProjection` fold is unit-tested; LiveView flows use
`Phoenix.LiveViewTest` with the facade's `:runner` seam (no real CLI in the default
suite); real-harness paths stay behind `--include integration`.

**Result**: PASS — no principle violation; Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/008-control-plane/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output — console read-model entities → backend sources
├── quickstart.md        # Phase 1 output — run + validate the console
├── contracts/           # Phase 1 output
│   ├── routes.md            # The six views' routes + drawer; facade/read each invokes
│   ├── console_projection.md# PubSub topic + message shapes + projection read-model
│   └── live_config.md       # Forward-only config-apply contract for the live run
└── checklists/
    └── requirements.md  # (already present)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── web/                          # NEW — the console (presentation/control layer)
│   ├── endpoint.ex               # Bandit endpoint, loopback bind, LiveView socket
│   ├── router.ex                 # Routes for the six views (no auth pipeline)
│   ├── telemetry.ex              # (optional) LiveDashboard-style metrics — not required
│   ├── components/
│   │   ├── layouts.ex + layouts/ # Root/app layout: left nav, status bar, drawer slot, toasts
│   │   ├── core_components.ex     # Shared: phase strip, status pill, cost gauge, badge, toast
│   │   └── feature_drawer.ex      # Slide-in feature drawer component (FR-011..013)
│   └── live/
│       ├── mission_control_live.ex   # US1 — status strip, backlog table, gauge, feed (FR-006..010)
│       ├── pipeline_dag_live.ex      # US4 — layered DAG, legend, node→drawer (FR-025..026)
│       ├── trigger_live.ex           # US2 — backlog vs single-spec, PR toggle (FR-014..019)
│       ├── escalations_live.ex       # US3 — list, checkpoint, resume/restart (FR-020..024)
│       ├── transcripts_live.ex       # US5 — feature+phase picker, render, path (FR-027..028)
│       └── config_live.ex            # US6 — model routing, budget, cap, PR mode (FR-029..032)
├── console_projection.ex         # NEW — telemetry→read-model fold + PubSub broadcast
├── console_read_model.ex         # NEW — pure fold + snapshot merge (unit-tested; the "current phase" gap)
├── live_config.ex                # NEW — forward-only apply to live Coordinator/Ledger/Config
├── coordinator.ex                # (existing) + tiny runtime setters for cap (live_config)
├── ledger.ex                     # (existing) + tiny runtime setter for budget (live_config)
├── application.ex                # + PubSub, ConsoleProjection, Endpoint in the supervision tree
└── … (existing pure core + runtime unchanged)

test/speckit_orchestrator/
├── console_read_model_test.exs   # pure fold unit tests (no CLI/LiveView)
├── live_config_test.exs          # forward-only apply semantics
└── web/
    ├── mission_control_live_test.exs
    ├── trigger_live_test.exs
    ├── escalations_live_test.exs
    ├── transcripts_live_test.exs
    ├── pipeline_dag_live_test.exs
    └── config_live_test.exs
```

**Structure Decision**: Single Mix project. The console lives under
`lib/speckit_orchestrator/web/` as a self-contained boundary, mirroring how the
CLI/harness adapter is isolated from the pure core. The only backend touches are
additive: an endpoint/PubSub/projection in the supervision tree, and two small
runtime setters (`Coordinator` cap, `Ledger` budget) that the live-config contract
needs for forward-only apply. No existing pipeline logic changes.

## Complexity Tracking

No constitution violations — section intentionally empty.
