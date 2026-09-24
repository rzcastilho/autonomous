# Contract: Pipeline Chain (`/dag`) wave-scoped rendering

This contract covers the markup hooks and behaviour that `PipelineDagLive`
must expose. Existing hooks (`data-dag-node`, `data-node-origin`,
`data-status`, `data-chain-position`, `data-chain-base`, `data-package-select`,
`data-chain="backlog"|"ad-hoc"`) are unchanged.

## Backlog node state (FR-001–FR-006)

A backlog node's `data-status`, its `.phase-strip` cells, its chunk and
remediation annotations, and its `.dag-node-spend` come **only** from the
selected wave's source (see `wave-history.md`):

| Source | Node rendering |
|---|---|
| `{:live, run}` | The live read model (`view`), updated by `feature_updated` events |
| `{:recorded, run}` | That run's hydrated record, with any interrupted rows applied. Live events never change it. |
| `:none` | Cold: `data-status="pending"`, all cells `phase-cell-pending`, `$0.00` |
| `{:unavailable, _}` | Cold, exactly as for `:none` |

The feature drawer opened from a backlog node reads the same source (FR-003).
A cold node's drawer shows no run state.

## Source receipt strip (FR-007, FR-010)

This element is rendered inside `.dag-canvas`, under `.dag-canvas-header`,
whenever `selected_package != nil`:

```html
<div class="dag-wave-source" data-wave-source="recorded|live|none|unavailable">
```

| `data-wave-source` | Required content |
|---|---|
| `recorded` | `<a href="/runs/<run_id>" data-wave-source-run>` holding the `run_id` in mono, plus `<span data-wave-source-state>` holding the run state as an atom (`:completed`, `:parked`, `:superseded`) in mono |
| `live` | The same two hooks, with the state `:in_flight` |
| `none` | Sans prose: `No recorded run for <slug>` (with `<slug>` in mono). No link, no call to action. |
| `unavailable` | Sans prose: `History for <slug> could not be read`, plus the `run_id` in mono when it is known. Neutral text tokens only, **never** a status color and never a `form_refusal` (FR-010, "non-alarming"). |

The strip is absent in the legacy no-packages layout.

## Interrupted feature (FR-007a)

For a backlog node drawn from a recorded run whose feature was left `:running`:

- the node has `data-status="blocked"`, and its status chip reads `Interrupted`;
- the open phase cell has class `phase-cell phase-cell-interrupted` and a
  `title` of `<phase> — interrupted`;
- completed earlier cells keep `phase-cell-completed`;
- **no** `phase-cell-active` appears anywhere on the node, and no element on
  it matches a `scPulse` selector.

`.phase-cell-interrupted` is defined in `priv/static/assets/console.css` as
`background: var(--blocked);` with no `animation`. It passes the
design-contract guard: it uses only tokens and adds no keyframe.

## Wave picker default (FR-008)

On mount, `selected_package = WaveHistory.default_package(packages, run_history())`.
The existing `<option selected>` hook reflects it.

## Refresh triggers (FR-004, SC-003)

The source is re-resolved on:
- mount;
- `select_package`;
- `{:console, :run_finished, _}`;
- a `{:console, :reconciled, _}` tick where `current_run_id/0` differs from
  the cached `live_run_id`.

No other event reads history.

## Unchanged (FR-009, SC-005)

- The ad-hoc lane (`data-chain="ad-hoc"`) and its drawer still read the live
  read model.
- The legacy layout (no packages) draws the live read model ungated.
- The empty backlog, the invalid backlog, and a missing breakdown dir render
  exactly as they do today.
