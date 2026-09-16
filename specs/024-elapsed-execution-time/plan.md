# Implementation Plan: Elapsed Is Execution Time

**Branch**: `024-elapsed-execution-time` | **Date**: 2026-09-16 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/024-elapsed-execution-time/spec.md`

## Summary

Feature 023 made a feature's ELAPSED on Mission Control, the Pipeline Chain,
and the drawer equal `(ended_at || now) - started_at` from the run record —
calendar time since the feature's first start, spanning overnight downtime,
parked runs, and restarts (feature 003 on the live mod-player run read
1348m). Owner decision 2026-09-16: ELAPSED is **execution time** — the length
of the union of every window during which a step for that feature was
running, plus the in-flight phase's live window while one is open.

Technical approach, in three separable pieces:

1. **A pure window algebra** (`SpeckitOrchestrator.ExecutionTime`): a window
   is `%{key, from, to}` in wall-clock milliseconds (`to: nil` = still
   running). `elapsed_ms/2` closes open windows at an injected `now`, merges
   overlaps, and sums — one function answers "how long was at least one
   execution running" for any mix of recorded and live windows, so the
   implement roll-up over its chunks and the final analyze record over its
   superseded runs and corrections are counted once by construction
   (FR-002, SC-006). `from_attempts/1` turns a feature's recorded
   `phase_attempts` (every phase name — pipeline phases, `:implement_chunk`,
   `:remediation`, `:auto_remediation`, superseded re-runs) into windows,
   skipping any attempt missing a timestamp (FR-013).
2. **The console fold keeps timing it already receives.**
   `ConsoleReadModel.apply_event/4` opens a window on `[:speckit, :phase |
   :remediation | :chunk, :start]` from the span's `system_time`, closes it
   on `:stop`/`:exception` from the span's `duration`, and closes every open
   window on `[:speckit, :feature, :terminal]` from a `system_time`
   measurement that `FeatureRunner.emit_terminal/4` starts carrying. The
   feature slice gains one field, `windows`; nothing else in the fold
   changes.
3. **Hydration composes windows instead of subtracting timestamps.**
   `ConsoleHydration.from_record/3` derives `windows` from the attempts;
   `layer/3` and `apply_update/3` (both now take `now`) keep the union of
   recorded and live windows on the row and set `elapsed_ms` from it,
   `apply_update` additionally clamped by `max` against the row's last value
   (FR-004, FR-011). `ConsoleReadModel.merge_per_feature/2` drops the
   Coordinator's `elapsed_ms` (its since-release monotonic counter) before
   layering, so it can never feed ELAPSED (FR-009); `Report.format_status/1`
   keeps reading it from `Coordinator.status/0` directly.

No persistence change, no new event source, no new timer, no new table or
field, no token or status change (FR-014). Run Detail's per-attempt Duration
column, the run record, the store, and the iex status report are untouched.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28, pinned via `.tool-versions`;
every command through `mise exec --`.

**Primary Dependencies**: Phoenix `~> 1.7` + LiveView `~> 1.0` (console),
`phoenix_pubsub` (reconcile/feature broadcasts), `:telemetry` (span
measurements already emitted by `:telemetry.span/3`). **No new dependency.**

**Storage**: Mnesia, single-node — read-only for this feature, through the
existing `SpeckitOrchestrator.run_detail/1` facade. **No schema change, no
new table, no new field** (FR-014).

**Testing**: ExUnit. Pure tests over synthetic windows / attempts / telemetry
events with an injected `now` (no store, no Coordinator, no harness);
LiveView tests under `StoreCase` for cold-boot, live, resume, and diverted
paths (SC-008). The window algebra is a total function set and should reach
100%.

**Target Platform**: macOS/Linux developer machine running the orchestrator
against a sibling target repository; console served by Bandit.

**Project Type**: Single Elixir/OTP application (control plane + LiveView
console), no Node/npm build step.

**Performance Goals**: N/A beyond "no new store reads, no new timer".
`elapsed_ms/2` is O(w log w) over a feature's windows (w ≤ ~40: one per
recorded attempt plus one per live span) per row per 2 s reconcile tick and
per `:feature_updated` broadcast.

**Constraints**: `warnings_as_errors` is ON. The pure modules must not depend
on Mnesia, Phoenix, the Coordinator, `:telemetry`, or the clock. No new
color, radius, font-size, or spacing literal (`test/support/design_contract.ex`
fails loud). Both clocks in play are wall-clock (`DateTime.utc_now/0` in the
recorders, `:erlang.system_time/0` in `:telemetry.span/3`); the Coordinator's
monotonic counter is excluded by requirement, not by conversion.

**Scale/Scope**: 1 new pure module, 2 pure modules amended
(`ConsoleHydration`, `ConsoleReadModel`), 1 emitter touched
(`FeatureRunner.emit_terminal/4`, one added measurement), 2 LiveViews
touched (arity of two calls), `Telemetry` moduledoc updated; 1 new test file,
4 test files amended. Runs of 7–20 features, each with ≤ ~30 recorded
attempts.

## Constitution Check

*GATE: passed before Phase 0; re-evaluated after Phase 1 design — still passes.*

| Principle | Verdict | Evidence |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | PASS | `ExecutionTime` is a pure module over plain maps and integers; `now` is injected everywhere it is needed (FR-012). The two telemetry measurements it consumes (`system_time`, `duration`) are read at the fold's edge, in `ConsoleReadModel.apply_event/4`, which already isolates the telemetry contract. The only IO — `run_detail/1` and `DateTime.utc_now/0` — stays in the LiveViews, where it already is. |
| **II. Fail Loud at Boundaries** | PASS | Nothing new is parsed or persisted. An attempt missing `started_at`/`ended_at`, a `:stop` without an observed `:start`, or a terminal without `system_time` contributes nothing and never raises (FR-013) — display tolerance of absent optional data, as 023 established; `Store.Query` refuses damaged records upstream exactly as before. No refusal is weakened. |
| **III. Least-Privilege Containment** | PASS | No change to `priv/target_pack/`, the hook, `settings.json`, or per-phase permissions. |
| **IV. Cost-Bounded Autonomy** | PASS | Read-only. Spend, the Ledger, and the breaker are untouched. |
| **V. Human-in-the-Loop Escalation** | PASS | No gate, policy, or threshold change. A diverted feature's elapsed now includes the attempt it diverted on (US3). |
| **VI. Idiomatic Elixir/OTP** | PASS | Pure multi-clause functions over maps, `Enum` pipelines, no new process, no process-state entanglement; `@spec` on every public function. The fold stays a pure reducer; the projection GenServer is unchanged. |
| **VII. Operator Surfaces Tell the Truth** | PASS | This feature *is* a Principle VII fix ("Show the receipt"): ELAPSED becomes the sum an operator can reproduce from Run Detail's Duration column (SC-001), and the Coordinator's since-release timer — a timer standing in for state — is excluded by requirement (FR-009). A running feature's value advances only while a phase runs; a finished feature's freezes. No new token, color, keyframe, status value, or inline style; the drawer and the row render the same `row.elapsed_ms` through the unchanged `format_elapsed/1`. `design_contract_test.exs` must stay green — an exit criterion. |

**Persistence subsection**: no mutation, no schema version change, no export
change; the pure core still does not depend on Mnesia. The one store read per
reconcile tick per LiveView already exists (018) and is reused, not added.

## Project Structure

### Documentation (this feature)

```text
specs/024-elapsed-execution-time/
├── plan.md                              # This file
├── spec.md                              # Input
├── research.md                          # Phase 0 output
├── data-model.md                        # Phase 1 output
├── quickstart.md                        # Phase 1 output
├── checklists/                          # From /speckit-specify
├── contracts/                           # Phase 1 output
│   ├── execution-time.md                # pure window algebra + hydration/fold changes
│   └── console-views.md                 # what each surface renders + test hooks (delta over 023)
└── tasks.md                             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── execution_time.ex                    # NEW — pure: window type, from_attempts/1, open/3, close/3,
│                                        #   close_all/2, normalize/1, elapsed_ms/2, ms conversions
├── console_hydration.ex                 # from_record/3 derives windows (elapsed_for/2 removed);
│                                        #   layer/2 -> layer/3, apply_update/2 -> apply_update/3 (now);
│                                        #   row gains :windows; elapsed from union, max-clamped on update
├── console_read_model.ex                # feature slice gains :windows; phase/remediation/chunk
│                                        #   start/stop/exception + feature terminal fold windows;
│                                        #   merge_per_feature/2 drops Coordinator :elapsed_ms (FR-009);
│                                        #   hydrate/3 + overlay_observed/2 thread now into layer/3
├── feature_runner.ex                    # emit_terminal/4 adds %{system_time: System.system_time()}
├── telemetry.ex                         # moduledoc: terminal measurements now include system_time
└── web/live/
    ├── mission_control_live.ex          # :feature_updated -> apply_update/3 with DateTime.utc_now()
    └── pipeline_dag_live.ex             # same one-line change

