# Feature Specification: Recovery State Reconciliation

**Feature Branch**: `014-recovery-reconciliation`

**Created**: 2026-07-24

**Status**: Draft

**Input**: User description: "Improve the persistence files to recovery from restarts and crashes, it must be possible to continue processing a breakdown wave, or a ad-hoc specification after crashes and restarts, the persistence must be handled by repository. For example, now I restart the application to execute waves in ../quickpoll/ repo, if you look at first-wave breakdown, the 001 specification are done, the PR are pushed to the repo, but the 001 spec is showing running, in this scenario it must shows as done and I can continue to the next spec 002. We have to check all persistent files to cover all possible states to be possible to recover and continue the process."

## Overview

Feature 009 made a crashed run resumable from on-disk state, but its recovery
mapping is optimistic-cache-only: it trusts the run manifest's recorded status
and, for any feature that was mid-flight, blindly resets it to "start over"
(`running` → re-run from scratch). The manifest is only as fresh as the last
moment the orchestrator wrote it. A crash between the moment a feature's work
actually finished (its final phase ran, the branch was committed, the PR was
pushed) and the moment the manifest recorded that terminal status leaves the
manifest **stale**: it still says `running` for a feature that is, on the ground,
**done**.

This is not hypothetical — it is the current live state of the `quickpoll`
first-wave run. The manifest shows feature `001` as `running`, yet every durable
artifact proves it completed: all seven phase transcripts are on disk through
`converge` (which ended with its explicit ready marker), the PR record was
written, and the pushed branch carries an OPEN pull request. On the next start
the orchestrator would re-run `001` from scratch — spending budget again, and
risking a duplicate PR — instead of recognizing `001` as done and releasing its
dependent `002`.

The fix reframes recovery around a single principle the user named directly:
**the repository is the source of truth, not the manifest.** On recovery, before
deciding what to do next, the orchestrator MUST reconcile each feature's recorded
status against the ground truth durably recorded outside the manifest — the
feature's own phase artifacts and the git/PR state of its branch — and correct
any status the manifest got wrong. A feature the repository shows as finished is
marked done and unblocks its dependents; only a feature the repository shows as
genuinely incomplete is re-run, and then only from its last clean phase boundary.

This covers **all** persistence files and **all** feature states — running,
pending, and each terminal state — for both run shapes the orchestrator drives: a
breakdown wave and a single ad-hoc specification. It builds on 009's mechanics
(checkpoints, manifest, per-phase commits, the `resume` entry points); it adds
the reconciliation layer that makes those mechanics trustworthy after a real
crash. It introduces no datastore — git and the existing JSON pointer files
remain the only persistence.

## Clarifications

### Session 2026-07-24

- Q: When the manifest and the repository disagree about a feature's status,
  which wins? → A: **The repository wins.** The manifest is treated as an
  optimistic cache; on recovery it is reconciled against, and corrected by, the
  durable per-feature artifacts and the git/PR state of the feature's branch.
- Q: What counts as durable proof that a feature is "done" for a PR-workflow run?
  → A: The feature's branch exists and carries the feature's committed work, and
  a pull request for that branch has been opened (recorded by the durable PR
  record and/or discoverable on the remote). Merge is a human action and is not
  required for the orchestrator to consider the feature done and release
  dependents.
- Q: Is reconciliation automatic on boot, or operator-initiated like 009's
  resume? → A: **Operator-initiated**, consistent with 009 (FR-014): the system
  reports an accurate, reconciled picture of the resumable run but starts no
  phase work until the operator triggers resume. Reconciliation is read-only
  status correction; it never spends budget on its own.
- Q: Which durable evidence is the authoritative "done" signal for a `running`
  feature? → A: **The PR record.** In a PR-workflow run, the durable PR record
  (`pr.json`) present together with the pushed branch is authoritative — PR push
  is the final lifecycle step, so its record existing implies every prior phase
  (through converge) succeeded. A non-PR-workflow run falls back to the
  final-phase transcript's success marker plus the committed branch.
