# Research: Console Restart Hydration

**Feature**: `023-console-restart-hydration` | **Date**: 2026-09-15

Every item below was resolved by reading the current code; nothing in
Technical Context remained `NEEDS CLARIFICATION`. Each entry records the
decision, the evidence in the tree, and the alternatives rejected.

## R1. Where the state is lost (root cause)

**Finding.** Three independent drops, all on the console side; the record is
intact (Run Detail proves it).

1. **Live mode ignores the record.** `ConsoleReadModel.overlay_last_known_statuses/2`
   is a no-op when `view.active?` (a live `Coordinator` exists). After a
   resume, `merge/3` builds `per_feature` from `Coordinator.status/0` (status,
   `elapsed_ms` since *this* Coordinator's start, slug) merged with
   `ConsoleProjection.read/0` (phases/spend observed *since boot*). Nothing
   reads attempts, cost entries, or timestamps — finished features get
   `phases: %{}`, `spend: 0.0`; `elapsed_ms` is `nil` for features this
   Coordinator never started.
2. **Cold boot uses only the checkpoint.** With no Coordinator, the overlay
   derives cells from `checkpoint.last_completed_phase` (`checkpoint_phases/2`)
   and hard-codes `spend: 0.0`, `elapsed_ms: nil`, `cost: nil`, `model: nil`.
   A `:done` feature has no checkpoint (`record_feature_terminal/5` deletes it)
   so it renders empty.
3. **Live updates clobber rows.** Both LiveViews handle
   `{:console, :feature_updated, %{feature: slice}}` with
   `Map.merge(row, slice)`. The slice is the projection's whole feature entry
   (`phases`, `spend`, `pr_url`, …) so `phases` is replaced wholesale by the
   since-boot map and `spend` by the since-boot sum. Even once rows are
   hydrated on reconcile, every phase event would blank them until the next
   tick (the "flicker" SC-004 forbids).

**Decision.** Fix all three at the read-model layer, not by seeding the
Coordinator/projection from the record (FR-015): a pure hydration step on
every seed/reconcile in both modes, plus a per-update merge that cannot
regress.

**Alternatives considered.**
- *Seed `ConsoleProjection` from the record on boot/resume.* Rejected: the
  projection would become a second copy of the record that drifts (FR-015
  forbids it; constitution "the console is never a second source of truth").
- *Seed `Coordinator.started_at` from `feature.started_at` on resume.*
  Rejected: mixes monotonic and wall clocks in the Coordinator, and still
  leaves finished features blank. FR-015 forbids it explicitly.
- *Persist the projection.* Rejected (008 FR-036, 023 FR-015).

## R2. The record already carries everything needed

**Finding.** `SpeckitOrchestrator.run_detail/1` (→ `Store.Query.build_run_detail/1`)
returns, per feature: `status`, `started_at`, `ended_at`, `pr_url`,
`checkpoint` (struct or `nil`), `phase_attempts` (maps, sorted by
`{step, started_at_unix, ordinal}` = execution order, each with `attempt_id`,
`phase`, `ordinal`, `step`, `outcome`, `model`, `cost_usd`, `started_at`),
`slug`, `group`, `spec_number`; and at run level `cost_entries`
(`%Records.CostEntry{id, amount_usd, kind}` where `id` **is** the
`attempt_id` tuple it belongs to — `Writer.write_cost_entry/3`).

Timestamps: `record_feature_started/2` stamps `started_at` only when `nil`
and clears `ended_at` on every (re)start; `record_feature_terminal/5` stamps
`ended_at`. So `(ended_at || now) - started_at` is the wall-clock elapsed the
spec asks for, across resumes, with no bookkeeping (spec Assumptions).

Both LiveViews already call `current_run_detail/0` on mount **and** on every
`:reconciled` message; `Store.current_run_key/1` finds the `:in_flight` run,
which a resumed run is. No new read (spec Assumptions confirmed).

**Decision.** Hydrate from `run_detail/1`'s existing shape; treat it as a plain
map contract (`Map.get` for every optional field) so records predating a
field render (FR-013).

## R3. Which recorded attempts make a phase cell

**Finding.** `phase_attempts` for one feature mixes:

| `phase` | Written by | Cost entry? | Cell? |
|---|---|---|---|
| one of `Pipeline.phases/0` (`:specify … :converge`) | `FeatureRunner.record_attempt/9` | yes | **yes** |
| `:remediation` (step 0, pre-phase corrective step, 013) | `FeatureRunner.run_remediation/4` | yes | no (FR-003) |
| `:implement_chunk` (015) | `ChunkRunner.record_chunk_attempt/6` | **no** — the `:implement` roll-up carries the summed cost | no (FR-003) |
| `:auto_remediation` (017) | `Writer.record_remediation_attempt/2` | yes | no (FR-003) |

A phase can have several attempts (`analyze` #1, `auto_remediation` #1,
`analyze` #2 … under one `step`). Execution order is already the list order
(`Query.attempt_order/1`).

**Decision.** Cell = the **last** attempt in list order whose `phase` is in
`Pipeline.phases/0`, per phase (FR-002, clarification 2). Filter by membership
in `Pipeline.phases/0` rather than by an exclusion list so a future non-phase
step never leaks a cell.

## R4. Spend derived from the record

**Finding.** `Query.effective_spend/1` (run header) and `Recovery.spend_of/1`
(Ledger seed on resume) both sum `speckit_cost_entry.amount_usd` for the run.
Per feature, the entries "belonging to its own attempts" are exactly those
whose `id` equals one of the feature's `phase_attempts[].attempt_id` — chunk
attempts have no entry, so they can never double count with the roll-up
(FR-005, edge cases 3–5).

**Decision.** `spend = Σ amount_usd over cost_entries whose id ∈ MapSet of the
feature's attempt_ids`. This uses no positional knowledge of the id tuple.

**Alternative rejected.** Matching `elem(id, 2) == feature_id` — works today
but couples the pure module to `Ids.attempt_id/5`'s tuple layout.

**SC-002 note.** "The spend Run Detail shows for that feature" is the sum of
its *cost-entry-backed* rows (every row except `implement_chunk`, whose
`cost_usd` is inspection-only per `ChunkRunner`). The pure test asserts the
two agree on a fixture with chunks + roll-up + auto-remediation.

## R5. Current phase and the "later cells render pending" rule

**Finding.** Checkpoint semantics (`FeatureRunner.checkpoint_for/3`):
`{:cont, next}` writes `%{phase: next, last_completed_phase: phase, status:
:in_progress}`; a diversion writes `%{phase: p, last_completed_phase: p,
status: :escalated | :halted | :failed}`; `:done` deletes the row. The
existing overlay already uses `last_completed_phase` as the boundary.

A resume from an earlier phase (`resume/2` with `:from`) does **not** rewrite
the checkpoint until that phase's attempt completes — so during the re-run
the checkpoint still points past the phase now running. The live active phase
is the only thing that knows the truth at that moment; hence the spec's rule
"current phase = live active phase when observed, otherwise checkpointed".

**Race to avoid (SC-004).** On a reconcile tick the LiveView reads
`run_detail` and the projection at slightly different instants. If a phase
just stopped live but the checkpoint read is a hair stale, trimming *all*
cells after the checkpoint phase would drop the freshly completed live cell
for one tick.

**Decision.** Two trims, one per source:
- cells after the **checkpoint phase** are dropped only among **record-derived**
  cells (inside `from_record/3`, before any live data is seen);
- cells after the **live active phase** (when there is one) are dropped from
  the merged row (inside `layer/2` and `apply_update/2`).
A `:done` feature (no checkpoint, `current_phase: nil`) keeps every recorded
cell (FR-002a). Within one session no phase is ever re-run at an earlier
position without a live `:start`, so the second trim can never drop a live
cell.

## R6. Diverted cell: marker vs receipt

**Finding.** `phase_strip`/drawer color the `:active` cell by the row's
`status` when it is `:escalated | :halted | :failed` — the marker is a
rendering rule over `state: :active` + row status. The existing cold-boot
cell sets `outcome: status` (the drawer prints `inspect(outcome)` as its
note) and `cost: nil, model: nil`.

**Decision.** For a diverted feature with a checkpoint, the cell at
`last_completed_phase` is `%{state: :active, outcome: <feature status>,
cost: <attempt.cost_usd>, model: <attempt.model>}` — marker semantics as
today, receipt from the attempt (FR-004 names cost and model, deliberately
not outcome: the attempt's own outcome is usually `:ok` — the session
succeeded, the gate diverted — and would mislead as the note). When no
attempt exists at that phase the cell degrades to `cost: nil, model: nil`,
as today.

## R7. Elapsed: wall clock, injected `now`

**Decision.** `elapsed_ms = DateTime.diff(ended_at || now, started_at,
:millisecond)`; `nil` when `started_at` is `nil` (FR-006/FR-007). In
`layer/2` the record's value wins whenever it is non-`nil`; otherwise the live
`elapsed_ms` (Coordinator monotonic counter) is kept; otherwise `nil` → `—`.
`now` is a parameter of every pure function; the LiveViews pass
`DateTime.utc_now/0` at seed and reconcile. Consequences accepted per spec
Assumptions: downtime counts; a feature the record says is running but whose
runner died keeps counting until reconciled.

A feature that finished **in this session** therefore freezes at
`ended_at - started_at` on the next reconcile tick (US1 scenario 3 / SC-005),
where today the Coordinator's counter keeps growing.

## R8. Live-over-record precedence (one table for both modes and updates)

**Decision** (full table in contracts/console-hydration.md §3):

| Field | Rule |
|---|---|
| `status`, `slug`, `group`, `spec_number` | live if present, else record (live mode: Coordinator is authority, FR-008) |
| `phases` | `Map.merge(record_cells, live_cells)` then drop cells after the live active phase |
| `current_phase` | live active phase → else live `current_phase` → else record (checkpoint) |
| `spend` | `max(record, live)` (FR-010) |
| `elapsed_ms` | record if non-nil, else live |
| `pr_url` | live if non-nil, else record (FR-011) |
| `chunk` | live if non-nil, else checkpoint-derived (FR-014) |
| `remediation` | live only (the record has no live-loop cell to offer) |

`apply_update/2` (per `:feature_updated`) is the same table with the *current
row* as the base and the update as "live", except `chunk`, `remediation`,
`current_phase` are **replaced** by the update (FR-011 keeps today's
terminal-clears-sub-label behaviour) and `chunk_cost_seen` (fold bookkeeping)
is dropped. Both functions are idempotent, so re-applying on every tick needs
no provenance in view state.

**Feature set in live mode.** `hydrate/3` iterates the Coordinator's
`per_feature` keys and looks each up in the record; record-only features are
not added (FR-008, edge case "out-of-scope on this resume"). In cold boot the
record defines the set, as today, and `overlay_observed/1` still promotes a
feature with a live active phase to `:running`.

## R9. Drawer shows model (FR-016)

**Finding.** `FeatureDrawerComponent.timeline_meta/1` renders `$cost` (or the
state word) and the note renders `inspect(outcome)`; `model` is folded into
live cells but never rendered anywhere on the console.

**Decision.** `timeline_meta/1` renders `"$<cost> · <model>"` when both are
present, `$<cost>` or `<model>` alone otherwise, state word when neither —
for live and record-derived cells alike (parity is the point of FR-016). No
new element, class, or token; the meta span is already mono.

## R10. Test strategy (SC-007)

- **Pure** (`console_hydration_test.exs`): synthetic `run_detail`-shaped maps,
  injected `now`. Covers FR-001–007, 010–013, both clarifications, and every
  edge case in the spec, including a record with `phase_attempts`/`checkpoint`
  /`started_at` absent (FR-013) and a cost-entry list with entries for two
  features.
- **Read model** (`console_read_model_test.exs`): `hydrate/3` in live mode
  (feature set = Coordinator's; record fills; record-only feature ignored) and
  cold mode (rows from record; `overlay_observed/1` promotion still works and
  now merges per phase).
- **LiveView** (`StoreCase`): cold boot with two `:done` features recorded
  through all seven phases → seven `phase-cell-completed`, non-zero spend,
  elapsed = end−start; live Coordinator started over the same store → same
  cells; `send(view.pid, {:console, :feature_updated, …})` with a since-boot
  slice → pre-restart cells still completed, spend not lower; drawer shows
  model. Pipeline chain: node cells + spend after restart (US1 scenario 4).
- Existing suite must pass (`design_contract_test.exs` included).
