# Feature Specification: Control Plane

**Feature Branch**: `008-control-plane`

**Created**: 2026-07-21

**Status**: Draft

**Input**: User description: "Use the claude_design MCP to import project d1fbee5a-f636-4fd1-a8f3-a6ffa55fc45c and implement `Control Plane.dc.html`."

## Overview

The Control Plane is an operator-facing web console for `speckit_orchestrator`.
Today an operator drives runs and recovers stuck features from an `iex` session
(`run/1`, `run_spec/2`, `status/0`, `resume/2`, `resolve/1`) and reads progress
from scattered log files and transcripts. The Control Plane replaces that
console workflow with a single live screen: watch every feature move through the
seven-phase pipeline in real time, keep an eye on the cost breaker, start new
runs, and clear escalations and halts — the human-in-the-loop moments the
pipeline is designed to stop on — without leaving the browser.

The design source (`Control Plane.dc.html`) defines six views behind a fixed
left navigation, a persistent status bar, a slide-in feature drawer, and toast
confirmations. This spec captures WHAT each surface must do and WHY; it does not
prescribe the frontend stack.

## Clarifications

### Session 2026-07-21

- Q: Access/auth model for the console — who can reach it and how is it protected? → A: Local single operator, no auth (bind to localhost / trusted network, one trusted operator, no login; multi-user auth and tenancy out of scope for v1).
- Q: Run scope — does the console track one live run or persist/manage many? → A: One live in-memory run — the console is a live view of the single run currently active in the running BEAM node; no run history, no persistence datastore, no run switcher.
- Q: When the operator edits config (budget, concurrency, model routing), what does it affect? → A: The current live run, forward-only — edits retune the running Coordinator/Ledger for work not yet started (next wave, unstarted phases, later breaker decisions); completed phases are unchanged.
- Q: On a browser refresh/reconnect versus a full orchestrator-node restart, what run state does the console recover? → A: A refresh, reconnect, or new tab reconstructs the full live view (status counts, per-feature seven-phase progress, cost gauge, recent telemetry feed) from server-side state — the running Coordinator/Ledger plus a boot-started server-side projection — because that state lives in the node, not the browser. A full node restart loses the in-memory run (FR-036) and shows the no-active-run state. Durable phase-boundary crash recovery (per-phase checkpoints/commits, a run manifest, and run resume) is out of scope for v1 and is tracked as a separate core feature; the console will only surface it later.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch a live run at a glance (Priority: P1)

An operator has started a backlog run that will execute unattended for a long
stretch. They open the Control Plane to see, on one screen, how many features are
done / running / escalated / halted / blocked, where each feature is in the
pipeline, how much has been spent against the budget, and the most recent
pipeline events — all updating on their own as the run progresses.

**Why this priority**: Visibility into an unattended autonomous run is the single
reason to build this console. Without it, nothing else matters; with only this,
the operator already gains the observability they lack in `iex`. This is the MVP.

**Independent Test**: Start a run, open Mission Control, and confirm the feature
table, status counts, cost gauge, and telemetry feed reflect the run's true state
and refresh as phases advance — no page reload required.

**Acceptance Scenarios**:

1. **Given** a run with features in mixed states, **When** the operator opens
   Mission Control, **Then** a status-count strip shows the number of features in
   each lifecycle state (done, running, escalated, halted, blocked, pending) and
   a backlog table lists every feature with its id, slug, current status,
   seven-phase progress, elapsed time, and spend.
2. **Given** a feature advances from one phase to the next, **When** the change
   occurs, **Then** its row's phase progress and status update within a few
   seconds without operator action, and a new entry appears at the top of the
   telemetry feed.
3. **Given** a run in progress, **When** the operator views the status bar,
   **Then** they see the run title and mode, the cost breaker gauge (committed
   spend, reserved spend, and budget) with a color that signals proximity to the
   limit, and whether the breaker is armed or tripped.
4. **Given** the operator clicks a feature row, **When** the row is selected,
   **Then** a detail drawer opens showing that feature's per-phase timeline,
   elapsed, spend, and prerequisites.

