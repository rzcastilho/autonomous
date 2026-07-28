# Feature Specification: Unified Run-State Persistence

**Feature Branch**: `018-unified-run-persistence`

**Created**: 2026-07-27

**Status**: Draft

**Input**: User description: "Let's implement a persistence layer to replace the current model where we use some files distributed accross application. The persistence must consider all run state from a repository, including current runs, checkpoints, escalations, configurations, transcripts, and any addictional information that allow to continue an execution from a checkpoint, with or witout failures, and check previous success and failure runs from a repository."

## Clarifications

### Session 2026-07-27

- Q: What does a run do when recording state fails mid-run (the store becomes unwritable after a successful start)? → A: Drain-and-halt — the in-flight phase finishes, no new phase or feature starts, the run halts between phases with a persistence-failure reason, and the run record is flagged incomplete.
- Q: Which operator surface exposes run history, run detail, pruning, and export? → A: Both — the programmatic facade is the contract (queries, prune, export), and the console renders it with a history list and a run-detail view; the console holds no query logic of its own.
- Q: How is growth bounded, given transcripts are stored and history is kept forever? → A: Keep everything; nothing is ever removed automatically. Pruning is the operator's action alone. When stored volume nears the capacity ceiling, the system refuses to start a new run until the operator prunes, rather than dropping or overwriting anything.
- Q: How are secrets that a tool may have echoed into a phase transcript handled? → A: No special handling — transcripts are stored and exported verbatim, with no redaction at write or at export. Secret hygiene in tool output is the operator's responsibility; the exclusion of secrets from recorded settings (FR-028) is unaffected.
- Q: What form does a run export take? → A: A single self-describing, machine-readable structured data file per run, with transcript content embedded as fields — one run, one artifact.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume an interrupted run from one authoritative record (Priority: P1)

An operator's orchestration run is interrupted — the machine restarts, the process
crashes mid-phase, the cost breaker drains the run, or a feature escalates for human
input. The operator returns later, asks the system what is resumable for the target
repository, and continues from the last durable position. Everything the resume needs
— which features exist, which finished, where each stopped, the settings the run was
started under, and what the last phase produced — comes from one authoritative record
for that run, not from several separate files that can disagree with each other.

**Why this priority**: Resumability is the whole point of durable state, and today it
is the state most at risk: the run record, the per-feature checkpoints, and the
transcripts are written independently, so a crash between two of those writes leaves a
record that disagrees with itself. Delivering only this story already gives a complete,
useful product: interrupted runs continue correctly.

**Independent Test**: Start a run, interrupt it at an arbitrary point (including
between two state writes), then ask the system to resume. Verify the resumed run
restarts each feature at the correct phase, under the original run settings, and that
no feature is silently dropped, duplicated, or re-run past a phase it already
completed.

**Acceptance Scenarios**:

1. **Given** a run that halted between phases because the cost breaker tripped, **When**
   the operator resumes it, **Then** each incomplete feature restarts at the phase
   recorded for it, the completed features are not re-run, and the resumed run uses the
   settings captured when the run first started.
2. **Given** a run whose process was killed in the middle of writing state, **When** the
   operator inspects what is resumable, **Then** the system reports either the complete
   prior state or the complete state after the interrupted write — never a half-applied
   mixture — and never reports a feature in a state it did not reach.
3. **Given** a feature that escalated for human input and was then resolved by the
   operator, **When** the run is resumed, **Then** that feature continues from its
   recorded phase and the escalation is preserved in the record as resolved rather than
   erased.
4. **Given** a stored record that is unreadable or internally inconsistent, **When** the
   operator asks to resume, **Then** the system reports the problem explicitly and
   refuses to resume, rather than inventing a plausible state.
5. **Given** a run for repository A and a run for repository B on the same machine,
   **When** the operator resumes repository A, **Then** only repository A's state is
   read or modified.

---

