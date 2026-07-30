# Feature Specification: Stacked Sequential Runs as the Only Behaviour

**Feature Branch**: `019-stacked-sequential-only`

**Created**: 2026-07-28

**Status**: Draft

**Input**: User description: "The `Stacked sequential PR workflow` must be the unique behaviour in the application, and not an option. And the features in backlog must be executed in alphabetical order, the user must numerate the features in the right sequence, there's no concurrency to execute features in a repo."

## Clarifications

### Session 2026-07-28

- Q: How are run records created before this change (which stored a non-stacked or multi-feature-at-once run shape) treated on resume? → A: They do not exist — persistence is reset before this change ships, so no compatibility path is built.
- Q: How do ad-hoc single-spec features (no backlog number) fit an order defined by numbering? → A: They form their own logical group named "Ad-hoc", ordered by creation time rather than by number, and always run one at a time like every other feature.
- Q: What base branch does an ad-hoc feature branch from and open its pull request against? → A: Always the configured base branch — ad-hoc features never stack on each other or on the backlog chain.
- Q: When a human resolves the feature that stopped the chain, does the stopped run continue automatically or does a new run have to be started? → A: The operator chooses at resolve time — a stopped run is parked and can either be continued from where it stopped or ended deliberately.
- Q: What happens when a new run is started for a repository that already has a parked run? → A: The new run is refused, naming the parked run and the two ways out; the parked decision must be settled first.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Every run is a stacked sequential run (Priority: P1)

An operator starts a run against a target repository. They make no choice about
run mode: there is no toggle to set, no environment variable to export, and no
console switch to flip. The run always executes one feature at a time, each
feature branching from the previously completed feature's branch, and each
completed feature's branch is pushed and opened as a pull request against that
base. The operator sees a single, predictable run shape everywhere the run is
described — the trigger screen, the live run view, the run history, and the
final report.

**Why this priority**: This is the whole point of the change. Two run shapes
meant two sets of semantics to reason about, two paths to keep correct, and an
operator decision that had no good answer. Collapsing to one shape removes an
entire class of misconfiguration — a run started in the wrong mode produced
branches that stacked on nothing.

**Independent Test**: Start a run with no options at all against a prepared
target repo and observe that it preflights the pull-request remote, releases
exactly one feature at a time, and opens a pull request per completed feature —
with no setting anywhere that could have produced different behaviour.

**Acceptance Scenarios**:

1. **Given** a target repo with the required remote and committed scaffold,
   **When** an operator starts a run without specifying any run-mode option,
   **Then** the run executes stacked and sequentially, and each completed
   feature's branch is published as a pull request against the previous
   completed feature's branch.
2. **Given** an operator who supplies the retired run-mode option (by any
   surface: start option, environment variable, or stored configuration),
   **When** the run is started, **Then** the system rejects the unknown setting
   loudly rather than silently accepting or ignoring it.
3. **Given** any completed or in-progress run, **When** an operator inspects it
   in the console or in the final report, **Then** the run is described as
   stacked and sequential without a mode label that implies an alternative
   existed.
4. **Given** a target repo missing the pull-request remote or with an unready
   scaffold, **When** a run is started, **Then** the run refuses before any
   feature work begins and reports what is missing.

---

### User Story 2 - The backlog runs in the order the operator numbered it (Priority: P1)

An operator prepares a backlog as numbered feature files. The number is the
contract: the run executes features in ascending numeric order, one at a time,
top to bottom. Nothing else reorders the work — there is no dependency
declaration that can promote or defer a feature, and no parallelism that can
interleave two features. If the operator wants a different order, they renumber
the files.

**Why this priority**: Ordering is now the operator's single, explicit input.
It must be exact and obvious, because in a stacked run each feature builds on
the branch of the one before it — the order *is* the chain.

**Independent Test**: Prepare a backlog of several numbered features and start a
run; observe features released strictly in ascending numeric order with never
more than one in flight, regardless of what any prose in the feature files
says.

**Acceptance Scenarios**:

