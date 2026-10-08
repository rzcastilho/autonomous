# Feature Specification: Atomic Continue of a Parked Run

**Feature Branch**: `035-continue-run-atomic`

**Created**: 2026-10-08

**Status**: Draft

**Input**: User description: "Make continue_run/1 atomic: a refused continue must leave the parked run exactly as it was. Incident (2026-10-07, mod-player run r000003): feature 004 failed at implement ({:unchecked_tasks, [\"T048\"]}) and parked the run (stopped_by \"004\"). The operator clicked Continue in Mission Control. Autonomous.continue_run/1 called Store.Writer.continue_run/1 (flipping :parked -> :in_flight and clearing stopped_by) BEFORE resume/2 -> run/1 ran its preflights. run_stacked's preflight_stacked then refused with {:preflight, [{:pack_outdated, \".claude/hooks/scope_guard.py\", ...}]} because the target checkout's committed pack lagged the permissive-profile contract. continue_run returned {:error, ...} but the store write was never undone: the run was left :in_flight with stopped_by nil, no Coordinator, no workers. Consequences: Mission Control no longer offered continue/end (it only acts on :parked runs), the Escalations page showed nothing, and the run looked active while nothing ran. Requirement: any refusal on the continue path (guard, capacity, containment/pack preflight, layout, reconcile, resume-route resolution, run/1 preflights, Coordinator start failure) must leave the parked run byte-identical — still :parked with stopped_by/stopped_reason intact — and return the same {:error, reason} it does today so the console flash still names the cause. Either preflight everything before the flip or restore the parked state on failure; the spec should pick the observable contract, not the mechanism. A successful continue is unchanged. Covers the console continue action (Mission Control and Escalations dispatch_resume) since both go through continue_run/1. Out of scope: Escalations reading stored diverted features when nothing is live (separate feature)."

## Background

Feature 019 introduced the **parked run**: when a backlog feature ends in a
non-`:done` terminal state with nothing else in flight, the run is recorded as
`:parked`, naming the feature that stopped it (`stopped_by`) and why
(`stopped_reason`). A parked run blocks all new work for its repository until
an operator chooses `continue_run/1` (carry the chain on from the stopping
feature) or `end_run/1` (close it out).

On 2026-10-07 an operator chose **continue** on run `r000003` (target
`mod-player`). The continue recorded the run as `:in_flight` and cleared
`stopped_by` *first*, and only afterwards did the start checks run. One of them
refused — the target repository's committed containment pack was older than the
run's `permissive` profile requires
(`{:pack_outdated, ".claude/hooks/scope_guard.py", ...}`). The operator got an
error, but the record was never put back. The run was left recorded as
`:in_flight` with no `stopped_by`, while nothing was actually running: no
Coordinator, no worker, no session.

From that moment every operator surface told a falsehood. Mission Control
offered neither continue nor end (it only offers them for a `:parked` run), the
Escalations page listed nothing, and the run looked active while it was dead.
Recovering it took a live-node investigation and a hand-issued `resume/2`.

This feature makes the continue all-or-nothing from the operator's point of
view: it either really continues the run, or it leaves the parked run exactly
as it found it and says why.

## Clarifications

### Session 2026-10-08

- Q: Should this feature also detect or repair runs already orphaned by the bug (`:in_flight` with nothing running)? → A: Out of scope — prevention only; `resume/2` remains the manual recovery.
- Q: Where does a restore failure (FR-009) surface? → A: A distinct error result plus an error log line, **and** a durable annotation on the run record shown on Run Detail until the run is next resumed, continued, or ended. No new run state.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A refused continue leaves the parked run intact (Priority: P1)

An operator looks at a parked run and chooses **continue**. Something stops the
continue from starting — the target's containment pack is out of date, the
store is near capacity, the checkpoint no longer resolves, the run's settings
fail validation, or the run cannot be started at all. The operator sees the
refusal and its cause, exactly as today. Afterwards the run is still parked:
same `stopped_by`, same `stopped_reason`, same feature statuses, and the
continue / end choice is still offered on every surface that offered it
before. The operator fixes the cause (for example, pulls the target's updated
pack) and chooses **continue** again — and it works.

**Why this priority**: This is the incident. A refused continue currently
corrupts the run record into a state no surface can act on, and that state
lies to the operator about whether anything is running. Every other story is
secondary to never leaving a dead run looking alive.

**Independent Test**: Park a run, arrange for one start check to refuse (an
outdated containment pack on a `permissive` run is the incident case), choose
continue, and confirm the error is reported and the stored run record —
state, `stopped_by`, `stopped_reason`, feature statuses — is unchanged; then
remove the cause, choose continue again, and confirm the run continues.

