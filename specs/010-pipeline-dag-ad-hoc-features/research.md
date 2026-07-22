# Phase 0 Research: Pipeline DAG Ad-Hoc Feature Visibility

No `NEEDS CLARIFICATION` remained after the spec's 2026-07-22 clarification
session (ad-hoc nodes sit in a separate lane; distinguished by both a per-node
marker and a legend entry). Research below records the design decisions that
turn those answers into a concrete, constitution-compliant implementation.

## Decision 1 — Source of ad-hoc nodes: derive, never fetch

- **Decision**: Ad-hoc feature ids are computed as the set difference
  `Map.keys(view.per_feature) − {backlog node ids}`. No new data source, no new
  Coordinator call, no backlog read.
- **Rationale**: `view.per_feature` (built by `ConsoleReadModel.merge/3` from
  `Coordinator.status/0` + `Ledger.snapshot/1` + `ConsoleProjection.read/0`) is
  already keyed by *every* Coordinator-tracked feature id — this is exactly why
  Mission Control shows ad-hoc runs today. `PipelineDagLive` already assigns
  `view` and already renders backlog nodes from `dag_layout.nodes`. The only gap
  is that nothing draws the `per_feature` keys that aren't backlog ids.
- **Alternatives considered**:
  - *Have `Backlog.load!` also surface worktree seeds* — rejected: violates
    FR-007 (presentation-only) and Constitution I (fast-moving worktree contract
    leaking into the pure backlog loader). Explicitly out of scope per spec.
  - *A dedicated Coordinator "ad-hoc list" call* — rejected: redundant; the id
    set is already fully derivable from data the view holds.

## Decision 2 — Where the logic lives: pure `PipelineDagLayout`, thin view

- **Decision**: Add a pure function `PipelineDagLayout.ad_hoc_nodes(backlog_layout, live_ids)`
  (or equivalent) returning positioned orphan nodes for a dedicated lane. The set
  difference and lane pixel-positioning are pure; `PipelineDagLive` only maps the
  result to markup.
- **Rationale**: Constitution I (Pure Core, Isolated Contracts) and the >90%
  pure-core coverage discipline. `PipelineDagLayout` is already a
  Phoenix-free, directly unit-tested layout module; keeping the id math and
  positioning there means the interesting logic is tested without
  `LiveViewTest`, and the view stays a renderer.
- **Alternatives considered**:
  - *Compute set-diff inline in the LiveView* — rejected: pushes untested-by-pure
    logic into the view layer; harder to cover the id-proximity and
    multiple-ad-hoc edge cases hermetically.

## Decision 3 — Layout: dedicated lane, backlog plane untouched

- **Decision**: Ad-hoc nodes render in a separate section/lane beneath (or
  beside) the existing `dag-plane`, each as an isolated node with no SVG edges.
  The backlog plane's node/edge/canvas math is called exactly as today.
- **Rationale**: Clarification answer ("separate lane/section; backlog layout
  unchanged") + FR-002 + FR-006 + SC-004 (backlog-only view structurally
  identical to today). Ad-hoc features are orphans by construction (Assumptions:
  wave-of-one, no prereqs/dependents), so no edge math applies.
- **Alternatives considered**:
  - *Place ad-hoc nodes at depth 0 inside the existing plane* — rejected: risks
    shifting/rescaling the backlog layout when ad-hoc nodes are present,
    violating SC-004's "identical when no ad-hoc present / backlog layout
    unaffected either way".

## Decision 4 — Distinguishing marker + legend (FR-005)

- **Decision**: Each node carries a `data-node-origin` attribute
  (`backlog` | `ad-hoc`) plus a visible marker on ad-hoc nodes (a small "ad-hoc"
  badge / distinct border), and the legend gains one entry explaining the ad-hoc
  marker, kept separate from the lifecycle-status color swatches.
- **Rationale**: FR-005 requires *both* a per-node marker recognizable without
  the drawer *and* a dedicated legend entry distinct from status colors. A
  `data-*` attribute gives a stable, testable selector; the visible badge/border
  satisfies the at-a-glance requirement (US3, SC-003) independent of status
  color. The legend palette is currently a pure `palette/0` status map — the
  ad-hoc entry is added as a separate legend row, *not* injected into the status
  palette, so status semantics stay clean.
- **Alternatives considered**:
  - *Reuse a status color to signal ad-hoc* — rejected: conflates origin with
    lifecycle status; FR-005 explicitly requires the marker be distinct from
    status colors.

## Decision 5 — Interaction reuse: same drawer, same actions (US2)

- **Decision**: Ad-hoc nodes fire the existing `select_feature` event with the
  feature id; the existing `feature_drawer` reads `Map.get(@view.per_feature, id)`
  and renders identically. No drawer change.
- **Rationale**: FR-004 + US2 (same drawer, same resume/restart actions). The
  drawer is already id-driven off `per_feature`, so an ad-hoc id "just works"
  once its node exists and is clickable — no new component, matching the spec's
  reuse assumption.

## Decision 6 — No-ad-hoc regression safety (FR-006 / SC-004)

- **Decision**: The ad-hoc lane section renders under an `:if` guard on a
  non-empty ad-hoc set; when empty, no new DOM is emitted and the backlog render
  path is byte-for-byte the current one.
- **Rationale**: SC-004 requires the backlog-only view be structurally identical
  to today. Guarding the whole lane (and the extra legend entry) on a non-empty
  ad-hoc set guarantees zero delta when no ad-hoc feature is in the run.

## Decision 7 — Slug-optional rendering

- **Decision**: An ad-hoc node renders from its id; slug is shown when present in
  `per_feature[id].slug`, omitted/blank when nil.
- **Rationale**: Spec Assumption — slug may be unknown for an ad-hoc node
  depending on what the live read-model captured. `SingleSpec` does assign a
  kebab slug, but the view must not assume it; id is always present and is the
  stable node key.
