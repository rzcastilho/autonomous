# Feature Specification: Console Projection Survives Coordinator Timeouts

**Feature Branch**: `038-console-projection-resilience`

**Created**: 2026-10-09

**Status**: Draft

**Input**: User description: "console projection survives coordinator timeouts"

## Context

Observed 2026-10-09 on the mod-player instance while a resumed run was in its
`converge` phase. The operator opened Mission Control and the Telemetry panel
(the live feed of "run started", "phase converge started", … entries) was empty.
The instance log showed the console's live-state process terminating because
the run controller did not answer a status request within five seconds (the
instance was briefly busy; a store log-dump warning appeared at the same time).
Nothing else was wrong — the feature's session kept running and the run was
healthy — but the console's in-memory view restarted blank, so every feed entry
and live row accumulated since the run started was lost, and a page load that
raced the failure crashed as well.

A momentary slow answer from the run controller is an expected condition on a
busy machine. It must not erase what the operator is watching.

## Clarifications

### Session 2026-10-09

- Q: Is the history rebuild (Story 2) in scope for this feature? → A: Yes — crash-proofing (P1) and rebuild from the durable record (P2) ship together; the delayed notice (P3) stays.
- Q: When does the rebuild happen? → A: On every start of the console's live view — after a crash and after an instance restart — whenever the instance has an in-flight or parked run.
- Q: How much history does the rebuild cover? → A: The whole current run (every feature's recorded events), trimmed to the feed's existing 200-entry limit, newest kept.
- Q: When does the delayed-status notice appear? → A: After 2 consecutive missed refreshes; it clears on the first successful refresh.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A slow run controller does not wipe the console (Priority: P1)

An operator has Mission Control open on a run in progress. The machine becomes
briefly busy and the run controller takes longer than usual to answer the
console's periodic refresh. The Telemetry feed, the feature rows, and the
spend/status shown keep their content; the refresh simply catches up on the
next tick. No operator action is needed and nothing is lost.

**Why this priority**: This is the observed failure. The console exists so the
operator can watch a run without trusting the run to be quiet; losing the feed
at the moment the machine is struggling is exactly when it matters.

**Independent Test**: With a run in progress and several feed entries shown,
make the run controller unresponsive for longer than the console's wait limit,
then release it. The feed still shows every earlier entry, new entries append,
and no error is raised in the instance log for the console.

**Acceptance Scenarios**:

1. **Given** a run in progress with feed entries on screen, **When** the run
   controller fails to answer a console refresh in time, **Then** the feed
   entries and rows are unchanged and the console keeps receiving new events.
2. **Given** the run controller was unresponsive for one refresh, **When** it
   answers again, **Then** the next refresh updates the console normally with
   no manual reload.
3. **Given** the run controller is unresponsive, **When** an operator opens or
   reloads a console page, **Then** the page loads with the last known state
   instead of failing.

---

### User Story 2 - The console's history survives its own restart (Priority: P2)

Whenever the console's live view starts — after a crash for a cause not yet
anticipated, or after the operator restarts the instance (new image, recovery)
while a run is in flight or parked — the operator does not
return to a blank panel while the run is mid-flight. The feed and rows are
rebuilt from what the system has durably recorded about the run, so the
operator sees the run's recorded history rather than nothing.

**Why this priority**: Story 1 removes the known trigger; this story removes
the blast radius of any other trigger. It is lower priority because it depends
on what is durably recorded and is best-effort for entries that were never
recorded.

**Independent Test**: Run a feature through at least one phase, force the
console's live view to restart, and open Mission Control: the feature's rows
and the phase/terminal entries that were durably recorded are shown, not an
empty feed.

**Acceptance Scenarios**:

1. **Given** a run with recorded phase and terminal events, **When** the
   console's live view restarts, **Then** the feed shows those recorded events
   and the rows show the recorded state.
2. **Given** a restart, **When** new events occur afterwards, **Then** they
   appear after the rebuilt history, in order, without duplicates.

---

### User Story 3 - The operator can tell a stale view from a quiet run (Priority: P3)

While the run controller is not answering, the console shows its last known
state. The operator can tell the data is possibly stale, rather than mistaking
it for a run that has simply gone quiet, and sees it clear itself once the
controller answers again.

**Why this priority**: Honest display of degradation; useful but the console is
already correct without it.

**Independent Test**: Make the run controller unresponsive across several
refreshes and observe the console, then release it.

**Acceptance Scenarios**:

1. **Given** the run controller has missed 2 consecutive refreshes, **When**
   the operator looks at Mission Control, **Then** an unobtrusive notice says
   the live status is delayed.
2. **Given** the run controller missed only a single refresh, **When** the
   next one succeeds, **Then** no notice was ever shown.
3. **Given** the notice is shown, **When** the controller answers again,
   **Then** the notice disappears on its own.

---

### Edge Cases

- The run controller never answers again (it is truly stuck): the console keeps
  its last known state, flags it as delayed (Story 3), and does not crash,
  retry in a tight loop, or hide the delay.
- No run is active: refreshes find nothing to ask and behave exactly as today.
- The unresponsive moment coincides with a page load or a button press (for
  example Continue): the page loads with last known state; an action that needs
  the controller reports that it could not be reached instead of crashing the
  page.
- The instance is restarted while a run is parked: the console shows that
  run's recorded history, so the operator can see what stopped it before
  choosing to continue or end.
- A restart happens before any event was recorded (very early in a run): the
  console shows an empty feed, as it would for a brand-new run.
- Events that were only ever shown live and never durably recorded cannot be
  recovered after a restart; the console shows what was recorded and does not
  invent entries.
- Repeated slow answers across many refreshes: no growth in memory or log noise
  beyond a bounded, rate-limited message.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The console's live view MUST NOT terminate, and MUST NOT lose its
  accumulated feed entries or feature rows, when the run controller fails to
  answer a status request within the wait limit.
- **FR-002**: After an unanswered refresh the console MUST resume normal
  updating on the next successful refresh without operator action or page
  reload.
- **FR-003**: Console pages MUST load and render the last known state when the
  run controller is unresponsive, rather than failing the page.
- **FR-004**: An operator action that requires the run controller (for example
  continuing or ending a parked run) MUST report that the controller could not
  be reached, and MUST NOT crash the page or leave the console in an
  inconsistent state.
- **FR-005**: Every time the console's live view starts — after a crash inside
  a running instance and after an instance restart — it MUST rebuild its feed
  and rows from the durably recorded history of the instance's in-flight or
  parked run, so the operator never sees a blank console for a run that has
  recorded events.
- **FR-006**: Rebuilt history MUST cover every feature of the current run
  (not only the one in flight), be trimmed to the feed's existing 200-entry
  limit keeping the newest, be shown in chronological order, MUST NOT
  contain entries that were not recorded, and later live events MUST follow it
  without duplicates.
- **FR-007**: After 2 consecutive refreshes the run controller did not answer,
  the console MUST show an indication that live status is delayed, and MUST
  clear it on the first refresh that succeeds. A single missed refresh MUST NOT
  show it.
- **FR-008**: A missed refresh MUST be recorded as a single, rate-limited
  warning in the instance log (not an error that restarts anything), so the
  condition is visible to an operator reading logs.
- **FR-009**: Behaviour when the run controller answers normally MUST be
  unchanged: same entries, same ordering, same update cadence.
- **FR-010**: The console remains read-only with respect to run state; none of
  the above may change how runs are scheduled, executed, recorded, or costed.

### Key Entities

- **Console live view**: the in-memory picture of the current run (feed
  entries, per-feature rows, status) that Mission Control and related pages
  render. Not durable by itself.
- **Feed entry**: one timestamped line of run activity (run started, phase
  started/finished, feature terminal). Source of truth is the durable run
  record; the live view is a projection of it.
- **Run controller**: the process that owns the current run's scheduling and
  answers status requests; may be briefly slow under load.
- **Delayed-status indicator**: a transient notice that the console's last
  refresh did not complete.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a test where the run controller is unresponsive for at least
  three consecutive refresh intervals during a run, 100% of feed entries and
  rows shown beforehand remain shown, and zero console crashes are logged.
- **SC-002**: Within one refresh interval after the controller answers again,
  the console shows current state with no operator action.
- **SC-003**: After a forced restart of the console's live view mid-run, the
  operator sees every durably recorded phase and terminal event of the current
  run within 5 seconds of opening Mission Control; the feed is never blank for
  a run that has recorded events.
- **SC-004**: While the controller is unresponsive, every console page still
  loads in under 3 seconds with last known state.
- **SC-005**: With a normally responsive controller, console output and the
  existing console test suite are unchanged.
- **SC-006**: The delayed-status indicator appears on the second consecutive
  missed refresh (never on a single miss) and disappears on the first successful
  refresh after recovery.

## Assumptions

- The known trigger is a status request to the run controller exceeding its
  wait limit under machine load; other causes of a console restart are covered
  only by the history rebuild (Story 2).
- The durable run record already holds enough about phases and feature terminal
  outcomes to rebuild a useful feed; finer-grained live-only messages may be
  absent after a rebuild, which is acceptable.
- "Current run" means the run the instance is serving; history of earlier
  runs stays on Run History pages and is not merged into the live feed.
- The refresh interval and wait limit are existing operating values; this
  feature does not change them.
- The delayed-status indicator uses the console's existing visual language and
  needs no new status colour.
- Out of scope: diagnosing why the controller was slow (a store log-dump
  hiccup was observed alongside), changing the run controller's own
  responsiveness, and persisting live-only messages.
