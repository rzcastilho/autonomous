# Feature Specification: Pipeline DAG Ad-Hoc Feature Visibility

**Feature Branch**: `010-pipeline-dag-ad-hoc-features`

**Created**: 2026-07-22

**Status**: Draft

**Input**: User description: "Pipeline DAG view must also render single-spec/ad-hoc features (run via run_spec/2) that never appear in the static docs/breakdown backlog. Currently PipelineDagLive builds its node list solely from Backlog.load!() (the persistent docs/breakdown/*.md dir), so a feature started via the Trigger console's single-spec mode — whose auto-generated seed lives only inside that feature's own git worktree, never in docs/breakdown — never shows up as a node, even while it is live, running, or has just finished with real spend. Mission Control shows it correctly (it reads Coordinator's live per_feature map directly, no backlog dependency); the DAG view should show it too, as an orphan node (no prereqs/dependents, depth 0) alongside the backlog-derived nodes, using the same status pill / spend / drawer-on-click as existing nodes. Scope: only the render/layout gap for ad-hoc single-spec features on the Pipeline DAG view — no change to run_spec/2, SingleSpec, or Backlog.load! itself."

## Clarifications

### Session 2026-07-22

- Q: Where do orphan ad-hoc nodes sit relative to backlog nodes on the DAG? → A: Separate lane/section for ad-hoc nodes; backlog layout unchanged.
- Q: How is an ad-hoc node distinguished from a backlog node? → A: Both — a per-node marker visible without the drawer AND a distinct legend entry.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See an ad-hoc run on the DAG (Priority: P1)

An operator starts a one-off, free-text feature through the console's
single-spec trigger (not part of the tracked backlog). While it runs, and
after it finishes, the operator checks the Pipeline DAG to see it alongside
everything else — and today finds nothing: the feature they just started is
invisible there, even though Mission Control confirms it is live and
accruing spend.

**Why this priority**: This is the reported gap. Without it, the Pipeline
DAG is an incomplete picture of "what's running right now" whenever an
ad-hoc feature is in flight, undermining its purpose as an at-a-glance view.

**Independent Test**: Trigger a single-spec run for a description not present
in the backlog directory; open Pipeline DAG while it is running and again
after it finishes; confirm a node for that feature is visible in both cases,
with status and spend matching Mission Control.

**Acceptance Scenarios**:

1. **Given** an ad-hoc single-spec feature is currently running, **When** the
   operator opens Pipeline DAG, **Then** a node for that feature appears with
   its live status and accruing spend, matching Mission Control.
2. **Given** an ad-hoc single-spec feature has just finished, **When** the
   operator opens (or has open) Pipeline DAG, **Then** the node reflects the
   terminal status and final spend, matching Mission Control's reported
   totals.
3. **Given** no ad-hoc feature is part of the current run, **When** the
   operator opens Pipeline DAG, **Then** the view renders exactly the
   backlog-derived nodes as it does today — no regression.

---

### User Story 2 - Inspect an ad-hoc feature from the DAG (Priority: P2)

Having spotted the ad-hoc feature's node, the operator wants the same detail
they'd get from any other node: phase timeline, elapsed time, spend
breakdown, and — if it stalled — the same recovery actions.

**Why this priority**: Consistency of interaction. An operator souldn't need
to remember "click here for backlog features, look elsewhere for ad-hoc
ones."

**Independent Test**: With an ad-hoc feature's node visible on the DAG, click
it and confirm the same feature drawer used for backlog nodes opens with
that feature's real detail.

**Acceptance Scenarios**:

1. **Given** an ad-hoc feature's node on the DAG, **When** the operator
   clicks it, **Then** the same feature drawer component opens, showing that
   feature's phase timeline, elapsed time, and spend.
2. **Given** an ad-hoc feature has escalated or halted, **When** the operator
   opens its drawer from the DAG, **Then** the same resume/restart actions
   available from Escalations are reachable, consistent with any other
   feature.

---

### User Story 3 - Tell ad-hoc and backlog nodes apart at a glance (Priority: P3)

Since ad-hoc features have no dependency relationships, an operator scanning
the DAG should be able to recognize which nodes are "real" backlog features
(with edges to prereqs/dependents) versus one-off ad-hoc runs, without
having to open each one.

