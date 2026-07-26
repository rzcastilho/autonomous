# Feature Specification: Implement Phase Chunking

**Feature Branch**: `015-implement-phase-chunking`

**Created**: 2026-07-25

**Status**: Draft

**Input**: User description: "Phase-chunked implement: run the implement phase one tasks.md phase at a time, with per-chunk UI visibility and per-chunk resume."

## Context

The orchestrator's `implement` step is dispatched today as a **single** agent session
covering a feature's **entire** task list, bounded by one turn cap. Real features
outgrow that cap.

Observed in production on 2026-07-25 (quickpoll run, feature 001): the task list held
18 tasks across 5 task-phases; the session completed 8 tasks in 81 turns (~10 turns per
task) and was cut off mid-edit when it exceeded the 80-turn cap. The harness reported an
error; the orchestrator classified that error as terminal (correctly, under its current
two-way transient/terminal split) and failed the feature. Half-finished but committed
work was abandoned and the two dependent features were blocked behind it.

Two distinct defects surfaced:

1. **Granularity.** One monolithic session cannot fit a real feature's task list inside
   any fixed turn cap. Raising the cap only moves the wall.
2. **Classification.** Turn exhaustion is *partial progress*, not a deterministic
   failure. Treating it as terminal discards completed work and blocks dependents.

Feature backlogs produced by the upstream task-generation step are already organised
into ordered, numbered task-phases (observed on quickpoll 001: *Setup*, *Foundational*,
*User Story 1*, *User Story 2*, *Polish & Cross-Cutting Concerns*). That existing
structure is the natural unit of work for a bounded session.

## Clarifications

### Session 2026-07-25

- Q: After every task-phase has been dispatched, some tasks are still unchecked. What should the implement step do? → A: Dispatch one final sweep session scoped to all remaining unchecked tasks; if any remain unchecked after it, fail with a reason naming them.
- Q: What bounds a runaway feature overall, given chunking multiplies worst-case implement work? → A: A configured per-feature ceiling on the total number of implement sessions, spanning all task-phases, continuations and the sweep.
- Q: Does the per-task-phase continuation bound stop a task-phase that keeps exhausting its turn budget while completing tasks every time? → A: No — the bound counts only consecutive attempts that completed nothing; any attempt completing at least one task resets it. The per-feature session ceiling is the outer stop.
- Q: What identifies a task-phase in the durable run state, given a regenerated task list renumbers and retitles task-phases? → A: Record ordinal, number and title; on resume match by number, then title, then ordinal, then fall back to the first task-phase with incomplete tasks.
- Q: Do the continuation rules apply to the fallback path for task lists with no task-phase headings? → A: Yes. The fallback still runs one session over the whole task list, but turn exhaustion with progress continues in a fresh session under the same bounds; SC-005 means no new failures and unchanged console rendering, not unchanged failure-on-exhaustion.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Long task lists finish (Priority: P1)

An operator starts an autonomous run for a feature whose task list is too large to
complete inside one bounded session. The orchestrator works through the task list one
task-phase at a time, each in its own bounded session, and the feature reaches
completion instead of failing part-way.

**Why this priority**: This is the defect that terminally failed a real feature and
blocked its dependents. Without it, any feature above roughly eight tasks is at risk,
which is most real features. It is a viable standalone slice: chunked execution alone
turns the observed failure into a success.

**Independent Test**: Run a feature whose task list holds 18 tasks across 5 task-phases
under the same per-session turn cap that previously failed it. The feature must reach
completion with every task marked complete.

**Acceptance Scenarios**:

1. **Given** a feature whose task list is organised into 5 task-phases totalling 18
   tasks, and a per-session turn cap of 80, **When** the orchestrator runs the implement
   step, **Then** it executes 5 bounded sessions in task-phase order and the feature
   completes with all 18 tasks marked complete.
2. **Given** a task-phase whose tasks are already all marked complete (for example after
   a resume), **When** the orchestrator reaches that task-phase, **Then** it skips the
   task-phase without dispatching a session.
3. **Given** a session scoped to task-phase 3, **When** that session finishes, **Then**
   only task-phase 3's tasks have been marked complete and no task belonging to a later
   task-phase has been started.
4. **Given** a task list with no recognisable task-phase structure, **When** the
   orchestrator runs the implement step, **Then** it falls back to a single session over
   the whole task list and the run proceeds without error.
5. **Given** that same fallback session exhausts its turn budget having completed at
   least one task, **When** the orchestrator evaluates the outcome, **Then** it
   dispatches a fresh session rather than failing the feature.