test/speckit_orchestrator/
├── execution_time_test.exs              # NEW — pure: union/overlap/open/idempotence/monotone/tolerance
├── console_hydration_test.exs           # elapsed = union of attempt windows; layer/3 + apply_update/3
├── console_read_model_test.exs          # windows fold per event; merge drops Coordinator elapsed_ms
└── web/
    ├── mission_control_live_test.exs    # US1-1 cold+live 40m-not-20h; US2-1 resume; US2-3 frozen
    │                                    #   between phases; US3-1 halted; US3-2 `—`; US3-3 live-only
    └── pipeline_dag_live_test.exs       # node drawer elapsed equals Mission Control row (US1-3)
```

**Structure Decision**: single Elixir application, existing layout. The new
pure module sits beside `ConsoleHydration` and `ConsoleReadModel` in
`lib/speckit_orchestrator/` (the pure core), not under `web/` — it knows
nothing about Phoenix, telemetry, or the store and is tested without them.
`Store.Query`, `Records`, `Writer`, `Coordinator`, `Report`, and
`RunDetailLive` are not touched.

**Superseded 023 artifacts**: `specs/023-console-restart-hydration/` is left
as written (the repository's precedent for historical spec artifacts — see
constitution Sync Impact Reports 1.3.0, 2.1.0, 4.0.0). Its FR-006, FR-007,
SC-003, contract rule §1.7, the `elapsed_ms` rows of its precedence table
§3, and console-views.md's "record wall-clock, else live counter" are
superseded by this feature's contracts (spec FR-015); its other rules stand.

## Complexity Tracking

No constitution violations; nothing to justify.

Two deliberate non-deviations worth recording:

- **The window list lives on the rendered row.** 023 recorded that no
  provenance sub-map is kept on the row because its precedence table is
  idempotent without one. This feature *does* keep `windows` on the row —
  not as provenance, but because a `:feature_updated` update carries only
  the live windows, and the union it must be merged into (the recorded
  windows) is not otherwise available between reconcile ticks. The list is
  normalized (deduplicated by `{key, from}`, closed-wins), so re-applying an
  update yields the same list and the same value (FR-011).
- **`now` is threaded, not read.** `layer/3` and `apply_update/3` take `now`
  rather than the LiveViews computing `elapsed_ms` at render time, so the
  monotone clamp and the union live in one pure place and the views stay
  thin (Principle VI); the two views' `DateTime.utc_now/0` calls are the
  same edge they already had for `hydrate/3`.
