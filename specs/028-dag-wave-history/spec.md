# Feature Specification: Pipeline Chain Shows Each Wave's Own History

**Feature Branch**: `028-dag-wave-history`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "There's a problem with pipeline dag UI, for example I ran the wave 008 now, but any wave that I select shows the same phases executed."

## Context

The Pipeline Chain view (`/dag`) lets the operator pick a breakdown package
("wave") from the wave picker and draws that wave's features as a chain, each
node showing status, phase strip, and spend. Feature ids are only unique
*within* a wave — `001` in wave `007` and `001` in wave `008` are different
features — but the run state the view draws from is keyed by id alone.

An earlier fix (`118dd30`) gated live state to "the wave the current run is
scoped to". That gate only knows the scope of an **in-flight** run. Once a run
finishes (or when no run is in flight), the run's scope is unknown, the gate
switches itself off, and the last run's per-feature state — still held by the
console's read model — is drawn under **every** wave. Observed: after running
wave `008`, selecting any other wave shows `008`'s executed phases on that
wave's same-numbered features.

This violates constitution Principle VII ("Operator Surfaces Tell the Truth"):
the view asserts that features ran phases they never ran.

## Clarifications

### Session 2026-09-24

- Q: Which run states may supply a wave's drawn history? → A: Any state (`:in_flight`, `:parked`, `:completed`, `:superseded`) — the wave's most recent run regardless of state, shown with its run id and state.
- Q: How is a past (not in-flight) run's feature left `:running` drawn? → A: As interrupted — its recorded phases stay visible, the phase open when the run ended is marked not finished, and nothing animates.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Another wave never shows the last run's phases (Priority: P1)

The operator has just run wave `008` to completion. They open the Pipeline
Chain, switch the wave picker to `007` (or any other wave), and see that
wave's features without any of `008`'s status, phases, or spend bleeding in.

**Why this priority**: This is the reported defect. A surface that shows phases
executed on features that never ran misinforms the operator about what the
system has done — the core failure Principle VII forbids.

**Independent Test**: Run (or seed a recorded run for) one wave, let it finish,
then select a different wave whose feature ids overlap numerically; verify no
node in the selected wave shows the finished run's status, phases, or spend,
and the feature drawer for those nodes shows none of it either.

**Acceptance Scenarios**:

1. **Given** a run scoped to wave `008` has finished and no run is in flight, **When** the operator selects wave `007`, **Then** no `007` node shows any phase, status, or spend recorded by the `008` run.
2. **Given** a run scoped to wave `008` is in flight, **When** the operator selects wave `007`, **Then** no `007` node shows `008`'s live state (existing behaviour preserved).
3. **Given** a finished `008` run, **When** the operator selects wave `008`, **Then** wave `008`'s nodes show that run's recorded status, phases, and spend.
4. **Given** a finished `008` run, **When** the operator clicks a `007` node whose id also exists in `008`, **Then** the feature drawer shows nothing from the `008` run.
5. **Given** the operator has wave `007` selected while a `008` run is in flight, **When** a live update for feature `001` arrives, **Then** `007`'s node `001` does not change.

---

### User Story 2 - Each wave shows its own most recent recorded run (Priority: P2)

The operator has run several waves over time (`006`, `007`, `008`). Switching
the wave picker to any of them shows that wave's own last known outcome — which
features finished, which escalated or halted, which phases each ran, and what
they cost — drawn from that wave's most recent recorded run.

**Why this priority**: Fixing the leak (US1) by blanking every non-current wave
is truthful but loses information the system already recorded. Showing each
wave's own history turns the wave picker into a real way to review past waves.
It depends on US1's scoping being correct, so it comes second.

**Independent Test**: With recorded runs for two different waves, select each
wave in turn and verify each shows exactly the status/phases/spend recorded by
its own most recent run.

**Acceptance Scenarios**:

1. **Given** recorded finished runs for waves `007` and `008`, **When** the operator selects `007`, **Then** its nodes show the status, phases, and spend from the most recent run scoped to `007`.
2. **Given** a wave with several recorded runs, **When** the operator selects it, **Then** only the most recent run scoped to that wave is drawn — earlier runs' outcomes are not merged in.
3. **Given** a wave that has never been run, **When** the operator selects it, **Then** every node is drawn as not yet run (`:pending`, empty phase strip, zero spend).
4. **Given** a wave's most recent run was `:superseded` while feature `003` was mid-`implement`, **When** the operator selects that wave, **Then** `003` shows its completed phases, `implement` marked not finished, and no live motion.
5. **Given** a wave is drawn from a past (not in-flight) run, **When** the view renders, **Then** it identifies which run the drawn state comes from (its run id and run state — `:parked`, `:completed`, or `:superseded`) so the state is traceable to a record.

---

### User Story 3 - Default wave follows the most recent activity (Priority: P3)

When the operator opens the Pipeline Chain with no run in flight, the wave
picker defaults to the wave of the most recent recorded run, rather than
simply the first wave alphabetically.

**Why this priority**: Convenience. After running `008` and reloading the
page, the operator expects to land on `008`, not `001-mvp`. Not needed for
correctness.

**Independent Test**: With a finished `008` run and no run in flight, open the
view fresh and verify the picker selects `008`.

**Acceptance Scenarios**:

