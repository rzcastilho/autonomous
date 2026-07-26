# Feature Specification: Resume Preserves Backlog Scope

**Feature Branch**: `016-resume-backlog-scope`

**Created**: 2026-07-26

**Status**: Draft

**Input**: User description: "Resume must preserve the run's full backlog scope. Today `SpeckitOrchestrator.resume/2` replaces the run's feature set with only the resumed feature, then starts a Coordinator seeded with that single feature. Because the Coordinator is the run manifest's single writer and the manifest is single-slot-per-repo, the narrowed run overwrites the original run record — permanently destroying the record of every other feature in the backlog. Observed live against `../quickpoll`. `resume_run/1` already does the right thing; `resume/2` should reuse that machinery. Additionally the manifest write path should fail loud rather than silently shrink a run's feature set. Include recovery for already-clobbered manifests if feasible."

## Context: the observed failure

A backlog run of `first-wave` (three features, strict prerequisite chain
`001 → 002 → 003`) halted `001` at the analyze gate. An operator resumed `001`
from the escalations surface with a remediation instruction. `001` completed
successfully and opened its pull request — and then the run reported
**"Run complete, Done: 1"** and stopped.

`002` and `003` were never released, and were **erased from the durable run
record**. The record left behind is internally inconsistent: its scope still
names the three-feature backlog, while its feature list holds a single entry.

The operator's entire reason for unblocking `001` was to let its dependents
flow. Resuming a blocked feature silently discarded the work it was blocking.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resuming one feature continues the whole run (Priority: P1)

An operator resolves a gate diversion on one feature of a multi-feature backlog
run. The resumed feature restarts at its recorded phase; every other feature in
the run keeps the state it had; and as the resumed feature reaches a terminal
success, the features that were waiting on it are released and built in
dependency order, exactly as they would have been had the diversion never
happened.

**Why this priority**: This is the defect. A gate diversion is the *expected*
path for a spec-driven pipeline (Constitution V) — a run that cannot survive one
is not autonomous. Today every backlog run that diverts loses its remaining
scope the moment an operator intervenes, which is precisely when they are
trying to save it. Nothing else in this feature matters if this does not hold.

**Independent Test**: Start a run of a three-feature backlog with a strict
prerequisite chain, force a diversion on the first feature, resume it from the
operator surface, and verify the second and third features are released and
reach terminal states without any further operator action.

**Acceptance Scenarios**:

1. **Given** a backlog run of `001 → 002 → 003` where `001` is halted and
   `002`/`003` are pending on prerequisites, **When** the operator resumes
   `001`, **Then** the resumed run contains all three features, `001` restarts
   at its recorded phase, and `002` then `003` are released as their
   prerequisites reach a terminal success.
2. **Given** the same run, **When** the operator resumes `001`, **Then** no
   feature other than `001` is dispatched at a phase earlier than the state it
   had recorded — already-completed features are not re-run.
3. **Given** a run where two features are independently diverted and the
   operator resumes only one, **When** the resume starts, **Then** the
   un-resumed diverted feature retains its diverted state and is not
   re-dispatched.
4. **Given** a resumed run, **When** it drains, **Then** the final report counts
   every feature from the original backlog, not only the resumed one.

---

### User Story 2 - A run's recorded scope can never be silently narrowed (Priority: P2)

The durable run record is the memory of what the operator asked for. Any write
that would shrink a live run's feature set is refused and reported, rather than
being applied silently.

**Why this priority**: US1 fixes the one path known to narrow scope. This makes
the *class* of defect non-recurring: the record cannot quietly lose features
again through some future path, and the inconsistency that made this bug hard to
see (a scope naming a backlog beside a one-feature list) becomes impossible to
write. It is a guard, so it ranks below the fix it guards.

**Independent Test**: Attempt to record a run state holding fewer features than
the live record it would replace, without an explicit supersede, and verify the
write is refused and surfaced rather than applied.

**Acceptance Scenarios**:

1. **Given** a recorded run of three features, **When** something attempts to
   record a state for the same run holding only one of them, **Then** the write
   is refused, the existing record is left intact, and the refusal is reported.
2. **Given** a recorded run of three features, **When** an operator
   deliberately starts a **new** run for the same repository, **Then** the new
   run supersedes the old record normally — a fresh start is not a narrowing.
3. **Given** any recorded run, **When** its features are recorded with statuses
   advancing over the run's life, **Then** ordinary progress writes are
   unaffected.

---

### User Story 3 - Recovering a run record that already lost its scope (Priority: P3)