**Acceptance Scenarios**:

1. **Given** a parked run whose target has an outdated containment pack for
   the run's `permissive` profile, **When** the operator chooses continue,
   **Then** the continue is refused with the same pack-outdated reason as
   today, and the run is still recorded as `:parked` with its original
   `stopped_by` and `stopped_reason`.
2. **Given** that refused continue, **When** the operator opens Mission
   Control, **Then** the parked run's continue and end choices are still
   offered, and nothing is shown as running.
3. **Given** that refused continue, **When** the operator removes the cause and
   chooses continue again, **Then** the run continues from the stopping
   feature exactly as a first-time continue would.
4. **Given** a parked run, **When** a continue is refused for any reason on the
   continue path (see FR-002), **Then** no Coordinator, no worker, no worktree,
   and no model session exists for the run afterwards.

---

### User Story 2 - The refusal still names its cause (Priority: P2)

When a continue is refused, the operator needs to know *why* to fix it. Today
the refusal reason reaches the console flash and the caller of
`continue_run/1`. That must not get worse: the reason returned is the same one
returned today for the same cause, so existing console messages, scripts, and
runbook guidance keep working.

**Why this priority**: The atomicity fix must not trade a corrupt record for an
uninformative error. The operator's next action depends entirely on the reason.

**Independent Test**: For each refusal cause in FR-002, trigger it and compare
the returned reason with the reason returned before this feature for the same
cause.

**Acceptance Scenarios**:

1. **Given** a parked run and a refusal cause, **When** the operator chooses
   continue from Mission Control, **Then** the flash names the same reason it
   names today.
2. **Given** a parked run and a refusal cause, **When** an operator calls
   `continue_run/1` from iex, **Then** the call returns the same
   `{:error, reason}` it returns today.

---

### User Story 3 - The same guarantee from the Escalations page (Priority: P3)

The Escalations page's resume form continues a parked run when the operator
targets the feature that stopped it. That path must carry the same guarantee:
a refused continue launched from Escalations leaves the parked run intact and
reports its cause.

**Why this priority**: Same failure, second entry point. Lower priority only
because both entry points share one continue path, so fixing User Story 1
should cover it; this story makes sure it does.

**Independent Test**: Park a run, arrange a refusal, submit the Escalations
resume form for the stopping feature, and confirm the run stays parked and the
error is shown.

**Acceptance Scenarios**:

1. **Given** a parked run stopped by feature X and a refusal cause, **When**
   the operator submits the Escalations resume form for X (with or without a
   guidance prompt or remediation options), **Then** the run stays `:parked`
   with its original `stopped_by` and `stopped_reason`, and the error names
   the cause.

---

### Edge Cases

- **A refusal from a check that only runs once the run is being started** —
  e.g. the containment-pack check inside the stacked start, or the run failing
  to start at all. These are exactly the incident's class and MUST be covered,
  not just the checks that run before anything is recorded.
- **Putting the parked state back itself fails** (if the mechanism records the
  continue first and must undo it, and the undo write fails). The run MUST NOT
  be left silently `:in_flight` with nothing running: the failure is returned,
  logged, and annotated on the run record for Run Detail (FR-009), so the
  operator knows the record needs attention and can recover with `resume/2`.
- **Two continues race** (e.g. two console tabs, or console plus iex). At most
  one may start the run. The loser MUST be refused without disturbing the
  winner's run, and MUST NOT put a running run back to `:parked`.
- **An `end_run/1` races a refused continue.** Whichever decision the record
  ends up holding must be a consistent one — either still parked, or ended by
  the operator — never `:in_flight` with nothing running.
- **The continue is refused before the parked run is even found** (no parked
  run, or another run already active). Nothing about any run record changes —
  unchanged from today.
- **The continued run starts, then the resumed feature fails again in a
  phase.** Out of this feature's scope: the run genuinely ran, and the
  existing path parks it again.
- **The orchestrator restarts mid-continue.** On restart the record MUST be
  either still `:parked` or a genuinely started `:in_flight` run that the
  existing restart/recovery path already handles — the same consistency the
  edge cases above require.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A continue of a parked run MUST be all-or-nothing as observed
  through the stored run record: either the continued run starts, or the
  parked run's record is left exactly as it was before the continue was
  attempted.
- **FR-002**: FR-001 MUST hold for every refusal on the continue path,
  including at least: the active-run guard; the store capacity check; the
  containment profile and containment-pack checks; layout resolution;
  reconciliation of the run's features against durable evidence; resolution
  of the stopping feature's resume route (checkpoint, start phase, task phase,
  remediation model, publish-only route); every start check the run itself
  performs; and a failure to start the run's control process.