---

### User Story 2 - Resume at the failing task-phase (Priority: P2)

An operator sees a feature diverted during implement. From the escalations surface they
resume it, and work restarts at the task-phase that failed — not at the beginning of the
task list — so already-completed work is not redone or overwritten.

**Why this priority**: Chunking without chunk-level resume would still throw away up to
a full feature's worth of completed task-phases on any single failure, and re-running
completed tasks costs money and risks clobbering good work. This is the payoff that
makes chunking safe to rely on.

**Independent Test**: Fail a run deliberately during task-phase 3 of 5, then resume from
the operator surface. Verify the resumed run dispatches its first session scoped to
task-phase 3 and that no task from task-phases 1–2 is re-executed.

**Acceptance Scenarios**:

1. **Given** a feature that failed during task-phase 3 of 5, **When** the operator
   resumes it, **Then** execution restarts at task-phase 3 and task-phases 1–2 are not
   re-dispatched.
2. **Given** the same feature, **When** the operator resumes it, **Then** the operator
   surface offers a starting task-phase that defaults to the recorded failing task-phase
   and lets the operator choose an earlier task-phase instead.
3. **Given** a resume with operator guidance supplied, **When** the resumed run starts,
   **Then** the guidance reaches the first dispatched task-phase session, matching how
   guidance already works for whole pipeline steps.
4. **Given** a feature whose recorded task-phase position is missing or unreadable,
   **When** the operator resumes it, **Then** the system falls back to the first
   task-phase with incomplete tasks rather than failing the resume, and reports that it
   did so.
5. **Given** a feature that failed during task-phase 3 with task-phases 1–2 complete,
   **When** the operator resumes it and the resume discards uncommitted output before
   re-running, **Then** task-phases 1–2's work and their completion marks survive,
   because each task-phase boundary was committed.
6. **Given** a task list regenerated between runs so task-phase numbers have shifted,
   **When** the operator resumes, **Then** the recorded task-phase is located by title
   and the operator is told the match was not by number.

---

### User Story 3 - See which task-phase is running (Priority: P3)

While a run is live, an operator watching the console can tell which task-phase of how
many is currently executing for each feature, which have completed, and when a task-phase
boundary was crossed — without opening transcripts or a shell.

**Why this priority**: implement is by far the longest step; today it shows as a single
opaque cell for tens of minutes, so an operator cannot distinguish healthy progress from
a stall. Visibility is a real operator need but the run completes correctly without it.

**Independent Test**: Start a run and watch the console. At any moment during implement,
the feature's row must state the current task-phase position and total, and the activity
feed must carry one entry per task-phase boundary.

**Acceptance Scenarios**:

1. **Given** a feature executing task-phase 3 of 5, **When** the operator views the
   console, **Then** the feature's implement step shows the current task-phase position,
   the total count, and the task-phase title.
2. **Given** a task-phase completes and the next begins, **When** the operator watches
   the activity feed, **Then** a boundary entry appears identifying the task-phase that
   finished and the one that started.
3. **Given** a run that is no longer active, **When** the operator views its recorded
   state, **Then** the implement step still shows the last known task-phase position
   reconstructed from the recorded run state.
4. **Given** a feature whose task list has no task-phase structure, **When** the operator
   views the console, **Then** the implement step renders exactly as it does today, with
   no empty or misleading task-phase indicator.

---

### User Story 4 - Turn exhaustion with progress is not a failure (Priority: P4)

A single task-phase is large enough to exhaust its own session budget. Because the
session made real progress, the orchestrator continues that same task-phase in a fresh
session rather than failing the feature. A task-phase that exhausts its budget while
completing nothing is treated as genuinely stuck and fails.

**Why this priority**: Chunking shrinks the blast radius but does not remove it — one
oversized task-phase can still exhaust a bounded session by itself. This invariant makes
correctness independent of how coarsely the upstream step happened to group tasks. It is
last only because the first three stories already deliver the operator-visible value.

**Independent Test**: Force a task-phase to exhaust its turn budget after completing at
least one task; verify a fresh session for the same task-phase is dispatched. Then force
one to exhaust its budget having completed nothing; verify the feature fails.

**Acceptance Scenarios**:

1. **Given** a session that exhausts its turn budget having marked at least one
   additional task complete, **When** the orchestrator evaluates the outcome, **Then** it
   dispatches a fresh session for the same task-phase and does not fail the feature.
2. **Given** a session that exhausts its turn budget having marked no additional task
   complete, **When** the orchestrator evaluates the outcome, **Then** it counts the
   attempt against the task-phase's consecutive no-progress bound and continues only
   while that bound is not reached.
