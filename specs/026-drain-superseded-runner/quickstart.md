# Quickstart: validating the superseded-runner drain

All scenarios run with stub workers / injected executors — **no `claude`
session, no spend**. See [contracts/workers.md](./contracts/workers.md) and
[contracts/facade-supersession.md](./contracts/facade-supersession.md) for the
behaviour asserted.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors
```

## Automated validation

```bash
# pure rows: drain? signal in Chunking/Remediation, Bound.wait_ms/3
mise exec -- mix test test/speckit_orchestrator/chunking_test.exs \
                      test/speckit_orchestrator/remediation_test.exs \
                      test/speckit_orchestrator/workers/bound_test.exs

# registry + drain against stub worker processes
mise exec -- mix test test/speckit_orchestrator/workers_test.exs

# facade: supersession ordering, guard, :force, timeout
mise exec -- mix test test/speckit_orchestrator/supersession_drain_test.exs \
                      test/speckit_orchestrator/resume_test.exs \
                      test/speckit_orchestrator/resume_run_test.exs

mise exec -- mix test             # full suite stays green
```

| Scenario | Spec ref | Expected |
|----------|----------|----------|
| Start run while a stub worker is mid-"session" | US1 AS1–2, FR-001/002 | new run's executor is not invoked until the stub has hit its boundary and exited; `Workers.in_flight/1` empty before `Store.open_run` |
| Start run with no worker | US1 AS3, FR-012 | no drain wait; timing unchanged vs. baseline test |
| Superseded record | US1 AS4, FR-010 | prior run `:superseded`; the drained feature `:ended_by_supersession` (not `:halted`) |
| Resume with only a worker alive | US2 AS1–2, FR-005 | `{:error, {:active_run, worker_pid}}`; executor never called |
| Resume with `force: true` | US2 AS3, FR-006 | worker drained first, then resume proceeds |
| Drain at phase boundary | US3 AS1–2, FR-003 | attempt + `{:cont, next}` checkpoint recorded before exit; resume starts at `next` |
| Drain at chunk boundary | US3 AS1, FR-003 | `implement_chunk` attempt + task-phase checkpoint recorded; no further chunk dispatched |
| Stub ignores drain past bound | US3 AS3, FR-004, SC-006 | `{:error, {:drain_timeout, [%{feature_id: …}]}}`; prior record still `:in_flight`; no Coordinator started |
| Worker under another repo_id | FR-007 | untouched, still registered |
| Breaker + drain both true | FR-011 | `{:halted, :breaker}` wins; drained telemetry distinct from terminal |

## Manual live check (optional, real CLI)

Against a scratch target repo, start a run, wait until
`SpeckitOrchestrator.workers()` shows the first feature mid-phase, then call
`SpeckitOrchestrator.run()` again from another `iex` / the console Trigger:

1. the second call blocks until the first feature's current phase ends;
2. `ps aux | grep claude` shows exactly one session at every moment;
3. `git log` on the feature branch has no duplicated
   `speckit: NNN checkpoint after <phase>` / implement progress commit;
4. the old run in Runs shows *superseded by* the new run id, the feature
   `ended_by_supersession`.
