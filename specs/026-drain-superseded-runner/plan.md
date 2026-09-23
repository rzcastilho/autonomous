# Implementation Plan: Drain the Superseded Runner

**Branch**: `026-drain-superseded-runner` | **Date**: 2026-09-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/026-drain-superseded-runner/spec.md`

## Summary

Superseding a run stops the prior run's Coordinator and rewrites its store
record, but never the `RunnerSup` task actually driving a feature — so the new
run releases the same feature into the same worktree while the old `claude`
session is still writing (incident `r000002`, `mod-player` 001). The resume
guard shares the blind spot: it looks only for a live Coordinator.

Approach (see [research.md](./research.md)): make every worker **findable** —
one spawn helper registers each `RunnerSup` child in a `Registry` keyed by
repository — and make it **drainable** through the mechanism the constitution
already names for this, "drain, don't kill": a `drain_requested?/0` predicate
checked at exactly the three boundaries where the cost breaker is already
checked (phase, implement chunk, analyze remediation), after the preceding
session's attempt/checkpoint/transcript are recorded. A drained worker exits
without writing a terminal status, so supersession's record outcome is
unchanged. A fresh `run/1` stops the prior Coordinator, drains the
repository's workers (bounded by the in-flight session's own deadline + grace),
and only then supersedes the record and starts; a timeout starts nothing. The
active-run guard refuses on a live worker too, and `:force` drains rather than
bypasses.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28 (`mise exec --`)

**Primary Dependencies**: Jido 2.x (`AgentServer`), `jido_harness`/`jido_claude`
(pinned SHAs), Phoenix LiveView (console, error wording only), OTP `Registry`,
`Task.Supervisor`, ETS

**Storage**: Mnesia store — **unchanged** (no schema bump); new state is
in-memory, process-scoped (`Registry` + one ETS table)

**Testing**: ExUnit via `mise exec -- mix test`; stub worker processes and
injected `:executor` seams; no `--include integration` needed

**Target Platform**: single BEAM node (operator workstation / server)

**Project Type**: OTP application + LiveView console (single project)

**Performance Goals**: zero added latency to `run/1` when no worker is
registered (SC-005) — one `Registry.lookup/2`

**Constraints**: never `Process.exit/2` a worker or stop its agent from outside
(orphans the CLI); drain bound = session deadline + existing grace, no second
timer; `warnings_as_errors`

**Scale/Scope**: one worker per repository in practice (structural
one-at-a-time rule), designed for N; ~6 modules touched + 1 new module + 1 pure
helper

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | How |
|-----------|---------|-----|
| I. Pure Core, Isolated Contracts | ✅ | Decision stays in pure tables: one `drain?` row each in `Chunking.next/2` and `Remediation.next/2`, predicate read upstream in the runners (exactly like `breaker?`). Bound arithmetic is a pure `Workers.Bound.wait_ms/3`. `Pipeline.next/3` untouched. |
| II. Fail Loud at Boundaries | ✅ | Drain timeout is a named refusal `{:drain_timeout, stuck}` naming each feature; the guard refuses with the existing `{:active_run, pid}` rather than proceeding silently. |
| III. Least-Privilege Containment | ✅ n/a | No change to the target pack, hook, or per-phase permissions. |
| IV. Cost-Bounded Autonomy (Drain, Don't Kill) | ✅ strengthened | Supersession now honours the same drain-at-boundary rule as the breaker; no outside kill anywhere. Both drains remain distinguishable (`:breaker` vs `:superseded`, breaker wins when both). Removes the double-spend of two sessions on one budget. |
| V. Human-in-the-Loop Escalation | ✅ | No gate changes. A drained worker opens no escalation (nothing was diverted); `:force` stays the single operator override. |
| VI. Idiomatic Elixir/OTP | ✅ | `Registry` for process lookup (named in the principle); worker stays a `Task.Supervisor` child, unlinked (FR-009); drain waits on monitors from the calling process, never inside a GenServer callback others await. `@spec` on all public functions. |
| VII. Operator Surfaces Tell the Truth | ✅ | No new view. The timeout/active-run wording follows existing refusal conventions and names what is still working; `workers/0` answers "is anything in flight?" truthfully even with no Coordinator. |
| Quality & Test Discipline | ✅ | Everything tested via stub workers and injected seams, hermetic; pure rows keep >90% coverage. |

**Result: PASS** — no violations, Complexity Tracking empty.

*Post-design re-check (after Phase 1):* PASS, unchanged. The design added no
persisted state, no new terminal status (the drained exit writes none, so
`Feature` lifecycle and the store's status set are untouched), and no new
operator view.

## Project Structure

### Documentation (this feature)

```text
specs/026-drain-superseded-runner/
├── plan.md                         # This file
├── research.md                     # Phase 0 — R1–R8
├── data-model.md                   # Phase 1 — worker entry, drain request, bound, exit paths
├── quickstart.md                   # Phase 1 — validation scenarios
├── contracts/
│   ├── workers.md                  # Workers registry/drain API + worker boundary obligations
│   └── facade-supersession.md      # run/1 preflight order, guard table, workers/0, wording
├── checklists/requirements.md      # (from /speckit-specify)
└── tasks.md                        # /speckit-tasks — not created here
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── workers.ex                  # NEW — spawn/3, session_started/1, drain_requested?/0,
│                               #       in_flight/1, drain/1; owns ETS drain table
├── workers/bound.ex            # NEW — pure wait_ms/3
├── application.ex              # + Workers (table owner) + WorkerRegistry, before RunnerSup
├── feature_runner.ex           # loop cond: drain row; drained exit path; session_started/1
├── chunk_runner.ex             # pass drain?: to Chunking.next/2; halt(:superseded); session_started/1
├── chunking.ex                 # + optional drain? signal, {:halted, :superseded, _} row
├── analyze_runner.ex           # pass drain?: to Remediation.next/2; halt(:superseded); session_started/1
├── remediation.ex              # + optional drain? signal, {:halted, :superseded, _} row
├── telemetry.ex                # log [:speckit, :feature, :drained], [:speckit, :drain, *]
└── web/live/escalations_live.ex (+ trigger error formatting)  # {:drain_timeout, _} wording
lib/speckit_orchestrator.ex     # 5 spawn sites → Workers.spawn/3; run/1 steps 7–8;
                                # guard_active_run/1 worker check + :force drain; workers/0,1

test/speckit_orchestrator/
├── workers_test.exs            # NEW — registry scoping, drain ok/timeout/no-op/dead pid
├── workers/bound_test.exs      # NEW — pure bound
├── supersession_drain_test.exs # NEW — facade ordering, record outcome, timeout starts nothing
├── chunking_test.exs           # + drain? rows
├── remediation_test.exs        # + drain? rows
├── feature_runner_test.exs     # + drained exit writes checkpoint, no terminal/notify
├── resume_test.exs, resume_run_test.exs   # + worker-only guard refusal, :force drains
docs/runbook.md                 # supersession now drains; drain_timeout; workers/0
CLAUDE.md                       # control-plane paragraph: worker registry + supersession drain
```

**Structure Decision**: single OTP project, existing layout. The one new
process-layer module (`Workers`) sits beside `Ledger`/`Coordinator`; its only
pure logic (`Workers.Bound`) is split out so it is testable without processes.

## Complexity Tracking

No violations — table intentionally empty.