---

### User Story 2 - Trigger a run from the console (Priority: P2)

An operator wants to kick off work without opening `iex`: either run the whole
prepared backlog, or describe a single feature in free text and have the
orchestrator build just that one.

**Why this priority**: Starting runs is the second core operator action after
observing them. It replaces `SpeckitOrchestrator.run/0` and `run_spec/2` with a
form, and makes the console self-sufficient for the common case.

**Independent Test**: From the Trigger view, start a backlog run and confirm the
run appears in Mission Control; separately, submit a free-text description and
confirm a new feature is created with an auto-assigned id and derived slug and
begins at the first phase.

**Acceptance Scenarios**:

1. **Given** the Backlog run mode, **When** the operator opens the Trigger view,
   **Then** it shows the breakdown source, the number of features found and
   whether their dependency graph validated, the max concurrency, and the budget,
   and offers a Start action.
2. **Given** the Single-spec mode, **When** the operator types a feature
   description, **Then** the console shows the id it will auto-assign and the slug
   it derives from the text, and rejects an empty description with a clear error.
3. **Given** either mode with the stacked sequential PR workflow toggle enabled,
   **When** the operator starts the run, **Then** the console reflects that the
   run is constrained to one feature at a time with one PR per feature, and the
   status bar shows the PR-workflow run mode.
4. **Given** a started run, **When** the Start action completes, **Then** the
   console navigates to Mission Control and a confirmation is shown.

---

### User Story 3 - Clear an escalation or halt (Priority: P2)

A feature diverted at the clarify gate (`## NEEDS HUMAN`) or was halted at the
analyze gate or by the drained cost breaker. The operator reviews what the
pipeline asked, answers it, and resumes the feature from its checkpoint — or
orders a full restart — from the console.

**Why this priority**: Human-in-the-loop escalation is a first-class principle of
the orchestrator; a diverted feature blocks its dependents until a human acts.
Resolving it from the console (rather than reconstructing `resume/2` arguments in
`iex`) is where the console earns its keep on a real backlog.

**Independent Test**: With one escalated feature, open Escalations, read its
checkpoint pointer and clarify questions, enter guidance, and trigger a resume;
confirm the feature re-enters the pipeline at the expected phase and the
escalation clears.

**Acceptance Scenarios**:

1. **Given** an escalated feature, **When** the operator opens Escalations,
   **Then** they see the divert reason, the checkpoint pointer (last completed
   phase, status, session id, reason), the recorded run context under which a
   resume will re-execute, and any clarify questions with their offered options.
