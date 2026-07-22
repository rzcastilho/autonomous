# Phase 0 Research: Control Plane UI Redesign

All unknowns below were resolved against the concrete state of the repo (no asset
build step; console currently ships **no** stylesheet) and the reference prototype
`docs/control-plane-design-reference/ControlPlane.dc.html` (+ `support.js`).

## 1. CSS delivery without a build step

- **Decision**: Ship one hand-authored static stylesheet at
  `priv/static/assets/console.css`, served through the existing `Plug.Static`
  (extend its `only:` list from `~w(app.js)` to include `console.css`), and link it
  from `root.html.heex`. Keep genuinely dynamic values (per-status colors, gauge
  fill width) as inline `style=` bound from Elixir, exactly as the reference and the
  current `core_components.ex` already do.
- **Rationale**: The endpoint comment is explicit — "Console has no asset build step
  (no esbuild/npm)". Adding tailwind/esbuild for six routes of chrome would violate
  the project's deliberate no-JS-toolchain choice and add a build dependency the plan
  forbids. A single static CSS file needs zero tooling, caches cleanly, and matches
  how `app.js` is already served.
- **Alternatives considered**:
  - *Tailwind/esbuild pipeline* — rejected: introduces a build toolchain the console
    explicitly avoids; overkill for a fixed design system.
  - *All-inline styles (as the reference does)* — rejected: the reference inlines
    everything because it is a single-file prototype; in HEEx that would bloat every
    template, defeat reuse, and make the palette impossible to keep consistent. Inline
    stays only for data-driven values.
  - *`<style>` block in root layout* — rejected: works but is not cacheable and mixes
    a large stylesheet into the HTML document on every request.

## 2. Self-hosting IBM Plex typography (FR-021, clarified)

- **Decision**: Bundle IBM Plex Sans (weights 400/500/600/700) and IBM Plex Mono
  (400/500/600) as `.woff2` files under `priv/static/fonts/`, declare them via
  `@font-face` in `console.css`, serve them through a new `Plug.Static` mount
  (`at: "/fonts"`), and add `<link rel="preload" as="font" crossorigin>` hints for the
  two primary weights in `root.html.heex`. No `fonts.googleapis.com` / `fonts.gstatic.com`
  request at runtime.
- **Rationale**: Clarification session mandated self-hosting (no external network call
  at runtime). IBM Plex is OFL-1.1 licensed and freely redistributable, so the woff2
  files can be committed. `woff2` is the single modern format needed for the target
  desktop browsers. Preloading the two hero weights avoids a flash of unstyled text on
  the shell.
- **Alternatives considered**:
  - *Google Fonts CDN `<link>` (as the reference uses)* — rejected: violates FR-021.
  - *`@ibm/plex` npm package at build time* — rejected: no npm/build step exists;
    committing the specific woff2 subset directly is simpler and reproducible.
  - *System font stack only* — rejected: FR-019 requires an exact match to the
    reference's IBM Plex typography.

## 3. Status-color palette migration

- **Decision**: Replace `CoreComponents.@palette` colors with the reference's `COLORS`
  values (`support.js`): pending `#64748b`, blocked `#475569`, running `#38bdf8`,
  escalated `#fbbf24`, halted `#fb7185`, failed `#f43f5e`, done `#34d399`. Labels and
  the atom keys stay identical; only hex values change. The single `@palette` remains
  the one source consumed by `status_pill`, `phase_strip`, the DAG legend/nodes, the
  drawer timeline, and the status-count cards (FR-010, SC-001).
- **Rationale**: The current palette (`#22c55e`, `#3b82f6`, `#f59e0b`, `#ef4444`,
  `#991b1b`, `#9ca3af`, `#6b7280`) predates the reference and does not match it. FR-019
  makes the reference palette definitive; the Assumptions preserve the *semantics*
  (same seven statuses) while changing only the *visual treatment*. Editing the one
  `@palette` map propagates the change everywhere by construction.
- **Alternatives considered**:
  - *Keep current colors, only restyle layout* — rejected: FR-019 requires exact color
    match, and SC-001 requires the reference's at-a-glance color coding.
  - *Duplicate a second palette for the DAG* — rejected: FR-010 mandates one shared
    status→color mapping across all views.

