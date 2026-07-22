# Phase 1 Data Model: Pipeline DAG Ad-Hoc Feature Visibility

This feature introduces **no new persisted entities**. It reshapes how existing
in-memory view state is projected onto the DAG. The entities below describe the
render-time shapes involved.

## Entity: DAG Node (extended)

A feature drawn on the Pipeline DAG. Existing backlog nodes come from
`PipelineDagLayout.layout/1`; ad-hoc nodes are newly derived from live state.
The node now carries an **origin** distinguishing the two.

| Field    | Type                        | Source (backlog)             | Source (ad-hoc)                    | Notes |
|----------|-----------------------------|------------------------------|------------------------------------|-------|
| `id`     | `String.t()` (zero-padded)  | `Feature.id` via `Backlog`   | `per_feature` key (from Coordinator) | Always present; stable node key & drawer key |
| `slug`   | `String.t()` \| `nil`       | `Feature.slug`               | `per_feature[id].slug`             | May be `nil`/blank for ad-hoc (render from id) |
| `origin` | `:backlog` \| `:ad_hoc`     | `:backlog` (derived)         | `:ad_hoc` (derived)                | **New.** Drives marker, legend, edge applicability |
| `depth`  | `non_neg_integer()`         | longest prereq chain         | `0` (orphan)                       | Ad-hoc always depth 0 |
| `prereqs`| `[String.t()]`              | `Feature.prereqs`            | `[]`                               | Ad-hoc has none by construction |
| `x`,`y`  | `non_neg_integer()`         | layered positioning          | ad-hoc lane positioning            | Ad-hoc positions computed independently of backlog plane |

**Origin rule**: `origin == :ad_hoc` ⟺ the id is a key of `view.per_feature`
that is **not** among the backlog-derived node ids. Ad-hoc nodes have no
incoming or outgoing edges.

### Render-time (live) fields, looked up per node by id from `view.per_feature`

These are unchanged from today and identical for both origins — they are read at
render time, not stored on the layout node:

| Field         | Type                    | Accessor in view                       |
|---------------|-------------------------|----------------------------------------|
| `status`      | lifecycle atom          | `per_feature[id].status` (default `:pending`) |
| `spend`       | `number()`              | `per_feature[id].spend` (default `0.0`) |
| `phases`      | `%{atom => phase_cell}` | `per_feature[id].phases` (default `%{}`) |
| `elapsed_ms`  | `non_neg_integer` \| nil| `per_feature[id].elapsed_ms`           |
| `current_phase`| `atom` \| `nil`        | `per_feature[id].current_phase`        |

## Entity: Ad-Hoc Lane

The dedicated layout region holding ad-hoc nodes, separate from the backlog
plane so the backlog plane's geometry is unaffected by ad-hoc presence.

| Field    | Type                | Notes |
|----------|---------------------|-------|
| `nodes`  | `[ad_hoc_node()]`   | Positioned orphan nodes; `[]` when no ad-hoc feature is live |
| (canvas) | pixel size          | Sized to the ad-hoc nodes only; independent of backlog canvas |

**Empty invariant**: when `nodes == []`, the LiveView emits no ad-hoc section
and no ad-hoc legend entry — the render is identical to the current
backlog-only output (FR-006 / SC-004).

## State transitions

None owned by this feature. An ad-hoc node's `status`/`spend`/`phases` transition
exactly as any feature's do, driven by the existing PubSub console updates
(`{:console, :feature_updated, …}`, `:reconciled`, `:run_finished`) that
`PipelineDagLive` already handles. This feature only ensures the node is drawn;
it does not add or alter any lifecycle transition.

## Validation rules

- **VR-1**: An id present in both the backlog node set and `per_feature` renders
  once, as a **backlog** node (backlog origin wins; it has the real dependency
  edges). Ad-hoc set = strict difference.
- **VR-2**: Ad-hoc nodes never contribute edges; `edges` for the backlog plane
  are computed solely from backlog features (unchanged).
- **VR-3**: Id proximity is irrelevant to origin — an ad-hoc `009` adjacent to a
  backlog `008` is still classified by set membership, and both remain visually
  distinguishable via `origin` marker (spec Edge Case).
- **VR-4**: A `nil` slug is a valid ad-hoc node; it renders from `id`.
