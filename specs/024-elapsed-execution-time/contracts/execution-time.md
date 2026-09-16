# Contract: `SpeckitOrchestrator.ExecutionTime` (pure) + hydration/fold deltas

**Feature**: `024-elapsed-execution-time` | **Status**: design

Pure functions over plain maps and integers. No Mnesia, Phoenix,
Coordinator, `:telemetry`, or clock access — `now` is always a parameter
(FR-012, Principle I). Supersedes 023's `contracts/console-hydration.md`
rule §1.7 and the `elapsed_ms` rows of its precedence table §3 (spec
FR-015); every other 023 rule stands.

## 1. Types

```elixir
@type ms :: non_neg_integer()          # wall-clock milliseconds since the Unix epoch
@type window :: %{key: term(), from: ms(), to: ms() | nil}   # to: nil = still running
```

## 2. `ExecutionTime` — window algebra

### 2.1 `from_attempts/1`

```elixir
@spec from_attempts([map()]) :: [window()]
```

| # | Rule | Req |
|---|---|---|
| 2.1.1 | One window per attempt with `%DateTime{}` values under **both** `:started_at` and `:ended_at` (read with `Map.get`); `key = {:attempt, Map.get(a, :phase), Map.get(a, :ordinal)}`, `from`/`to` via `DateTime.to_unix(_, :millisecond)`. | FR-002 |
| 2.1.2 | Every `phase` atom qualifies — pipeline phases, `:remediation`, `:implement_chunk`, `:auto_remediation`, and any future step name. No allow-list. | FR-002 |
| 2.1.3 | An attempt missing either timestamp, or with `ended_at < started_at`, yields no window and raises nothing. Non-list input ⇒ `[]`. | FR-013 |
| 2.1.4 | Output is `normalize/1`d. | — |

### 2.2 `open/3`, `close/3`, `close_all/2`

```elixir
@spec open([window()], key :: term(), from :: ms()) :: [window()]
@spec close([window()], key :: term(), to :: ms()) :: [window()]
@spec close_all([window()], to :: ms()) :: [window()]
```

| # | Rule | Req |
|---|---|---|
| 2.2.1 | `open/3` removes any window with the same `key` and `to == nil`, then adds `%{key, from, to: nil}`. | FR-003 |
| 2.2.2 | `close/3` sets `to = max(to, from)` on the window with the same `key` and `to == nil`; when there is none the list is returned unchanged (a stop whose start was never observed contributes nothing). | FR-004, edge case 2 |
| 2.2.3 | `close_all/2` applies `close/3` to every open window, at the same `to`. | edge case 3 |
| 2.2.4 | All three return a `normalize/1`d list. | — |

### 2.3 `normalize/1`

```elixir
@spec normalize([window()]) :: [window()]
```

| # | Rule |
|---|---|
| 2.3.1 | Deduplicates by `{key, from}`: of colliding entries, a closed one beats an open one; among closed ones the larger `to` wins. |
| 2.3.2 | Sorts by `{from, to}` with `nil` `to` last among equals. |
| 2.3.3 | Idempotent: `normalize(normalize(w)) == normalize(w)`. |

### 2.4 `elapsed_ms/2`

```elixir
@spec elapsed_ms([window()], now :: ms() | DateTime.t()) :: non_neg_integer() | nil
```

| # | Rule | Req |
|---|---|---|
| 2.4.1 | `[]` ⇒ `nil`. | FR-010 |
| 2.4.2 | Each open window is closed at `max(now, from)` (a window that "started in the future" relative to `now` has length 0, never negative). | FR-003 |
| 2.4.3 | Intervals are sorted by `from` and merged while `next.from <= current.to` (overlapping **or touching**); the result is the sum of merged lengths. | FR-001, FR-002, FR-004 |
| 2.4.4 | A `DateTime` `now` is converted with `DateTime.to_unix(_, :millisecond)`. | — |

Properties (asserted by `execution_time_test.exs`):

- **Union**: disjoint windows sum; nested windows add nothing (SC-006);
  partially overlapping windows count the overlap once; windows that merely
  touch (`a.to == b.from`) form one span.
- **Monotone in `now`**: with an open window, `elapsed_ms(w, t2) >=
  elapsed_ms(w, t1)` for `t2 >= t1`; with none, equal (FR-005, FR-006,
  SC-003).
- **Close never lowers**: `elapsed_ms(close(w, k, from + d), now) >=
  elapsed_ms(w, k_open_at_from, from + d)` — closing at the duration the
  span reported equals the value shown live at that instant.
- **Tolerance**: `from_attempts/1` over attempts with `nil` timestamps,
  non-DateTime timestamps, or reversed timestamps returns windows for the
  well-formed ones only.

### 2.5 `native_to_ms/1`

```elixir
@spec native_to_ms(integer()) :: integer()
```

`System.convert_time_unit(value, :native, :millisecond)`. The only place the
telemetry unit is named; the fold calls it on `system_time` and `duration`.

## 3. `ConsoleReadModel.apply_event/4` — window fold (delta)

The feature slice gains `windows: [window()]` (default `[]`). Every other
effect of every event is unchanged.

