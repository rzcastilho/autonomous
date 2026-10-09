# Data Model: Console Projection Survives Coordinator Timeouts

**Feature**: 038-console-projection-resilience | **Date**: 2026-10-09

All entities are in-memory (console projection state, LiveView assigns). No
store schema change; no new Mnesia table or field; store schema version stays
as is.

## 1. Probe result (`Autonomous.CoordinatorProbe`)

```text
probe_result :: {:ok, coordinator_status :: map()}
              | :none                      # no live Coordinator (today's nil)
              | {:error, :timeout}         # call exceeded the wait limit
              | {:error, :down}            # Coordinator died mid-call
```

- Produced only by `CoordinatorProbe.status(server, timeout_ms)`.
- `:none` is **not** a miss (no run to ask → behaves exactly as today).

## 2. Projection state (`ConsoleProjection` GenServer state)

| Field | Type | New? | Meaning |
|-------|------|------|---------|
| `model` | `ConsoleReadModel.t()` | existing | features + feed + run_key (+ `rebuilt_keys`, §4) |
| `pubsub`, `coordinator`, `ledger`, `handler_id` | — | existing | unchanged |
| `last_known` | `%{coordinator: map() \| nil, ledger: map() \| nil}` | new | last successful probe result; `%{coordinator: nil, ledger: nil}` at start |
| `misses` | `non_neg_integer()` | new | consecutive probes that returned `{:error, _}` |
| `probe` | `reference() \| nil` | new | in-flight probe task ref; `nil` when idle |
| `warned_at` | `integer() \| nil` (monotonic ms) | new | last miss warning logged, for rate limiting |
| `history` | `(-> {:ok, run_detail} \| :none \| {:error, term()})` | new (option) | injected loader used by the rebuild; default reads in-flight-else-parked run |
| `probe_timeout` | `pos_integer()` | new (option) | default 5 000 ms — the existing wait limit, unchanged |

**Validation / invariants**

- At most one probe in flight (`probe != nil` ⇒ a reconcile tick is skipped).
- `misses` resets to 0 on `{:ok, _}` and on `:none`.
- `last_known` only ever replaced by a successful probe — never cleared by a miss (FR-001).
- `model` is never reset by a miss; only `[:speckit, :run, :start]` with a different `run_key` drops feature slices (unchanged rule).

## 3. Delay state (pure: `Autonomous.ConsoleDelay`)

```text
step(misses, probe_result) :: misses'
  {:ok, _} | :none   -> 0
  {:error, _}        -> misses + 1

delayed?(misses) :: boolean()      # misses >= 2   (FR-007, SC-006)

broadcast?(misses', probe_result) :: :reconciled | :delayed | :silent
  success/none                     -> :reconciled   (delayed?: false)
  error, misses' == 1              -> :silent       (single miss shows nothing)
  error, misses' >= 2              -> :delayed      (last_known, delayed?: true)

log?(misses', warned_at, now_ms) :: :warn | :recovered | :quiet
  misses' == 1                         -> :warn      (first miss of a streak)
  misses' > 1 and now - warned_at >= 60_000 -> :warn
  success after misses > 0             -> :recovered (one info line)
  otherwise                            -> :quiet
```

State transitions (per reconcile probe):

```text
 healthy(0) --miss--> missed(1) --miss--> delayed(2..n) --miss--> delayed(n+1)
     ^                   |                    |
     +------success------+------success-------+   (notice clears; info logged if misses>0)
```

## 4. Rebuilt history (pure: `Autonomous.ConsoleHistory`)

Input: one `Autonomous.run_detail/1` map (`%{run:, features: [...], cost_entries: [...]}`), or `nil`.

Output: `ConsoleReadModel.t()` with:

| Field | Value |
|-------|-------|
| `features` | per recorded feature: `ConsoleHydration.from_record/3` projected to `feature_slice()` keys (`current_phase, phases, spend, windows, chunk, remediation, pr_url`) + `chunk_cost_seen: 0.0` |
| `feed` | entries derived per research R6, chronological, newest 200 kept, stored newest-first |
| `run_key` | `run.key` |
| `rebuilt_keys` | `MapSet` of `{feature_id, phase, text}` for rebuilt entries (dedupe, R7); `MapSet.new()` outside a rebuild |

**Feed entry** (unchanged type `ConsoleReadModel.event_entry`): `feature_id`, `phase`, `text`, `severity`, `at` — `at` is the recorded timestamp, never invented.

**Validation rules**

- Missing timestamp on a record ⇒ that entry is skipped (never stamped with "now"; FR-006 "MUST NOT contain entries that were not recorded").
- Only phases in `Pipeline.phases/0` produce phase entries (`:implement_chunk` rows excluded).
- `nil` run_detail or empty features ⇒ `ConsoleReadModel.new()` (edge case: restart before anything was recorded).
- Ordering ties broken by: run start < phase start < phase stop < terminal < PR opened, then feature id.

## 5. View assigns (Mission Control and peers)

| Assign | New? | Source |
|--------|------|--------|
| `view` (from `ConsoleReadModel.merge/3`) | existing | + `delayed?: boolean()` key (default `false`) |

`merge/3` signature unchanged; `delayed?` is put on the view by the caller from
the `:reconciled` payload (or from `last_known` on a fallback mount).