**Why this priority**: Avoids confusing an ad-hoc feature for a missing or
misconfigured backlog entry (e.g., "why does this node have no edges?").

**Independent Test**: With both backlog and ad-hoc features on the DAG at
once, confirm a visual distinction (e.g., legend entry, node styling) lets an
operator identify each without clicking in.

**Acceptance Scenarios**:

1. **Given** the DAG shows both backlog-derived and ad-hoc nodes, **When**
   the operator looks at the legend, **Then** it explains the ad-hoc marker
   distinctly from lifecycle-status colors.
2. **Given** an ad-hoc node, **When** the operator views it, **Then** it is
   visually identifiable as ad-hoc without needing to open the drawer.

---

### Edge Cases

- Multiple ad-hoc features are part of the same live run: each renders as
  its own orphan node.
- An ad-hoc feature's auto-assigned id happens to look adjacent to an
  existing backlog id (e.g., backlog ends at 008, ad-hoc is 009): the two
  must remain visually distinguishable regardless of id proximity.
- The console process restarts mid-run (no persistence, per the existing
  console constraint): an ad-hoc feature from a prior process is not
  expected to reappear — this feature does not change that constraint, it
  only ensures whatever the *live* per-feature state currently knows about
  is reflected on the DAG, same as it already is for backlog features.
- No ad-hoc feature has ever run in the current session: the DAG shows only
  backlog-derived nodes, unchanged from today.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Pipeline DAG MUST render a node for every feature present in
  the live run's per-feature state, whether or not that feature exists in
  the persistent backlog.
- **FR-002**: An ad-hoc (non-backlog) feature's node MUST render with no
  prerequisite or dependent edges, placed in a dedicated ad-hoc lane/section
  separate from the backlog node layout so the backlog layout is unaffected
  whether or not ad-hoc nodes are present.
- **FR-003**: An ad-hoc feature's node MUST show the same status indicator
  and spend value as backlog-derived nodes, sourced from the same live data
  the rest of the console already uses.
- **FR-004**: Clicking an ad-hoc feature's node MUST open the same feature
  drawer used for backlog-derived nodes, with equivalent detail and actions.
- **FR-005**: The DAG MUST distinguish an ad-hoc node from a backlog-derived
  node by BOTH a per-node visual marker recognizable without opening the
  drawer AND a dedicated legend entry explaining that marker (distinct from
  the lifecycle-status colors).
- **FR-006**: When no ad-hoc feature is part of the live run, Pipeline DAG's
  rendering MUST be unchanged from its current backlog-only behavior.
- **FR-007**: This feature MUST NOT alter, write to, or persist anything in
  the backlog directory — it is a presentation-only change.

### Key Entities

- **DAG Node**: A feature shown on the Pipeline DAG — id, slug (when known),
  status, spend, and now an origin marker (backlog-derived vs. ad-hoc) that
  determines whether prereq/dependent edges apply.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can locate any currently running or just-finished
  ad-hoc feature on the Pipeline DAG within 5 seconds of opening the view,
  without needing to check Mission Control.
- **SC-002**: 100% of features present in the live run's per-feature state
  appear as Pipeline DAG nodes (today only backlog-derived features do).
- **SC-003**: In an informal usability check, operators correctly identify
  ad-hoc nodes versus backlog nodes without opening any drawer.
- **SC-004**: Existing backlog-only DAG views (no ad-hoc features present)
  render pixel-for-pixel/structurally identical to today's behavior.

## Assumptions

- Ad-hoc (single-spec) features always run as a wave of one with no
  prerequisites or dependents by construction, so "no edges, single node"
  is the correct and only placement needed — no partial-dependency case
  exists for them.
- The console's existing no-persistence behavior (a process restart forgets
  prior live state) is an accepted, unchanged constraint; this feature only
  ensures currently-known live state is displayed, not that history is
  recovered.
- The existing feature drawer, status pill, and spend read-model components
  are reused unchanged — no new detail views are introduced.
- "Slug" may be unknown/absent for an ad-hoc node depending on what the live
  read-model has captured at the time; the node still renders using its id.