3. **Given** repeated turn exhaustion on one task-phase where every attempt completes at
   least one task, **When** the orchestrator evaluates each outcome, **Then** it keeps
   continuing that task-phase until either it finishes or the per-feature session ceiling
   is reached.
4. **Given** consecutive turn-exhausted attempts on one task-phase that complete nothing,
   **When** the configured no-progress limit is reached, **Then** the feature fails
   naming that task-phase as stuck.
5. **Given** a feature that reaches the per-feature implement session ceiling, **When**
   the orchestrator evaluates the outcome, **Then** the feature fails with a reason
   identifying an exhausted feature session budget, distinct from a stuck task-phase.
6. **Given** a session that fails for a reason other than turn exhaustion, **When** the
   orchestrator evaluates the outcome, **Then** the existing transient-versus-terminal
   handling applies unchanged.

---

### Edge Cases

- **No task-phase structure.** A hand-written or older task list without task-phase
  headings must fall back to a single session over the whole task list rather than crash,
  and that session still gets continuation on turn exhaustion (FR-004).
- **Task-phase with no tasks.** A heading carrying no tasks is skipped without
  dispatching a session.
- **Task list rewritten mid-run.** A session may edit the task list. Task-phase
  membership is re-read before each dispatch, so additions and renumbering are picked up
  rather than served from a stale snapshot.
- **Out-of-scope completions.** A session scoped to one task-phase marks tasks belonging
  to a later one. Those completions are respected — later task-phases whose tasks are
  already complete are skipped rather than re-run.
- **All task-phases dispatched, tasks still incomplete.** One sweep session scoped to
  every remaining unchecked task runs first (FR-007). Only if tasks are still unchecked
  after the sweep does the implement step fail, with a reason naming those tasks. The
  step never reports success while unchecked tasks remain.
- **Cost breaker trips mid-implement.** The run's drain-don't-kill rule applies at
  task-phase boundaries: the in-flight task-phase finishes, then the feature halts
  between task-phases instead of running to the end of the task list.
- **Recorded position no longer matches the task list** (regenerated between runs):
  resolve by heading number, then title, then ordinal; only when none match fall back to
  the first task-phase with incomplete tasks. Any match weaker than by number is reported
  to the operator (FR-025a).
- **Duplicate or non-sequential task-phase numbering** in the task list: order of
  appearance in the file is authoritative.
- **Session killed mid-task-phase** (crash, restart, breaker). Uncommitted output from
  the interrupted task-phase is discarded on resume; work from earlier task-phases
  survives because each boundary is committed (FR-023a). The interrupted task-phase is
  re-run whole, never half-applied.

## Requirements *(mandatory)*

### Functional Requirements

**Chunked execution**

- **FR-001**: The system MUST derive an ordered list of task-phases, with their titles
  and member tasks, from the feature's generated task list.
- **FR-002**: The system MUST execute the implement step as one bounded agent session
  per task-phase, in task-list order, instead of a single session covering all tasks.
- **FR-003**: The system MUST skip any task-phase whose tasks are all already marked
  complete, without dispatching a session for it.
- **FR-004**: The system MUST fall back to dispatching one session over the whole task
  list, without error, when the task list contains no recognisable task-phase structure —
  today's behaviour. The
  continuation rules (FR-010–FR-013a) MUST still apply to that single session, so turn
  exhaustion with progress is recoverable on every task list, not only well-formed ones.
- **FR-005**: Each dispatched session MUST be instructed to complete only its assigned
  task-phase, to mark each completed task as complete in the task list, and MUST be
  explicitly released from any instruction to keep working until the whole task list is
  complete.
- **FR-006**: The system MUST re-read the task list before each dispatch so that edits
  made by a previous session are reflected in what the next session is asked to do.
- **FR-007**: When every task-phase has been dispatched and unchecked tasks remain, the
  system MUST dispatch one final sweep session scoped to all remaining unchecked tasks,
  irrespective of which task-phase they belong to.
- **FR-007a**: The implement step MUST report success only when every task in the task
  list is marked complete. If tasks remain unchecked after the sweep session of FR-007,
  it MUST fail with a reason naming the unchecked tasks.
- **FR-007b**: The sweep session MUST run at most once per implement step; a sweep that
  ends in turn exhaustion is subject to the continuation rules (FR-010–FR-013a) but MUST
  NOT trigger a second sweep.
