# Implementation Plan: Console Restart Hydration

**Branch**: `023-console-restart-hydration` | **Date**: 2026-09-15 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/023-console-restart-hydration/spec.md`

## Summary

After a BEAM restart and `resume/2`, Mission Control (`/`) and the Pipeline
Chain (`/dag`) lose per-feature state that Run Detail still shows: finished
features render an empty strip, `—`, `$0.00`; the resumed feature lights only
post-restart phases and counts elapsed from the resume. The durable run record
already holds everything (execution-ordered attempts with outcome/model/cost,
per-attempt cost entries, per-feature `started_at`/`ended_at`, checkpoints, PR
links) and both pages already read it on mount and on every 2 s reconcile —
today that read is ignored the moment a live `Coordinator` exists
(`overlay_last_known_statuses/2` is a no-op when `active?`), and in cold boot
it is reduced to the checkpoint alone.

Technical approach, in three separable pieces:

1. **A pure hydration module** (`SpeckitOrchestrator.ConsoleHydration`) turns
   one recorded feature + the run's cost entries + an injected `now` into a
   console row slice (phase cells, spend, elapsed, current phase, chunk
   sub-label, PR link), then *layers* the live slice on top under one
   precedence table: live wins per phase it observed, spend is `max`, a known
   PR link is never blanked, cells after the live active phase are dropped.
2. **`ConsoleReadModel.hydrate/3`** replaces `overlay_last_known_statuses/2`
   and runs in **both** modes: with a live `Coordinator` it fills every
   coordinator-listed row from the record (never adding features — FR-008);
   without one it builds rows from the record as today, but complete.
3. **Regression-proof live updates**: both LiveViews replace their
   `Map.merge(row, update)` on `{:console, :feature_updated, …}` with
   `ConsoleHydration.apply_update/2`, so an update between reconcile ticks
   merges per phase and can never blank a hydrated row (FR-011, SC-004).

No persistence for the telemetry fold, no Coordinator seeding, no schema
change, no new store round-trips (FR-015).

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28, pinned via `.tool-versions`;
every command through `mise exec --`.

**Primary Dependencies**: Phoenix `~> 1.7` + LiveView `~> 1.0` (console),
`phoenix_pubsub` (reconcile/feature broadcasts). **No new dependency.**

**Storage**: Mnesia, single-node — read-only for this feature, through the
existing `SpeckitOrchestrator.run_detail/1` facade (018). **No schema change,
no new table, no new field** (FR-015).

**Testing**: ExUnit. Pure tests over synthetic `run_detail`-shaped maps with an
injected `now` (no store, no Coordinator, no harness); LiveView tests under
`StoreCase` for cold-boot, live, and resume paths (SC-007). Coverage target
>90% on the pure core; the hydration module is a total function set and
should reach 100%.

**Target Platform**: macOS/Linux developer machine running the orchestrator
against a sibling target repository; console served by Bandit.

**Project Type**: Single Elixir/OTP application (control plane + LiveView
console), no Node/npm build step.

**Performance Goals**: N/A beyond "no new store reads". Hydration is
O(attempts + cost entries) per reconcile tick over the already-fetched
`run_detail`; the 2 s reconcile cadence is unchanged.

**Constraints**: `warnings_as_errors` is ON. The pure module must not depend on
Mnesia, Phoenix, the Coordinator, or `:telemetry`. No new color, radius,
font-size, or spacing literal (`test/support/design_contract.ex` fails loud).
Run Detail is the reference and is **not changed**.

**Scale/Scope**: 1 new pure module, 1 pure module amended (`ConsoleReadModel`),
2 LiveViews + 1 component touched, 3 test files amended + 1 new. Runs of
7–20 features, each with ≤ ~30 recorded attempts.

## Constitution Check

*GATE: passed before Phase 0; re-evaluated after Phase 1 design — still passes.*

| Principle | Verdict | Evidence |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | PASS | `ConsoleHydration` is a pure module over plain maps (`run_detail/1`'s shape) with `now` injected (FR-012). The only IO — `run_detail/1` and `DateTime.utc_now/0` — stays in the LiveViews, where it already is. No Mnesia, Phoenix, or `:telemetry` dependency in the pure code. |
| **II. Fail Loud at Boundaries** | PASS | Nothing new is parsed or persisted. Records lacking attempt lists, cost entries, or timestamps degrade to empty cells / `—` / `$0.00` (FR-013) — this is *display tolerance of absent optional data*, not silent acceptance of a malformed contract: damaged rows are still refused upstream by `Store.Query` exactly as before. No refusal is weakened. |
| **III. Least-Privilege Containment** | PASS | No change to `priv/target_pack/`, the hook, `settings.json`, or per-phase permissions. |
| **IV. Cost-Bounded Autonomy** | PASS | Read-only. Spend shown is the recorded cost-entry sum (the same source `Recovery.spend_of/1` seeds the `Ledger` from) combined with the live fold by `max` — it can never under-report what the breaker has already accounted for (FR-010). The Ledger and breaker are untouched. |
| **V. Human-in-the-Loop Escalation** | PASS | No gate, policy, or threshold change. Diverted features keep their marker and now also keep their receipt (FR-004). |
| **VI. Idiomatic Elixir/OTP** | PASS | Pure multi-clause functions over maps, `Enum` pipelines, no new process, no process-state entanglement; `@spec` on every public function. The LiveViews stay thin (delegate the merge instead of inlining `Map.merge`). |
| **VII. Operator Surfaces Tell the Truth** | PASS | This feature *is* a Principle VII fix ("Show the receipt"): every cell, spend, and elapsed shown after a restart becomes traceable to a recorded attempt or cost entry. Elapsed is wall-clock from recorded timestamps, never a timer standing in for state; a finished feature's elapsed freezes. No new token, color, keyframe, or inline style; the drawer's per-phase `model` renders in the existing mono meta slot under its real value (the CLI alias recorded on the attempt). `design_contract_test.exs` must stay green — an exit criterion. |

**Persistence subsection**: no mutation, no schema version change, no export
change; the pure core still does not depend on Mnesia. The one store read per
reconcile tick per LiveView already exists (018) and is reused, not added.

## Project Structure

### Documentation (this feature)

```text
specs/023-console-restart-hydration/
├── plan.md                              # This file
├── spec.md                              # Input
├── research.md                          # Phase 0 output
├── data-model.md                        # Phase 1 output
├── quickstart.md                        # Phase 1 output
├── checklists/                          # From /speckit-specify
├── contracts/                           # Phase 1 output
│   ├── console-hydration.md             # pure API + precedence table
│   └── console-views.md                 # what each surface renders + test hooks
└── tasks.md                             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── console_hydration.ex                 # NEW — pure: from_record/3, layer/2, apply_update/2
├── console_read_model.ex                # overlay_last_known_statuses/2 -> hydrate/3 (both modes);
│                                        #   overlay_observed/1 merges via ConsoleHydration.layer/2;
│                                        #   checkpoint_* helpers move to ConsoleHydration
└── web/
    ├── live/
    │   ├── mission_control_live.ex      # seed/reconcile call hydrate/3 with now;
    │   │                                #   :feature_updated -> ConsoleHydration.apply_update/2
    │   └── pipeline_dag_live.ex         # same two changes
    └── components/
        └── feature_drawer.ex            # timeline meta shows model beside cost (FR-016)

test/speckit_orchestrator/
├── console_hydration_test.exs           # NEW — pure, synthetic records, injected now
├── console_read_model_test.exs          # overlay_* describes -> hydrate/3 (cold + live modes)
└── web/
    ├── mission_control_live_test.exs    # cold-boot full strip; live+record; update no-blank; drawer model
    └── pipeline_dag_live_test.exs       # node cells/spend after restart (US1 scenario 4)
```

**Structure Decision**: single Elixir application, existing layout. The new
pure module sits beside `ConsoleReadModel` in `lib/speckit_orchestrator/`
(the pure core), not under `web/` — it knows nothing about Phoenix and is
tested without it. `Store.Query`, `Records`, `Writer`, and `RunDetailLive` are
not touched.

## Complexity Tracking

No constitution violations; nothing to justify.

One deliberate non-deviation worth recording: a `recorded` sub-map is **not**
kept on the rendered row to remember which cells came from the record. The
single precedence table (contracts/console-hydration.md §3) is idempotent, so
re-applying it on every reconcile tick and every live update yields the same
row without provenance bookkeeping in view state.