### User Story 2 - Review past runs for a repository (Priority: P2)

An operator wants to know how a target repository has fared over time: which runs
succeeded, which failed, which were halted or escalated and why, what each cost, and
how long each took. Today a run is superseded the moment a new one starts, so this
history does not exist. The operator asks for the run history of a repository and gets
a list of completed and in-flight runs with their outcomes, ordered most recent first.

**Why this priority**: History is the second-largest gap and is independently valuable
— it answers "has this ever worked?", "what did we spend?", and "which feature keeps
escalating?" — but the system remains usable without it, so it ships after resume.

**Independent Test**: Complete several runs against the same repository with different
outcomes (all-done, halted, escalated, failed), then request that repository's run
history. Verify every run appears exactly once with the correct outcome, timing, and
cost, and that starting a new run does not remove or alter any earlier one.

**Acceptance Scenarios**:

1. **Given** three completed runs for a repository with different outcomes, **When** the
   operator requests the run history, **Then** all three appear with their outcome, start
   and end times, total cost, and per-feature terminal statuses.
2. **Given** an in-flight run, **When** a second run is started for the same repository,
   **Then** the earlier run is retained in history with its state at the point it was
   superseded, and is distinguishable from the current one.
3. **Given** run history for repository A, **When** the operator requests history for
   repository B, **Then** only repository B's runs are returned.
4. **Given** a repository with no recorded runs, **When** the operator requests its
   history, **Then** the system returns an empty history rather than an error.

---

### User Story 3 - Inspect the full record of one run (Priority: P3)

An operator investigating a failure opens one run and sees everything that happened:
each feature, each phase attempt with its outcome and cost, the model used, every
escalation with its reason, every auto-remediation attempt, and the phase transcripts —
without hunting across the worktree directory, the transcript directory, and the run
record.

**Why this priority**: Post-mortem depth builds on the history list from US2 and is
where the "distributed files" pain is felt most acutely, but an operator can still
diagnose from raw files today, so it follows the two stories that unlock capabilities
that do not exist at all.

**Independent Test**: Take a run that escalated after auto-remediation exhausted its
attempts, open its full record, and verify the phase sequence, every remediation
attempt, the escalation reason, the effective settings, the cost breakdown, and the
transcript for each phase are all reachable from that one record.

**Acceptance Scenarios**:

1. **Given** a completed run, **When** the operator opens it, **Then** every feature's
   phase sequence is shown in execution order with each phase's outcome, cost, model,
   and duration.
2. **Given** a feature that escalated, **When** the operator opens that feature's record,
   **Then** the escalation reason, the phase that raised it, and the evidence that
   triggered it are present.
3. **Given** a feature whose worktree was removed after it completed, **When** the
   operator opens its record, **Then** its phase transcripts are still retrievable.
4. **Given** a feature that ran a bounded auto-remediation loop, **When** the operator
   opens its record, **Then** each remediation attempt is listed individually with its
   outcome and cost, and the attempt limit and severity threshold in force are shown.

---

### Edge Cases

- **Interrupted write**: the process dies while state is being recorded — a reader must
  see either the pre-write or the post-write state, never a partial one.
- **Concurrent writers**: several features run in parallel and record phase results at
  the same instant; no update may be lost or overwrite another feature's update.
- **Two repositories, one machine**: state for one repository is never read into, or
  overwritten by, a run for another repository, including repositories with the same
  directory name from different origins.
- **Repository with no identifiable origin**: state is still recorded and retrievable
  without silently sharing a bucket with a different such repository.
- **Store unavailable or unwritable at run start**: the run fails loudly at start rather
  than proceeding to spend money it cannot record.
- **Store becomes unwritable mid-run**: the run drains and halts between phases with a
  persistence-failure reason and an incomplete-record flag; the in-flight phase is not
  aborted, and no further work starts (FR-010).