## 4. Cost-gauge threshold colors

- **Decision**: Keep `cost_gauge`'s threshold logic (green < 70% ≤ amber < 90% ≤ red,
  red when tripped) but source the three colors from the reference's semantic palette
  (done/escalated/halted-family) so the gauge reads consistently with the rest of the
  console.
- **Rationale**: The gauge's proximity semantics (FR-003, SC-007) are behavior and must
  not change (FR-020); only the specific greens/ambers/reds shift to the reference's.
- **Alternatives considered**: *Change thresholds* — rejected, that is a behavior change.

## 5. Pipeline DAG rendering

- **Decision**: Render the DAG as inline SVG — nodes positioned by the existing
  `PipelineDagLayout` wave/column math, prerequisite edges as bezier paths
  (`M x1,y1 C mx,y1 mx,y2 x2,y2`, matching the reference), node fill/stroke from the
  shared status palette, plus a status legend. Reuse the existing layout module's
  coordinates; extend it only if the SVG needs explicit pixel coords not already
  produced.
- **Rationale**: The reference draws exactly this (bezier edges, colored nodes, legend).
  `pipeline_dag_layout.ex` already computes wave placement, so the change is a render
  swap from unstyled list to SVG, not a new layout algorithm — keeping data flow
  unchanged (FR-020).
- **Alternatives considered**:
  - *A JS graph library (d3/cytoscape)* — rejected: no JS build step; adds a runtime
    dependency for a static, server-rendered graph.
  - *CSS-grid nodes without SVG edges* — rejected: FR-008 requires an edge drawn to
    each prerequisite, which needs SVG/line drawing.

## 6. Preserving behavior + test hooks while restyling (FR-020)

- **Decision**: Treat the class names and `data-*` attributes the existing web tests
  assert on as a **stable seam** and keep them: `cost-gauge`, `badge-warn`,
  `status-pill` + `data-status`, `data-phase`, `nav-active`, and the run-state text
  ("No active run" / "Active run" / "armed"/"tripped"). Where the reference's structure
  forces markup changes that a test asserts on positionally, update that assertion in
  lockstep to the new structure while keeping it semantic (assert on the data hook, not
  on incidental layout markup).
- **Rationale**: FR-020 forbids behavior change; the LiveView data flow, events, and
  PubSub subscriptions stay byte-identical. The restyle is markup + CSS. Anchoring tests
  to semantic hooks (data attributes, stable class names) rather than to visual detail
  keeps the suite meaningful after the redesign.
- **Alternatives considered**:
  - *Rewrite markup freely and rewrite all tests* — rejected: loses the regression
    guarantee that behavior is unchanged; higher risk of silently altering data flow.

## 7. Responsive collapse without build tooling

- **Decision**: Author plain CSS `@media (max-width: 1120px)` rules in `console.css`
  (the same breakpoint the reference uses) to collapse the two-column layouts (Mission
  Control's backlog + telemetry feed) to a single column and make feeds/lists scroll
  within their container. Long slugs/ids truncate with `text-overflow: ellipsis`.
- **Rationale**: Media queries are native CSS — no tooling needed. This directly
  satisfies the Edge Cases (narrow-desktop collapse, scrollable lists, truncation).
- **Alternatives considered**: *JS-driven responsive layout* — rejected: unnecessary,
  no build step, native CSS suffices.

## Resolved unknowns summary

| Unknown | Resolution |
|---|---|
| How to ship CSS with no build step | One static `console.css` via `Plug.Static` |
| Font self-hosting (FR-021) | Commit IBM Plex woff2 under `priv/static/fonts`, `@font-face` + `/fonts` static mount |
| Status colors | Adopt reference `COLORS` in the single `@palette`; keep semantics |
| Gauge colors | Reference palette, unchanged thresholds |
| DAG rendering | Inline SVG (bezier edges) reusing existing layout math |
| No behavior change (FR-020) | Preserve class/`data-*` test seams; keep data flow identical |
| Narrow-desktop layout | Native CSS media queries at 1120px |