2. **Given** an escalation, **When** the operator enters free-text guidance and
   chooses a start-phase override, **Then** the console lets them resume the
   feature with that guidance injected and starting at the chosen phase
   (defaulting to the checkpoint's last phase when no override is chosen).
3. **Given** an escalation the operator judges unrecoverable at its checkpoint,
   **When** they choose the full-restart action, **Then** the console restarts
   the feature from the first phase and frees its retained worktree.
4. **Given** no open escalations or halts, **When** the operator opens
   Escalations, **Then** an empty state confirms all gates are clear.
5. **Given** any diverted or halted feature, **When** the operator opens its
   drawer, **Then** the drawer surfaces the same resume / full-restart actions
   and a link to the relevant phase transcript.

---

### User Story 4 - Inspect the dependency DAG (Priority: P3)

An operator wants to understand why features release in the order they do — which
are waiting on prerequisites, which are in the current wave, and how the graph is
shaped.

**Why this priority**: Wave-release order is a frequent source of "why isn't X
running yet?" questions. A visual DAG answers them, but the backlog table already
conveys per-feature status, so this is enhancement rather than MVP.

**Independent Test**: Open the Pipeline DAG view for a run and confirm each
feature is a node placed by dependency depth, edges connect prerequisites to
dependents, and node status/phase/spend match Mission Control.

**Acceptance Scenarios**:

1. **Given** a run, **When** the operator opens Pipeline DAG, **Then** each
   feature appears as a node showing its id, slug, phase progress, status, and
   spend, with edges drawn from each prerequisite to its dependents.
2. **Given** the DAG view, **When** the operator reads the legend, **Then**
   node colors map to lifecycle states consistently with the rest of the console.
3. **Given** the operator clicks a DAG node, **When** the node is selected,
   **Then** the same feature drawer opens as from the backlog table.

---

### User Story 5 - Read phase transcripts (Priority: P3)

An operator investigating a feature's behavior wants to read the durable
transcript the orchestrator wrote for a given phase without hunting through the
filesystem.

**Why this priority**: Transcripts are the audit trail for what the CLI actually
did each phase. Browsing them in-console is valuable for diagnosis but not
required to run or recover features.

**Independent Test**: Open Transcripts, pick a feature and a phase, and confirm
the corresponding transcript document renders with its source path shown.

**Acceptance Scenarios**:

1. **Given** the Transcripts view, **When** the operator selects a feature and a
   phase, **Then** the console renders that phase's transcript and displays the
   path it was loaded from.
2. **Given** a feature that has not yet reached a phase, **When** the operator
   selects that phase, **Then** the console indicates the transcript does not yet
   exist rather than showing a broken or empty document silently.

---

### User Story 6 - Tune run configuration (Priority: P3)

An operator wants to adjust per-phase model routing, the cost-breaker budget, the
max concurrency, and the PR-workflow mode, and have those choices take effect.

**Why this priority**: Configuration is normally set before a run and changed
rarely; the defaults ship correct. Exposing it in-console is convenience, so it
ranks below observing, triggering, and recovering.

**Independent Test**: Change the budget and the concurrency in the Config view and
confirm the console reflects the new values and the change affects work not yet
started.

**Acceptance Scenarios**:

1. **Given** the Config view, **When** the operator sets a phase's model between
   the two offered aliases (opus / sonnet), **Then** the console records the
   choice and applies it to phases that have not yet started.
2. **Given** the Config view, **When** the operator changes the budget or the max
   concurrency, **Then** the status bar and gauge reflect the new value and the
   change governs subsequent breaker decisions and wave sizing.
3. **Given** the operator enables the stacked PR workflow in Config, **When** it
   is on, **Then** the console forces effective concurrency to one and surfaces
   the PR base and remote it will use.

---

### Edge Cases

- **Breaker trips mid-run**: when committed spend reaches the budget, the console
  MUST show the breaker as tripped, stop showing new features being released, and
  show in-flight features draining to the end of their current phase then halting
  between phases (drain, not kill) — never depict a mid-phase kill.
- **Backlog fails to validate**: if the breakdown has a dangling prerequisite or
  a dependency cycle, the Trigger view MUST surface that the DAG did not validate
  and MUST NOT let the operator start the backlog run.
- **Resume with a missing or corrupt checkpoint**: the console MUST steer the
  operator to full restart rather than offering a checkpoint resume that cannot
  succeed.
- **Concurrent operators / stale view**: if the underlying run state changes from
  outside the console (e.g. another operator, or the run finishing), the console
  MUST converge to the true state rather than acting on a stale snapshot.
- **Run finishes while being watched**: Mission Control MUST reflect a drained /
  completed run (final counts and spend) rather than appearing to still be live.
- **Browser refresh / reconnect vs node restart**: a browser refresh, reconnect,
  or new tab MUST restore the full live view from server-side state (nothing is
  lost to the client). A full orchestrator-node restart loses the in-memory run
  (FR-036) and MUST show the no-active-run state, never a stale or half-rendered
  run; the console MUST NOT offer to resume a run the node no longer holds
  (durable crash recovery is a separate v-next core feature).
- **Empty backlog / no active run**: the console MUST render a coherent empty
  state, not a broken layout, when there is nothing to show.
- **Long-running feed**: the telemetry feed MUST bound its length so a long run
  does not grow it without limit.

## Requirements *(mandatory)*

### Functional Requirements

**Global chrome & navigation**

- **FR-001**: The console MUST present a fixed navigation offering six views —
  Mission Control, Pipeline DAG, Trigger Run, Escalations, Transcripts,
  Configuration — and indicate which is active.
- **FR-002**: The navigation MUST show a count badge on Escalations when one or
  more features are escalated, halted, or failed, and hide it when there are none.
- **FR-003**: The console MUST show persistent context: the target repository, and
  health indicators for the `claude` CLI authentication and the orchestrator
  runtime.
- **FR-004**: A persistent status bar MUST show the current run's title and mode,
  a cost-breaker gauge (committed spend, reserved spend, budget) whose fill color
  signals proximity to the budget, an armed/tripped breaker indicator, and a
  live clock.
- **FR-005**: The console MUST confirm operator actions (run started, resume,
  resolve, config change) with a transient, non-blocking notification.

**Live run state (Mission Control)**

- **FR-006**: Mission Control MUST display a status-count strip aggregating
  features by lifecycle state.
- **FR-007**: Mission Control MUST display a backlog table with one row per
  feature showing id, slug, lifecycle status, a seven-phase progress indicator,
  elapsed time, and spend.
- **FR-008**: The seven phases MUST be represented in fixed order —
  specify, clarify, plan, tasks, analyze, implement, converge — with each
  feature's completed, active, and pending phases visually distinguished, and the
  active phase distinguished by status (running vs escalated vs halted vs failed).
- **FR-009**: Mission Control MUST display a telemetry feed of recent pipeline
  events (feature id, event text, timestamp), newest first, sourced from the
  orchestrator's phase telemetry.
- **FR-010**: All Mission Control surfaces MUST update to reflect run state changes
  without an operator-initiated reload.

**Feature drawer**

- **FR-011**: Selecting a feature (from the backlog table or a DAG node) MUST open
  a drawer showing its elapsed, spend, prerequisites, and a per-phase timeline
  annotated with each phase's outcome/meta and a short description of what that
  phase does.
- **FR-012**: For a diverted or halted feature, the drawer MUST offer resume and
  full-restart actions and a link to the relevant phase transcript; for a
  completed feature it MUST offer a link to its pushed branch / PR.
- **FR-013**: The drawer MUST be dismissible and MUST not obstruct the operator
  from returning to the underlying view.

**Triggering runs**

- **FR-014**: The Trigger view MUST offer two modes — a backlog run over the
  prepared breakdown, and a single-spec run from a free-text feature description.
- **FR-015**: In backlog mode, the console MUST show the breakdown source, the
  feature count and whether the dependency graph validated, the max concurrency,
  and the budget before starting.
- **FR-016**: In single-spec mode, the console MUST derive and preview the
  auto-assigned feature id and the slug from the entered text, and MUST reject an
  empty description with a clear error.
- **FR-017**: The console MUST expose a stacked sequential PR-workflow toggle that,
  when enabled, constrains the run to one feature at a time with one PR per
  feature.
- **FR-018**: Starting a run MUST invoke the orchestrator's run entry point,
  navigate the operator to Mission Control, and confirm the start.
- **FR-019**: The console MUST NOT allow starting a backlog run whose dependency
  graph failed to validate.

**Escalations & recovery**

- **FR-020**: The Escalations view MUST list every escalated, halted, or failed
  feature, each with its divert reason and a checkpoint pointer (last completed
  phase, status, session id, reason).
- **FR-021**: For an escalated feature, the console MUST display the clarify
  questions and their offered options, and the recorded run context under which a
  resume re-executes.
- **FR-022**: The console MUST let the operator enter free-text guidance that is
  injected into the resumed phase, and choose a start-phase override that defaults
  to the checkpoint's last phase.
- **FR-023**: The console MUST let the operator resume a feature from its
  checkpoint (preserving completed work) and, separately, order a full restart
  from the first phase that frees the retained worktree.
- **FR-024**: When there are no open escalations or halts, the console MUST show an
  explicit all-clear empty state.

**Pipeline DAG**

- **FR-025**: The Pipeline DAG view MUST render each feature as a node positioned
  by dependency relationships, with edges from prerequisites to dependents, and
  each node showing id, slug, phase progress, status, and spend.
- **FR-026**: The DAG view MUST provide a legend mapping node colors to lifecycle
  states, consistent with the rest of the console, and MUST open the feature
  drawer on node selection.

**Transcripts**

- **FR-027**: The Transcripts view MUST let the operator pick a feature and a phase
  and render that phase's transcript document with its source path shown.
- **FR-028**: The console MUST clearly indicate when a requested transcript does
  not yet exist rather than rendering an empty document silently.

**Configuration**

- **FR-029**: The Config view MUST let the operator set each phase's model to one
  of the two supported aliases (opus / sonnet).
- **FR-030**: The Config view MUST let the operator adjust the cost-breaker budget
  and the max concurrency within supported bounds, reflecting changes in the
  status bar and gauge.
- **FR-031**: The Config view MUST expose the stacked PR-workflow toggle (forcing
  effective concurrency to one) and display the PR base and remote.
- **FR-032**: Configuration changes MUST apply to the current live run
  forward-only — the next wave, phases not yet begun, and subsequent breaker/wave
  decisions; the console MUST NOT depict a change retroactively altering an
  already-completed phase (see FR-037).

**State fidelity**

- **FR-033**: The console MUST derive all displayed run state from the
  orchestrator's authoritative state and telemetry, and MUST reconcile to the true
  state when it changes from outside the console.
- **FR-034**: Lifecycle colors and phase ordering MUST be consistent across every
  view (status strip, table, DAG, drawer, escalations).
- **FR-038**: The console MUST reconstruct the full live-run view — status counts,
  per-feature seven-phase progress, cost gauge, and the recent telemetry feed — on
  a browser refresh, reconnect, or new tab, deriving it from server-side state (the
  running orchestrator plus a server-side projection) rather than from browser-held
  state. A full orchestrator-node restart, which loses the in-memory run (FR-036),
  MUST render the no-active-run state, not a partial or broken view. Durable resume
  of a crashed run is out of scope for v1 (tracked as a separate core feature); the
  console MUST NOT claim to recover a run the node no longer holds.

**Scope & access**

- **FR-035**: The console MUST serve a single trusted operator on a local/trusted
  network (bind to localhost or a trusted interface) with no login; it MUST NOT
  require, and MUST NOT implement, user accounts, sign-in, or per-user access
  control in v1.
- **FR-036**: The console MUST present the single run currently active in the
  running orchestrator node; it MUST NOT persist runs, show run history, or offer
  a run switcher. When no run is active, it MUST show an explicit no-active-run
  state.
- **FR-037**: Configuration edits MUST apply to the current live run forward-only —
  retuning the running Coordinator/Ledger for work not yet started — and MUST NOT
  be persisted as cross-run defaults or alter already-completed phases.

### Key Entities *(include if feature involves data)*

- **Run**: the single orchestrator invocation currently active in the node, over a
  backlog (or a single spec) — has an id, a title, a mode (parallel waves vs
  stacked PR workflow), a max concurrency, a budget, and an overall lifecycle. The
  console holds at most one active run and does not persist runs across restarts
  (see FR-036).
- **Feature**: a work unit within a run — id, slug, prerequisite feature ids,
  lifecycle status (pending, blocked, running, escalated, halted, failed, done),
  current phase, elapsed time, and accumulated spend.
- **Phase**: one of the seven fixed pipeline stages (specify, clarify, plan,
  tasks, analyze, implement, converge) with a per-feature outcome and cost.
- **Checkpoint**: the recovery record a diverted/halted feature writes — last
  completed phase, status, session id, divert reason, and the run context to
  re-execute under.
- **Escalation / Halt**: a feature diverted at the clarify gate or stopped at the
  analyze gate or by the drained breaker, carrying its reason, clarify questions
  and options, and recovery actions.
- **Telemetry event**: a timestamped pipeline event (feature id, text, severity)
  emitted as features move through phases.
- **Transcript**: the durable per-feature, per-phase document the orchestrator
  wrote, addressed by feature id and phase.
- **Cost breaker**: the budget-versus-spend guard — committed spend, reserved
  spend, budget, and armed/tripped state.
- **Configuration**: per-phase model routing, budget, max concurrency, and
  PR-workflow settings (base, remote) for a run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can determine the full status of every feature in a run
  — which state each is in and where in the pipeline — within 10 seconds of
  opening the console, without reading any log file.
- **SC-002**: Run state shown in the console reflects an actual phase transition
  within 5 seconds of it occurring, with no operator-initiated reload.
- **SC-003**: An operator can start a backlog run and a single-spec run entirely
  from the console, without opening an interactive shell.
- **SC-004**: An operator can take an escalated feature from "needs human" to
  resumed — reading the question, answering it, and resuming from the checkpoint —
  in under 2 minutes and without hand-constructing any command arguments.
- **SC-005**: The console never depicts a state that contradicts the
  orchestrator's authoritative state; when the run changes from outside, the
  console converges within 5 seconds.
- **SC-006**: 100% of the six views render a coherent state — including empty and
  error states (no active run, empty backlog, invalid DAG, missing transcript,
  missing checkpoint) — with no broken layout or silent blank.
- **SC-007**: The cost breaker's tripped state and drain-not-kill behavior are
  visible to the operator: at no point does the console show a feature killed
  mid-phase, and a tripped breaker halts new releases on screen.

## Assumptions

- **Single local operator, no auth** (confirmed — Clarifications 2026-07-21): the
  console serves one trusted operator on a local/trusted network with no sign-in;
  multi-user access control and tenancy are out of scope for v1 (FR-035).
- **One live in-memory run, no persistence** (confirmed — Clarifications
  2026-07-21): the console reflects the single run active in the running node;
  run history, a persistence datastore, and a run switcher are out of scope for v1
  (FR-036).
- **Refresh recovers from server state; node restart does not** (confirmed —
  Clarifications 2026-07-21): a browser refresh/reconnect reconstructs the full
  live view from server-side state (running Coordinator/Ledger + a boot-started
  projection), so no run state is browser-held (FR-038). A full node restart loses
  the in-memory run (FR-036). Durable phase-boundary crash recovery — per-phase
  checkpoints/commits, a run manifest, and `resume_run` extending the existing
  `resume/2` — is deliberately a **separate core feature**, not part of the
  console; git worktrees (artifacts) and per-phase transcripts (audit) already
  persist, so no new datastore (e.g. SQLite) is implied. The console will only
  *surface* run resume once that core feature lands.
- **Presentation/control layer over the existing backend**: the Control Plane
  wraps the existing orchestrator facade (`run/1`, `run_spec/2`, `status/0`,
  `resume/2`, `resolve/1`) and its telemetry/transcripts rather than
  reimplementing pipeline logic; the `iex` facade remains available.
- **Authoritative state lives in the orchestrator**: the console is a view/command
  surface; the Coordinator, Ledger, and telemetry remain the source of truth.
  Live updates are pushed or polled from that state.
- **Live-apply is forward-only**: configuration changes affect work not yet
  started (next wave, unstarted phases, subsequent breaker/wave decisions); the
  console does not retroactively re-run completed phases.
- **Seven fixed phases and model aliases**: the pipeline phases and the two model
  aliases (opus / sonnet) match the current orchestrator; the console does not
  introduce new phases or full model strings.
- **Transcripts and checkpoints are read from their existing on-disk locations**
  (`.speckit-transcripts/…`, `checkpoint.json`) written by the orchestrator.
- **The design file is the visual contract**; exact styling, animation, and the
  simulated sample data in `Control Plane.dc.html` are illustrative — real data
  comes from the live orchestrator.

## Dependencies

- The existing `speckit_orchestrator` control plane: Coordinator, Ledger,
  Release/Backlog, Worktree, FeatureRunner, Transcripts, and the phase telemetry
  (`[:speckit, :phase]`, `[:speckit, :feature, :terminal]`).
- The orchestrator facade functions the console invokes (`run/1`, `run_spec/2`,
  `resume/2`, `resolve/1`, `status/0`).
- Read access to on-disk transcripts and per-feature checkpoints.