- **Store becomes writable again**: the halted run resumes from the last successfully
  recorded position, with the possible gap between that position and the work actually
  completed surfaced to the operator rather than assumed away (FR-010a, FR-018).
- **Very large transcript** for a long phase: recording it must not stall the run or
  make the run history unreadable.
- **A run superseded while in flight**: its features are marked as ended-by-supersession,
  distinguishable from features that genuinely completed or failed.
- **Cost accounting across a resume**: a resumed run's spend is attributable, so total
  spend for the work is not double-counted nor lost.
- **Clock movement** (restart, timezone change, machine sleep): ordering of runs and of
  phases within a run remains stable and correct.
- **Retention limit reached**: pruning old runs never removes state a resumable run
  depends on.
- **Capacity headroom exhausted**: a new run is refused with a message naming the shortfall
  and what pruning would reclaim; the in-flight run (if any) is untouched, and history,
  detail, export, and pruning all stay available so the operator can act.
- **Ceiling hit mid-run**: treated as a write failure — drain and halt (FR-010); no
  recorded state is discarded to make room.

## Requirements *(mandatory)*

### Functional Requirements

**Single authoritative store**

- **FR-001**: The system MUST record all run state for a target repository in one
  authoritative store, so that no two independently-written locations can disagree about
  the same fact.
- **FR-002**: The store MUST hold, for every run: the run's identity and lifecycle
  (start, end, outcome), the features in it and their terminal statuses, every phase
  attempt with its outcome, the checkpoints needed to resume, every escalation, the
  settings the run was started under, the cost recorded, and the phase transcripts.
- **FR-003**: Every consumer of run state — the resume path, the recovery
  reconciliation, the operator console, and status reporting — MUST read from this store
  as the single source of truth; no consumer may depend on a second, separately
  maintained copy of the same state.
- **FR-004**: State MUST be partitioned by target repository identity, such that reading
  or writing one repository's state can never read or modify another's, including two
  checkouts with the same directory name from different origins.
- **FR-005**: The store MUST remain outside the target repository's own working tree, so
  that recorded state is never committed to, or destroyed by, target-repository
  operations such as worktree removal or branch switching.

**Durability and integrity**

- **FR-006**: A state update MUST be all-or-nothing: after any interruption, a reader
  MUST observe either the complete pre-update state or the complete post-update state.
- **FR-007**: Concurrent updates from features running in parallel MUST all be recorded
  without loss, and MUST NOT overwrite one another.
- **FR-008**: The system MUST distinguish absent state, complete state, and damaged
  state, and MUST report damaged state explicitly rather than substituting defaults or
  inferring missing values.
- **FR-009**: The system MUST verify at run start that the store is reachable and
  writable, and MUST fail the run loudly at start if it is not.
- **FR-010**: If recording fails after a successful run start, the system MUST drain and
  halt rather than continue silently: the in-flight phase MUST be allowed to finish, no
  further phase and no further feature MUST be started, the run MUST halt between phases
  with a reason naming the persistence failure, and the run's record MUST be flagged
  incomplete so history shows it as such. This mirrors the cost breaker's drain-don't-kill
  behaviour; it MUST NOT abort mid-phase and MUST NOT continue in a degraded mode.
- **FR-010a**: A run halted by a persistence failure MUST be resumable once the store is
  writable again, from whatever position was last successfully recorded, and the resumed
  run MUST report that a gap may exist between the last recorded position and the work
  that actually completed (reconciled per FR-018).
- **FR-011**: Recorded state MUST survive process restart, machine restart, and removal
  of any target-repository worktree.

**Resume from checkpoint**

- **FR-012**: For every feature that has not reached a successful terminal state, the
  store MUST hold enough information to resume it: the phase to restart at, its status
  and reason, its identity and location, and the position within a phase where a phase
  records sub-steps.
- **FR-013**: A checkpoint MUST be recorded after every successfully completed phase, not
  only when a feature terminates, so an interruption mid-run always has a current restore
  point.
