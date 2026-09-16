# Feature Specification: Elapsed Is Execution Time

**Feature Branch**: `024-elapsed-execution-time`

**Created**: 2026-09-16

**Status**: Draft

**Input**: User description: "Console elapsed must be phase execution time, not wall clock. Feature 023 made ELAPSED on Mission Control, the Pipeline Chain, and the feature drawer equal recorded-end-or-now minus the feature's recorded start — calendar time since the feature's first start, spanning idle gaps, parks, and restarts. On the live mod-player run feature 003 shows 1348m: the interval since 002 finished, mostly overnight downtime. Operators read ELAPSED as 'how long the pipeline has been working on this feature'. Decision (owner, 2026-09-16): ELAPSED = the sum of every phase attempt's own execution time, plus the in-flight phase's live time while a phase is running; idle gaps, parked time, and restart downtime excluded; every recorded execution of a phase counts, not just the last attempt; overlapping attempt records (the implement roll-up over its chunks, the final analyze run over superseded runs and corrections) must not double count. Cold boot and live modes agree; a running feature's value advances every refresh; a finished feature's value is frozen; `—` only when nothing has run. Out of scope: the store, the run record, the iex status report, the per-attempt Duration column."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Elapsed tells the operator how long the pipeline worked on a feature (Priority: P1)

An operator glances at Mission Control to judge how expensive, in machine time,
each feature has been. Today a feature that started yesterday afternoon, sat idle
overnight while the control plane was down, and was resumed this morning reads
"1348m" — the calendar interval since it began — even though the pipeline spent
perhaps five hours actually running phases on it. The operator wants ELAPSED to be
the time the pipeline was *executing* that feature: the durations of its phase
runs added up, with every moment of execution counted exactly once and every
moment of idleness excluded.

**Why this priority**: ELAPSED is one of the three per-feature numbers on the
primary operator surface, next to spend. A number that mostly measures how long
the laptop was closed is not a receipt for anything (Principle VII); it misleads
capacity and cost judgement for every feature that crossed a restart or a parked
run — which, on real multi-day runs, is most of them.

**Independent Test**: Take a run record whose feature finished through all seven
phases with a known duration for each phase attempt and with idle gaps between
phases. Open Mission Control with no live control plane, and again with a control
plane resumed over the same record. In both, that feature's ELAPSED equals the
total time covered by its phase runs — the gaps contribute nothing — and matches
what an operator adds up from Run Detail's Duration column for that feature.

**Acceptance Scenarios**:

1. **Given** a finished feature whose seven recorded phase runs cover 40 minutes of execution spread across a 20-hour calendar interval, **When** the operator opens Mission Control (cold boot or live), **Then** the row's ELAPSED reads 40 minutes, not 20 hours.
2. **Given** a finished feature, **When** a minute passes, or other features' live activity arrives, **Then** its ELAPSED does not change.
3. **Given** a finished feature, **When** the operator opens its drawer on Mission Control or its node's drawer on the Pipeline Chain, **Then** the drawer's ELAPSED equals the row's.
4. **Given** a feature whose implement phase ran as several chunks, each recorded alongside the implement phase's own roll-up record that spans them, **When** ELAPSED is shown, **Then** the implement phase's time is counted once — the chunks add nothing on top of the roll-up.
5. **Given** a feature whose analyze phase ran three times with two corrections in between, all individually recorded and all spanned by the final analyze record, **When** ELAPSED is shown, **Then** that loop's time is counted once.

---

### User Story 2 - A running feature's elapsed grows only while a phase runs (Priority: P1)

The operator watches a feature in flight. ELAPSED should be the execution time of
the phases already finished plus how long the current phase has been running,
advancing with each refresh while a phase runs — and *not* advancing while the
feature is between phases, parked, or waiting for the control plane to come back.
After a restart and resume, the feature carries the execution time it accumulated
before the restart and adds only what runs after it.

**Why this priority**: This is the case the owner observed. The in-flight feature
is the one row an operator watches continuously; a counter that keeps growing
through downtime, or resets to zero at each resume, is the difference between
"is this phase stuck?" being answerable from the console or not.

