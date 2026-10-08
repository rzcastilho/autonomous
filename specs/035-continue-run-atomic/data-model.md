# Data Model: Atomic Continue of a Parked Run (035)

## Parked run record (`speckit_run`, existing — one field added)

| Field | Type | Change | Notes |
|---|---|---|---|
| `state` | `:in_flight \| :parked \| :completed \| :superseded` | unchanged | No new state (Clarification 2026-10-08). |
| `stopped_by` | `binary() \| nil` | unchanged | Must be byte-identical after a refused continue (FR-003). |
| `stopped_reason` | `term() \| nil` | unchanged | Same. |
| `continue_restore_failure` | `map() \| nil` | **new (schema v7)** | See below. `nil` on every pre-v7 row and on every run that never hit FR-009. |
| `schema_version` | `pos_integer()` | 6 → 7 for new rows | |

All other run fields and every `speckit_feature_run`, `checkpoint`,
`phase_attempt`, `cost_entry`, `escalation` row: **unchanged and untouched**
by a refused continue (FR-003).

### `continue_restore_failure` value

```text
%{
  refusal:       String.t(),   # inspect/1 of the original {:error, reason}'s reason
  restore_error: String.t(),   # inspect/1 of repark's error
  at:            DateTime.t()  # UTC, when the restore failed
}
```

Strings, not raw terms: the refusal may carry pids/refs/structs the record
decoder should not have to round-trip.

### Lifecycle of the annotation

```text
nil ──(continue refused AND repark failed AND annotate write ok)──> %{...}
%{...} ──Writer.continue_run/1 (flip)─────────────────────────────> nil
%{...} ──Writer.end_run/2──────────────────────────────────────────> nil
%{...} ──successful start_run with :run_key (resume/2, resume_run/1)> nil
```

## Run state transitions on the continue path

```text
        read-only checks (FR-002 items 1-8, reconcile via plan_run/2)
  :parked ───────────────────────────────────────────── refused ──> :parked (untouched)
     │
     │ Writer.continue_run/1  (flip; transactional :parked guard = race arbiter;
     │                         loser returns here, before any process side effect)
     ▼
  :in_flight ──apply_corrections → start_stack_tracker → start_coordinator ok──>
     │                                         :in_flight (running; unchanged path)
     │ any of the three {:error, r}
     ▼
  Writer.repark_run/2 ──ok──> :parked (stopped_by/stopped_reason = snapshot)  → {:error, r}
     │
     └─{:error, e}─> :in_flight + continue_restore_failure annotation (best effort)
                     + Logger.error → {:error, {:continue_restore_failed, r, e}}
```

## Continue snapshot (in-memory, new)

Captured once by `continue_run/1` from `Store.parked_run/1` and threaded via
the internal `:continue_parked` option:

```text
%{run_key: {repo_id, run_id}, stopped_by: binary(), stopped_reason: term()}
```

Consumed by `resume/2` (which run to read), `run/1` (which parked run not to
treat as blocking), and `run_stacked/4` (flip + repark target). Never
persisted; never forwarded to the Coordinator.

## Validation rules

- `Writer.repark_run/2` transitions only `:in_flight -> :parked`; any other
  current state aborts (`:not_in_flight`) — it can never re-park a completed
  or superseded run.
- `Writer.continue_run/1` remains the only `:parked -> :in_flight` writer
  and additionally sets `continue_restore_failure: nil`.
- `annotate_continue_restore_failure/2` changes no field but the annotation.