1. **Given** a run is in flight scoped to a wave, **When** the view opens, **Then** that wave is selected (existing behaviour preserved).
2. **Given** no run in flight and the most recent recorded run was scoped to `008`, **When** the view opens, **Then** `008` is selected.
3. **Given** no recorded runs at all, **When** the view opens, **Then** the first wave alphabetically is selected (existing behaviour preserved).

---

### Edge Cases

- **Most recent run was ad-hoc**: ad-hoc runs have no wave; they never supply state to any wave's backlog chain, and the default wave falls back to the most recent *wave-scoped* run, else the first wave.
- **Recorded run whose scope is unknown/unreadable**: that run contributes to no wave (drawn cold) rather than to every wave — the "unknown means show everywhere" behaviour is removed.
- **Legacy layout with no waves** (flat breakdown directory, no picker): continues to show the current/last run's state as today — there is only one chain, so no collision is possible.
- **Wave selected is the in-flight run's wave**: live updates apply as today; the drawn state must never lag behind or be replaced by a stale recorded run for the same wave.
- **Run finishes while the operator watches its wave**: the chain keeps showing the just-finished state (no flash to empty).
- **Run starts for a different wave while the operator views another**: the viewed wave's drawn state is unchanged.
- **Past run left a feature mid-flight** (`:superseded` or crashed run with a feature recorded `:running`): the feature is drawn as interrupted — recorded phases visible, the open phase marked not finished, no live motion.
- **Ad-hoc lane**: ad-hoc features are identified as "not in any wave" exactly as today and keep drawing from the current/last run; this feature does not change the ad-hoc lane.
- **Store unreadable/damaged record for a wave's run**: the wave renders cold (as never run) with a visible indication that its history couldn't be read, never a broken layout and never another wave's state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Pipeline Chain MUST draw a wave's backlog nodes (status, phase strip, chunk progress, remediation annotation, spend) only from run state whose recorded scope is that same wave.
- **FR-002**: Run state whose scope is unknown MUST NOT be drawn under any wave; the absence of an in-flight run MUST NOT disable wave scoping.
- **FR-003**: The feature drawer opened from a wave's node MUST show only state belonging to that wave (consistent with FR-001).
- **FR-004**: Live updates for the in-flight run MUST change only nodes of the in-flight run's wave, and only while that wave is selected.
- **FR-005**: When the selected wave is not the in-flight run's wave, its nodes MUST be drawn from the most recent recorded run scoped to that wave, whatever that run's state (`:parked`, `:completed`, or `:superseded`); if none exists, as never run.
- **FR-006**: State from different runs of the same wave MUST NOT be merged; exactly one run (the in-flight one if it is scoped to that wave, else the most recent recorded one) supplies a wave's drawn state.
- **FR-007**: When a wave is drawn from a past run, the view MUST show that run's identifier and its run state (`:parked`, `:completed`, `:superseded`) so the drawn state is traceable to its record.
- **FR-007a**: A feature drawn from a past (not in-flight) run whose recorded status is `:running` MUST be drawn as interrupted: its recorded phases shown, the phase open when the run ended marked not finished, and no live-work motion or `:running` status shown.
- **FR-008**: With no run in flight, the default selected wave MUST be the wave of the most recent wave-scoped recorded run, falling back to the first wave alphabetically.
- **FR-009**: The legacy no-waves layout and the ad-hoc lane MUST behave as they do today.
- **FR-010**: A wave whose recorded run cannot be read MUST render as never run with a visible, non-alarming note that its history is unavailable, and MUST NOT fall back to another wave's state.
- **FR-011**: Automated tests MUST cover the reported scenario: a finished run for one wave, then selecting another wave with overlapping feature ids, asserting no leaked status/phases/spend on nodes or in the drawer.

### Key Entities

- **Wave (breakdown package)**: a directory of numbered feature files; the unit the wave picker selects. Feature ids are unique only within a wave.
- **Run**: one execution of a wave (or of an ad-hoc feature), recorded with its scope (which wave, or ad-hoc), its run state (`:in_flight | :parked | :completed | :superseded`), per-feature status, phase attempts, and spend.
- **Wave history**: for a given wave, the single run whose state the chain draws — the in-flight run if scoped to it, else its most recent recorded run in any state, else none.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After finishing a run for one wave, selecting any other wave shows 0 nodes carrying that run's status, phases, or spend (verified across every wave with overlapping feature ids).
- **SC-002**: For every wave with at least one recorded run, the chain shows the same per-feature status and spend as that wave's most recent run record — 100% agreement.
- **SC-003**: Switching waves in the picker reflects the selected wave's own state within 1 second on a repository with up to 20 waves.
- **SC-004**: Reloading the view after a finished run lands on that run's wave without any operator action.
- **SC-005**: Existing Pipeline Chain behaviours (in-flight live updates, ad-hoc lane, legacy layout, empty/invalid backlog states) pass their existing tests unchanged.

## Assumptions

- "Most recent" run for a wave means most recently started run whose recorded scope is that wave, in any run state (no state is skipped); the run store already records each run's scope and is scoped to the current repository.
- Reading a past run's state for display is read-only and never alters the run record or the console's live read model.
- The view shows one run per wave; browsing older runs of a wave remains the job of the Runs/Run Detail views and is out of scope here.
- No change to how runs record scope, to feature id numbering, or to other console views (Mission Control, Runs) — only the Pipeline Chain's choice of which state to draw.