- **FR-008**: Task-phase chunking MUST NOT change the seven-step pipeline model, its
  step ordering, or its existing gate semantics; chunking is internal to the implement
  step.
- **FR-009**: When the cost breaker is tripped, the system MUST halt the feature at the
  next task-phase boundary after the in-flight task-phase finishes, rather than
  abandoning it mid-task-phase or continuing through remaining task-phases.

**Turn exhaustion and continuation**

- **FR-010**: The system MUST distinguish a session that ended by exhausting its turn
  budget from other session outcomes.
- **FR-011**: On turn exhaustion where the count of completed tasks increased during the
  session, the system MUST dispatch a fresh session over the same scope — the same
  task-phase, or the whole task list on the FR-004 fallback path — rather than failing
  the feature.
- **FR-012**: On turn exhaustion where the count of completed tasks did not increase, the
  system MUST count the attempt against the consecutive no-progress bound of FR-013 and
  continue only while that bound is not reached. It MUST NOT fail the feature on a single
  no-progress attempt.
- **FR-013**: The system MUST bound, by configuration, the number of *consecutive*
  continuation attempts on one task-phase that complete no task, and MUST fail the
  feature when that bound is reached. An attempt that completes at least one task MUST
  reset that count, so a large but steadily progressing task-phase is not killed for its
  size.
- **FR-013a**: The system MUST bound, by configuration, the total number of implement
  sessions dispatched for one feature — counting every task-phase session, every
  continuation attempt, and the sweep session — and MUST fail the feature when that
  ceiling is reached, with a reason distinguishing an exhausted feature session budget
  from a stuck task-phase.
- **FR-013b**: The count of implement sessions consumed against the FR-013a ceiling MUST
  be visible to the operator and MUST be recorded in the feature's durable run state. An
  operator-initiated resume MUST reset the count, since resuming is an explicit human
  decision to grant the feature more budget.
- **FR-014**: Session outcomes that are not turn exhaustion MUST continue to be handled
  by the existing transient-versus-terminal retry rules, unchanged.

**Operator visibility**

- **FR-015**: While implement is running, the console MUST show, per feature, the
  current task-phase position, the total number of task-phases, and the current
  task-phase title.
- **FR-016**: The activity feed MUST carry an entry at each task-phase boundary,
  identifying the task-phase that completed and the one that started.
- **FR-017**: Continuation attempts and the reason for them MUST be visible to the
  operator, so repeated attempts on one task-phase are distinguishable from steady
  forward progress.
- **FR-018**: For a run that is no longer active, the reconstructed view MUST show the
  last known task-phase position for the implement step.
- **FR-019**: Features whose task list has no task-phase structure MUST render as they
  do today, with no empty or misleading task-phase indicator.

**Resume**

- **FR-020**: The system MUST record, as part of the feature's durable run state, the
  task-phase currently being executed, updated at each task-phase boundary.
- **FR-020a**: The recorded task-phase MUST be identified by all three of its ordinal
  position in file order, its heading number, and its title, so the position survives a
  task list that is renumbered or retitled between runs.
- **FR-021**: Resuming a feature that was diverted during implement MUST restart at the
  recorded task-phase, not at the first task-phase.
- **FR-022**: The operator resume surface MUST let the operator choose the starting
  task-phase, defaulting to the recorded one, with the same ergonomics the existing
  starting-step picker provides.
- **FR-023**: A resumed run MUST NOT re-execute tasks already marked complete.
- **FR-023a**: The system MUST commit the feature branch at every task-phase boundary,
  not only at the end of the implement step. Resume discards uncommitted output back to
  the last committed boundary before re-running, so without per-task-phase commits a
  resume at task-phase 3 would destroy the completed work — and the completion marks — of
  task-phases 1 and 2, contradicting FR-023.
- **FR-023b**: Per-task-phase commits MUST be collapsed into the feature's single
  terminal commit on success, exactly as existing per-step commits are, so chunking adds
  no commit noise to a completed feature's history. On a non-success terminal state the
  per-task-phase commits MUST remain as the post-mortem trail.
- **FR-024**: Operator guidance supplied at resume MUST reach the first dispatched
  task-phase session, matching existing whole-step resume behaviour.
- **FR-025**: Resume MUST locate the recorded task-phase in the current task list by
  matching on heading number, then title, then ordinal position, in that order. When the
  recorded position is missing, unreadable, or matches none of the three, resume MUST
  fall back to the first task-phase with incomplete tasks rather than failing.
- **FR-025a**: When resume resolves the recorded task-phase by a weaker match than its
  number, or falls back entirely, that MUST be reported to the operator, so a silently
  relocated resume is distinguishable from an exact one.