- **FR-014**: A resume MUST reapply the settings captured when the run started, so the
  resumed work runs under the original run shape unless the operator explicitly overrides
  them.
- **FR-015**: A resume MUST work for both failure-free interruptions (breaker drain,
  operator stop, machine restart) and failure interruptions (phase failure, crash,
  escalation), with the same record shape.
- **FR-016**: The system MUST let an operator ask what is resumable for a repository and
  answer without starting any work.
- **FR-017**: Resuming MUST NOT re-execute a phase already recorded as successfully
  completed, and MUST NOT skip a phase that was not.
- **FR-018**: A run's recorded state MUST be reconcilable against the target
  repository's actual evidence, and any disagreement MUST be reported to the operator
  rather than resolved silently.

**Run history**

- **FR-019**: Starting a new run MUST NOT destroy or overwrite the record of any prior
  run for the same repository.
- **FR-020**: Every run MUST carry a stable identifier that is unique within a
  repository's history and is stable across resumes of that run.
- **FR-021**: The system MUST return a repository's run history — successful and
  unsuccessful runs alike — with each run's outcome, start and end time, duration, total
  cost, and per-feature terminal statuses, ordered most recent first.
- **FR-022**: The system MUST support retrieving the full detail of a single run:
  per-feature phase sequences with outcome, model, cost, and duration; every escalation
  with its reason and originating phase; every auto-remediation attempt with its outcome;
  and the transcript of each phase.
- **FR-023**: A run in flight MUST be distinguishable from a completed run in the
  history, and a run that was superseded while in flight MUST be distinguishable from one
  that reached its own terminal state.
- **FR-024**: History MUST be filterable by outcome and by feature, so an operator can
  find, for example, every run in which a given feature escalated.

**Escalations, configuration, and transcripts as first-class records**

- **FR-025**: Every escalation and every halt MUST be recorded as an explicit entry
  carrying the feature, the phase that raised it, the reason, the evidence that triggered
  it, and the time — retrievable without re-reading target-repository files.
- **FR-026**: An escalation's resolution MUST be recordable against the original entry so
  the history shows both that it happened and that it was resolved; resolving MUST NOT
  erase the entry.
- **FR-027**: The settings in force for a run MUST be recorded with the run, and any
  change applied to a live run MUST be recorded with the point at which it took effect,
  so the record explains why later work behaved differently from earlier work.
- **FR-028**: Recorded settings MUST exclude credentials and secrets by construction.
- **FR-029**: Every phase transcript MUST be retrievable from the run's record after the
  corresponding worktree has been removed.
- **FR-029a**: Transcripts MUST be recorded verbatim — a faithful copy of the phase output.
  The system MUST NOT redact, scrub, filter, or otherwise transform transcript content,
  either when recording it or when exporting it. FR-028's exclusion of secrets from
  recorded *settings* is unchanged and continues to apply.
- **FR-030**: Recording a transcript MUST NOT block or materially delay the run, and
  MUST NOT make the run history listing slow to retrieve.

**Operator surfaces**

- **FR-030a**: Every capability in this feature — asking what is resumable, listing run
  history, filtering it, retrieving a run's full detail, retrieving a transcript, pruning,
  and exporting — MUST be available as a programmatic operator function that works with no
  user interface present. That programmatic surface is the contract these requirements are
  verified against.
- **FR-030b**: The operator console MUST render that same surface: a run-history list for
  the current repository and a run-detail view reachable from it, including escalations,
  per-phase attempts, remediation attempts, and on-demand transcript retrieval.
- **FR-030c**: The console MUST call the programmatic surface for every query; it MUST NOT
  read the store directly, hold its own query logic, or maintain a parallel copy of run
  state. It stays an observability surface over one source of truth.

**Lifecycle and operations**

- **FR-031**: The system MUST let an operator remove run history older than a chosen
  boundary, and pruning MUST NOT remove state that any resumable run depends on.