1. **Given** a backlog numbered 001, 002, 003, **When** a run starts,
   **Then** 001 runs to a terminal state before 002 starts, and 002 before 003.
2. **Given** a backlog whose files declare prerequisites in prose, **When** a
   run starts, **Then** those declarations have no effect on ordering — order
   is taken from the numbers alone.
3. **Given** a running feature, **When** its run is inspected, **Then** exactly
   one feature is in flight at any moment.
4. **Given** a backlog with gaps in numbering (001, 005, 020), **When** a run
   starts, **Then** the run executes them in ascending order without error —
   gaps are legal.

---

### User Story 3 - A broken link stops the chain (Priority: P1)

A feature ends in any state other than done — escalated at the clarify gate,
halted by the analyze gate, or failed. Because every later feature would branch
from this one's branch, the run stops there. It does not skip ahead to the next
feature. The operator's report shows what completed, which feature broke the
chain and why, and that the remaining features were never started.

**Why this priority**: Without this, "run in order" is not true in the case
that matters most. Continuing past a broken link produces a stack whose top
does not contain the work the operator intended, which is silently wrong and
expensive to unwind.

**Independent Test**: Prepare a backlog where the second feature is forced to
escalate, and confirm the run stops after it, leaving later features
untouched.

**Acceptance Scenarios**:

1. **Given** a backlog of 001–007 where 002 ends escalated, **When** the run
   completes, **Then** 001 is done, 002 is escalated, and 003–007 are reported
   as never started.
2. **Given** the same run, **When** the operator reads the report, **Then** it
   names the feature that stopped the chain and its reason.
3. **Given** a feature that ends done, **When** its branch is published,
   **Then** the next feature in numeric order starts from that published
   branch.
4. **Given** a feature that ends done but whose publication fails, **When** the
   next feature starts, **Then** it still stacks on the completed local branch
   and the publication failure is reported, not swallowed silently.

---

### User Story 4 - Continue or end a parked chain (Priority: P2)

After a run stops on a broken link, the run is parked — it stopped, but it is
not written off. The operator fixes the cause (resolves the ambiguity, corrects
the specification, addresses the constitution violation) and then decides, at
that moment, what the parked run should do: continue from where it stopped, or
end deliberately. Continuing re-runs the feature that broke the chain and, on
success, carries on in numeric order through the features that were never
started, each stacking on the one before it. Ending closes the run out with its
never-started features recorded as such.

**Why this priority**: Stopping the chain is only acceptable if restarting it
is cheap. Without this, stop-on-first-failure turns a single escalation into a
full manual re-run — and forcing every resolution to continue would be equally
wrong when the operator has decided the backlog itself needs rework.

**Independent Test**: Take a run stopped at feature 002, resolve it choosing to
continue, and confirm 002 re-runs and 003 onward follow in order on the correct
bases; repeat choosing to end, and confirm nothing further is released.

**Acceptance Scenarios**:

1. **Given** a run stopped at an escalated feature, **When** the operator
   resolves it and chooses to continue, **Then** the run picks up from where it
   stopped, stacked and sequential, without the operator restating any
   run-shape setting.
2. **Given** a continued run whose stopped feature now completes, **When** it
   completes, **Then** the next-numbered never-started feature begins from the
   newly published branch.
3. **Given** a run stopped at a broken link, **When** the operator resolves it
   and chooses to end the run, **Then** no further feature is released and the
   run closes out with its never-started features recorded as never started.
4. **Given** a parked run, **When** the operator inspects it, **Then** it is
   distinguishable from both a still-working run and a closed-out one, so the
   pending decision is visible.
5. **Given** a continued run, **When** its recorded run shape is read back,
   **Then** it contains no run-mode flag and no concurrency limit, and
   continuation needs neither to reconstruct the chain.

---

### Edge Cases

- **Backlog with one feature** — runs, publishes against the configured root
  base branch, and completes normally.
- **Empty backlog** — the run completes immediately with an empty report rather
  than erroring.
