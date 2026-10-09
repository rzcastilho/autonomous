# Contract: Console Projection Resilience

**Feature**: 038-console-projection-resilience
**Extends**: `specs/008-control-plane/contracts/console_projection.md`,
`specs/023-console-restart-hydration/contracts/console-hydration.md`

## 1. `Autonomous.CoordinatorProbe` (boundary)

```elixir
@spec status(GenServer.server(), timeout()) ::
        {:ok, map()} | :none | {:error, :timeout | :down}
```

- Registered-name server not registered, or pid not alive → `:none`.
- `Coordinator.status/1` answers within `timeout` → `{:ok, status}` (the map is passed through untouched).
- Call exits with `{:timeout, _}` → `{:error, :timeout}`.
- Call exits for any other reason (`:noproc` race, `:normal`, `:shutdown`, crash) → `{:error, :down}`.
- MUST NOT raise or exit. MUST be the only `Coordinator.status/1` caller under `lib/autonomous/web/` and in `ConsoleProjection`.

## 2. `Autonomous.ConsoleProjection` (process)

### Client API

| Function | Contract |
|----------|----------|
| `read(server \\ __MODULE__)` | unchanged shape. New: `read_safe/1` returns `ConsoleReadModel.new()` if the server is absent/exits (never raises). |
| `last_known(server \\ __MODULE__)` | **new.** `%{coordinator: map() \| nil, ledger: map() \| nil, delayed?: boolean()}`; absent/exiting server → `%{coordinator: nil, ledger: nil, delayed?: false}`. Never blocks on the Coordinator. |
| `topic/0` | unchanged |

### Start options (additions)

| Option | Default | Purpose |
|--------|---------|---------|
| `:probe_timeout` | `5_000` | Coordinator wait limit for the reconcile probe (existing value, unchanged). |
| `:history` | loads in-flight-else-parked run detail | Injected loader for the rebuild; returns `{:ok, run_detail} \| :none \| {:error, term}`. A loader error/raise logs one warning and starts with an empty model — never fails `start_link`. |

### Lifecycle

1. `init/1`: attach telemetry (unchanged), schedule reconcile (unchanged), return `{:ok, state, {:continue, :rebuild}}`.
2. `handle_continue(:rebuild)`: `model = ConsoleHistory.rebuild(detail)`; telemetry already queued in the mailbox folds afterwards, deduped by `rebuilt_keys` (§4).
3. `:reconcile` tick: if `probe == nil`, start `Task.async` running `CoordinatorProbe.status(coordinator, probe_timeout)` + exit-safe `Ledger.snapshot/1`; else skip.
4. Probe result: apply `ConsoleDelay.step/2`; update `last_known` on success; broadcast per §3; log per data-model §3; clear `rebuilt_keys` on first success.
5. The projection MUST NOT make any blocking call to the Coordinator inside a callback.

### Invariants

- A miss never changes `model` (FR-001).
- A miss never terminates the projection (FR-001, SC-001).
- With every probe succeeding, the sequence of broadcasts is identical to today's except the extra `delayed?: false` key (FR-009).

## 3. PubSub messages on `"console:run"`

| Message | Change |
|---------|--------|
| `{:console, :reconciled, %{coordinator: c, ledger: l, delayed?: boolean()}}` | **one added key.** Sent on every successful probe (`delayed?: false`), and on each miss once `misses >= 2` with `c`/`l` = `last_known` and `delayed?: true`. Not sent on a single miss. |
| `{:console, :feature_updated, …}`, `{:console, :feed, entry}`, `{:console, :run_finished, report}` | unchanged |

`ConfigLive`'s own `:reconciled` broadcast sends `delayed?: false` (it just
probed successfully) or uses `last_known` on probe failure.

Subscribers MUST treat a missing `delayed?` key as `false` (back-compat for any
handler matching `%{coordinator:, ledger:}`).

## 4. `Autonomous.ConsoleHistory` (pure)

```elixir
@spec rebuild(map() | nil) :: ConsoleReadModel.t()
@spec rebuild(map() | nil, DateTime.t()) :: ConsoleReadModel.t()   # now injected for elapsed_ms
```

- Output feed: recorded entries only (data-model §4), chronological, newest 200, newest-first in the list.
- Output features: one slice per recorded feature.
- `run_key` = recorded run key.
- `rebuilt_keys` = `{feature_id, phase, text}` per rebuilt entry.
- `nil` / no features → `ConsoleReadModel.new()`.
- No Mnesia, Phoenix, Coordinator, or `:telemetry` dependency.

### `ConsoleReadModel` additions

- `new/0` gains `rebuilt_keys: MapSet.new()`.
- Live fold (`apply_event/4`): compute the result as today; if its new feed head `{feature_id, phase, text}` ∈ `rebuilt_keys`, return the **input** model with that key removed — the event is already reflected in the rebuilt slices, so neither the feed nor the slice (spend, phase cell, windows) is applied twice. Otherwise return the result unchanged. With `rebuilt_keys` empty this is a no-op (FR-009).
- `clear_rebuilt/1` empties the set.

## 5. LiveView call sites

| Site | Contract |
|------|----------|
| `MissionControlLive`, `EscalationsLive`, `PipelineDagLive` seed | `CoordinatorProbe.status(Coordinator, 250)` (via `ConsoleProjection.coordinator_or_last_known/1`; 250 ms per probe so a page render stays < 3 s); `{:error, _}` → `last_known().coordinator` (+ `last_known().ledger` when ledger read also fails); `view.delayed?` from `last_known().delayed?` on fallback, else `false`. Use `ConsoleProjection.read_safe/0`. |
| `Layouts` topbar | same probe + fallback; renders the same chip/title it would for the fallback status. |
| `:reconciled` handlers | put `Map.get(payload, :delayed?, false)` onto `view.delayed?`. |
| `run_unlinked/1` (Mission Control, Escalations, Trigger) | `Task.yield` bounded wait: result → result; `{:exit, r}` → `{:error, {:controller_unreachable, r}}`; no reply → `{:error, :controller_unreachable}`, task left running (never `Task.shutdown`). |

Page load with an unresponsive Coordinator MUST complete under 3 s (SC-004).

## 6. Mission Control delayed notice

- Rendered iff `view.delayed?`.
- Text: `live status delayed — ` + mono `Coordinator.status/1` + ` not answering; showing last known state`.
- `data-console-delayed` attribute for tests.
- Existing tokens/classes only; no status color, no animation; passes `design_contract_test.exs`.
- Absent markup when not delayed (SC-005 byte-identical normal output).
