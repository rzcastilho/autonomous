# Contract: console surfaces — ELAPSED (delta over 023)

**Feature**: `024-elapsed-execution-time` | **Status**: design

What Mission Control (`/`), the Pipeline Chain (`/dag`), and the feature
drawer render for ELAPSED, and the DOM hooks tests assert on. Markup,
classes, tokens, and data attributes are the **existing** ones — this feature
adds no new element, class, color, keyframe, status value, or inline style
(Principle VII; `design_contract_test.exs` stays green). Everything 023's
`contracts/console-views.md` says about status, progress cells, spend, PR
links, and no-blanking stands; only the ELAPSED rows below change.

## 1. Call sites

| Surface | Seed (mount) | `:reconciled` | `:feature_updated` |
|---|---|---|---|
| `MissionControlLive` | `merge/3` → `hydrate(view, current_run_detail(), DateTime.utc_now())` (unchanged) | same | `apply_update(row, feature, DateTime.utc_now())` |
| `PipelineDagLive` | same | same | `apply_update(row, feature, DateTime.utc_now())` |
| `RunDetailLive` | unchanged — its Duration column is the reference | — | — |

`current_run_detail/0`, the 2 s reconcile cadence, and the broadcast set are
unchanged (no new store read, no new timer, spec Assumptions).

## 2. Mission Control row — `tr[data-feature-row=<id>]`

| Column | Source after 024 | Hooks |
|---|---|---|
| Elapsed | `format_elapsed(row.elapsed_ms)` — **union of recorded attempt windows and live span windows, closed at render `now`**; `—` only with no window at all | text, `Mm Ss` |

Required renderings (acceptance scenarios; each is a LiveView test):

- **US1-1** (cold and live): a `:done` feature whose seven recorded attempts
  cover 40 min of execution across a 20 h calendar span reads `40m 0s`, not
  `1200m 0s` — identically with no Coordinator and with a live Coordinator
  resumed over the same store.
- **US1-2 / SC-005**: a finished feature shows the same elapsed on every
  later reconcile tick and after other features' `:feature_updated`
  broadcasts.
- **US1-4 / US1-5 / SC-006**: a record with `:implement_chunk` attempts under
  the `:implement` roll-up, or with superseded `:analyze` and
  `:auto_remediation` attempts under the final `:analyze` record, reads the
  same as the same record with those inner attempts removed.
- **US2-1**: a feature with four recorded phases and a live `:analyze`
  `:start` emitted with `system_time: System.system_time()` reads the four
  attempts' union **plus** the time since that start, and a later
  `:reconciled` tick reads a value ≥ the first.
- **US2-2 / SC-004**: after that phase's `:stop` and its record landing,
  the row's value is ≥ the last live value and ≤ it plus one reconcile
  interval.
- **US2-3 / FR-006**: a feature whose live phase has stopped (no open
  window) shows the same elapsed across successive ticks.
- **US2-4**: a feature resumed from `plan` with stale `tasks`/`analyze`
  attempts recorded counts those attempts' windows too.
- **US3-1**: halted at `analyze` after four completed phases: elapsed equals
  the union of all five recorded attempts, cold and live.
- **US3-2**: a feature with no attempt and no live phase reads `—`.
- **US3-3**: a feature whose only activity is a live `:start` reads the
  seconds since it (`0m Ns`).
- **FR-009**: a live Coordinator whose `status/0` reports
  `elapsed_ms: 80_880_000` for a feature with no attempts and no live phase
  renders `—`.

## 3. Pipeline Chain node drawer — `div[data-dag-node=<id>]` → `aside.feature-drawer`

The node click opens the same `feature_drawer` component over the same
hydrated row; **US1-3**: its `.drawer-stat-value` ELAPSED equals the Mission
Control row's for the same record.

## 4. Feature drawer — `aside.feature-drawer`

| Element | Source | Change |
|---|---|---|
| `.drawer-stat-value` (ELAPSED) | `row.elapsed_ms` | value semantics only (§2); markup unchanged |
| everything else | 023 §4 | none |

## 5. Regression protection on live updates (FR-011, SC-004)

`apply_update/3` is the only path a `:feature_updated` broadcast takes into
a row on either view (as in 023). Its `elapsed_ms` is `max`-clamped against
the row's previous value, so no update — including an update for a feature
whose windows the projection has not yet observed this session (empty
`windows`) — can lower a hydrated row's ELAPSED. The 023 test "a
`:feature_updated` broadcast carrying only since-boot phases leaves
pre-restart cells completed and spend non-decreasing" gains an
elapsed-non-decreasing assertion.
