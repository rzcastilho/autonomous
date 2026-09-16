# Data Model: Console Restart Hydration

**Feature**: `023-console-restart-hydration` | **Date**: 2026-09-15

No durable entity is added or changed (FR-015). This document names the
**inputs** the pure hydration consumes (all pre-existing, read through
`SpeckitOrchestrator.run_detail/1`) and the **derived** shapes it produces,
which are view state only.

## Inputs (existing, read-only)

### Recorded feature — one element of `run_detail.features`

| Field | Type | Used for |
|---|---|---|
| `feature_id` | `String.t()` | row key |
| `slug`, `group`, `spec_number` | as recorded | cold-boot row labels |
| `status` | `:pending \| :running \| :done \| :escalated \| :halted \| :failed \| :never_started \| :ended_by_supersession` | cold-boot status; diverted marker |
| `started_at` | `DateTime.t() \| nil` | elapsed start |
| `ended_at` | `DateTime.t() \| nil` | elapsed end (`nil` ⇒ `now`) |
| `pr_url` | `String.t() \| nil` | PR link |
| `checkpoint` | `%Records.Checkpoint{} \| nil` | current phase (`last_completed_phase`), diverted marker, `implement_chunk` sub-label |
| `phase_attempts` | `[recorded attempt]` in execution order | phase cells; spend membership |

Optional-field tolerance (FR-013): every field above may be absent from the
map; `phase_attempts` defaults to `[]`, `checkpoint` and timestamps to `nil`.

### Recorded attempt — one element of `phase_attempts`

| Field | Type | Used for |
|---|---|---|
| `attempt_id` | `{repo_id, run_id, feature_id, phase, ordinal}` | cost-entry membership (opaque; compared by equality only) |
| `phase` | atom — a `Pipeline.phases/0` member **or** `:remediation`, `:implement_chunk`, `:auto_remediation` | cell eligibility (FR-003) |
| `outcome` | atom | cell outcome |
| `model` | `String.t() \| nil` | cell model |
| `cost_usd` | `float() \| nil` | cell cost (the attempt's own, FR-002) |
| `step`, `ordinal`, `started_at` | — | already applied by `Store.Query.attempt_order/1`; hydration trusts list order |

### Cost entry — one element of `run_detail.cost_entries`

| Field | Type | Used for |
|---|---|---|
| `id` | attempt_id tuple | membership test against the feature's attempt ids |
| `amount_usd` | `float()` | spend sum |

### Live slice — `ConsoleReadModel.feature_slice()` (unchanged)

`%{current_phase, phases: %{phase => phase_cell}, spend, chunk, remediation,
pr_url}` (+ `chunk_cost_seen`, fold bookkeeping, dropped before merge).

### Coordinator per-feature entry (unchanged)

`%{status, elapsed_ms (monotonic, since this Coordinator started the feature
or nil), slug, spec_number}`.

## Derived (view state only)

### Phase cell — `ConsoleReadModel.phase_cell()` (unchanged shape)

```elixir
%{state: :active | :completed, outcome: term(), cost: number() | nil, model: String.t() | nil}
```

Record-derived instances:

| Case | `state` | `outcome` | `cost` / `model` |
|---|---|---|---|
| completed pipeline phase (last attempt, at or before checkpoint phase) | `:completed` | attempt's own | attempt's own |
| checkpoint phase of a diverted feature, attempt present | `:active` | feature `status` (marker) | attempt's own (FR-004) |
| checkpoint phase of a diverted feature, no attempt | `:active` | feature `status` | `nil` / `nil` |
| phase after the checkpoint phase (non-`:done` feature) | *absent* (renders pending, FR-002a) | — | — |
| non-phase attempt (`:remediation`, `:implement_chunk`, `:auto_remediation`) | *no cell* (FR-003) | — | — |

### Recorded row slice — `ConsoleHydration.recorded_slice()` (new)

The record's contribution for one feature, before any live data:

```elixir
%{
  status: atom(),                     # recorded status (cold-boot use only)
  slug: String.t() | nil,
  group: atom() | nil,
  spec_number: pos_integer() | nil,
  current_phase: atom() | nil,        # checkpoint.last_completed_phase; nil when no checkpoint (:done)
  phases: %{atom() => phase_cell()},  # trimmed to <= current_phase unless current_phase is nil
  spend: float(),                     # Σ own cost entries (FR-005)
  elapsed_ms: non_neg_integer() | nil,# (ended_at || now) - started_at; nil without started_at
  chunk: chunk_cell() | nil,          # from checkpoint.implement_chunk (as today)
  remediation: nil,
  pr_url: String.t() | nil
}
```

Invariants:
- `phases` keys ⊆ `Pipeline.phases/0`.
- if `current_phase != nil`, no key in `phases` is later than it.
- `spend >= 0.0`, counts each cost entry at most once.
- pure in `now`: same inputs + same `now` ⇒ same slice.

### Console row — what `per_feature[id]` holds (existing shape, now complete)

`recorded_slice` fields ∪ Coordinator fields (`status`, `elapsed_ms`, `slug`,
`spec_number`) ∪ live slice fields, combined by the precedence table in
[contracts/console-hydration.md §3](./contracts/console-hydration.md). The
row shape rendered by `phase_strip`, the backlog table, the chain node, and
the drawer is unchanged — only its completeness is.

## State / precedence (no lifecycle change)

Feature lifecycle, checkpoint lifecycle, and the telemetry fold are untouched.
The one "transition" this feature defines is the per-tick recomputation:

```
seed / :reconciled  →  merge(coordinator, ledger, projection)
                    →  hydrate(view, run_detail, now)        # both modes
:feature_updated    →  apply_update(row, live_slice)         # never regresses
```

Both steps are idempotent: `hydrate` over an already-hydrated view and
`apply_update` with an update already reflected yield the same row.