**Diagnosability**

- **FR-026**: Each dispatched session MUST produce its own distinguishable durable
  transcript, identifying the feature, its scope (the task-phase, or the sweep), and the
  attempt number.
- **FR-027**: A phase transcript MUST record the session's failure detail, not only its
  status, so an operator can determine the cause of a failure from the operator surfaces
  without reading agent-tool logs.

### Key Entities

- **Task Plan**: The ordered set of task-phases derived from a feature's generated task
  list, together with each task-phase's completion state. Derived, never authoritative —
  the task list file itself remains the source of truth and is re-derived before each
  dispatch.
- **Task Phase**: One numbered, titled section of the task plan, holding an ordered set
  of tasks. The unit of work for one bounded session.
- **Task**: A single identified work item within a task-phase, either complete or
  incomplete.
- **Chunk Attempt**: One dispatched session for one task-phase, carrying an attempt
  number, an outcome, and a count of tasks completed during it. Multiple attempts on one
  task-phase arise from continuation after turn exhaustion. The sweep session (FR-007) is
  a chunk attempt whose scope is every remaining unchecked task rather than one
  task-phase.
- **Run State Record** (existing, extended): The feature's durable position marker, today
  holding the pipeline step; extended with the task-phase position within implement
  (ordinal, number and title per FR-020a) and the count of implement sessions consumed
  against the per-feature ceiling.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A feature whose task list holds 18 tasks across 5 task-phases completes the
  implement step end-to-end under the same per-session turn cap (80) that previously
  failed it — the exact production case observed on 2026-07-25.
- **SC-002**: Zero features are terminally failed on a single turn-exhausted session that
  made forward progress. Every implement failure reported to an operator names exactly one
  of: a stuck task-phase, an exhausted feature session budget, unchecked tasks surviving
  the sweep, or a non-exhaustion cause.
- **SC-003**: An operator can determine which task-phase of how many is executing for any
  running feature from the console alone, within 5 seconds of a task-phase boundary, with
  no shell access and no transcript reading.
- **SC-004**: A resume after a task-phase failure re-executes zero already-completed
  tasks.
- **SC-005**: Feature task lists with no task-phase structure produce no new failures and
  no changed console rendering relative to before this feature, while still gaining
  continuation on turn exhaustion.
- **SC-006**: Given only the operator surfaces, the cause of a failed implement step is
  identifiable without inspecting agent-tool logs — the gap that made the 2026-07-25
  failure take a manual investigation to diagnose.
- **SC-007**: Chunking adds no more than 20% to the implement step's total cost for a
  feature that previously completed in a single session, measured against a comparable
  run.

## Assumptions

- **Task-phase structure is stable.** Generated task lists carry ordered, numbered,
  titled task-phase sections, as produced by the upstream task-generation step. Order of
  appearance in the file is authoritative when numbering is duplicated or non-sequential.
- **Scoped instructions are honoured.** The implementation agent's published contract
  accepts an optional task filter and already organises its own work task-phase by
  task-phase, so scoping a session to one task-phase is supported behaviour rather than a
  workaround.
- **Task-list completion marks are the progress signal.** Counting completed tasks in the
  task list before and after a session is the measure of forward progress. No separate
  progress channel is assumed.
- **Sequential chunks.** Task-phases run one at a time per feature. Parallelism stays at
  the existing across-feature level; parallel task-phases within one feature are out of
  scope.
- **Turn cap unchanged.** The existing per-session turn cap is reused per task-phase
  rather than replaced. Raising the cap is an independent, still-available knob.
- **Bound defaults.** Absent a stated preference: two consecutive no-progress attempts on
  one task-phase (FR-013), and a per-feature ceiling of twice the task-phase count plus
  four sessions (FR-013a), which comfortably covers one continuation per task-phase and
  the sweep while still stopping a runaway.
- **Resume parity means a picker.** "Same behaviour as other pipeline steps" is read as:
  the escalations surface offers a task-phase picker defaulting to the recorded position,
  alongside the existing starting-step picker and optional guidance field.
- **Per-chunk cost overhead is accepted.** Each session re-reads the feature's planning
  documents, so chunking adds setup cost per task-phase. This is accepted in exchange for
  bounded sessions; the offsetting saving is that late tasks no longer carry the whole
  earlier session's history (the failed run reached 131k cached input tokens by turn 81).
- **Existing worktree, checkpoint, and cost-breaker semantics are reused**, not
  reimplemented — this feature extends them with a sub-step dimension.
