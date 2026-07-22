# Quickstart: Pipeline DAG Ad-Hoc Feature Visibility

Validation guide proving ad-hoc single-spec features render on `/dag`. See
[data-model.md](./data-model.md) for shapes and
[contracts/dag-ad-hoc-render.md](./contracts/dag-ad-hoc-render.md) for the
selector/function contracts asserted below.

## Prerequisites

- Toolchain via mise (`.tool-versions` → `1.20.2-otp-28`). Run every Elixir
  command through `mise exec --`.
- `mise exec -- mix deps.get && mise exec -- mix compile` (warnings are errors).

## Automated validation

### Pure layout tests (fast, hermetic — the interesting logic)

```bash
mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_layout_test.exs
```

Covers the pure `ad_hoc_nodes/2` contract (C1–C7): empty when live ⊆ backlog;
one node per absent id; multiple ad-hoc → multiple orphans; overlap resolves to
backlog (VR-1); id-proximity still classified by set membership (VR-3, C5);
`nil` slug tolerated (VR-4, C6); no process/Phoenix dependency (C7).

### LiveView render tests

```bash
mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs
```

Assert, mounting `/dag` against a Coordinator status whose `per_feature`
contains an id **not** in the backlog fixture:

1. **US1 / FR-001,003** — a `data-dag-node={id}` element exists for the ad-hoc id,
   inside `data-state="ad-hoc-lane"`, showing its live `status_pill` and spend
   matching `per_feature[id]`.
2. **US3 / FR-005** — that node has `data-node-origin="ad-hoc"` and a visible
   badge; a `data-legend-origin="ad-hoc"` legend entry is present and distinct
   from the `data-legend-status` swatches.
3. **US2 / FR-004** — `render_click` on the ad-hoc node opens the
   `feature_drawer` with that feature's detail.
4. **FR-006 / SC-004 (regression)** — mounting with a `per_feature` that is a
   subset of the backlog (no ad-hoc): **no** `data-state="ad-hoc-lane"`, **no**
   `data-legend-origin="ad-hoc"`, and existing backlog node/edge/legend
   assertions unchanged.

### Full suite (no regressions elsewhere)

```bash
mise exec -- mix test
```

## Manual validation (end-to-end, optional)

1. Start the console: `mise exec -- iex -S mix` (boots the app + web endpoint).
2. Trigger a single-spec run for a description **not** in `docs/breakdown/` via
   the Trigger console's single-spec mode (`run_spec/2`).
3. Open Mission Control — confirm the ad-hoc feature appears (baseline: it
   already does).
4. Open `/dag` **while it runs**: confirm a node for that feature appears in the
   ad-hoc lane with live status + accruing spend matching Mission Control
   (Acceptance Scenario US1-1).
5. Let it finish; confirm the node reflects terminal status + final spend
   (US1-2).
6. Click the ad-hoc node: the same feature drawer opens with phase timeline,
   elapsed, spend, and (if escalated/halted) resume/restart actions (US2).
7. Confirm the ad-hoc marker + legend entry distinguish it from backlog nodes at
   a glance without opening the drawer (US3).

## Expected outcomes (maps to Success Criteria)

- **SC-001/SC-002**: every id in the live `per_feature` map is a node on `/dag`.
- **SC-003**: ad-hoc vs backlog nodes distinguishable without opening a drawer.
- **SC-004**: with no ad-hoc feature present, `/dag` renders structurally
  identical to pre-feature behavior (regression test #4 above is green).
