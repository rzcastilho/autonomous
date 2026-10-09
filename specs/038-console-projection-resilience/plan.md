# Implementation Plan: Console Projection Survives Coordinator Timeouts

**Branch**: `038-console-projection-resilience` | **Date**: 2026-10-09 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/038-console-projection-resilience/spec.md`

## Summary

`ConsoleProjection` crashes — losing its in-memory feed and slices — when its
2 s reconcile tick calls `Coordinator.status/1` synchronously and the call
exceeds the 5 s `GenServer.call` limit; while blocked, LiveViews reading the
projection crash too. Fix (research R1–R9):

1. **P1 — crash-proofing.** A new boundary `CoordinatorProbe.status/2` turns
   every exit into a tagged result. The projection runs the probe in a
   `Task.async` off its own callback (one in flight at a time), keeps
   `last_known` status, never touches its model on a miss. Every console call
   site (Mission Control, Escalations, Pipeline DAG, Config, topbar) uses the
   probe with a 1 s mount budget and falls back to `ConsoleProjection.last_known/0`.
   `run_unlinked/1` becomes a bounded `Task.yield` that reports
   `:controller_unreachable` instead of crashing.
2. **P2 — rebuild.** On every projection start, `handle_continue(:rebuild)`
   loads the in-flight-else-parked run detail and folds it via the new pure
   `ConsoleHistory.rebuild/1` into feed entries (same texts as the live fold,
   recorded timestamps, newest 200) and feature slices; a bounded
   `rebuilt_keys` set drops the mailbox-backlog duplicates.
3. **P3 — delayed notice.** Pure `ConsoleDelay` counts consecutive misses;
   from the 2nd miss the projection broadcasts `:reconciled` with
   `delayed?: true` (last-known status) and Mission Control shows one
   unobtrusive line; first success clears it. One rate-limited warning per
   streak.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28 (`mise.toml`; `mise exec --`)

**Primary Dependencies**: Phoenix LiveView ~> 1.0, phoenix_pubsub, `:telemetry`; OTP `Task`/`GenServer` (no new dependency)

**Storage**: Mnesia (read-only here, via existing `Autonomous.run_detail/1` / `Store.parked_run/1`); no schema change

**Testing**: ExUnit, `Phoenix.LiveViewTest`, `ExUnit.CaptureLog`; hermetic default suite (`StoreCase` temp schema)

**Target Platform**: single-node BEAM instance (host or container)

**Project Type**: OTP application with embedded Phoenix LiveView operator console

**Performance Goals**: page load < 3 s while the Coordinator is unresponsive (SC-004); rebuilt feed visible < 5 s after open (SC-003); recovery within one 2 s refresh (SC-002)

**Constraints**: existing 2 s reconcile interval and 5 s Coordinator wait limit unchanged; feed limit 200; no change to run scheduling/recording/cost (FR-010); normal-path output byte-identical (FR-009/SC-005)

**Scale/Scope**: one projection process per instance; ≤ 200 feed entries; one run's record (tens of features × handful of attempts)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| I. Pure Core, Isolated Contracts | ✅ Decisions in pure modules (`ConsoleDelay`, `ConsoleHistory`, `ConsoleReadModel` dedupe); the Coordinator call contract isolated in `CoordinatorProbe`. |
| II. Fail Loud at Boundaries | ✅ Probe returns tagged errors, not silence; the miss is logged (FR-008) and surfaced in the UI (FR-007). Rebuild never invents entries (skips untimestamped records). A rebuild load failure logs a warning and starts empty — the console is an observability surface, not a gate, so degrading is correct; no run state is touched. |
| III. Least-Privilege Containment | ✅ N/A — no session, hook, or permission change. |
| IV. Cost-Bounded Autonomy | ✅ No Ledger/breaker behaviour change; `Ledger.snapshot/1` only read. Rebuild dedupe prevents double-counted **displayed** spend. |
| V. Human-in-the-Loop | ✅ Continue/End stay explicit operator actions; unreachable controller reported rather than retried. |
| VI. Idiomatic OTP | ✅ Fixes a current violation ("No blocking the scheduler"): the blocking call moves to a `Task`. GenServer stays a thin shell. `handle_continue` keeps `init` non-blocking. Tagged tuples throughout. |
| VII. Operator Surfaces Tell the Truth | ✅ Delayed notice tells the operator the view may be stale instead of implying a quiet run; uses real identifier `Coordinator.status/1` (mono), existing tokens, no animation; guarded by `design_contract_test.exs`. Rebuilt entries carry recorded timestamps (show the receipt). |
| Tech stack (Console never a second source of truth) | ✅ Rebuild reads the authoritative record; projection still never persists. |
| Quality | ✅ New pure modules unit-tested >90%; process behaviour tested with stub servers; `mix test` whole suite must stay green. |

**Result**: PASS, no violations. Post-design re-check: PASS (design adds no dependency, table, or process supervisor child).

## Project Structure

### Documentation (this feature)

```text
specs/038-console-projection-resilience/
├── plan.md              # This file
├── research.md          # Phase 0 (R1–R9)
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── console-projection-resilience.md
├── checklists/
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── coordinator_probe.ex          # NEW boundary: exit-safe Coordinator.status/1
├── console_delay.ex              # NEW pure: miss counting, delayed?, broadcast/log decisions
├── console_history.ex            # NEW pure: run_detail -> ConsoleReadModel (rebuild)
├── console_read_model.ex         # + rebuilt_keys, dedupe in apply_event/4, clear_rebuilt/1
├── console_projection.ex         # async probe, last_known, misses, handle_continue(:rebuild), read_safe/1, last_known/1
└── web/
    ├── components/layouts.ex     # topbar: probe + fallback
    └── live/
        ├── mission_control_live.ex   # probe+fallback seed, delayed? assign + notice, bounded run_unlinked
        ├── escalations_live.ex       # probe+fallback, bounded run_unlinked
        ├── pipeline_dag_live.ex      # probe+fallback
        ├── config_live.ex            # probe+fallback in :reconciled broadcast
        └── trigger_live.ex           # bounded run_unlinked

priv/static/assets/console.css    # only if no existing notice class fits (tokens only)

test/autonomous/
├── coordinator_probe_test.exs                # NEW
├── console_delay_test.exs                    # NEW
├── console_history_test.exs                  # NEW
├── console_read_model_test.exs               # + dedupe cases
├── console_projection_resilience_test.exs    # NEW (stub coordinator, capture_log)
└── web/
    ├── mission_control_live_test.exs         # + delayed notice, stall mount, continue unreachable
    └── layout_test.exs                       # + topbar under stall
docs/runbook.md                               # short note: delayed notice + rebuild behaviour
```

**Structure Decision**: Single OTP app; pure logic as new sibling modules of
`console_read_model.ex`/`console_hydration.ex`, process changes confined to
`ConsoleProjection` and the LiveView call sites listed above.

## Complexity Tracking

No constitution violations — section intentionally empty.
