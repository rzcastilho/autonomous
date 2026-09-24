# Implementation Plan: Pipeline Chain Shows Each Wave's Own History

**Branch**: `028-dag-wave-history` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/028-dag-wave-history/spec.md`

## Summary

After a wave's run ends, every wave in the Pipeline Chain (`/dag`) draws that
run's phases on its same-numbered features. There are two leaks, and both come
from `PipelineDagLive` (research R1):

1. **The gate fails open.** `118dd30` gates backlog nodes on `run_package`,
   which it derives from `current_run_detail/0`, and that only finds an
   `:in_flight` run. With nothing in flight, `run_package == nil`, and
   `drawing_run_package?/1` returns `true` for **every** wave.
2. **The drawn state has no scope.** With the gate open, `view.per_feature` is
   filled from sources that remember the last run by feature id alone: a
   finished-but-alive `Coordinator`, `ConsoleProjection`'s observed slices,
   and hydration. None of them knows which wave a row belongs to.

The fix gives each wave its own resolved **source run** and builds its drawn
state only from that run:

- **Pure resolution.** A new pure `SpeckitOrchestrator.WaveHistory` module
  reads the `run_history/1` summaries, which already carry `scope`, `state`
  and a monotonic `run_id`. It resolves the selected wave to exactly one of:
  - `{:live, run}` when the in-flight run is scoped to this wave;
  - `{:recorded, run}` for the wave's most recent run in any state;
  - `:none`;
  - `{:unavailable, reason}`.
- **Live source.** Keeps today's `merge` + `hydrate` path, gated to the live
  wave.
- **Recorded source.** Built only from that run's `run_detail/1`, hydrated
  into an empty, inactive view. No Coordinator and no projection are involved,
  and `WaveHistory.interrupt/2` then draws any leftover `:running` feature as
  `:interrupted`. The only styling change is that one phase cell uses the
  existing `--blocked` token (no eighth status color, no motion).
- **Other sources.** `:none` and `:unavailable` draw the wave cold.
- **Receipt.** A strip under the canvas header names the source run (`run_id`
  linked to `/runs/:run_id`, plus its `:state`).
- **Default wave.** It follows the most recent wave-scoped run (US3).
- **Unchanged.** The ad-hoc lane and the legacy no-packages layout.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28 (via `mise exec --`)

**Primary Dependencies**: Phoenix LiveView (console). No new dependencies.

**Storage**: Mnesia store, **read-only** through the existing facade
(`SpeckitOrchestrator.run_history/1`, `run_detail/1`). No schema change, no
migration, no new write.

**Testing**: ExUnit plus `Phoenix.LiveViewTest`:
- pure unit tests for `WaveHistory`;
- LiveView tests that seed recorded runs through `Store.Writer` in the
  hermetic temp store, using the `breakdown_packages` fixture (two waves that
  both number `001`);
- `design_contract_test.exs` stays green.

**Target Platform**: BEAM host serving the operator console

**Project Type**: OTP control plane (library + LiveView console)

**Performance Goals**: A wave switch costs one `run_history/1` and at most one
`run_detail/1`, so it renders in under 1 s with up to 20 waves (SC-003).
Reconcile ticks do not re-read history unless the in-flight run changed.

**Constraints**:
- `warnings_as_errors`.
- The design-contract guard stays clean: no literals, only tokens.
- No eighth status color.
- Motion only with a live referent.
- The console never becomes a second source of truth: it only reads.

**Scale/Scope**: One LiveView (`pipeline_dag_live.ex`), one new pure module,
one `CoreComponents` clause pair (`status_class`/`phase_cell_state`), one CSS
rule, plus tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Pure Core, Isolated Contracts | `WaveHistory` is pure. It takes run summaries and rows as arguments, and never touches Mnesia, the Coordinator, or PubSub. Store access stays behind the facade. | PASS |
| II. Fail Loud at Boundaries | A history read error or a damaged run record renders a visible "history unavailable" note, never another wave's state and never invented rows (FR-010). A damaged summary has an unknown scope, so it is skipped rather than guessed at (R2). | PASS |
| III. Containment | Untouched. | N/A |
| IV. Cost-Bounded Autonomy | Untouched. The console only reads spend that is already recorded. | N/A |
| V. Human-in-the-Loop | Untouched. | N/A |
| VI. Idiomatic Elixir/OTP | Source resolution uses multi-clause pattern matching and tagged results. The LiveView stays a thin shell over pure functions. There is no blocking work in `handle_info`: one bounded history read, and only on a run change. | PASS |
| VII. Operator Surfaces Tell the Truth | This is the core purpose. No node asserts phases it never ran (FR-001/002). **Show the receipt**: the source `run_id` and `:state` are visible and linked (FR-007). **Motion means live**: interrupted features never pulse (FR-007a). **Status color**: `:interrupted` folds to the existing `blocked` color, following the `:never_started` precedent. **Empty states are status reports**: "No recorded run for `<slug>`". | PASS |
| Persistence rules | Read-only, through the existing transactional `Store.Query` reads. No `dirty_*`, no schema change. | PASS |
| Tech stack / Frontend | Hand-authored CSS rule on existing tokens. No JS, no deps. | PASS |
| Quality & Test Discipline | Pure module unit-tested. The LiveView is tested hermetically with a temp store. The reported scenario is covered (FR-011). | PASS |

**Post-design re-check (after Phase 1)**: PASS.
- `:interrupted` is a display-only atom and never a lifecycle status: it is
  not persisted and not in `Feature.status/0`. It adds no color.
- The receipt uses real identifiers (`run_id`, `:completed`, and the others)
  in mono.
- No violations, so Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/028-dag-wave-history/
├── plan.md              # This file
├── research.md          # Phase 0 — root cause + decisions R1–R9
├── data-model.md        # Phase 1 — WaveSource, drawn wave view, interrupted row
├── quickstart.md        # Phase 1 — validation scenarios
├── contracts/
│   ├── wave-history.md  # Pure WaveHistory API contract
│   └── dag-surface.md   # /dag markup hooks + behaviour contract
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── wave_history.ex                        # NEW — pure: source_for/2, default_package/2, interrupt/2
└── web/
    ├── live/pipeline_dag_live.ex          # CHANGED — per-wave source, wave_view, receipt, default wave
    └── components/core_components.ex      # CHANGED — :interrupted label/status_class, phase cell state

priv/static/assets/console.css             # CHANGED — .phase-cell-interrupted (var(--blocked), no animation)

test/speckit_orchestrator/
├── wave_history_test.exs                  # NEW — pure resolution/default/interrupt tables
└── web/
    ├── pipeline_dag_live_test.exs         # CHANGED — US1/US2/US3 + FR-010/FR-011 scenarios
    └── phase_strip_test.exs               # CHANGED — interrupted cell renders, never animates
```

**Structure Decision**: This is the existing single-project OTP layout. The
pure decision logic goes in a new top-level core module, next to its siblings
`Release` and `Remediation`. The LiveView only fetches data through the facade
and passes it to that module.

## Complexity Tracking

No constitution violations to justify.
