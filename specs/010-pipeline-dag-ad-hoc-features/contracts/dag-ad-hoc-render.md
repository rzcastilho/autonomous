# Contract: DAG Ad-Hoc Render

Two contracts define this feature's surface: a **pure function** contract on
`PipelineDagLayout`, and a **DOM / test-selector** contract on the rendered
`/dag` view. Both are exercised by the tests in `quickstart.md`.

## 1. Pure function — `PipelineDagLayout`

Add a pure, LiveView-free helper that derives the ad-hoc lane from the
already-computed backlog layout and the set of live feature ids. Exact name/arity
is an implementation choice; the contract is the behavior below.

```elixir
@type ad_hoc_node :: %{
        id: String.t(),
        slug: String.t() | nil,
        origin: :ad_hoc,
        depth: 0,
        prereqs: [],
        x: non_neg_integer(),
        y: non_neg_integer()
      }

@type ad_hoc_lane :: %{nodes: [ad_hoc_node()]}

@spec ad_hoc_nodes(backlog_layout :: t(), live :: %{String.t() => map()}) :: ad_hoc_lane()
```

**Behavioral contract**

| # | Given | Then |
|---|-------|------|
| C1 | `live` keys are a subset of backlog node ids | `nodes == []` |
| C2 | `live` has one key absent from backlog nodes | one node with that `id`, `origin: :ad_hoc`, `depth: 0`, `prereqs: []` |
| C3 | `live` has N absent keys | N nodes, one per id, distinct positions (each an isolated orphan) |
| C4 | an id is in both backlog nodes and `live` | it is **not** in the ad-hoc lane (backlog origin wins — VR-1) |
| C5 | ad-hoc id numerically adjacent to a backlog id (e.g. backlog `008`, live `009`) | `009` still returned as ad-hoc; classification is by set membership, not id order (VR-3) |
| C6 | live slice has `slug: nil` | node `slug` is `nil`; function does not raise (VR-4) |
| C7 | any input | function is pure — no Phoenix, no process calls, no I/O (Constitution I) |

Positioning may reuse the module's existing spacing constants; the only
requirement is that ad-hoc positions are computed independently of the backlog
plane so backlog geometry is unchanged whether or not ad-hoc nodes exist.

## 2. DOM / test-selector contract — `/dag` render

Rendered by `PipelineDagLive`. Selectors below are the stable contract asserted
by `pipeline_dag_live_test.exs`.

### Backlog nodes (unchanged behavior, new attribute)

- Each backlog node keeps `data-dag-node={id}` and its current markup.
- Each node carries `data-node-origin="backlog"`.

### Ad-hoc lane (new, guarded)

- Rendered only when the ad-hoc set is non-empty (`:if`).
- Wrapped in a distinct section, e.g. `data-state="ad-hoc-lane"` (a sibling of
  the backlog `data-state="dag"` plane, not nested in it).
- Each ad-hoc node:
  - `data-dag-node={id}` — same selector family as backlog nodes.
  - `data-node-origin="ad-hoc"` — the machine-readable origin marker (FR-005).
  - a visible marker element (badge/border) recognizable without opening the
    drawer (FR-005 / US3) — e.g. `data-adhoc-badge` or a dedicated class.
  - reuses `<.status_pill status={…}/>`, `<.phase_strip …/>`, and the spend
    cell, all sourced from `view.per_feature[id]` (FR-003).
  - `phx-click="select_feature"` with `phx-value-id={id}` (FR-004).

### Legend (new entry, distinct from status colors)

- The existing per-status swatches (`data-legend-status={status}`) are unchanged.
- A **separate** legend entry explains the ad-hoc marker, e.g.
  `data-legend-origin="ad-hoc"`, rendered outside/after the status swatch loop so
  it is not one of the `palette/0` status colors (FR-005). Present only when the
  ad-hoc lane is present.

### Drawer (reused unchanged)

- Clicking any node (backlog or ad-hoc) sets `selected_feature_id` and renders
  the existing `<.feature_drawer feature={Map.get(@view.per_feature, id)} …/>`.
  For an ad-hoc id this opens the same drawer with that feature's live detail and
  the same resume/restart actions (US2) — no drawer code change.

### No-regression guarantee (FR-006 / SC-004)

- When the ad-hoc set is empty: no `data-state="ad-hoc-lane"` element, no
  `data-legend-origin="ad-hoc"` entry, and every existing backlog selector
  renders exactly as today (the only additive delta is the constant
  `data-node-origin="backlog"` attribute on existing nodes).
