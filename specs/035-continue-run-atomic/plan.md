# Implementation Plan: Atomic Continue of a Parked Run

**Branch**: `035-continue-run-atomic` | **Date**: 2026-10-08 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/035-continue-run-atomic/spec.md`

## Summary

`continue_run/1` flips the parked run to `:in_flight` before `resume/2` →
`run/1` run their checks, so any later refusal (r000003: `preflight_stacked`'s
`{:pack_outdated, …}`) leaves a dead run that looks alive. Fix: **check
everything first, flip last, undo only a failed start** (research R1).
`continue_run/1` threads an internal `:continue_parked` snapshot through
`resume/2` and `run/1`, which run every existing check unchanged against the
still-parked record (reconciliation is computed read-only via
`Recovery.plan_run/2`, its correction writes deferred — research R8);
`run_stacked/4` performs the flip right after `preflight_stacked/2` and
before any process side effect (the stack tracker start retires any existing
tracker — research R3), then applies the deferred corrections, starts the
tracker and the Coordinator, and on any failure there re-parks with the
snapshot's `stopped_by`/`stopped_reason`. If that re-park itself fails, the
attempt returns `{:error, {:continue_restore_failed, reason, restore_error}}`,
logs at error, and annotates the run (new `speckit_run.continue_restore_failure`,
schema v7) for Run Detail until the next resume/continue/end.

## Technical Context

**Language/Version**: Elixir 1.20.2 / Erlang OTP 28.5.0.6 (via `mise exec --`)

**Primary Dependencies**: Jido 2.2, jido_harness/jido_claude (pinned SHAs), Phoenix 1.7 + LiveView 1.0 (console) — no new dependency

**Storage**: Mnesia (`speckit_run` gains one nullable field; schema v6 → v7 transform)

**Testing**: ExUnit (`mise exec -- mix test`), hermetic temp-dir Mnesia; seams `:runner`/`:executor` plus two new internal seams (`:coordinator_start`, `:repark`)

**Target Platform**: single-node BEAM (host or container, `scripts/autonomous`)

**Project Type**: OTP application + LiveView operator console

**Performance Goals**: N/A — the change only reorders existing checks; no added I/O on the success path beyond a no-op-when-nil clear

**Constraints**: FR-005 byte-identical refusal reasons; FR-008 success path unchanged; `warnings_as_errors`; design-contract guard clean

**Scale/Scope**: one facade function's control flow (`lib/autonomous.ex`), three writer functions, one migration, one Run Detail block

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Pure core, isolated contracts | Pass. No pure-core module changes; all work is facade + Store boundary. |
| II. Fail loud at boundaries | Pass — strengthened. Refusals move before any write; the one unavoidable compensation reports its own failure loudly (FR-009: distinct error, error log, durable annotation), never silently. |
| III. Containment | Pass. `preflight_stacked`/`preflight_containment` and the profile lock run unchanged and in the same order; a permissive run still cannot start against an outdated pack. |
| IV. Cost-bounded autonomy | Pass. `Ledger.restore/2` on a refused continue is in-memory and idempotent/monotonic (spec Assumptions); no cost rows written. |
| V. Human-in-the-loop | Pass. Parked runs stay human-resolved; a refused continue keeps both choices offered. |
| VI. Idiomatic Elixir/OTP | Pass. `with` chains, tagged tuples; each store mutation one transaction; no process work inside a transaction fun (R1 rejects that alternative). |
| VII. Operator surfaces tell the truth | Pass — this feature's purpose. Mission Control again offers `continue_run/1`/`end_run/1` after a refusal; Run Detail block uses mono for machine values, existing tokens, no inline style, no raw `inspect/1` in markup. |
| Persistence | Pass. Every write transactional; schema v7 explicit, versioned transform (contracts/store-schema-v7.md); export includes the field. |
| Quality | Pass. Seam-based tests in the default suite; incident case tested against a temp git target without CLI. |

**Post-design re-check (after Phase 1)**: unchanged — no violations;
Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/035-continue-run-atomic/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── continue-run.md
│   ├── operator-surfaces.md
│   └── store-schema-v7.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/autonomous.ex                         # continue_run/1, resume/2, run/1 (preflight_parked_run),
                                          # run_stacked/4 (flip + repark + annotate + clear)
lib/autonomous/recovery.ex                # apply_corrections/3 (write_corrections promoted)
lib/autonomous/store/writer.ex            # repark_run/2, annotate_/clear_continue_restore_failure,
                                          # continue_run/1 + end_run/2 clear the field
lib/autonomous/store/records.ex           # Records.Run.continue_restore_failure
lib/autonomous/store/schema.ex            # :speckit_run attribute appended
lib/autonomous/store/migrations.ex        # v7 transform, current_version 7
lib/autonomous/store/query.ex             # run summary/detail exposes the field
lib/autonomous/store/export.ex            # field exported
lib/autonomous/web/live/run_detail_live.ex  # data-marker="continue-restore-failure" block

test/autonomous/continue_run_atomic_test.exs   # new: FR-001..010 matrix (quickstart §1)
test/autonomous/parked_run_test.exs            # unchanged (SC-005)
test/autonomous/recovery_test.exs              # apply_corrections/3; reconcile_run unchanged
test/autonomous/store/migrations_test.exs      # v6 -> v7
test/autonomous/store/writer_test.exs          # repark/annotate/clear
test/autonomous/store/records_test.exs         # Run round-trip with new field
test/autonomous/store/export_test.exs          # field exported
test/autonomous/web/run_detail_live_test.exs   # restore-failure block
test/autonomous/web/mission_control_live_test.exs  # parked panel + flash after refusal
test/autonomous/web/escalations_live_test.exs  # US3
docs/runbook.md                                # continue refusal semantics + restore-failure recovery
```

**Structure Decision**: Existing single OTP app layout; no new modules
beyond tests. Writer functions live beside `park_run/2`/`continue_run/1`.

## Complexity Tracking

No constitution violations.