- **FR-031a**: Operator-initiated pruning MUST be the only mechanism that removes recorded
  state. The system MUST NOT expire, roll over, overwrite, downsample, or truncate any run
  record or transcript on its own, at any age or volume.
- **FR-031b**: The system MUST track stored volume against a capacity ceiling and MUST
  refuse to start a new run once a configured headroom threshold is crossed, reporting the
  shortfall and what pruning would reclaim. Refusing to start is required behaviour, not a
  failure mode: it is how FR-031a's no-automatic-deletion guarantee is kept.
- **FR-031c**: The capacity refusal MUST NOT affect a run already in flight, and MUST NOT
  block read-only operations — history, run detail, transcript retrieval, export, and
  pruning MUST all remain available while a start is being refused, since pruning is the
  operator's way out.
- **FR-031d**: If the capacity ceiling is reached while a run is in flight, the resulting
  write failure MUST be handled by FR-010 (drain and halt), never by discarding state to
  make room.
- **FR-031e**: Before pruning, the operator MUST be able to see what a given prune boundary
  would remove and how much it would reclaim, without performing it.
- **FR-032**: The system MUST let an operator export a single run's full record for
  sharing or archival, and the export MUST be readable without the system that produced
  it.
- **FR-032a**: An export MUST be exactly one self-describing, machine-readable structured
  data file per run, carrying the run, its features, every phase attempt, every checkpoint,
  every escalation, every remediation attempt, the recorded settings, the cost entries, and
  the transcript content embedded as fields. It MUST NOT be a directory, an archive, or a
  set of side files.
- **FR-032b**: An export MUST be self-contained: it MUST NOT reference the store, a
  worktree, or any path on the exporting machine in order to be read, and it MUST carry a
  format version so a reader can tell what it is holding.
- **FR-032c**: Exporting MUST NOT modify, lock, or prune anything in the store, and MUST be
  available while a run is in flight (exporting the state recorded so far) and while a
  capacity refusal is in effect (FR-031c).
- **FR-033**: The system MUST record, per repository, an ordering of runs that stays
  correct across process restarts and clock changes.
- **FR-034**: A repository MUST have at most one run in flight at a time. Starting a run
  for a repository that already has one in flight MUST mark the existing run superseded
  and retain it in history (FR-019, FR-023); it MUST NOT delete it and MUST NOT leave two
  runs in flight for the same repository.
- **FR-035**: Phase transcript content MUST be held inside the store itself, recorded
  with the phase attempt it belongs to, so a transcript and the phase record it describes
  cannot be separated, lost independently, or pruned out of step with one another.
- **FR-036**: Retrieving a repository's run history or a run's summary MUST NOT require
  loading transcript content, so history stays responsive regardless of how much
  transcript volume is stored (FR-030, SC-009).
- **FR-037**: This feature is a clean break: the store is used for runs started after it
  is adopted. The system MUST NOT read, write, or import the pre-existing distributed
  file format. Where a pre-existing file location is no longer authoritative, the system
  MUST NOT keep writing to it, so no second copy of the same fact survives (FR-003).

### Key Entities

- **Repository**: a target repository the orchestrator builds against, identified stably
  by its origin rather than by its local path; owns all runs recorded for it.
- **Run**: one orchestration attempt over a set of features for a repository. Has a
  stable identifier, a start and end time, a lifecycle state (in flight, completed,
  superseded), an outcome, a total cost, and the settings it was started under.
- **Run Settings**: the run-shaping values captured when a run starts and reapplied on
  resume (concurrency, budget, workflow toggles, per-phase model routing, remediation
  bounds). Contains no secrets. Amendments applied to a live run are recorded with their
  effective point.
- **Feature Run**: one feature's participation in a run — its identity, its dependency
  prerequisites, its current or terminal status, its phase sequence, and its worktree
  location while one exists.