- Q: When are the corrected statuses persisted — immediately on reconciliation, or
  only when the operator continues? → A: **Immediately on reconciliation.** Recovery
  rewrites the manifest with corrected statuses at reconcile time, so a subsequent
  restart reads the already-correct picture and never re-derives from stale data.
  A status-only rewrite runs no phase and spends no budget, so read-only-w.r.t.-work
  (FR-010) still holds.
- Q: When reconciliation flags a feature as a conflict (self-contradictory
  evidence), how does it affect the run's release? → A: **Held like a human gate,
  dependents blocked, rest of the run continues.** A conflict-flagged feature is
  held for human resolution (gate-like, per Principle V); its dependents stay
  blocked, but independent features elsewhere in the DAG still release and run —
  one bad feature never freezes the whole run.
- Q: Does recovery depend on network/remote reachability? → A: **Offline-first.**
  Reconciliation runs from local durable state (`pr.json` + git branch) alone; a
  live remote query is used only as a fallback when the local PR record is
  absent/corrupt, and remote-unreachable is treated as "no extra evidence," never
  a recovery failure — recovery works when GitHub/the network is down.
- Q: When checkpoint, transcripts, and git disagree, which sets a mid-run
  feature's resume point? → A: **The latest committed phase boundary in git.** A
  phase's work isn't complete until its boundary commit lands, so resume from the
  phase after the latest git boundary commit — guaranteeing a clean worktree and
  never skipping a phase whose transcript was written but whose commit never
  landed. Checkpoint and transcripts corroborate but are not authoritative.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Reconcile a stale "running" feature that actually finished (Priority: P1)

An operator restarts the orchestrator against a target repo whose in-flight run
was interrupted. One feature was recorded as `running` in the manifest, but its
work had in fact completed before the crash: its branch is committed and its PR
is pushed. On recovery the operator sees that feature reported as **done**, its
dependent feature released as the next runnable work, and can continue the run
from there without re-running the finished feature.

**Why this priority**: This is the exact failure the user reported and the whole
point of the feature. Without it, recovery re-does completed, paid-for work and
can create duplicate PRs — the run cannot be trusted to continue correctly after
any crash. Delivering only this story already restores correct continuation for
the most common crash window.

**Independent Test**: Reproduce the `quickpoll` first-wave state (manifest says
`001: running`; `001`'s phase artifacts complete through the final phase, PR
record present, branch pushed with an open PR). Run recovery. Verify `001` is
reported `done`, `002` is reported as the next runnable feature, and no phase is
re-run for `001`.

**Acceptance Scenarios**:

1. **Given** a manifest recording a feature as `running` **and** that feature's
   durable artifacts show its final phase completed with the PR pushed, **When**
   the operator recovers the run, **Then** the feature is reported `done` and its
   status is corrected in the persisted manifest.
2. **Given** the reconciled feature is `done`, **When** the operator continues
   the run, **Then** the feature's dependents become releasable and no phase of
   the reconciled feature is executed again.
3. **Given** a reconciled `done` feature, **When** recovery runs, **Then** its
   committed spend is preserved in the run's total (recovery neither loses nor
   double-counts the finished feature's cost).

### User Story 2 - Reconcile a "running" feature that stopped partway (Priority: P1)

A feature was recorded `running` but the crash happened mid-way: some phases
completed and were committed, but the feature had not reached its terminal phase
and no PR was pushed. On recovery the operator sees this feature reported as
resumable **from its last completed phase boundary**, not from the start, so
continuing the run re-runs only the interrupted phase onward.

**Why this priority**: The other half of the `running` case. Recovery must
distinguish "finished but manifest was stale" from "genuinely incomplete" so it
neither re-runs completed work nor skips unfinished work. Both halves are needed
for correct continuation.

**Independent Test**: Set up a feature with completed phase artifacts up to an
intermediate phase (checkpoint present, no PR record), manifest says `running`.
Run recovery. Verify the feature is reported as resumable at the phase after its
last completed one, and that continuing runs only remaining phases.

**Acceptance Scenarios**:

1. **Given** a `running` feature whose durable artifacts show it reached only an
   intermediate phase (no terminal/PR evidence), **When** recovery runs, **Then**
   the feature is reported as resumable from the phase boundary after its last
   completed phase.
2. **Given** such a feature, **When** the operator continues the run, **Then**
   already-completed phases are not regenerated and execution resumes at the
   correct phase.

