# Data Model: Elapsed Is Execution Time

**Feature**: `024-elapsed-execution-time` | **Phase**: 1 | **Date**: 2026-09-16

Nothing here is durable. No Mnesia table, record, or field changes (FR-014).
Every shape below is an in-memory value: a pure-module input/output, a
projection slice, or a rendered row.

## Execution window — `ExecutionTime.window()` (new)

One span of time during which a step for a feature was running.

| Field | Type | Meaning |
|---|---|---|
| `key` | `term()` | Identifies the execution the window describes. Live: `{:phase, phase}` / `{:remediation, :analyze}` / `{:chunk, :implement}` — the span kind and its `metadata.phase`. Recorded: `{:attempt, phase, ordinal}` (ordinal may be `nil` when the record lacks it). Used only to (a) close the right open live window on a span's stop and (b) deduplicate on merge; never compared across sources. |
| `from` | `non_neg_integer()` | Wall-clock start, milliseconds since the Unix epoch. |
| `to` | `non_neg_integer() \| nil` | Wall-clock end, same unit; `nil` = still running (closed at `now` by `elapsed_ms/2`). Invariant when non-nil: `to >= from`. |

**Sources** (see research R1–R3):

- Recorded: one per element of a feature's `phase_attempts` with both
  `started_at` and `ended_at` present (`DateTime.to_unix(_, :millisecond)`);
  every `phase` atom qualifies.
- Live: one per observed `[:speckit, :phase | :remediation | :chunk]` span
  `:start` (`from = native→ms(system_time)`), closed on that span's
  `:stop`/`:exception` (`to = from + native→ms(duration)`), or on
  `[:speckit, :feature, :terminal]` (`to = native→ms(system_time)`).

**Normalization** (`ExecutionTime.normalize/1`): a window list is
deduplicated by `{key, from}` — when two entries collide, a closed one beats
an open one and the later `to` beats the earlier — and sorted by
`{from, to}`. Normalization is idempotent and is applied whenever two lists
are joined.

**Measure** (`ExecutionTime.elapsed_ms/2`): `nil` for `[]`; otherwise close
open windows at `max(now_ms, from)`, merge overlapping-or-touching intervals,
sum the merged lengths. Properties asserted by tests: idempotent under
`normalize/1`; monotone in `now` (an open window never shrinks as `now`
advances); invariant under adding a window contained in an existing one
(SC-006); equal to the plain sum for pairwise-disjoint windows.

## Projection feature slice — `ConsoleReadModel.feature_slice()` (amended)

The per-feature state the console fold holds and broadcasts in
`{:console, :feature_updated, %{feature: slice}}`.

| Field | Change |
|---|---|
| `current_phase`, `phases`, `spend`, `chunk`, `chunk_cost_seen`, `remediation`, `pr_url` | unchanged |
| `windows` | **new** — `[ExecutionTime.window()]`, the live windows observed for this feature in this session (open ones have `to: nil`). Default `[]`. Kept normalized. |

State transitions on `windows`:

| Event | Effect |
|---|---|
| `[:speckit, :phase \| :remediation \| :chunk, :start]` with `measurements.system_time` | `open(windows, key, from)`: any open window under `key` is replaced; a new `%{key, from, to: nil}` is added |
| same kinds, `:stop` / `:exception` with `measurements.duration` | `close(windows, key, from + duration)` on the open window under `key`; no open window ⇒ unchanged |
| `:start` without `system_time`, or `:stop`/`:exception` without `duration` | unchanged (tolerant, FR-013) |
| `[:speckit, :feature, :terminal]` with `measurements.system_time` | `close_all(windows, system_time)`: every open window closed at that instant |
| `[:speckit, :feature, :terminal]` without `system_time` | unchanged |

## Recorded row slice — `ConsoleHydration.recorded_slice()` (amended)

| Field | Change |
|---|---|
| `status`, `slug`, `group`, `spec_number`, `current_phase`, `phases`, `spend`, `chunk`, `remediation`, `pr_url` | unchanged (023 rules §1.1–1.6, 1.8–1.11) |
| `windows` | **new** — `ExecutionTime.from_attempts(phase_attempts)`, normalized |
| `elapsed_ms` | **redefined** — `ExecutionTime.elapsed_ms(windows, now)`; `nil` when there are no windows. The feature's `started_at`/`ended_at` are no longer read. |

## Console row — `ConsoleHydration.row()` (amended)

What Mission Control, the Pipeline Chain, and the drawer render per feature.

| Field | `layer/3` (seed / reconcile) | `apply_update/3` (per `:feature_updated`) |
|---|---|---|
| `windows` | `normalize(record.windows ++ live.windows)` | `normalize(row.windows ++ update.windows)` |
| `elapsed_ms` | `elapsed_ms(windows, now)` | `max(row.elapsed_ms, elapsed_ms(windows, now))` — `nil` only when both sides are `nil` |
| every other field | unchanged from 023 §3 | unchanged from 023 §3 |

The Coordinator's `elapsed_ms` never reaches a row: `merge_per_feature/2`
deletes it from the status slice before the projection slice is merged in
(FR-009).

## Telemetry measurement — `[:speckit, :feature, :terminal]` (amended)

| Measurement | Change |
|---|---|
| `cost_total` | unchanged |
| `system_time` | **new** — `System.system_time()` (native units) at emission, so the fold can close a still-open window without reading the clock (research R6). |

No metadata change; no change to any other event.

## Relationships

```text
run_detail.features[i].phase_attempts ──from_attempts/1──▶ recorded windows ─┐
                                                                             ├─ normalize ─▶ row.windows ──elapsed_ms(now)──▶ row.elapsed_ms
telemetry spans (start/stop/exception/terminal) ──apply_event/4──▶ live windows ─┘
```

## Validation rules (from requirements)

- A window with `to < from` cannot be produced: `close/3` and `close_all/2`
  clamp `to` to `max(to, from)`; `from_attempts/1` skips an attempt whose
  `ended_at < started_at` as it would a missing timestamp.
- `elapsed_ms/2` never returns a negative or a value smaller than any single
  closed window's length.
- `apply_update/3` never returns an `elapsed_ms` smaller than the row's
  (FR-011) and, given the same `now`, is idempotent.
- With no windows on either side, `elapsed_ms` is `nil` and the surfaces
  render `—` (FR-010).
