# Contract: facade supersession & active-run guard

Changes to `SpeckitOrchestrator` (`lib/speckit_orchestrator.ex`). Every return
shape that exists today is kept; one error term is added.

## `run/1` (fresh run, no `:run_key`) — and `run_spec/2`, which delegates to it

Preflight order (existing steps unchanged, new steps **bold**):

| # | Step | Refusal |
|---|------|---------|
| 1 | retired opts | `{:error, {:preflight, [{:retired_option, k}]}}` |
| 2 | remediation settings | `{:error, {:preflight, [reason]}}` |
| 3 | parked run | `{:error, {:parked_run, id, [:continue, :end]}}` |
| 4 | layout | `{:error, {:preflight, [...]}}` |
| 5 | store writable | `{:error, {:preflight, [{:store_unwritable, _}]}}` |
| 6 | store capacity | `{:error, {:preflight, [{:store_capacity, _}]}}` |
| **7** | **stop prior Coordinator** | — |
| **8** | **`Workers.drain(repo_id)`** | **`{:error, {:drain_timeout, stuck}}`** |
| 9 | `Store.open_run/2` (supersedes prior record) | `{:error, {:preflight, [{:store_open_failed, _}]}}` |
| 10 | `run_stacked/4` … `start_run/2` | as today |

Guarantees:
- A refusal at 1–6 drains nothing, stops nothing, supersedes nothing (today's
  "a refused start supersedes nothing" preserved).
- A refusal at 8 leaves the prior run record `:in_flight`, starts no
  Coordinator, releases no feature (FR-004, SC-006).
- With no registered worker, step 8 returns without waiting (FR-012, SC-005).
- Step 9's record outcome (`:superseded`, features `:ended_by_supersession`)
  is byte-identical to today (FR-010) — the drained worker wrote no terminal
  status.

`run/1` **with** `:run_key` (the resume paths' internal call) skips 7–9 as
today; those paths are guarded below instead.

## `guard_active_run/1` — used by `continue_run/1`, `resume/2`, `resume_run/1`

| `:force` | Coordinator alive & unfinished | worker registered for repo | Result |
|----------|-------------------------------|----------------------------|--------|
| absent | yes | any | `{:error, {:active_run, coordinator_pid}}` (today) |
| absent | no | yes | `{:error, {:active_run, worker_pid}}` (**new**, FR-005) |
| absent | no | no | `:ok` (today, US2 AS4) |
| `true` | any | any | stop Coordinator → `Workers.drain/1` → `:ok` or `{:error, {:drain_timeout, stuck}}` (FR-006) |

A refusal starts no work and spends nothing (SC-004).

## `workers/0`, `workers/1` (new, FR-013)

`workers(repo \\ Config.repo()) :: [%{feature_id, run_id, pid, deadline_at}]`
— read-only; delegates to `Workers.in_flight/1`.

## Operator-facing wording

`{:drain_timeout, stuck}` is formatted wherever `{:active_run, _}` already is
(console `format_resume_error/1`, trigger error flash, runbook). Wording
convention: name each feature still working and state that nothing was
started; point to `:force` only for the case where the operator knows the
worker is stuck. It MUST NOT reuse the breaker's or the parked run's wording
(FR-011). No new console view (spec Assumptions).