An operator who already hit this defect can rebuild the run record for their
repository from the durable evidence that survived — the backlog definition on
disk and the per-feature state recorded during the run — and continue the
backlog from where it actually stands, without re-running completed features.

**Why this priority**: A repair path for damage already done. It affects a known
finite set of runs (those resumed before this fix), and the alternative —
starting a fresh run and re-building completed features — is expensive but not
destructive. Valuable, but not blocking.

**Independent Test**: Take a run record narrowed to one feature whose backlog on
disk holds three, run the recovery, and verify the rebuilt record names all
three with states matching the evidence on disk — the completed one terminal,
the untouched ones pending.

**Acceptance Scenarios**:

1. **Given** a run record narrowed to one feature and a backlog on disk holding
   three, **When** the operator runs recovery, **Then** the rebuilt record names
   all three features with states consistent with the evidence available for
   each.
2. **Given** a rebuilt record, **When** the operator resumes the run, **Then**
   features already complete are not rebuilt and the remaining ones proceed in
   dependency order.
3. **Given** a backlog whose definition on disk changed since the run started,
   **When** recovery runs, **Then** it reports what it could not reconcile
   rather than inventing a state for it.

---

### Edge Cases

- **A genuinely single-feature run.** An ad-hoc single-spec run legitimately
  has exactly one feature. Resuming it must behave exactly as it does today —
  the fix must key on *narrowing an existing multi-feature record*, not on
  "the run has one feature".
- **No run record at all.** Resuming a feature whose run record is missing or
  unreadable must keep working from the feature's own recorded state, as it
  does today — the ability to resume without a readable run record is an
  existing guarantee and must not regress.
- **The resumed feature is absent from the run record.** Resuming a feature the
  record does not name must not drop the recorded features; the resumed feature
  is added to the run rather than replacing it.
- **A prerequisite never succeeds.** If the resumed feature diverts again, its
  dependents must remain unreleased and be reported as blocked — not counted as
  failed, and not silently dropped.
- **Cost breaker already tripped.** A resume that would release dependents must
  still honour the breaker: no new features are released while it is tripped,
  and the in-flight one drains between phases.
- **Two operators resume concurrently.** Two resumes racing on the same
  repository must not interleave into a record that loses features from either.
- **Recovery against a changed backlog.** Features added to or removed from the
  backlog on disk after the run started must be reported during recovery, not
  silently merged or dropped.
- **A feature terminal in the record but with contradicting evidence on disk.**
  Recovery must report the contradiction rather than pick a side silently.

## Requirements *(mandatory)*

### Functional Requirements

#### Resuming preserves scope

- **FR-001**: Resuming a single feature MUST restore the full set of features
  recorded for that run, not replace it with the resumed feature alone.
- **FR-002**: Every feature other than the resumed one MUST retain the state
  the run recorded for it; resuming MUST NOT reset any other feature's progress.
- **FR-003**: The resumed feature MUST start at its recorded phase (or an
  operator-supplied override), while all other features MUST start at the point
  their recorded state implies.
- **FR-004**: Features whose prerequisites reach a terminal success during a
  resumed run MUST be released and built in dependency order, without further
  operator action.
- **FR-005**: Features recorded in a terminal state MUST NOT be re-dispatched by
  a resume.
- **FR-006**: Features recorded as diverted (awaiting a human) other than the
  one being resumed MUST retain their diverted state and MUST NOT be
  re-dispatched.
- **FR-007**: A resumed run's final report MUST account for every feature in the
  restored set.
- **FR-008**: Resuming a feature that the run record does not name MUST add that
  feature to the run rather than replacing the recorded set.
- **FR-009**: Resuming MUST continue to work when the run record is missing or
  unreadable, falling back to the feature's own recorded state exactly as it
  does today.
- **FR-010**: The run-shaping settings a resume already reapplies (concurrency
  cap, budget, publication workflow and its targets, plan stack) MUST continue to
  be reapplied unchanged, under the existing precedence.

#### Scope loss is refused, not silent

- **FR-011**: An attempt to record a run state that holds fewer features than
  the live record it would replace MUST be refused; the existing record MUST be
  left intact.
- **FR-012**: A refused write MUST be reported through the operator-visible
  channels rather than failing silently.
- **FR-013**: Deliberately starting a new run for a repository MUST continue to
  supersede that repository's previous record — a fresh start MUST NOT be
  treated as a narrowing.
- **FR-014**: A refused write MUST NOT abort the run in progress; recording is a
  durability concern and MUST NOT take down work already underway.
- **FR-015**: The recorded scope descriptor and the recorded feature set MUST be
  mutually consistent — a record naming a multi-feature backlog while listing a
  single feature MUST NOT be producible.

