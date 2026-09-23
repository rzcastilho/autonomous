# Feature Specification: Drain the Superseded Runner

**Feature Branch**: `026-drain-superseded-runner`

**Created**: 2026-09-22

**Status**: Draft

**Input**: User description: "Superseding a run must drain its in-flight runner, not just its coordinator. Starting a new run stops the prior run's control process but leaves the worker that is actually driving a feature's phase — and its external model session — running. The new run then releases the same feature and a second session starts writing to the same working copy. Two sessions, one working copy, duplicated commits."

## Context

Starting a run supersedes whatever run was already in flight for the same target repository. Today that supersession stops the prior run's **control process** — the part that decides which feature goes next — but not the prior run's **worker**, the part that is actually driving a feature through a phase and holding an external model session open.

The worker is deliberately independent of the control process. That independence was added for a good reason and must stay: a control process started from a short-lived console request used to die when the request returned, taking the worker with it and stranding a half-run feature. The fix made the worker outlive its control process. The gap this feature closes is that nothing was then put in place to stop the worker when the run it belongs to is superseded.

The consequence, observed live on run `r000002` (target repository `mod-player`, feature `001`): two model sessions ran at the same time against the same working copy and the same branch. The visible damage is a duplicated implementation progress commit — the same task-phase committed twice, with an unrelated commit between the two. The invisible damage is two independent writers interleaving artifact edits in one tree, and both drawing from the same run budget.

The same blind spot exists in the guard that is supposed to refuse a resume while a run is still active: it looks only for a live control process. A run whose control process is gone but whose worker is still driving a phase reads as "nothing active", so a resume proceeds and stacks a second session on top of the first. This is exactly how the incident above began.

This is distinct from two drains that already exist and must not be confused with it: the cost-breaker drain (budget exhausted — finish the phase, release nothing new) and the parked-run refusal (a broken feature stopped the chain — refuse new work until an operator decides). Neither of those is about a *superseding* run, and neither is changed here.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Starting a new run never leaves the old one working (Priority: P1)

An operator starts a run for a repository that already has a run in flight with a feature mid-phase. The prior run's worker is brought to a stop, and its external model session is shut down with it, before the new run releases anything. At no point are two sessions writing to the same working copy.

**Why this priority**: This is the defect, and it corrupts work rather than merely wasting it. Duplicated commits are the visible symptom; interleaved artifact writes from two independent writers are the damage that is not visible until a later phase reads a tree neither writer intended.

**Independent Test**: Start a run while a prior run has a worker in flight. Observe that no second session begins until the first has stopped, and that the first run's external session is gone once supersession completes. Testable with a stubbed worker and session, with no real model spend.

**Acceptance Scenarios**:

1. **Given** a run in flight with one feature mid-phase, **When** an operator starts a new run for the same repository, **Then** the prior worker is stopped and its external session ended before the new run releases any feature.
2. **Given** the same situation, **When** supersession completes, **Then** no external model session belonging to the prior run remains alive.
3. **Given** a repository with no run in flight, **When** an operator starts a run, **Then** the start behaves exactly as it does today, with no added delay.
4. **Given** a superseded run, **When** its record is read afterwards, **Then** its features and the run itself carry the same supersession outcome they carry today.

---

### User Story 2 - A resume refuses while a worker is still working (Priority: P1)

An operator resumes a run — one feature or the whole run — while a worker from the previous run is still driving a phase. The resume refuses, names what is still working, and starts nothing. The operator's existing explicit override remains the one way past it.

**Why this priority**: The guard is what turns the defect above from "possible" into "prevented". Without it, the operator's own recovery attempt is the thing that creates the second session — which is exactly what happened in the incident.

**Independent Test**: With a live worker and no live control process, ask for a resume. It must refuse with the same refusal shape it already uses for an active run, and start nothing.

**Acceptance Scenarios**:

1. **Given** a live worker driving a phase and no live control process, **When** an operator asks to resume the whole run, **Then** the resume refuses as already-active and starts no work.
2. **Given** the same state, **When** an operator asks to resume a single feature, **Then** it refuses identically.
3. **Given** the same state, **When** the operator passes the existing explicit override, **Then** the resume proceeds — and the prior worker is drained first, exactly as a supersession drains it.
4. **Given** no live worker and no live control process, **When** an operator resumes, **Then** the resume proceeds exactly as it does today.

---

### User Story 3 - The drain finishes the phase rather than killing it (Priority: P2)

An operator supersedes a run whose worker is part-way through a phase. The phase is allowed to reach its boundary and record what it did — attempt, checkpoint, transcript — before the worker stops. The recorded state never claims progress that did not happen.

**Why this priority**: Killing a phase mid-flight is how a run ends up with a durable record that disagrees with what actually happened, which then misleads the very recovery this incident required. The system already holds "drain, don't kill" as a rule for the cost breaker; supersession must honour the same rule.

**Independent Test**: Supersede while a phase is mid-flight and confirm that the phase's own boundary record is written before the worker stops, and that no record is written claiming a phase completed when it did not.

**Acceptance Scenarios**:

1. **Given** a worker mid-phase, **When** supersession drains it, **Then** the phase reaches its boundary and its attempt, checkpoint, and transcript are recorded before the worker stops.
2. **Given** a drained worker, **When** its feature is later resumed, **Then** it resumes from the phase the drain recorded, with no phase re-run and none skipped.
3. **Given** a drain that cannot complete within its bound, **When** the bound expires, **Then** the operator is told the drain timed out, the new run is not started, and nothing is recorded that claims the phase finished.

---

### Edge Cases

- A worker belonging to a *different* repository's run is in flight: it is untouched — supersession is per repository, and one repository's run must never stop another's.
- Several workers in flight for the same run (a shape the current one-feature-at-a-time rule does not produce, but the drain must not assume away): every one of them is drained before the new run starts.
- The worker is between phases when the drain arrives: it stops immediately, with nothing to finish.
- The worker has already finished but has not yet been reaped: the drain is a no-op and adds no delay.
- The external session's own deadline expires during the drain: the session ends by its own deadline, the phase records its outcome, and the drain completes — the drain never becomes a second, competing way to kill a session.
- The drain times out: no new run starts, the operator is told which feature is still working, and the explicit override remains available for the case where the operator knows the worker is genuinely stuck.
- The operator uses the explicit override while a worker is genuinely mid-phase: the worker is still drained first — the override bypasses the *refusal*, not the drain.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Before a new run starts for a repository, every in-flight worker belonging to that repository's prior run MUST be stopped.
- **FR-002**: Stopping a worker MUST end the external model session it holds; no such session may outlive the worker that started it.
- **FR-003**: The drain MUST let an in-flight phase reach its boundary and record its attempt, checkpoint, and transcript rather than killing it mid-phase.
- **FR-004**: The drain MUST be bounded. When the bound expires, the operator MUST be told the drain timed out, naming the feature still working, and the new run MUST NOT start.
- **FR-005**: The guard that refuses work while a run is active MUST treat a live worker as an active run, whether or not a control process is alive, and MUST refuse with the same refusal it already uses for an active run.
- **FR-006**: The existing explicit operator override MUST remain the single way past that refusal, and MUST still drain the prior worker before proceeding.
- **FR-007**: A drain MUST be scoped to the repository being superseded; workers belonging to other repositories' runs MUST be untouched.
- **FR-008**: No record may be written that claims a phase made progress its stopped session did not make.
- **FR-009**: The worker MUST remain independent of its run's control process — a control process ending MUST NOT, by itself, stop a worker.
- **FR-010**: The supersession record outcome for the prior run and its features MUST be unchanged by this feature.
- **FR-011**: The cost-breaker drain and the parked-run refusal MUST be unchanged and MUST remain distinguishable from this drain in everything the operator sees.
- **FR-012**: Starting a run for a repository with nothing in flight MUST behave exactly as it does today, with no added delay.
- **FR-013**: The operator MUST be able to tell, without starting any work, whether a worker is currently in flight for a repository.

### Key Entities

- **Worker**: the unit that drives one feature through its phases and holds the external model session. Independent of the control process; currently nothing stops it when its run is superseded.
- **Control process**: the per-run decision-maker that releases features in order. Already stopped on supersession.
- **External session**: the model session a worker holds while a phase runs. Must never outlive its worker.
- **Drain**: the bounded, boundary-respecting stop applied to a worker when its run is superseded or explicitly overridden.
- **Active-run refusal**: the existing refusal that keeps a second run from starting on top of a first; extended here to see workers, not only control processes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero occurrences of two model sessions writing to one working copy, across supersession, whole-run resume, and single-feature resume.
- **SC-002**: Zero duplicated phase-progress commits on a feature branch after a supersession or a resume.
- **SC-003**: 100% of drained phases have their boundary record written before their worker stops.
- **SC-004**: A resume attempted while a worker is in flight refuses in 100% of cases, and starts no work and spends nothing when it refuses.
- **SC-005**: Starting a run against a repository with nothing in flight takes no longer than it does today.
- **SC-006**: A drain that cannot complete tells the operator which feature is still working, in 100% of timeout cases, and never leaves a partially started new run behind.

## Assumptions

- **Drain bound**: the drain waits as long as the in-flight phase's own deadline allows, plus the existing grace period — the same bound the system already applies when waiting on a phase session — rather than introducing a second, shorter timer that could fire while a phase is still legitimately working. A superseding operator therefore waits at most one phase, not one feature. The alternative (a short fixed bound, then refuse) was considered and rejected: it would turn every supersession during a long implementation phase into a refusal, and the operator's only recourse would be the override, which is the blunt instrument this feature is trying to make unnecessary.
- The worker's session already shuts its external process down cleanly when the worker stops it from the inside; this feature asks the worker to stop, it does not introduce a new way to kill a session from the outside. An outside kill is known to strand the external process and must not be used.
- One feature runs at a time today, so in practice the drain handles a single worker; the requirement is written for several because the guarantee must not depend on that structural property.
- The resume-position defect observed in the same incident (a whole-run resume rewinding to an earlier phase) is a separate concern with its own feature and is out of scope here.
- No new operator surface is introduced. The drain's timeout message and the extended active-run refusal follow the wording conventions of the refusals that already exist.
