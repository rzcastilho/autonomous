# Implementation Plan: Pipeline DAG Ad-Hoc Feature Visibility

**Branch**: `010-pipeline-dag-ad-hoc-features` | **Date**: 2026-07-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-pipeline-dag-ad-hoc-features/spec.md`

## Summary

The Pipeline DAG view (`/dag`) builds its node list solely from
`Backlog.load!()` (the persistent `docs/breakdown/*.md` dir), so a feature
started via the Trigger console's single-spec mode (`run_spec/2`) — whose seed
lives only in its own git worktree, never in the backlog dir — is never drawn,
even while live. Mission Control already shows it because it reads the merged
`view.per_feature` map (keyed by *every* Coordinator-tracked feature id),
not the backlog.

**Technical approach**: presentation-only. `view.per_feature` already carries
every live feature (id, slug, status, spend, phases, elapsed). Ad-hoc ids are
exactly the `per_feature` keys absent from the backlog-derived node set. Add a
pure helper to `PipelineDagLayout` that computes that set difference and
positions the orphans in a dedicated lane (no edges, depth 0); render that lane
as a second section in `PipelineDagLive` reusing the existing node markup
(`status_pill` / `phase_strip` / spend / `select_feature` → `feature_drawer`),
tagged with an origin marker plus a distinct legend entry. No change to
`run_spec/2`, `SingleSpec`, `Backlog.load!`, or the backlog dir.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned `.tool-versions`; run via `mise exec --`)

**Primary Dependencies**: Phoenix LiveView (control-plane console); no new dependency

**Storage**: N/A — console is in-memory, no persistence (unchanged constraint from 008/009)

**Testing**: ExUnit + `Phoenix.LiveViewTest`; pure-layout unit tests; `mise exec -- mix test`

**Target Platform**: BEAM / web console

**Project Type**: Web (single project — the control-plane console lives inside the orchestrator lib)

**Performance Goals**: N/A — one-shot view render over a handful of features per run

**Constraints**: Presentation-only (FR-007: no backlog writes); zero regression to
backlog-only render (FR-006 / SC-004); ad-hoc nodes must be visually distinct
regardless of id proximity to backlog ids

**Scale/Scope**: Tens of features per run at most; a single LiveView + one pure layout helper

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Pure Core, Isolated Contracts** — PASS. The ad-hoc set-difference and
  lane positioning go into `PipelineDagLayout` (already a pure, LiveView-free,
  directly unit-tested module). The LiveView stays a thin renderer. No pure
  module gains a CLI/harness/Jido dependency.
- **II. Fail Loud at Boundaries** — N/A (no new boundary). The existing
  invalid-DAG / empty-backlog rescue paths are untouched; ad-hoc nodes are
  additive and never interact with backlog validation.
- **III. Least-Privilege Containment** — N/A. No CLI invocation, no filesystem
  write, no permission surface touched.
- **IV. Cost-Bounded Autonomy** — N/A. Read-only view; no reservation, no spend.
- **V. Human-in-the-Loop Escalation** — N/A to the render, and *supported* by it:
  an escalated/halted ad-hoc feature's drawer exposes the same resume/restart
  actions as any node (US2), no new escalation logic.
- **Quality & Test Discipline** — PASS. New logic sits in the pure layer to keep
  it above 90% coverage via the existing pure-test seam; `mise exec` +
  `warnings_as_errors` respected; LiveView render asserted with `LiveViewTest`.

**Result**: No violations. Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/010-pipeline-dag-ad-hoc-features/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions
├── data-model.md        # Phase 1 — DAG Node + ad-hoc lane entities
├── quickstart.md        # Phase 1 — validation guide
├── contracts/
│   └── dag-ad-hoc-render.md   # Pure helper signature + DOM/test-selector contract
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/web/
├── live/
│   ├── pipeline_dag_live.ex       # MODIFY — render a second "ad-hoc lane" section + legend entry
│   └── pipeline_dag_layout.ex     # MODIFY — add pure ad_hoc_nodes/2 (set-diff + lane positioning)
└── components/
    ├── feature_drawer.ex          # UNCHANGED — reused as-is (reads view.per_feature[id])
    └── core_components.ex         # UNCHANGED — status_pill / phase_strip / palette reused

test/speckit_orchestrator/web/
├── pipeline_dag_layout_test.exs   # MODIFY/ADD — pure tests for ad_hoc_nodes/2
└── pipeline_dag_live_test.exs     # MODIFY — ad-hoc node render, marker, legend, drawer, no-regression
```

**Structure Decision**: Single project. The console is a set of LiveViews +
components under `lib/speckit_orchestrator/web/`. The change is confined to the
two DAG modules (`pipeline_dag_live.ex` view + `pipeline_dag_layout.ex` pure
helper); all reused presentation components stay untouched, satisfying the
spec's "reuse existing drawer/pill/spend components" assumption.

## Complexity Tracking

> No Constitution violations — section intentionally empty.