- **Phase Attempt**: one execution of one pipeline phase for a feature — phase name,
  attempt ordinal, start and end time, outcome, model used, cost, and any sub-step
  position for phases that record internal progress.
- **Checkpoint**: the durable resume pointer for a feature — the phase to restart at,
  the status and reason at that point, and any within-phase position. Superseded by each
  newer checkpoint for the same feature within a run.
- **Escalation**: an explicit human-handoff or halt record — feature, phase, severity,
  reason, triggering evidence, time raised, and optional resolution.
- **Remediation Attempt**: one iteration of the bounded pre-gate auto-remediation loop —
  its ordinal, the findings it acted on, its outcome, its cost, and the limit and
  threshold in force.
- **Transcript**: the recorded output of one phase attempt, held in the store alongside
  that attempt and retrievable after its worktree is gone. Retrieved on demand, never as
  part of a history listing.
- **Cost Entry**: a recorded charge attributable to a run, feature, and phase attempt,
  distinguishing an actual reported amount from an estimate.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of runs interrupted at an arbitrary point — including during a state
  write — resume to the correct per-feature phases, verified across a suite of injected
  interruption points covering every phase boundary.
- **SC-002**: After any interruption, a reader never observes partial state: 0
  occurrences of a half-applied update across repeated interrupt-and-read trials.
- **SC-003**: An operator can determine whether a repository has a resumable run, and at
  which phases, in a single request, without starting any work.
- **SC-004**: 100% of completed runs remain retrievable after subsequent runs start;
  starting a run destroys 0 prior run records.
- **SC-005**: An operator can answer "did this repository's last five runs succeed, and
  what did they cost" from one request, with no manual file inspection.
- **SC-006**: 100% of phase transcripts for completed features remain retrievable after
  their worktrees are removed.
- **SC-007**: All state consumers (resume, recovery reconciliation, operator console,
  status report) read from the one store; 0 remaining code paths read a second
  independently-written copy of the same fact, and 0 console code paths query the store
  directly rather than through the programmatic surface.
- **SC-007a**: 100% of this feature's capabilities are exercisable, and are verified, with
  no user interface running.
- **SC-008**: With the maximum supported number of features running in parallel, no state
  update is lost: recorded phase attempts equal executed phase attempts, exactly.
- **SC-009**: Retrieving a repository's run history stays responsive as history grows —
  listing remains fast enough for interactive use at 500 recorded runs, and listing time
  is unaffected by stored transcript volume.
- **SC-010**: Recording state adds no more than a negligible fraction of a phase's own
  duration, so total run wall-clock is not measurably increased.
- **SC-011**: Damaged or unreadable state is always reported as such: 0 cases where the
  system substitutes a default or infers a value for state it could not read.
- **SC-012**: A repository never has two runs in flight simultaneously, across all
  start/resume/supersede sequences exercised; every superseded run remains retrievable.
- **SC-013**: When the store is made unwritable mid-run, 0 phases are aborted mid-flight,
  0 further phases start, and the run is reported halted with a persistence-failure reason
  and an incomplete record in 100% of trials.
- **SC-014**: 0 run records and 0 transcripts are ever removed without an explicit operator
  prune, at any stored age or volume.
- **SC-015**: With headroom exhausted, 100% of new-run starts are refused with a message
  naming the shortfall and the reclaimable amount, while history, run detail, transcript
  retrieval, export, and pruning remain fully available.
- **SC-016**: An exported run is fully readable on a machine with no access to the store
  that produced it: 100% of the run's features, phase attempts, escalations, remediation
  attempts, settings, cost entries, and transcripts are recoverable from the single
  exported file alone, with 0 external references required.

## Assumptions

- The store is local to the machine running the orchestrator; no remote or multi-machine
  shared store is required, and no cross-machine run coordination is in scope.
- Only the orchestrator writes to the store. External processes may read exports but are
  not supported as writers.
