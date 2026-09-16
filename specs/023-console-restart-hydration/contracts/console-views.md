# Contract: console surfaces after hydration

**Feature**: `023-console-restart-hydration` | **Status**: design

What Mission Control (`/`), the Pipeline Chain (`/dag`), and the feature
drawer must render, and the DOM hooks tests assert on. Markup, classes,
tokens, and data attributes are the **existing** ones — this feature adds no
new element, class, color, keyframe, or inline style (Principle VII;
`design_contract_test.exs` stays green).

## 1. Call sites

| Surface | Seed (mount) | `:reconciled` | `:feature_updated` |
|---|---|---|---|
| `MissionControlLive` | `merge/3` → `hydrate(view, current_run_detail(), DateTime.utc_now())` | same | `apply_update(row, feature)` |
| `PipelineDagLive` | same (run_detail already fetched for `default_package/2`) | same | `apply_update(row, feature)` |
| `RunDetailLive` | unchanged — it is the reference | — | — |

`current_run_detail/0` and the 2 s reconcile cadence are unchanged (no new
store read, spec Assumptions).

## 2. Mission Control row — `tr[data-feature-row=<id>]`

| Column | Source after 023 | Hooks |
|---|---|---|
| Status | live status (Coordinator) or recorded status (cold) | `.status-pill` / `data-status` (unchanged) |
| Progress | `phase_strip phases=row.phases status=row.status chunk=row.chunk remediation=row.remediation` | `span[data-phase=<p>].phase-cell-{pending\|active\|completed\|escalated\|halted\|failed}` |
| Elapsed | `format_elapsed(row.elapsed_ms)` — record wall-clock, else live counter, else `—` | text |
| Spend | `format_money(row.spend)` — `max(record, live)` | text |

Required renderings (acceptance scenarios):

- **US1-1/4/5**: a feature recorded `:done` through all seven phases renders
  seven `phase-cell-completed`, spend = Σ its cost entries, elapsed =
  `ended_at − started_at` — identically in cold boot and with a live
  Coordinator.
- **US1-3**: a feature that finished in-session shows the same elapsed on
  every later tick.
- **US2-1**: a feature resumed at phase 5: cells 1–4 `completed`, 5 `active`,
  elapsed from the recorded `started_at`.
- **US2-5**: resumed from `plan` with `tasks`/`analyze` recorded: `plan`
  `active`, `tasks`/`analyze` `pending`.
- **US3-1/2**: halted at `analyze`: `analyze` cell `phase-cell-halted`, four
  earlier cells `completed`, spend and elapsed non-empty.
- **Recovered banner** (`data-state="recovered-run"`) and the parked banner
  are unchanged.

## 3. Pipeline Chain node — `div[data-dag-node=<id>]`

Same `phase_strip` and `.dag-node-spend` as today, fed from the hydrated view
(`chain_view/1` gating by run package unchanged). US1-4: a `:done`
pre-restart feature's node carries the same cells and spend as its Mission
Control row.

## 4. Feature drawer — `aside.feature-drawer`

| Element | Source | Change |
|---|---|---|
| `.drawer-stat-value` elapsed / spend | `row.elapsed_ms` / `row.spend` | none (values now complete) |
| `li.timeline-cell[data-phase][data-phase-state]` | `row.phases` + `row.status` | none |
| `.timeline-meta` | **`"$<cost> · <model>"`** when both present; `"$<cost>"` or `"<model>"` alone; state word when neither | **FR-016** — renders `model` for live and record-derived cells alike |
| `.timeline-note` | `inspect(cell.outcome)` | none — a diverted cell's note is the status marker (`:halted`), as today |
| Pull request block | `row.pr_url` | none (record link now survives live updates, US3-3) |

`model` is the CLI alias recorded on the attempt (`opus`/`sonnet`) — a
machine value, rendered inside the existing mono `.timeline-meta` span, under
no friendlier name.

## 5. Regression protection on live updates (FR-011, SC-004)

For a hydrated row and an update slice carrying only since-boot phases:

- every pre-restart `completed` cell stays `completed` after the update;
- the row's spend does not decrease;
- a `pr_url` known to the row survives an update with `pr_url: nil`;
- `chunk`/`remediation` follow the update (a terminal update still clears
  them);
- an update whose active phase is earlier than a recorded cell (resume from
  an earlier phase) renders the later recorded cells `pending`.

Tests drive this by `send(view.pid, {:console, :feature_updated, %{id:, feature:}})`
after a cold-boot or live mount and re-rendering.

## 6. Tolerance (FR-013, SC-006)

A run record whose features lack `phase_attempts`, `checkpoint`,
`started_at`/`ended_at`, or `pr_url`, or a run lacking `cost_entries`, renders
every page: empty strip, `—`, `$0.00`. No `KeyError`, no crash.
