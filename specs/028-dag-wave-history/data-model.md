# Data Model: Pipeline Chain Shows Each Wave's Own History

This feature adds no persisted entity and makes no schema change. Everything
here is either a value derived in memory from existing store records or
LiveView assign state.

## Existing inputs (read-only)

### Run summary: `SpeckitOrchestrator.run_history/1` element

The fields this feature uses come from `Store.Query.run_summary/1`:

| Field | Type | Use |
|---|---|---|
| `run_id` | `binary()` (zero-padded monotonic, e.g. `"000042"`) | Recency order: the list arrives sorted by `run_id` descending. It is also the receipt identifier. |
| `state` | `:in_flight \| :parked \| :completed \| :superseded` | Picks between the live and recorded source, and is shown in the receipt. |
| `scope` | `{:breakdown, slug} \| :ad_hoc \| other` | The wave the run belongs to. Only `{:breakdown, slug}` ever matches a wave. |

A damaged row is `%{run_id:, damaged: true, reason:}`. It has no `scope` and
is never matched.

### Run detail: `SpeckitOrchestrator.run_detail/1`

`{:ok, %{run: run, features: [feature_run], cost_entries: [...]}}` is
hydrated through the existing
`ConsoleReadModel.hydrate/3` → `ConsoleHydration.from_record/3`. On failure it
returns `{:error, :absent}` or `{:error, {:damaged, key, reason}}`.

## New derived values

### `WaveHistory.source()`: which run a wave draws from

```text
{:live, summary}          in-flight run scoped to this wave
{:recorded, summary}      newest run scoped to this wave, any non-in-flight state
:none                     no run was ever scoped to this wave
{:unavailable, reason}    history or run record could not be read
```

**Invariants**
- Exactly one source per wave (FR-006).
- `summary.scope == {:breakdown, slug}` for the selected slug (FR-001).
- `{:live, _}` is only ever the `:in_flight` summary.
- `{:recorded, _}`'s `summary.state` is one of `:parked | :completed | :superseded`.

**Transitions (while the page is open)**

```text
:none ──(run of this wave starts)──▶ {:live, s}
{:recorded, old} ──(run of this wave starts)──▶ {:live, s}
{:live, s} ──(run ends: :run_finished / reconcile sees current_run_id change)──▶ {:recorded, s'}   (s'.state ∈ parked|completed|superseded)
any ──(history read error)──▶ {:unavailable, reason}
```

### Drawn wave view: `chain_view/1` output

This is the same shape as today's `view`: a map with `per_feature` keyed by
feature id, each row a `ConsoleHydration.row()` (`status`, `phases`,
`current_phase`, `spend`, `chunk`, `remediation`, `windows`, `elapsed_ms`,
`pr_url`, …).

| Source | `per_feature` comes from |
|---|---|
| `{:live, _}` | `assigns.view` (Coordinator + Ledger + projection, merged and hydrated, as today) |
| `{:recorded, s}` | `assigns.wave_view`: `hydrate(empty_inactive_view, run_detail(s.run_id), now)` then `interrupt/2` on each row, using `s.state` |
| `:none` / `{:unavailable, _}` | `%{}` (every node cold: `:pending`, empty strip, `$0.00`) |
| legacy layout (`selected_package == nil`) | `assigns.view`, ungated (today's behaviour, FR-009) |

The drawer reads the same map for backlog nodes (FR-003). Ad-hoc nodes still
read `assigns.view` (FR-009).

### Interrupted row: `WaveHistory.interrupt/2` output

This applies only when the source is recorded and the row's `status == :running`.

| Field | Before | After |
|---|---|---|
| `status` | `:running` | `:interrupted` (display-only, never persisted, not in `Feature.status/0`) |
| `phases[open_phase]` | absent or pending | `%{state: :interrupted}` |
| `phases[earlier]` | `%{state: :completed, ...}` | unchanged |
| everything else | n/a | unchanged |

`open_phase` is the element of `Pipeline.phases/0` that follows
`row.current_phase` (the checkpoint's `last_completed_phase`), or the first
phase when `current_phase` is `nil`. If `current_phase` is already the last
phase, no cell is added.

Rendering maps it as follows:
- `status_class(:interrupted)` → `"blocked"`
- `label(:interrupted)` → `"Interrupted"`
- `phase_cell_state(%{state: :interrupted}, _)` → `"interrupted"` →
  `.phase-cell-interrupted` (`var(--blocked)`, no animation)

## LiveView assigns (`PipelineDagLive`)

| Assign | Type | New/changed | Meaning |
|---|---|---|---|
| `packages` | `[slug]` | unchanged | Sorted wave slugs |
| `selected_package` | `slug \| nil` | changed default | `WaveHistory.default_package/2` (FR-008) |
| `view` | map | unchanged role | The live read model: ad-hoc lane plus the live wave |
| `run_package` | n/a | **removed** | Replaced by `wave_source` |
| `wave_source` | `WaveHistory.source() \| nil` | **new** | The selected wave's source. `nil` only in the legacy layout. |
| `wave_view` | map \| `nil` | **new** | Hydrated rows for a `{:recorded, _}` source. Otherwise `nil`. |
| `live_run_id` | `binary() \| nil` | **new** | Cached `current_run_id/0`, so a reconcile only re-resolves history when it changes |