- **Duplicate feature numbers** — two files claiming the same number make the
  order ambiguous; the backlog is rejected at load rather than one being picked
  arbitrarily.
- **Cost breaker trips mid-chain** — the in-flight feature finishes its current
  phase and halts between phases; no later feature is released. This existing
  drain-don't-kill behaviour composes with the chain stop: a halted feature is
  not done, so the chain stops regardless.
- **Publication fails for a completed feature** — the chain continues from the
  local completed branch; the failure is surfaced in the run's record.
- **The stopping feature is the last one** — the run reports normally with no
  never-started remainder.
- **An ad-hoc feature is started while a run is in flight** — it does not run
  alongside; the one-feature-at-a-time rule holds across both groups.
- **An ad-hoc feature is started while a run is parked** — it is refused like
  any other new run until the parked decision is settled.
- **Two ad-hoc features created in the same instant** — the Ad-hoc group's
  order must still be total and stable, so ties resolve deterministically
  rather than varying between views.
- **Two ad-hoc features touch the same code** — both root at the base branch,
  so neither sees the other's work and the second pull request may conflict at
  merge. This is accepted: one-off work is independent by construction, and the
  operator resolves the conflict in review.
- **An ad-hoc feature ends non-completed** — nothing is stacked on it, so
  there is no chain to stop; it is reported on its own and the backlog chain is
  unaffected.
- **A parked run is never resolved** — it stays parked indefinitely and blocks
  no other work except by the one-feature-at-a-time rule; it must not be
  silently garbage-collected into a closed-out run.
- **The operator continues a parked run and the same feature breaks again** —
  the run parks again at the same point, with the second failure recorded
  distinctly from the first.
- **The operator resolves the stopping feature but the chain has nothing left
  to run** (it was the last feature) — continuing and ending reach the same
  closed-out result.
- **Operator supplies a concurrency setting out of habit** — the setting no
  longer exists; the run refuses it loudly rather than accepting a number it
  will not honour.
- **Stored configuration still names a retired setting** (a stale config file
  or exported environment variable at start) — the system must not honour it;
  it refuses the start with a message naming the retired setting.

## Requirements *(mandatory)*

### Functional Requirements

**Single run shape**

- **FR-001**: The system MUST execute every run as a stacked sequential
  pull-request run: one feature at a time, in order, each branching from the
  previous completed feature's branch, with each completed feature's branch
  published as a pull request against that base.
- **FR-002**: The system MUST NOT expose any setting, option, environment
  variable, or console control that selects or disables the stacked sequential
  behaviour.
- **FR-003**: The system MUST preflight the pull-request remote and the target
  repository's scaffold for every run, refusing the run before any feature work
  starts when the preflight fails.
- **FR-004**: The system MUST reject an attempt to set the retired run-mode
  setting through any run-start surface, rather than accepting and ignoring it.
- **FR-005**: Every description of a run shown to an operator (trigger screen,
  live run view, run history, run detail, final report) MUST describe the one
  run shape, with no mode label, toggle, or comparison implying an alternative.

**No concurrency**

- **FR-006**: The system MUST run at most one feature at a time per repository,
  as a structural property rather than a configured limit.
- **FR-007**: The system MUST remove the concurrency setting from every
  surface: stored configuration, environment, run-start options, live
  configuration edits, the console, and the recorded per-run settings.
- **FR-008**: The system MUST NOT offer a live operation that changes how many
  features run at once.

**Ordering by number**

- **FR-009**: The system MUST determine execution order solely by ascending
  feature number, taken from the numbered backlog files.
- **FR-010**: The system MUST NOT read, parse, or act on prerequisite
  declarations in backlog files; ordering has exactly one input, the numbering.
- **FR-011**: The system MUST tolerate gaps in numbering.
- **FR-012**: The system MUST reject a backlog at load time when two features
  claim the same number, naming the conflicting files.
- **FR-013**: The system MUST document the numbering contract for operators —
  that the number determines execution order, and that renumbering is how order
  is changed.

**Stop on the first broken link**

- **FR-014**: The system MUST stop releasing further features as soon as a
  feature reaches any terminal state other than done.