- **FR-003**: "Exactly as it was" MUST mean, at minimum: run state `:parked`,
  the same `stopped_by`, the same `stopped_reason`, the same per-feature
  statuses and checkpoints, and no new phase-attempt, cost, or escalation
  records attributable to the refused continue.
- **FR-004**: A refused continue MUST leave nothing running for the run: no
  control process, no registered worker, no worktree created, no model
  session started.
- **FR-005**: A refused continue MUST return the same refusal reason the
  system returns today for the same cause, on every entry point
  (`continue_run/1` called directly, Mission Control's continue action, and
  the Escalations page's resume form for the stopping feature).
- **FR-006**: After a refused continue, every operator surface that offered
  the parked run's continue / end choice before the attempt MUST still offer
  it, and no surface may show the run as running.
- **FR-007**: After a refused continue, a later continue whose cause has been
  removed MUST behave exactly as a first-time continue of that parked run.
- **FR-008**: A successful continue MUST be unchanged: same resulting run
  state, same feature released, same options honoured, same result returned.
- **FR-009**: If the system cannot guarantee FR-001 for a particular attempt
  (for example, an undo write fails), it MUST report this loudly and MUST NOT
  report the attempt as a plain refusal of an intact parked run. Specifically:
  - the attempt returns a distinct restore-failure result naming both the
    original refusal and the restore error, and logs it at error level;
  - the restore failure is durably annotated on the run record (both reasons
    and when it happened) and rendered on the run's Run Detail view;
  - the annotation stays until the run is next resumed, continued, or ended,
    which clears it;
  - no new run state is introduced; if the annotation itself cannot be
    written, the returned result and the error log line still carry both
    reasons.
- **FR-010**: Concurrent continue attempts for the same parked run MUST start
  the run at most once; a losing attempt MUST be refused without altering the
  winning attempt's run.

### Key Entities

- **Parked run record**: The stored run with state `:parked`, naming the
  stopping feature (`stopped_by`) and its terminal reason (`stopped_reason`),
  plus each feature's status and checkpoint. This is the thing a refused
  continue must not change.
- **Continue attempt**: An operator's request to carry a parked run on from
  its stopping feature, from any entry point. Outcome is exactly one of:
  started, refused-with-run-intact, or (only when the guarantee cannot be
  kept) refused-with-restore-failure reported loudly.
- **Restore-failure annotation**: Durable note on a run record that a refused
  continue could not put the parked state back — the original refusal reason,
  the restore error, and a timestamp. Shown on Run Detail; cleared when the
  run is next resumed, continued, or ended.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For each refusal cause listed in FR-002, a refused continue
  leaves the stored parked run record unchanged in 100% of test runs.
- **SC-002**: After any refused continue, the operator can retry continue (or
  choose end) from Mission Control with zero manual intervention outside the
  console — no live-node commands, no store edits.
- **SC-003**: Zero runs are left recorded as `:in_flight` with nothing running
  as a result of a refused continue.
- **SC-004**: For each refusal cause, the reason shown to the operator is
  identical to the reason shown before this feature.
- **SC-005**: Every existing test of a successful continue passes unchanged.
- **SC-006**: When a restore is forced to fail in testing, 100% of such
  attempts return the distinct restore-failure result, and the run's Run
  Detail view shows both reasons until the run is next resumed, continued, or
  ended.

## Assumptions

- Atomicity covers everything up to and including the continued run actually
  starting. Once the run is genuinely executing, later outcomes (a feature
  failing again in a phase) follow the existing rules and park the run again.
- The mechanism (check everything before recording, record-then-undo, or a
  single transactional step) is a planning decision; any choice must satisfy
  every requirement and edge case above.
- Out of scope: detecting or repairing runs already left orphaned by this bug
  before the fix (like `r000003`, since recovered by hand with `resume/2`). No
  surface flags them and nothing re-parks them; `resume/2` on the orphaned
  `:in_flight` run remains the documented recovery.
- Making the Escalations page list stored diverted features when nothing is
  live is a separate feature and out of scope here.
- In-memory state that a refused continue may touch but that is rebuilt on
  every start (for example, the spend ledger's restored committed total) is
  not part of the "run record" for FR-003, provided it cannot cause a later
  run to misreport or mis-account spend.
- `end_run/1`, `resume/2` on a non-parked run, `resume_run/1`, and fresh
  `run/1` starts are unchanged except where they interact with a racing
  continue (FR-010 and the edge cases).