### User Story 3 - Reconcile pending and terminal states across the whole run (Priority: P2)

Recovery reconciles **every** feature in the run, not only the one that was
running: features recorded `pending` that the repository shows were never started
stay pending; features recorded at a human gate (`escalated` / `halted`) stay at
that gate (a resume must never carry a feature past a human gate); a `failed`
feature stays reported as failed. The operator gets one accurate, whole-run
picture from which to decide what to continue.

**Why this priority**: Correct continuation requires the *entire* status map to
be trustworthy, not just the single running slot — the wave/DAG releases the next
work off every feature's status. Lower priority than P1 only because these states
are already close to correct today; this story guarantees no state is silently
mis-mapped.

**Independent Test**: Construct a manifest exercising each status
(`running`/`pending`/`escalated`/`halted`/`failed`/`done`) with matching or
conflicting on-disk evidence, run recovery, and verify each feature's reported
status matches the repository-reconciled rule for its state.

**Acceptance Scenarios**:

1. **Given** a feature recorded `pending` with no branch and no phase artifacts,
   **When** recovery runs, **Then** it is reported `pending` (never started) and
   is releasable only when its prerequisites are `done`.
2. **Given** a feature recorded `escalated` or `halted` at a human gate, **When**
   recovery runs, **Then** it stays reported at that gate and is not advanced by
   recovery.
3. **Given** a feature recorded `done`, **When** recovery runs, **Then** it stays
   `done` and its dependents remain releasable.

### User Story 4 - Recovery works for both breakdown waves and ad-hoc runs (Priority: P2)

The same reconciliation applies whether the interrupted run was a multi-feature
breakdown wave or a single ad-hoc specification. In both shapes the operator can
recover and continue from the repository-reconciled state.

**Why this priority**: The user explicitly requires both run shapes. A breakdown
wave has dependents to release; an ad-hoc run is a single feature, but the same
stale-manifest crash window applies and must recover correctly.

**Independent Test**: Run reconciliation for an ad-hoc run whose single feature
finished before the crash (manifest `running`, PR pushed) and confirm it is
reported `done`/complete; repeat for a breakdown wave and confirm dependents
release.

**Acceptance Scenarios**:

1. **Given** an ad-hoc run whose feature finished before a crash, **When**
   recovery runs, **Then** the run is reported complete and no phase re-runs.
2. **Given** a breakdown-wave run, **When** recovery reconciles a finished
   feature, **Then** the wave releases that feature's dependents on continuation.

### Edge Cases

- **Manifest missing or corrupt** but per-feature artifacts and branches exist:
  recovery MUST NOT silently discard the run; it reports what can be reconstructed
  from the surviving durable state (per 009 FR-016's fail-loud principle) and, at
  minimum, surfaces that a run's artifacts exist so the operator can act.
- **A per-feature artifact is corrupt or partially written** (e.g. a truncated
  checkpoint or PR record from a crash mid-write): reconciliation MUST treat that
  single source as untrustworthy and fall back to other durable evidence for that
  feature (git branch/PR state) rather than crashing recovery or fabricating a
  status.
- **Manifest says `done` but the repository shows no branch/PR** (impossible-under-
  normal-operation disagreement): recovery MUST surface the conflict rather than
  silently trusting either side into an unsafe continuation.
- **PR was pushed but later closed without merge** on the remote: the durable
  local PR record is the primary "done" signal; a live remote check, when
  available, is a secondary confirmation — recovery relies on the local record and
  does not require the remote to be reachable.
- **The feature's branch was committed but the PR push had not yet happened** when
  the crash hit: reconciliation MUST classify this as *not yet done* (resume to
  complete the PR step) rather than done.
- **A stale manifest from a previous, different run** for the same repo slot:
  recovery MUST NOT resume a stale manifest over a different run's artifacts (per
  009 FR-017); reconciliation is scoped to the run the manifest and artifacts
  agree on.
- **Uncommitted mid-phase edits** in a worktree from a phase that was interrupted
  before its boundary commit: reconciliation treats the last *committed* phase
  boundary as the restore point; uncommitted partial work is not counted as a
  completed phase.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: On recovery, the system MUST reconcile every feature's manifest-
  recorded status against durable ground truth outside the manifest (the feature's
  phase artifacts and the git/PR state of its branch) before reporting the run or
  releasing any work.
