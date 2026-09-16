# Feature Specification: Console Restart Hydration

**Feature Branch**: `023-console-restart-hydration`

**Created**: 2026-09-15

**Status**: Draft

**Input**: User description: "Console per-feature state must survive a restart + resume. After a BEAM restart and `SpeckitOrchestrator.resume/2`, Mission Control (`/`) and Pipeline DAG (`/pipeline`) lose per-feature state that Run Detail (`/runs/:id`) still shows correctly: done features render empty phase strips, elapsed `—`, spend `$0.00`; the resumed running feature shows only the phases run since the restart lit and elapsed counted from the resume instead of its original start. […] The store is the single durable truth; in both modes (live Coordinator or cold boot) every feature row's phase cells, spend, elapsed, current phase and PR link are hydrated from the durable run record and live data is layered on top. No projection persistence, no Coordinator seeding, no new tables."

## Clarifications

### Session 2026-09-15

- Q: After a resume from an earlier phase, phases beyond that point still have recorded attempts — do their cells stay lit? → A: No. Cells after the feature's current phase render pending even when an older attempt exists; those attempts remain visible only in Run Detail and the drawer history.
- Q: A phase with several recorded attempts (e.g. `analyze` re-run after an auto-remediation correction) — what cost does its cell carry? → A: The most recent attempt's own cost only, matching the live cell semantics; the row's spend still sums every attempt.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Finished features keep their history across a restart (Priority: P1)

An operator restarts the control plane while a run is in flight (crash, deploy,
upgrade) and resumes it. On opening Mission Control or the Pipeline DAG they
expect every feature that had already finished before the restart to look exactly
as it did before: all seven phase cells lit as completed, the spend the feature
actually cost, and the wall-clock time it took from its first phase to its terminal
state. Today those rows go blank — empty strip, `—` for elapsed, `$0.00` — even
though the Run Detail page for the same run still shows every phase, its cost, and
its duration.

**Why this priority**: This is the defect that prompted the feature and the one
with the widest blast radius: every feature that finished before a restart is
affected, for the rest of the run. An operator glancing at Mission Control after a
resume is told that finished work never happened, which contradicts the run's own
durable record and Principle VII ("Show the receipt": every state a surface asserts
must be traceable to recorded state — and here the recorded state is present and
ignored).

**Independent Test**: With a run whose durable record holds two finished features
(every phase recorded with cost and timestamps) and one in-flight feature, restart
the node, resume the in-flight feature, and open `/`. The two finished rows show
seven completed cells, their recorded spend, and an elapsed value equal to the gap
between their recorded start and end — with no live activity having touched them
since the restart.

**Acceptance Scenarios**:

1. **Given** a resumed run with a feature that finished `:done` before the restart, **When** the operator opens Mission Control, **Then** that feature's row shows all seven phase cells as completed, its spend equal to the sum of its recorded phase costs, and its elapsed equal to recorded end minus recorded start.
2. **Given** that same finished feature, **When** live telemetry for *other* features arrives, **Then** the finished feature's row does not change.
3. **Given** a feature that finished `:done` **in the current session** (no restart), **When** minutes pass after it finished, **Then** its elapsed value stays frozen at end minus start rather than continuing to grow.
4. **Given** a resumed run with a feature that finished `:done` before the restart, **When** the operator opens the Pipeline DAG, **Then** that feature's node carries the same completed cells and spend as its Mission Control row.
5. **Given** a resumed run and no live control plane yet (cold boot, resume not yet issued), **When** the operator opens Mission Control, **Then** finished features are rendered from the durable record with the same completeness as after a resume — the cold-boot view is no longer limited to the last checkpointed phase.

---

### User Story 2 - The resumed feature shows its whole history, not just what ran since the restart (Priority: P1)

The operator resumes a feature that was mid-pipeline when the restart happened. They
expect its phase strip to show the phases completed before the restart as completed,
the phase now running as active, and its elapsed time counted from when the feature
first started — not from the moment it was resumed.

**Why this priority**: Equal in urgency with Story 1: it concerns the one feature the
operator is actively watching. A strip that lights only the post-restart phases
misrepresents how far along the feature is, and an elapsed counter that restarts at
zero hides how long the feature has really been running.

**Independent Test**: Record a feature through its first four phases, restart, resume
it, and open `/` while its fifth phase runs. The first four cells read completed
(with their recorded outcome, model, and cost visible in the drawer), the fifth reads
active, and elapsed equals now minus the feature's original recorded start.

**Acceptance Scenarios**:

1. **Given** a feature resumed at its fifth phase after four phases were recorded before the restart, **When** the operator opens Mission Control, **Then** cells one through four are completed, cell five is active, and elapsed is measured from the feature's original recorded start.
2. **Given** that resumed feature, **When** its running phase emits a live progress update, **Then** the four pre-restart cells stay completed — the update never blanks them, not even briefly between refresh ticks.
3. **Given** that resumed feature, **When** a phase that was recorded before the restart runs again (a retry, or a resume from an earlier phase), **Then** its cell reflects the live run (active, then its new outcome) in preference to the earlier record.
4. **Given** that resumed feature, **When** the operator opens its drawer, **Then** each completed pre-restart phase shows the outcome, model, and cost recorded for it.
5. **Given** a feature resumed from `plan` after `tasks` and `analyze` were recorded before the restart, **When** the operator opens Mission Control while `plan` re-runs, **Then** `plan` is active and `tasks` and `analyze` render pending; their earlier attempts are still listed in Run Detail.

