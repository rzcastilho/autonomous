# Quickstart: Recovery State Reconciliation

**Feature**: 014-recovery-reconciliation

Runnable validation that recovery reconciles manifest status against repository
ground truth. All commands run through mise (pinned `1.20.2-otp-28`).

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile        # warnings_as_errors is ON
```

Contracts: [reconcile.md](./contracts/reconcile.md),
[evidence.md](./contracts/evidence.md),
[recovery-report.md](./contracts/recovery-report.md). Entities:
[data-model.md](./data-model.md).

## Scenario 1 — Stale `running` that actually finished (SC-001, US1) ⭐

The exact `quickpoll` first-wave defect. Manifest says `001: running`; on disk
`001` finished — branch committed, `pr.json` present, PR pushed.

Setup (test fixture, not shipped code): a manifest with `001: running`, `002:
pending`; a durable `001/` dir with `pr.json` + `07-converge.md` (READY); a git
branch `feature/001-…` whose newest boundary commit is `after converge`.

Validate:

```bash
mise exec -- mix test test/speckit_orchestrator/recovery_quickpoll_test.exs
```

**Expected**: `001` reconciled `done`; manifest rewritten with `001: done`;
`002` reported as next runnable; **zero** `001` phases re-run; `001`'s committed
spend counted exactly once.

## Scenario 2 — `running` interrupted mid-run (SC-003, US2)

Feature reached an intermediate phase: boundary commits through `plan`, no
`pr.json`, checkpoint `last_phase: plan / in_progress`.

**Expected**: reconciled `{:resume, :tasks}` (phase after the latest committed
boundary `plan`); continuation runs only `tasks → … → converge`; `specify/
clarify/plan` are not regenerated.

## Scenario 3 — Whole-run pending + terminal states (SC-004, US3)

Construct a manifest exercising every status against matching/conflicting
evidence.

**Expected**: `pending`-never-started stays `pending`; `escalated`/`halted` stay
held (not advanced); `done`-with-evidence stays `done`; `done`-without-branch/PR
→ `conflict` (held, dependents blocked, rest of run releases).

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/reconcile_test.exs
```

## Scenario 4 — Both run shapes (SC-005, US4)

Ad-hoc run whose single feature finished before the crash → reported
`done`/complete, no re-run. Breakdown wave → a reconciled `done` releases its
dependents on continuation.

## Scenario 5 — Corrupt / offline resilience (SC-006, SC-009)

- Truncate `pr.json` for a finished feature → collector falls back to git/
  transcript evidence; still reconciles correctly or surfaces a conflict; never
  crashes recovery.
- Run reconciliation with the remote unreachable (default local-only seam) →
  every feature reaches its correct status from local durable state; `pr_remote?`
  is `:unknown`; no recovery failure attributable to the remote.

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/evidence_test.exs
mise exec -- mix test test/speckit_orchestrator/recovery_test.exs
```

## Full validation

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/          # pure + collector
mise exec -- mix test test/speckit_orchestrator/recovery_test.exs  # orchestration + manifest rewrite
mise exec -- mix test --cover                                      # core >90%
mise exec -- mix test                                              # full suite green (warnings-as-errors)
```

## Operator flow (manual, after implementation)

```elixir
# read-only reconciled preview — starts no work, spends no budget
SpeckitOrchestrator.resumable_run()
#=> {:ok, %{report: <reconciled whole-run picture>, ...}}

# continue from the reconciled state (done features skipped, resume at boundary)
SpeckitOrchestrator.resume_run()
```

**Success**: for the reproduced `quickpoll` state, `resumable_run/0` shows `001:
done` and `002` next; `resume_run/0` continues at `002` without re-running `001`,
within the original budget.