| Event | `measurements` read | Effect on `slice.windows` |
|---|---|---|
| `[:speckit, :phase, :start]` | `system_time` | `open(w, {:phase, meta.phase}, native_to_ms(system_time))` |
| `[:speckit, :phase, :stop \| :exception]` | `duration` | `close(w, {:phase, meta.phase}, from + native_to_ms(duration))` where `from` is the open window's |
| `[:speckit, :remediation, :start]` | `system_time` | `open(w, {:remediation, meta.phase}, …)` |
| `[:speckit, :remediation, :stop \| :exception]` | `duration` | `close(w, {:remediation, meta.phase}, …)` |
| `[:speckit, :chunk, :start]` | `system_time` | `open(w, {:chunk, meta.phase}, …)` |
| `[:speckit, :chunk, :stop \| :exception]` | `duration` | `close(w, {:chunk, meta.phase}, …)` |
| `[:speckit, :feature, :terminal]` | `system_time` | `close_all(w, native_to_ms(system_time))` |
| any of the above with the measurement absent or non-integer | — | unchanged |

`[:speckit, :chunk, :resolved]`, `[:speckit, :publish, *]`, and
`[:speckit, :run, *]` never touch `windows`.

**Emitter obligation** (`FeatureRunner.emit_terminal/4`):
`[:speckit, :feature, :terminal]` measurements become
`%{cost_total: float(), system_time: integer()}` with
`system_time: System.system_time()`. `Telemetry`'s moduledoc records it.

## 4. `ConsoleReadModel.merge_per_feature/2` (delta)

The Coordinator status slice has `:elapsed_ms` deleted before the projection
slice is merged over it. A per-feature row built by `merge/3` therefore has
no `elapsed_ms` from the Coordinator under any circumstance (FR-009).
`Coordinator.status/0` itself is unchanged; `Report.format_status/1` still
reads its `elapsed_ms`.

## 5. `ConsoleHydration` (delta)

### 5.1 `from_record/3`

| 023 rule | Replacement |
|---|---|
| §1.7 `elapsed_ms = DateTime.diff(ended_at \|\| now, started_at)`; `nil` when `started_at` is `nil` | `windows = from_attempts(phase_attempts)`; `elapsed_ms = elapsed_ms(windows, now)`. The feature's own `started_at`/`ended_at` are not read. |

The slice gains `windows`. Every other 023 rule (§1.1–1.6, 1.8–1.11) is
unchanged.

### 5.2 `layer/3` — signature change

```elixir
@spec layer(recorded_slice() | nil, live :: map() | nil, now :: DateTime.t()) :: row()
```

| Field | Rule |
|---|---|
| `windows` | `normalize((recorded.windows \|\| []) ++ (live.windows \|\| []))` |
| `elapsed_ms` | `elapsed_ms(windows, now)` |
| all others | 023 §3 seed/reconcile column, unchanged |

### 5.3 `apply_update/3` — signature change

```elixir
@spec apply_update(row() | nil, update :: map() | nil, now :: DateTime.t()) :: row()
```

| Field | Rule |
|---|---|
| `windows` | `normalize((row.windows \|\| []) ++ (update.windows \|\| []))` |
| `elapsed_ms` | `max_nil(row.elapsed_ms, elapsed_ms(windows, now))` where `max_nil(nil, x) = x`, `max_nil(x, nil) = x` |
| all others | 023 §3 update column, unchanged |

`apply_update(row, nil, now)` returns `row` unchanged. A `nil` row starts
from 023's default shape plus `windows: []`.

### 5.4 Properties (asserted by `console_hydration_test.exs`)

- **Idempotent**: `layer(r, layer(r, l, t), t) == layer(r, l, t)` field-wise;
  `apply_update(apply_update(row, u, t), u, t) == apply_update(row, u, t)`.
- **Monotone elapsed**: `apply_update(row, u, t).elapsed_ms >= row.elapsed_ms`
  (FR-011); `layer(r, l, t2).elapsed_ms >= layer(r, l, t1).elapsed_ms` for
  `t2 >= t1`.
- **Record replaces live without a dip**: for a live open window `w_live`
  and its recorded window `w_rec ⊇ w_live`, `layer(r_with_w_rec, l_with_w_live,
  t).elapsed_ms == elapsed_ms([w_rec], t)` and is `>= elapsed_ms([w_live], t)`
  (FR-004, SC-004).
- **Cold = live at rest**: for a feature with no open live window,
  `layer(r, nil, t).elapsed_ms == layer(r, l_closed_only, t).elapsed_ms`
  (FR-007).
- **No Coordinator fallback**: a live slice carrying `elapsed_ms: 1348 * 60_000`
  and no `windows` layers to `elapsed_ms: nil` over an empty record (FR-009,
  FR-010).
- 023's idempotence / monotone-spend / no-blanking / live-wins-per-phase
  properties continue to hold.

## 6. `ConsoleReadModel.hydrate/3` and `overlay_observed/2`

`hydrate/3` calls `layer/3` with its own `now`; `overlay_observed/1` becomes
`overlay_observed/2` (`now` threaded) and calls `layer/3`. Modes and feature
sets are unchanged from 023 §5.

## 7. Non-goals (explicit)

- No function here writes anything, seeds the Coordinator, touches the
  projection process, or adds a broadcast (research R8).
- `Store.*`, `Records`, `Writer`, `Coordinator`, `Report`, `RunDetailLive`,
  `RunsLive`, and `format_elapsed/1` are not part of this contract and are
  unchanged.
- The per-attempt Duration column on Run Detail is the reference and is not
  derived from this module.