- **FR-002**: When the manifest and the repository disagree about a feature's
  status, the system MUST treat the repository as authoritative and correct the
  reported status accordingly (the manifest is an optimistic cache).
- **FR-003**: The system MUST classify a feature recorded as `running` (or
  otherwise non-terminal) as **done** using this authoritative done-signal: in a
  PR-workflow run, the durable PR record present **and** the feature's branch
  pushed with its work committed; in a non-PR-workflow run, the final-phase
  transcript's success marker **and** the committed branch. A feature classified
  done MUST then treat its dependents as releasable.
- **FR-004**: The system MUST classify a `running` feature whose durable artifacts
  show only intermediate progress (no terminal/PR evidence) as **resumable from
  the phase boundary after its last completed phase**, re-running only remaining
  phases (reusing 009's phase-boundary resume; never resuming within a phase).
- **FR-005**: The system MUST determine "the last completed phase" for a feature
  from the **latest committed phase boundary in git** as the authoritative source
  (a phase is complete only once its boundary commit lands), resuming from the
  phase after it — guaranteeing a clean worktree and never skipping a phase whose
  transcript was written but whose commit never landed. The checkpoint and phase
  transcripts corroborate but do not override the committed-boundary evidence, and
  the manifest status alone MUST NOT be used.
- **FR-006**: The system MUST NOT re-run any phase of a feature that
  reconciliation determines is already complete.
- **FR-007**: A feature recorded at a human gate (`escalated` / `halted`) MUST
  remain at that gate after reconciliation; recovery MUST NOT advance it past a
  human gate.
- **FR-008**: A feature recorded `pending` with no durable start evidence MUST
  remain `pending` and be releasable only when its prerequisites are `done`.
- **FR-009**: The system MUST persist the corrected statuses durably by rewriting
  the run manifest **immediately at reconciliation time** (not deferred to operator
  continuation), so a subsequent restart reads the already-reconciled picture and
  does not re-derive from stale data. This rewrite MUST NOT alter the repository's
  own artifacts, and — being status-only — runs no phase and spends no budget
  (consistent with FR-010).
- **FR-010**: Reconciliation MUST be read-only with respect to executing work: it
  MUST NOT run any phase, push, or spend budget on its own; it corrects status and
  reports, and phase work happens only when the operator triggers continuation
  (consistent with 009's operator-initiated recovery).
- **FR-011**: Reconciliation MUST cover all persistence files the run relies on —
  the run manifest, each feature's checkpoint, each feature's phase transcripts,
  and the durable PR record — and MUST tolerate any one of them being absent or
  corrupt by falling back to the remaining durable evidence rather than failing
  recovery or fabricating a status.
- **FR-012**: Reconciliation MUST apply to both run shapes — a breakdown wave and
  a single ad-hoc specification — producing a correct continuation point for each.
- **FR-013**: The system MUST preserve the run's committed spend across
  reconciliation, neither losing a finished feature's recorded cost nor double-
  counting it, and MUST continue to honor the original budget on continuation.
- **FR-014**: When durable evidence is insufficient or self-contradictory for a
  feature (e.g. manifest says `done` but no branch/PR exists), the system MUST
  surface the conflict to the operator rather than silently choosing an unsafe
  continuation, and MUST hold that feature like a human gate: the conflict feature
  and its dependents are not released until a human resolves it, while independent
  features elsewhere in the DAG continue to release and run (never freezing the
  whole run).
- **FR-015**: The system MUST report the reconciled, whole-run picture (each
  feature's corrected status and the next runnable work) so the operator can
  decide what to continue, without starting work.
- **FR-016**: Reconciliation MUST NOT introduce any persistence datastore; it MUST
  rely solely on git and the existing JSON pointer files (consistent with 009
  FR-018).
- **FR-017**: Reconciliation MUST NOT resume or continue a stale manifest over a
  different run's artifacts; it operates only on the run the manifest and durable
  artifacts consistently identify (consistent with 009 FR-017).
- **FR-018**: Reconciliation MUST work offline: it MUST reconcile from local
  durable state (the durable PR record and local git branch) without requiring
  network/remote reachability. A live remote query MAY be used only as a fallback
  when the local PR record is absent or corrupt, and remote-unreachable MUST be
  treated as "no additional evidence" for that feature — never a recovery failure.

### Key Entities *(include if feature involves data)*

- **Run manifest**: The single-slot-per-repo durable record of a run's features,
  statuses, run-shaping context, and spend. After this feature it is explicitly an
  *optimistic cache* that reconciliation reads, corrects, and rewrites — never the
  final authority when it disagrees with the repository.
- **Feature durable evidence**: The per-feature ground truth used to reconcile a
  status — the feature's committed branch, its pushed pull request (durable PR
  record plus optional live remote confirmation), its per-phase transcripts, and
  its checkpoint. Collectively the authority for "what phase did this feature
  actually reach, and is it done."
- **Reconciled status**: The corrected status the system reports and persists for a
  feature after comparing manifest against durable evidence: `done`, resumable-at-
  phase-N, `pending`, `escalated`, `halted`, `failed`, or conflict-flagged.
- **Repository ground truth**: The git branch/commit and PR state of a feature's
  work — the authoritative "did this actually complete" signal that overrides the
  manifest.

## Success Criteria *(mandatory)*

- **SC-001**: For the reported `quickpoll` first-wave state (manifest `001:
  running`, `001` finished with PR pushed), recovery reports `001` as done and
  `002` as the next runnable feature — with no re-run of any `001` phase.
- **SC-002**: For any feature that finished before a crash, recovery reports it
  done and re-runs zero of its phases (0% redundant phase execution for completed
  features).
- **SC-003**: For any feature interrupted mid-run, recovery reports it resumable
  from its last completed phase boundary, and continuation re-runs only the
  interrupted phase onward — no already-completed phase is regenerated.
- **SC-004**: 100% of features that had reached a human gate before the crash stay
  reported at that gate after recovery; none are advanced past a gate by recovery.
- **SC-005**: A crashed run is correctly reconcilable from on-disk state alone
  (manifest + per-feature artifacts + git/PR), for both breakdown-wave and ad-hoc
  runs, with no datastore involved.
- **SC-006**: When any single persistence file is removed or corrupted, recovery
  still produces a correct reconciled status for each affected feature from the
  remaining durable evidence, or surfaces an explicit conflict — it never
  fabricates a status and never crashes recovery.
- **SC-007**: A resumed run's total spend stays within the original budget, and a
  finished feature's committed cost is counted exactly once across reconciliation.
- **SC-008**: Reconciliation starts no phase work on its own; work begins only on
  explicit operator continuation.
- **SC-009**: A crashed run reconciles correctly with the network/remote
  unreachable — every feature reaches its correct reconciled status from local
  durable state alone, with no recovery failure attributable to an unreachable
  remote.

## Assumptions

- Reconciliation reuses feature 009's recovery mechanics (per-phase checkpoints,
  the run manifest, per-phase boundary commits, and the existing `resume` entry
  points) and 012's per-repo/per-scope layout; this feature adds the repository-
  reconciliation layer on top rather than replacing that machinery.
- Git is the artifact store; the durable PR record written per feature (the
  existing `pr.json`-style record) plus the git branch state are the primary
  "is this feature done" signals. A live remote PR check, when the remote is
  reachable, is a secondary confirmation, not a hard dependency of recovery.
- "Done" for a PR-workflow run means the feature's terminal phase completed, its
  work is committed to its branch, and its PR has been pushed/opened. Human
  merge/review is out of scope and not required for the orchestrator to release
  dependents (consistent with the existing PR workflow, where merge is manual).
- Recovery remains operator-initiated (009 FR-014); this feature improves the
  accuracy of the reported resumable picture and the correctness of continuation,
  not the trigger model.
- The reserved single-slot-per-repo manifest model (009) and per-repo layout
  partitioning (012) are unchanged; reconciliation operates within one repo's
  slot and scope.
- This spec covers recovery mechanics and the reconciled operator-facing report;
  surfacing reconciliation in the Control Plane console UI (008/011) is a later,
  separate concern.