**Independent Test**: Record a feature through four phases (known durations),
restart, resume it, open Mission Control while the fifth phase runs. ELAPSED starts
at the four recorded durations' total plus the seconds the fifth phase has been
running, and grows by roughly the refresh interval on each refresh. Once the fifth
phase finishes and its record lands, ELAPSED continues from the same value without
a jump or a dip.

**Acceptance Scenarios**:

1. **Given** a feature with four phases recorded before a restart and a fifth phase live since the resume, **When** the operator opens Mission Control, **Then** ELAPSED equals the four recorded durations plus the fifth phase's time so far, and increases on the next refresh.
2. **Given** a live phase whose start the console observed, **When** that phase finishes and its record arrives, **Then** ELAPSED neither double counts that phase (live window plus recorded window) nor drops below the value shown while it was live.
3. **Given** a feature that is between phases, parked, or whose run has stopped, **When** refreshes occur, **Then** ELAPSED does not advance.
4. **Given** a feature resumed at a phase earlier than one it had already completed before the restart (the later attempts are superseded), **When** ELAPSED is shown, **Then** the superseded attempts' execution time still counts — every run of a phase is machine time the pipeline spent.
5. **Given** a feature whose phases are running with no live control plane to report them (a runner outliving the control plane), **When** the console observes those phases, **Then** their time counts exactly as it would with a control plane present.

---

### User Story 3 - Diverted and unstarted features read correctly (Priority: P2)

A feature that escalated, halted, or failed shows the execution time of every phase
it ran, including the attempt it diverted on; a feature that has not run any phase
yet shows no elapsed at all.

**Why this priority**: These rows are read less often than the in-flight row, but a
halted feature's elapsed is what an operator uses to judge whether a re-run is
affordable, and an unstarted feature showing a value would be a lie.

**Independent Test**: Record a feature halted at `analyze` after four completed
phases; ELAPSED equals the five attempts' execution time, both cold and live. A
pending feature with no attempt and no live phase shows `—`.

**Acceptance Scenarios**:

1. **Given** a halted feature with four completed phases and the halting analyze attempt recorded, **When** shown cold or live, **Then** ELAPSED equals the execution time of all five recorded attempts.
2. **Given** a feature with no recorded attempt and no phase live, **When** shown, **Then** ELAPSED reads `—`.
3. **Given** a feature whose only activity is a live phase just started, **When** shown, **Then** ELAPSED reads the seconds since that phase started.

---

### Edge Cases