- **FR-015**: The system MUST NOT skip a feature and continue with a later one
  for any reason.
- **FR-016**: The system MUST report each never-started feature distinctly from
  a feature that ran and did not complete, so an operator can tell what was
  attempted from what was not.
- **FR-017**: The final report MUST name the feature that stopped the chain and
  the reason it stopped.
- **FR-018**: A completed feature's published branch MUST become the base for
  the next-numbered feature; when publication fails, the completed local branch
  MUST still become that base and the failure MUST be recorded.

**Parked runs and operator resolution**

- **FR-019**: A run that stopped on a broken link MUST be parked — recorded as
  stopped-but-continuable, distinguishable from a run still working and from a
  run closed out — until an operator resolves it.
- **FR-019a**: Resolving the feature that stopped a parked run MUST let the
  operator choose, at resolve time, between continuing the run from where it
  stopped and ending it deliberately; the system MUST NOT decide this on the
  operator's behalf.
- **FR-019b**: Ending a parked run MUST close it out with its never-started
  features still recorded as never started, releasing nothing further.
- **FR-019c**: A continued run MUST continue under stacked sequential semantics
  without the operator restating any run-shape setting.
- **FR-020**: After the previously-stopped feature completes, the continued run
  MUST proceed with the next-numbered never-started feature, stacked on the
  newly completed branch, and MUST stop again at the next broken link under the
  same rules.
- **FR-020a**: Starting a new run for a repository that already has a parked
  run MUST be refused, and the refusal MUST name the parked run and the two
  ways out of it (continue or end). A parked run MUST NOT be superseded
  automatically.
- **FR-020b**: The refusal in FR-020a MUST apply to ad-hoc single-spec starts
  as well as backlog runs — a parked decision blocks all new work for that
  repository.
- **FR-021**: The recorded run shape MUST NOT carry a run-mode flag or a
  concurrency limit, and resuming MUST NOT depend on either being present.

**Clean break — no compatibility with pre-change records**

- **FR-022**: The system MUST NOT carry a compatibility path for run records
  written before this change; persistence is reset as part of shipping it, so
  no record predating the change is expected to exist.
- **FR-023**: Should a record predating the change nevertheless be encountered,
  the system MUST refuse to act on it with a message naming the incompatibility
  rather than interpreting its retired settings.

**Ad-hoc single-spec features**

- **FR-024**: The system MUST keep ad-hoc single-spec features (started from
  free text, absent from the numbered backlog) in their own logical group named
  "Ad-hoc", distinct from the numbered backlog group.
- **FR-025**: The system MUST order the Ad-hoc group by creation time, oldest
  first, since its members have no number to order by.
- **FR-026**: The system MUST run an ad-hoc feature one at a time, alone, under
  the same single-run-shape rules as a backlog feature — never alongside
  another feature.
- **FR-027**: Every operator-facing view that lists features MUST present the
  two groups distinctly — the numbered backlog in numeric order and the Ad-hoc
  group in creation order — so an operator never has to guess which ordering
  rule applies to a given feature.
- **FR-028**: An ad-hoc feature MUST branch from the configured base branch and
  open its pull request against that same branch. It MUST NOT stack on another
  ad-hoc feature or on the backlog chain, and MUST NOT advance the backlog
  chain when it completes.

### Key Entities

- **Backlog**: The ordered list of numbered features for a repository, derived
  from numbered files. Its only ordering input is the number; it carries no
  dependency relationships.
- **Ad-hoc group**: The set of one-off features started from free text rather
  than from the numbered backlog. It is a separate logical group named
  "Ad-hoc", ordered by creation time, whose members run one at a time like any
  other feature. Its members are not links in the chain: each roots at the
  configured base branch and leaves the chain's top where it found it.
- **Feature**: One unit of work, identified by its number and name, with a
  lifecycle status. It no longer carries prerequisites and can no longer be
  blocked by another feature's state — after this change a feature is either
  attempted (reaching a terminal state) or never started.