- Git worktrees, branches, and the target repository's own spec artifacts (`spec.md`,
  `plan.md`, `tasks.md`, the constitution) remain in the target repository and are **not**
  moved into the store; the store records references to them and the outcomes derived
  from them.
- The store keeps everything until an operator prunes. There is no automatic retention,
  expiry, or rollover at any age or volume (FR-031a). Because transcript content lives in
  the store (FR-035) and transcripts are the bulk of stored volume, operator pruning is
  also the only mechanism that reclaims space.
- The consequence is accepted deliberately: an operator who never prunes will eventually
  be refused a new run (FR-031b). Refusing to start is preferred to deleting recorded
  history without being asked.
- Adoption is a clean break (FR-037). Any run interrupted at the moment of adoption is
  finished or abandoned on the old path before cutting over; the operator accepts this.
  Pre-existing on-disk state may be deleted manually and is never read by the new system.
- One run in flight per repository (FR-034) means run-scoped worktree partitioning, a
  per-run cost breaker, and cross-run write isolation are all unnecessary — the existing
  single-run concurrency model carries over unchanged.
- "Repository identity" continues to mean identity derived from the origin remote, with a
  defined fallback for a repository that has none.
- Existing behavioural contracts are unchanged by this feature: the clarify and analyze
  gates, the cost breaker's drain-don't-kill rule, worktree retention on non-successful
  terminal states, and the bounded pre-gate remediation loop all behave exactly as they
  do today — only where their state is recorded changes.
- Cost figures continue to prefer actually reported spend and fall back to per-phase
  estimates, and the record distinguishes the two.
- **Accepted risk, transcript content**: a phase transcript is raw tool output and may
  contain credentials or other sensitive material that a tool echoed. Transcripts are
  stored and exported verbatim (FR-029a), and moving them into the store makes them durable
  past worktree teardown, so the store and any export inherit the sensitivity of their
  contents. Protecting them — filesystem permissions on the store, care before sharing an
  export — is the operator's responsibility, deliberately chosen over redaction that could
  corrupt a transcript's diagnostic value.
- The operator console remains an observability surface over the store and never becomes
  a second source of truth.

## Dependencies

- **Constitution amendment — RESOLVED (2026-07-27, v1.2.0 → v1.3.0).** The Technology
  Stack section previously stated "there is no database — run/checkpoint state is
  file-backed". It now carries a normative `Persistence (run state)` subsection adopting
  **Mnesia** (part of the Erlang/OTP runtime) as the store, single-node and machine-local,
  transactional, with bulk content held out of RAM and never loaded by a history listing.
  Planning is unblocked and MUST satisfy that subsection.
- Existing state producers and consumers must all be cut over together: run manifest,
  per-feature checkpoints, transcripts, recovery reconciliation, the console read model
  and projection, and status reporting. Because this is a clean break (FR-037), a partial
  cutover would leave two authoritative locations and violate FR-003.
- The repository-identity derivation and the run-directory layout resolution are inputs
  to how state is partitioned; both already exist and are assumed stable.

## Out of Scope

- Moving target-repository artifacts (specs, plans, tasks, source, git worktrees) into
  the store.
- Migrating, importing, or reading pre-existing distributed-file state (FR-037); no
  backward-compatible read path and no legacy fallback.
- More than one concurrent run per repository (FR-034), and everything it would require:
  run-scoped worktree partitioning, per-run budgets, cross-run write isolation.
- Remote, shared, or multi-machine state; run coordination across machines.
- Analytics, dashboards, or aggregate reporting beyond the history list and single-run
  detail described above.
- Changing any gate, breaker, or pipeline decision behaviour.
- Storing credentials or any secret material as recorded *settings* (FR-028).
- Redacting, scrubbing, or filtering transcript content, at write or at export (FR-029a).
- Encrypting the store at rest, or any access control beyond the host filesystem's.