- A recorded attempt lacks its start or end timestamp: it contributes nothing to elapsed and does not fail the page; other attempts still count.
- A live phase start was never observed (the console came up mid-phase) but its finish is: the finish contributes nothing on its own; the phase's time arrives with its record.
- A live phase start was observed but its finish never is (runner crash): the feature's terminal event closes the open window; until then the window is treated as still running.
- The live window and the recorded window for the same phase run differ by a few milliseconds at the edges: they are treated as one span, never as two.
- Two recorded attempts of the same phase that do not overlap in time (a re-run at a later step) both count in full.
- A control plane's own per-feature counter — time since it released the feature in this process — is not execution time and is never used for ELAPSED, even as a fallback.
- Elapsed derived from the record and elapsed derived from live observation are combined idempotently: refreshing, resuming, or reapplying an already-seen update yields the same value, and a live update never lowers a row's elapsed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A feature's ELAPSED on Mission Control, in the Mission Control drawer, and in the Pipeline Chain drawer MUST equal the total time during which at least one execution of that feature's steps was running — every moment counted once, no moment of idleness counted.
- **FR-002**: Every recorded execution of a step for the feature MUST contribute its execution window: pipeline phases, implement chunks, the pre-phase remediation step, auto-remediation corrections, and superseded re-runs alike. Overlapping windows (a phase's roll-up record over its chunks; a final analyze record over earlier analyze runs and corrections) MUST be merged so the overlap is counted once; non-overlapping windows of the same phase MUST each count in full.
- **FR-003**: While a phase is running, its window from its observed start to the present MUST be included, so a running feature's ELAPSED advances on each console refresh; the refresh cadence is unchanged.
- **FR-004**: A live window and the recorded window of the same execution MUST be reconciled as one span; once the record of a live phase arrives, ELAPSED MUST NOT double count it and MUST NOT fall below the last live value.
- **FR-005**: A finished feature's ELAPSED MUST be frozen: identical one minute later and unaffected by other features' activity.
- **FR-006**: Between phases, while parked, and while the control plane is down, ELAPSED MUST NOT advance; a feature resumed after a restart MUST keep its pre-restart execution time and add only post-restart execution.
- **FR-007**: Cold boot (no live control plane) and live modes MUST show the same ELAPSED for any feature with no phase currently running.
- **FR-008**: Phases observed live without a control plane present (a runner outliving it) MUST count exactly as they do with one present.
- **FR-009**: The control plane's per-feature "time since released in this process" counter MUST NOT feed ELAPSED, as primary value or fallback; it remains available to the iex status report only.
- **FR-010**: ELAPSED MUST read `—` only when the feature has no recorded execution and no phase running.
- **FR-011**: Live updates MUST never decrease a row's ELAPSED; applying an already-reflected update, refreshing, or re-hydrating MUST yield the same value (idempotent, monotone).
- **FR-012**: ELAPSED MUST be computed by pure, side-effect-free logic over synthetic records and observed events with an injected "now" (Principle I).
- **FR-013**: A recorded attempt missing its timestamps MUST be skipped without failing the page (Principle II tolerance at the read boundary, as in 023).
- **FR-014**: The feature MUST NOT add durable entities, tables, or fields, MUST NOT change how attempts are recorded, and MUST NOT introduce new design tokens or status values (Principle VII, Operator Surface Design).
- **FR-015**: This feature supersedes 023's FR-006, FR-007, SC-003, SC-005's rationale, and the "elapsed is wall-clock" assumption; 023's other requirements (phase cells, spend, precedence, no-blanking) are unchanged.

### Key Entities

- **Execution window**: one span of time during which a step for a feature was running — from an observed or recorded start to a recorded end, or to "now" while still running.
- **Recorded attempt**: one execution of a step for a feature as the run record keeps it — phase name (a pipeline phase or a non-phase step), execution order, outcome, model, cost, start, end, duration. Source of recorded windows.
- **Live observation**: the console's own view of a phase's start and finish in the current session. Source of live windows, including the one still open.
- **Feature row (console view)**: what Mission Control and the Chain render per feature; its ELAPSED is the merged length of all its windows, closed at the time of rendering.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For every finished feature, Mission Control's ELAPSED equals the time covered by that feature's attempts in Run Detail (each moment counted once) to within one second, in both cold and live modes.
- **SC-002**: For a feature that crossed a restart with idle downtime, ELAPSED is strictly less than the calendar interval since its first start by at least the downtime.
- **SC-003**: A running feature's ELAPSED increases on 100% of refreshes during a phase and on 0% of refreshes while no phase is running.
- **SC-004**: When a live phase finishes and its record arrives, the observed ELAPSED sequence never decreases and never jumps by more than one refresh interval.
- **SC-005**: A finished feature shows the same ELAPSED one minute after finishing as at the moment it finished.
- **SC-006**: Records with implement chunks or repeated analyze runs show the same ELAPSED whether or not the chunk / correction records are present — the roll-up already covers them.
- **SC-007**: A run record lacking attempt timestamps renders every page without error.
- **SC-008**: The change is covered by pure tests over synthetic records and events plus console tests for the cold-boot, live, resume, and diverted paths; the existing suite passes with no regressions and the design guard stays clean.

## Assumptions

- Owner decision 2026-09-16: ELAPSED means execution time — the union of the feature's step execution windows — replacing 023's wall-clock decision of 2026-09-15. Every recorded execution counts (retries, superseded re-runs), not only the last attempt per phase; the phase cell's cost/model semantics (last attempt) are unchanged.
- Each recorded attempt already carries its own start and end; the run record and the per-attempt Duration column on Run Detail are the ground truth and are not changed.
- Recorded attempts of one feature can overlap (a roll-up spanning its parts); merging overlapping windows is the correct de-duplication and is the only one needed.
- The console already receives a phase's start and finish as they happen; it currently discards the timing and will begin keeping it. No new event source is required.
- The console's periodic refresh (a couple of seconds) is the tick on which a running feature's ELAPSED advances; no additional timer is introduced.
- An in-flight phase has no record until it finishes; its time is visible only through the live window until then. The gap between finishing and the next refresh is already covered by 023's no-regression rules.
- The iex status table keeps the control plane's own counter; it is not an operator surface governed here.