- **Chain**: The sequence of completed feature branches, each based on the one
  before it, rooted at the configured base branch. The chain advances only on a
  completed feature and, within a run, stops permanently at the first
  non-completed one.
- **Parked run**: A run that stopped at a broken link and is awaiting an
  operator decision. It is doing no work, holds its never-started remainder,
  and is neither a working run nor a closed-out one until the operator
  continues or ends it.
- **Run shape**: The settings recorded with a run so it can be resumed
  faithfully. After this change it no longer includes a run-mode flag or a
  concurrency limit, because neither is variable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can start a correct stacked sequential run with zero
  run-shape decisions — the number of run-shape choices presented at start
  drops from two (mode, concurrency) to zero.
- **SC-002**: For a backlog of N numbered features, 100% of runs release those
  features in ascending numeric order, with a maximum of one feature in flight
  at every point of the run.
- **SC-003**: In 100% of runs where a feature ends in a non-completed state, no
  later-numbered feature is started.
- **SC-004**: After a run stops on a broken link, an operator can tell from the
  report alone which feature stopped it, why, and exactly which features were
  never attempted — without inspecting the target repository.
- **SC-005**: No surface of the product (start options, environment,
  configuration screen, live edits) accepts a value that would change run mode
  or concurrency; attempts are refused with a message naming the retired
  setting.
- **SC-006**: Zero compatibility code exists for pre-change run records, and
  the reset persistence starts empty — the first run after the change is run
  number one.
- **SC-007**: A stopped chain can be continued and carried to completion
  without the operator manually re-basing any branch or re-declaring the run
  shape.
- **SC-008**: For every parked run, an operator can see that a decision is
  pending and can act on it in a single step — continue or end — with the
  outcome of that choice observable in the run's record.
- **SC-009**: No parked run is ever lost to an automatic supersede: 100% of
  attempts to start new work for a repository with a parked run are refused
  with a message that names the parked run.

## Assumptions

- **Numbering is the operator's responsibility.** The system validates that
  numbering is unambiguous (no duplicates) but does not infer whether the
  chosen order is semantically correct — an operator who numbers a dependent
  feature before the work it depends on gets the order they asked for.
- **Order compares numbers, not filename text.** Feature numbers are compared
  numerically, so differing zero-padding widths order predictably and two files
  whose numbers are numerically equal count as duplicates under FR-012.
- **Continuing a parked run is the common path, but never the automatic one.**
  The operator states the choice; the system offers no default that acts
  without them.
- **Prerequisite sections may remain in backlog files as prose.** They become
  documentation for humans and are ignored by the system; operators are not
  required to delete them.
- **The blocked feature state is retired.** It existed only to express "a
  prerequisite did not complete". With prerequisites gone and the chain
  stopping at the first non-completed feature, remaining features are reported
  as never started instead.
- **Stop-on-first-non-completed applies to every non-done terminal state** —
  escalated, halted, and failed alike — because each equally invalidates the
  branch later features would stack on. This includes a feature halted by the
  cost circuit breaker.
- **The cost circuit breaker, the clarify gate, the analyze gate, and the
  bounded auto-remediation loop are unchanged** by this feature. They decide
  whether a feature completes; this feature only decides what the run does
  next.
- **Ad-hoc features are independent one-offs, not chain links.** They root at
  the configured base branch, so ordering within the Ad-hoc group is a display
  and bookkeeping concern rather than a branching dependency; the
  stop-on-first-broken-link rule governs the backlog chain only.
- **The pull-request base branch, remote, and budget remain configurable.**
  Only the run-mode flag and the concurrency limit are retired; the other
  recorded run-shape settings stay.
- **Persistence is reset as part of shipping this change** (operator decision,
  2026-07-28): there are no run records to migrate and none will exist, so the
  change is a clean break with no back-compatibility layer, no dual-shape
  decode, and no historical-record rendering path to preserve.
- **Publication failure is non-fatal to the chain**, matching current
  behaviour: the completed local branch is a valid base even when pushing or
  opening the pull request fails.