#### Recovering a damaged record

- **FR-016**: Operators MUST be able to rebuild a run record for a repository
  from the backlog definition on disk together with the per-feature evidence
  that survived.
- **FR-017**: Recovery MUST derive each feature's state from available evidence
  and MUST NOT invent a state for a feature it cannot reconcile.
- **FR-018**: Recovery MUST report every feature it could not reconcile, and
  every discrepancy between the backlog on disk and the record being rebuilt.
- **FR-019**: Recovery MUST be explicitly invoked by an operator and MUST NOT
  run automatically as part of an ordinary resume.
- **FR-020**: Recovery MUST leave the existing record untouched when it cannot
  produce a consistent result, reporting why.

#### Operator surface

- **FR-021**: The operator surface that offers resume MUST make clear that
  resuming continues the whole run, not only the selected feature.
- **FR-022**: After a resume, the operator surface MUST show every feature in
  the restored run, including those still waiting on prerequisites.

### Key Entities

- **Run record**: The durable memory of one run for one repository — which
  features it covers, each feature's last known state, the run-shaping settings
  it started under, its accumulated spend, and the scope it was drawn from.
  Exactly one live record per repository. Its feature set is the run's
  authoritative scope.
- **Feature state**: A single feature's last known position — its lifecycle
  status and, where applicable, the phase it should restart at.
- **Backlog definition**: The on-disk description of the features available for
  a run and the prerequisite relationships between them. The source recovery
  rebuilds from.
- **Resume request**: An operator's instruction to continue a run, naming one
  feature to restart, optionally overriding its start phase and supplying
  correction guidance.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a backlog run where one feature diverts and is then resolved by
  an operator, **100% of the run's other features remain accounted for** — none
  is dropped from the run or from its durable record.
- **SC-002**: The dependents of a resumed feature reach their terminal states
  **without any operator action beyond the single resume** that unblocked their
  prerequisite.
- **SC-003**: The exact observed failure — a three-feature chained backlog whose
  first feature diverts at a gate — completes all three features end-to-end
  after one operator resume, where today it completes one.
- **SC-004**: **No sequence of operations can reduce a live run's recorded
  feature count** other than deliberately starting a new run; attempts are
  refused and reported.
- **SC-005**: Resuming a genuinely single-feature run, and resuming with no
  readable run record, behave **exactly as they do today** — no change in
  dispatched work or reported outcome.
- **SC-006**: A run record already narrowed by this defect can be rebuilt to
  name its full backlog, and the run continued, **without rebuilding any feature
  that already completed**.
- **SC-007**: A resumed run's reported spend continues to reflect the run's
  accumulated cost, and the cost breaker governs the resumed run exactly as it
  governs an uninterrupted one.

## Assumptions

- **The operator's stated intent governs.** Resuming a feature within a backlog
  run is an instruction to continue *that run*, with one feature's start phase
  overridden — not to start a new, narrower run. The alternative reading (keep
  per-feature resume narrow and direct operators to a separate whole-run resume
  for this case) was considered and rejected: it leaves the destructive default
  in place and puts the burden of knowing which command preserves scope on the
  operator at their least convenient moment.
- **The whole-run resume path is the model.** The existing whole-run recovery
  path already restores a full feature set, seeds recorded states, and dispatches
  only the features needing a restart. This feature aligns per-feature resume
  with that behaviour rather than inventing a second mechanism.
- **"Narrowing" means shrinking a live record in place.** A fresh run explicitly
  supersedes the previous record for its repository; that path is unchanged. The
  guard applies to writes that would replace a live record with a strictly
  smaller feature set.
- **Recording is best-effort and stays that way.** A refused or failed write must
  not take down a run in progress; durability failures are reported, not fatal.
  This preserves the existing separation between scheduling and persistence.
- **Recovery is a repair tool, not a routine path.** It is operator-invoked,
  applies to runs damaged before this fix, and reports rather than guesses. It is
  not part of the ordinary resume flow.
- **Prerequisite semantics are unchanged.** Dependency ordering, wave release,
  the concurrency cap, and the cost breaker's drain-don't-kill behaviour all
  keep their current meaning; this feature only ensures the full feature set is
  present for them to operate on.
- **No new persistent store.** Run state remains file-backed, single-slot per
  repository, consistent with the existing technology constraints.
- **The observed run is recoverable in practice.** The damaged `../quickpoll`
  record is expected to be repairable by US3, with its completed first feature
  preserved and its two dependents rebuilt from the backlog on disk.
