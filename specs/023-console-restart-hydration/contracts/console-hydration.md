# Contract: `SpeckitOrchestrator.ConsoleHydration` (pure) + `ConsoleReadModel.hydrate/3`

**Feature**: `023-console-restart-hydration` | **Status**: design

Pure functions over plain maps. No Mnesia, Phoenix, Coordinator, `:telemetry`,
or clock access — `now` is always a parameter (FR-012, Principle I).

## 1. `ConsoleHydration.from_record/3`

```elixir
@spec from_record(recorded_feature :: map(), cost_entries :: [map()], now :: DateTime.t()) ::
        recorded_slice()
```

Builds the record's contribution for one feature (shape in
[data-model.md](../data-model.md#recorded-row-slice--consolehydrationrecorded_slice-new)).

Rules:

| # | Rule | Req |
|---|---|---|
| 1.1 | Only attempts whose `phase ∈ Pipeline.phases/0` produce a cell. `:remediation`, `:implement_chunk`, `:auto_remediation` (and any other atom) never do. | FR-003 |
| 1.2 | Per phase, the cell is the **last** eligible attempt in list order (`phase_attempts` is already in execution order). The cell's `outcome`, `model`, `cost` are that attempt's own (`outcome`, `model`, `cost_usd`) — never a sum. | FR-002, clarification 2 |
| 1.3 | `current_phase = checkpoint.last_completed_phase` when a checkpoint exists, else `nil`. | FR-002a |
| 1.4 | When `current_phase != nil`, cells for phases **later** than it are dropped. When `nil` (a `:done` feature, or no checkpoint), every recorded cell stays. | FR-002a, FR-014 |
| 1.5 | When feature `status ∈ [:escalated, :halted, :failed]` and `current_phase != nil`, the cell at `current_phase` is `%{state: :active, outcome: status, cost: c, model: m}` where `c`/`m` come from that phase's last attempt (or `nil` when there is none). Every other cell is `state: :completed`. | FR-004 |
| 1.6 | `spend = Σ entry.amount_usd` over `cost_entries` whose `id ∈ MapSet.new(phase_attempts, & &1.attempt_id)`. Entries for other features' attempts and attempts with no entry contribute nothing. | FR-005 |
| 1.7 | `elapsed_ms = DateTime.diff(ended_at || now, started_at, :millisecond)`; `nil` when `started_at` is `nil`. | FR-006, FR-007 |
| 1.8 | `pr_url = feature.pr_url` (may be `nil`). | FR-001 |
| 1.9 | `chunk` from `checkpoint.implement_chunk` exactly as the pre-023 `checkpoint_chunk/1` (attempt fixed at 1, `remaining`/`outcome` nil); `nil` without one. `remediation` is always `nil`. | FR-014 |
| 1.10 | Every input field is read with `Map.get`; `phase_attempts` absent ⇒ `[]`, `cost_entries` absent/`nil` ⇒ `[]`, `checkpoint` absent ⇒ `nil`, attempt `cost_usd`/`model` absent ⇒ `nil`. Never raises on a record lacking fields. | FR-013 |
| 1.11 | `slug`, `group`, `spec_number`, `status` are carried through for cold-boot rows. | FR-001 |

## 2. `ConsoleHydration.layer/2` — live over record

```elixir
@spec layer(recorded :: recorded_slice() | nil, live :: map() | nil) :: row()
```

`live` is the union of a Coordinator per-feature entry and a projection
feature slice (what `ConsoleReadModel.merge_per_feature/2` builds), or `nil`.
`recorded` is `from_record/3`'s output, or `nil` when the record has no such
feature. At least one is non-`nil`.

Precedence table (§3). Then **trim**: if `live.phases` has any cell with
`state: :active`, drop every cell (any source) for a phase later than that
one.

## 3. Precedence table

| Field | `layer/2` (seed / reconcile) | `apply_update/2` (per `:feature_updated`) | Req |
|---|---|---|---|
| `status` | live if present, else record | update if present, else row | FR-008 |
| `slug`, `group`, `spec_number` | live if non-nil, else record | row (updates never carry them) | — |
| `phases` | `Map.merge(record.phases, live.phases)`, then trim after live active phase | `Map.merge(row.phases, update.phases)`, then trim after update's active phase | FR-009, FR-011, FR-002a |
| `current_phase` | live active phase → live `current_phase` → record | update's if non-nil, else row | FR-002a |
| `spend` | `max(record.spend, live.spend)` | `max(row.spend, update.spend)` | FR-010, FR-011 |
| `elapsed_ms` | record if non-nil, else live | row (updates never carry it) | FR-006, FR-007 |
| `pr_url` | live if non-nil, else record | update if non-nil, else row | FR-011 |
| `chunk` | live if non-nil, else record | **replaced** by update (nil clears) | FR-011, FR-014 |
| `remediation` | live | **replaced** by update (nil clears) | FR-011 |
| `chunk_cost_seen` | dropped | dropped | — |

Properties (asserted by tests):

- **Idempotent**: `layer(r, layer(r, l)) == layer(r, l)` field-wise;
  `apply_update(apply_update(row, u), u) == apply_update(row, u)`.
- **Monotone spend**: `apply_update(row, u).spend >= row.spend`.
- **No blanking**: for every phase `p` with a cell in `row.phases` and no
  cell in `u.phases`, `apply_update(row, u).phases[p] == row.phases[p]`
  unless `p` is later than `u`'s active phase.
- **Live wins per phase**: for every `p` in `u.phases`,
  `apply_update(row, u).phases[p] == u.phases[p]`.

## 4. `ConsoleHydration.apply_update/2`

```elixir
@spec apply_update(row :: map(), update :: map() | nil) :: map()
```

Column 3 of §3. `update == nil` returns `row`. A row that does not exist yet
(new feature id) starts from `%{status: :pending, elapsed_ms: nil, slug: nil,
phases: %{}, spend: 0.0, chunk: nil, remediation: nil, pr_url: nil,
current_phase: nil}` — the LiveViews' existing default, now supplied by this
function so both views agree.

## 5. `ConsoleReadModel.hydrate/3` (replaces `overlay_last_known_statuses/2`)

```elixir
@spec hydrate(view :: map(), run_detail :: map() | nil, now :: DateTime.t()) :: map()
```

| Mode | Feature set | Per row | Then |
|---|---|---|---|
| `view.active? == true` (live Coordinator) | **`view.per_feature`'s keys only** — a feature present in the record but not in the Coordinator is **not** added | `layer(from_record(f, cost_entries, now) \|\| nil, live_row)` | — |
| `view.active? == false`, `run_detail` non-nil | record's features, `Map.put_new` (never overwrites an existing entry — as today) | `layer(from_record(f, cost_entries, now), nil)` | `overlay_observed/1` |
| `run_detail == nil` | unchanged | — | `overlay_observed/1` |

`overlay_observed/1` keeps its promotion rule (only a feature whose live
slice has an `:active` cell becomes `:running`) but merges the live slice via
`layer/2` instead of `Map.merge`, so it also cannot blank record cells.

`run_detail.cost_entries` absent ⇒ `[]`. A `run_detail` whose `features` is
not a list is treated as `nil`.

## 6. Non-goals (explicit)

- No function here writes anything, seeds the Coordinator, or touches the
  projection process (FR-015).
- `RunDetailLive`, `Store.Query`, `Records`, `Writer` are not part of this
  contract and are unchanged.
- Chunk-attempt ordinal numbering after a resume, and the run header's
  committed+reserved vs run history's committed spend, are out of scope
  (spec Assumptions).