---

### User Story 3 - Diverted features keep their marker and their receipt (Priority: P2)

A feature escalated, halted, or failed before the restart and has not been resolved.
The operator expects Mission Control after the restart to show the phase where it
diverted with the diverted status's color, the phases before it as completed, and
the spend and elapsed that the run's record already knows.

**Why this priority**: Diverted features are exactly the ones an operator returns to
after a restart to decide what to do next. Today they keep their status pill and
their diverted-phase marker (the checkpoint survives), but lose spend and elapsed
and lose the recorded outcome/model/cost of every earlier phase.

**Independent Test**: Record a feature halted at `analyze` with four completed phases
before it, restart, and open `/` with and without resuming another feature. The
`analyze` cell carries the halted marker with the recorded cost and model of the
analyze attempt; the four earlier cells are completed; spend and elapsed are
non-empty and match the record.

**Acceptance Scenarios**:

1. **Given** a feature halted at `analyze` before the restart, **When** the operator opens Mission Control, **Then** the `analyze` cell shows the halted marker, keeps the analyze attempt's recorded cost and model, and the four earlier cells are completed with their recorded details.
2. **Given** that halted feature, **When** the row is rendered, **Then** spend equals the sum of its recorded phase costs and elapsed equals recorded end minus recorded start.
3. **Given** a feature that escalated with a PR link already recorded, **When** live telemetry that carries no PR link arrives for that feature, **Then** the recorded PR link is still shown.

---

### Edge Cases

- A feature is resumed from an earlier phase: recorded attempts of phases later than its current phase are superseded and render pending, not completed. The current phase is the live active phase when one is observed, otherwise the checkpointed phase; a finished feature has no current phase and every recorded phase cell stays lit.
- A feature has several recorded attempts of the same phase (e.g. `analyze` re-run by auto-remediation): the most recent attempt in execution order defines that phase's cell, including its cost; every attempt still counts toward the row's spend.
- Recorded attempts that are not pipeline phases (implement chunks, auto-remediation corrections, the pre-phase remediation step) never produce a phase cell of their own; they are already reflected by the pipeline phase they belong to.
- Chunk attempts carry no cost record of their own — the implement phase's roll-up does. Spend must count each cost exactly once, never both a chunk and its roll-up.
- Two features' recorded costs live in the same run-level ledger: a feature's spend must include only entries belonging to its own attempts.
- The run's record has a feature that the live control plane does not know about (out-of-scope on this resume): while the control plane is live, that feature is not added to the view; the live control plane owns the feature set.
- A feature has a recorded start but no recorded end and is not currently running (e.g. the record says running but the runner died with the node): its elapsed keeps counting against the current time, matching its last-known status, until the record is reconciled.
- A feature has no recorded start at all (it was never started, or its record predates start timestamps): elapsed falls back to whatever the live control plane knows, or `—`.
- A recorded run whose feature entries lack attempt lists or timestamps (records written before those fields existed) must still render — missing data degrades to empty cells / `—` / `$0.00`, never to a crash.
- Live spend for a feature can never be reported lower than what the record already accounts for, and it can never decrease from one refresh to the next.
- A live update that clears a feature's chunk or remediation sub-label (terminal state) still clears it; only phase cells, spend, and the PR link are protected from regression.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Mission Control and the Pipeline DAG MUST render, for every feature in the current run, phase cells, spend, elapsed, current phase, and PR link drawn from the run's durable record — in both operating modes: with a live control plane (after a resume) and without one (cold boot).
- **FR-002**: A phase cell derived from the record MUST reflect the most recent recorded attempt of that pipeline phase in execution order, carrying that attempt's own outcome, model, and cost — not a sum over earlier attempts or corrections — so a record-derived cell means the same thing as a live one.
- **FR-002a**: Cells for phases later than the feature's current phase MUST render pending regardless of recorded attempts. The current phase is the live active phase when one is observed, otherwise the checkpointed phase; a feature with terminal status `:done` has no current phase and keeps every recorded cell.
- **FR-003**: Recorded attempts that are not pipeline phases (implement chunks, auto-remediation corrections, the pre-phase remediation step) MUST NOT produce phase cells of their own.
- **FR-004**: For a feature whose recorded status is escalated, halted, or failed, the phase it diverted at MUST render with that status's marker while retaining the recorded cost and model of that phase's attempt.
- **FR-005**: A feature's spend derived from the record MUST equal the sum of recorded cost entries that belong to that feature's own attempts, counting each cost exactly once (chunk attempts have no entry of their own; the implement roll-up does).
- **FR-006**: Elapsed MUST be wall-clock: recorded end (or the current time, when the feature has not ended) minus the feature's recorded start. A finished feature's elapsed therefore freezes at end minus start, including within a single session.
- **FR-007**: When the record holds no start for a feature, elapsed MUST fall back to the live control plane's counter, or `—` when there is none.
- **FR-008**: When a live control plane is present, it MUST remain the sole authority for which features are in the run and for each feature's status; the record MUST only fill in phase cells, spend, elapsed, current phase, and PR link, and MUST NOT add features the control plane does not list.
- **FR-009**: Live telemetry MUST take precedence over the record for any phase it has observed in the current session — a phase running now renders as active over a recorded completion of the same phase.
- **FR-010**: Live spend MUST be combined with recorded spend by taking the larger of the two, so the displayed value never falls below what the record accounts for.
- **FR-011**: A live per-feature update MUST NOT regress a row: phase cells merge per phase, spend never decreases, and an update with no PR link never blanks a known one. Status, chunk sub-label, and remediation sub-label continue to be replaced by the update as today.
- **FR-012**: The record-derived state MUST be computed by pure, side-effect-free logic testable with synthetic run records and an injected "now" (Principle I).
- **FR-013**: Rendering MUST tolerate run records lacking attempt lists, cost entries, or timestamps — degrading to empty cells, `—`, or `$0.00` rather than failing.
- **FR-014**: The cold-boot view MUST stop relying solely on the last checkpointed phase for phase cells; the checkpoint remains only the source of the diverted/in-progress marker and the implement chunk sub-label.
- **FR-015**: The feature MUST NOT introduce persistence for the live telemetry fold, MUST NOT seed the control plane's per-feature clocks from the record, and MUST NOT add durable tables or fields.
- **FR-016**: The feature drawer MUST show, for each record-derived completed cell, the recorded outcome, model, and cost, exactly as it does for a cell observed live.

