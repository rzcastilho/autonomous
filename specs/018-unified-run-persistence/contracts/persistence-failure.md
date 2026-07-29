# Contract: Persistence Failure — Drain, Don't Kill

**Feature**: `018-unified-run-persistence` | **Requirements**: FR-009, FR-010,
FR-010a, FR-031d, SC-013

FR-010 is explicit that this mirrors the cost breaker. The implementation
therefore reuses the breaker's two existing check points rather than inventing a
parallel mechanism.

## States

```
ok ── first write abort ──▶ failed(reason) ── successful write after operator fix ──▶ ok
```

`Store.Health` is a `GenServer` in the application supervision tree, sibling to
`Ledger`, holding `:ok | {:failed, reason, at}`. It is a thin shell: the
decision of what a failure *means* is the two call sites below, exactly as
`Ledger.breaker_tripped?/1` is consumed today.

```elixir
Store.Health.record_failure(server \\ __MODULE__, reason) :: :ok
Store.Health.failed?(server \\ __MODULE__)                :: boolean
Store.Health.status(server \\ __MODULE__)                 :: :ok | {:failed, reason, DateTime.t()}
Store.Health.clear(server \\ __MODULE__)                  :: :ok   # operator action only
```

Every `Store.Writer` function reports an `{:aborted, reason}` transaction to
`record_failure/2` before returning `{:error, reason}`. No writer raises into
the run.

## Behaviour at each stage

| Stage | Behaviour | Requirement |
|-------|-----------|-------------|
| **Run start** | `run/1` preflights store reachability + writability, and `Store.Capacity.check/1`. Either failing refuses the run with `{:error, {:preflight, problems}}` and starts **no** work and **no** spend. | FR-009, FR-031b |
| **Mid-phase** | Nothing. The in-flight phase is never aborted. | FR-010, SC-013 |
| **Inter-phase (FeatureRunner)** | At the existing `{:cont, next}` drain point — the same place `breaker_tripped?/1` is checked, evaluated after it — a failed store halts the feature with `{:halted, {:persistence_failed, reason}}` **before** starting the next phase. | FR-010 |
| **Wave release (Coordinator)** | `advance/1` releases nothing new when `Store.Health.failed?/1`, exactly as it releases nothing when the breaker is tripped. | FR-010 |
| **Run drain** | The run is closed with `halt_reason: {:persistence_failed, reason}` and `record_complete?: false`, best-effort. | FR-010 |
| **Halt write also fails** | The run row stays `state: :in_flight` with its last successful `updated_at`. That *is* the incompleteness signal; `resumable/1` reports it as `gap_possible?: true`. Nothing is fabricated. | FR-010a, SC-011 |
| **Capacity ceiling hit mid-run** | Treated as an ordinary write failure — the rows above. No recorded state is ever discarded to make room. | FR-031d, FR-031a |
| **Store writable again** | The halted run resumes from the last successfully recorded position under the same `run_id`. `Recovery` reconciles store record against repository evidence and surfaces any gap as a `Recovery.Report` conflict rather than assuming it away. | FR-010a, FR-018 |

## Ordering with the cost breaker

Both are checked at the same inter-phase point. The breaker is checked first
(unchanged), then the store. If both are tripped, the reason recorded is the
breaker's — a budget halt is the operator-actionable one, and the persistence
failure is still visible in `Store.Health.status/0` and in the run's
`record_complete?` flag.

## What must never happen (SC-013)

- 0 phases aborted mid-flight.
- 0 further phases started after the failure is recorded.
- 0 features released after the failure is recorded.
- 0 runs that continue in a degraded, non-recording mode.
- 0 fabricated states substituted for state that could not be read or written.

## Test plan for this contract

| Test | Shape |
|------|-------|
| Halt between phases | Injected `Store.Writer` seam whose Nth write aborts; assert the in-flight phase completes, the next never starts, terminal is `{:halted, {:persistence_failed, _}}` |
| No new releases | Same seam under a multi-feature Coordinator; assert wave size 0 after the failure |
| Run flagged incomplete | Assert `record_complete?: false` and the halt reason in `run_history/1` |
| Resume after repair | Clear health, `resume_run/1`; assert same `run_id`, resume phases from the last recorded checkpoint, `gap_possible?: true` |
| Start refused | Unwritable store dir; assert `run/1` returns a preflight error and spends nothing |
| Capacity mid-run | Capacity check forced over ceiling mid-run; assert drain-and-halt, and that no row was deleted |