### Key Entities

- **Feature row (console view)**: what Mission Control and the DAG render per feature — status, phase cells (one per pipeline phase: pending / active / completed, with outcome, model, cost), spend, elapsed, current phase, chunk and remediation sub-labels, PR link.
- **Recorded feature**: the durable per-feature entry of a run — status, start and end timestamps, PR link, checkpoint (last completed phase, diverted status, implement chunk position), and its recorded attempts.
- **Recorded attempt**: one execution of a step for a feature — phase name (a pipeline phase, or a non-phase step such as an implement chunk or an auto-remediation correction), execution order, outcome, model, cost, duration, timestamps, and an identity that a cost entry can reference.
- **Cost entry**: one accounted cost, tied to exactly one recorded attempt; the run-level ledger the budget gauge and run history already sum.
- **Live slice**: what the in-memory telemetry fold knows about a feature in the current session — phases observed since boot, spend since boot, current chunk / remediation, PR link if observed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a restart and resume, 100% of features finished before the restart show seven completed phase cells, non-zero spend, and a non-`—` elapsed on Mission Control and the Pipeline DAG, with no operator action beyond opening the page.
- **SC-002**: For every feature, the spend shown on Mission Control equals the spend Run Detail shows for that feature to the cent, and the completed cells match Run Detail's attempt list phase for phase.
- **SC-003**: A resumed feature's elapsed on Mission Control agrees with the feature's recorded start in Run Detail (elapsed = now − recorded start, within one refresh tick).
- **SC-004**: During a live phase of a resumed feature, its pre-restart cells remain completed on every refresh — zero observed blank-outs across a full phase.
- **SC-005**: A feature finished in the current session shows the same elapsed value one minute after finishing as it did at the moment it finished.
- **SC-006**: A run record lacking attempt lists or timestamps renders every page without error.
- **SC-007**: The change is fully covered by pure tests over synthetic records (no live control plane, no harness) plus console tests for the cold-boot, live, and resume paths, and the existing suite passes with no regressions.

## Assumptions

- Elapsed is wall-clock and includes downtime between a crash and its resume (operator decision, 2026-09-15): a feature interrupted for hours reports those hours. This matches the meaning the live counter and the run header already have; "active time" (sum of phase durations) is explicitly not what this feature shows.
- The run's durable record — per-feature start/end timestamps, execution-ordered attempts with outcome/model/cost, checkpoints, PR links, and per-attempt cost entries — already exists and is already read by both console pages on mount and on every periodic refresh; this feature reuses that read and adds no store round-trips.
- A resumed feature's recorded start is preserved across resume and its recorded end is cleared when it restarts, so end-or-now minus start is the right elapsed for a running feature without further bookkeeping.
- Checkpoints are removed when a feature finishes; the attempt list is therefore the only durable source of a finished feature's phases, and the checkpoint is only consulted for the marker of an unfinished feature.
- Run Detail is already correct and is the reference the console pages are reconciled against; it is not changed by this feature.
- Chunk attempt ordinal numbering after a resume and the run-header vs run-history spend difference (committed plus reserved vs committed) observed during investigation are out of scope.
- The periodic refresh cadence of the console (a couple of seconds) is unchanged; regression protection on live updates exists precisely so the window between an update and the next refresh never shows a blanked row.
