# Feature Specification: Remove Cost Budget Breaker and Strict Containment Profile

**Feature Branch**: `039-remove-budget-strict-profile`

**Created**: 2026-10-09

**Status**: Draft

**Input**: User description: "Remove the Cost breaker budget from application, cost is just an informational feature, and remove distinction between strict and permissive, keep only the run over container that is permissive, remove all associated configurations"

## Clarifications

### Session 2026-10-09

- Q: When a run starts outside the container, should the system block or warn? → A: Warn at preflight and proceed
- Q: With one permissive profile, what happens to the agent-root `sudo` rules? → A: Drop the sudo grammar; keep agent-root markers, prompt note, and install logging
- Q: How are existing target repos with an older pack handled? → A: Bump pack contract; preflight fails on older pack with reinstall instructions
- Q: How are legacy budget/profile options handled? → A: Reject; run does not start and error names the removed option

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cost is informational only; runs never stop on spend (Priority: P1)

An operator starts a run and no longer sets, sees, or has to reason about a spend budget. The run proceeds through every feature until the backlog is exhausted or a feature reaches a non-done terminal state for a real reason (escalation, halt, failure). Cost is still measured and shown — per phase, per feature, per run — so the operator can see what a run spent, but it never gates, pauses, or halts anything.

**Why this priority**: The budget breaker is the one mechanism that can stop a run for a non-correctness reason. Removing it changes run semantics and touches the control plane, so it is the core of this feature and must be provably complete.

**Independent Test**: Start a run with cost reporting producing large totals (simulated or real). Confirm the run releases and completes every remaining feature, no feature is halted "between phases" for spend, and the final report shows total spend as plain information.

**Acceptance Scenarios**:

1. **Given** a run whose cumulative cost exceeds any figure that previously would have been a budget, **When** the next phase or feature is due, **Then** it starts normally and no spend-related halt, drain, or refusal occurs.
2. **Given** a completed run, **When** the operator views the final report, run status, and console, **Then** per-phase, per-feature, and total cost are shown as informational figures with no budget, remaining-budget, or "breaker tripped" wording.
3. **Given** the operator configures a run (config files, environment, console Trigger/Configuration, API call options), **When** they look for a budget setting, **Then** none exists, and supplying a legacy budget setting rejects the start with an error naming the option.
4. **Given** a phase session reports no actual cost, **When** the run records cost, **Then** the existing fallback estimate still populates the informational figure so totals remain meaningful.

---

### User Story 2 - One containment behavior: permissive, run inside the container (Priority: P1)

An operator starts a run and is never asked to choose between `strict` and `permissive`. There is a single behavior — what was called `permissive` — and the supported way to run is inside the container. Per-phase permissions are full access; no orchestrator-session deny list is applied. The profile choice, its locking, its resume/continue inheritance rules, and every operator-surface rendering of the profile disappear.

**Why this priority**: Equal in weight to Story 1: the two-profile distinction runs through the permission model, preflight, pack, hook, reports, PR body, console, and docs. Leaving half of it behind would create dead, misleading options.

**Independent Test**: Start a run with no profile setting; confirm sessions run with the full-access permission set, the preflight accepts the committed pack, and no output mentions a profile. Confirm there is no way to request `strict`.

**Acceptance Scenarios**:

1. **Given** a default run, **When** phase sessions start, **Then** they receive the permission set formerly granted under `permissive`, with no profile selection step.
2. **Given** any operator surface (final report, status table, console topbar/Run Detail/Configuration, PR body), **When** it renders a run, **Then** no containment-profile label or row appears, and the `strict`-era byte-identical output guarantee is replaced by the new single output.
3. **Given** an operator supplies a containment-profile option in config, environment, or an API/console call, **When** the run starts, **Then** the start is rejected with an error naming the removed option.
4. **Given** a halted or escalated feature is resumed or a parked run is continued, **When** it restarts, **Then** no profile is read from, written to, or compared against the stored run record.
5. **Given** a run is started outside the container, **When** preflight runs, **Then** the operator is shown a loud, explicit warning that the container is the supported runtime for unrestricted sessions, and the run proceeds.

---

### User Story 3 - Stored data, docs, and governance stay consistent (Priority: P2)

Existing run records that carry budget or profile fields still load and display correctly; documentation, the runbook, enforcement and container guides, smoke checks, and the project constitution no longer describe a budget breaker or two profiles, so the next feature's pipeline (clarify, analyze, converge) is not steered by stale rules.

**Why this priority**: Not user-visible at run time, but stale governance text would make future automated runs enforce principles that no longer exist.

**Independent Test**: Load a run record created before this change; confirm it opens in Run Detail and the report without error. Search docs, config, constitution, and smoke scripts for budget-breaker and profile terminology; confirm only historical/migration mentions remain.

**Acceptance Scenarios**:

1. **Given** a stored run containing legacy budget/profile fields, **When** it is read by report, console, resume, or continue, **Then** it loads without error and the legacy fields are ignored or shown only as historical data.
2. **Given** the repository after this change, **When** reviewing the constitution, **Then** the cost-bounded-autonomy and least-privilege-containment principles are amended (version bumped) to reflect informational cost and a single permissive container-run model.
3. **Given** the container smoke checks, **When** run, **Then** no check depends on the removed budget or profile options, and the checks that remain pass.

---

### Edge Cases

- A run record or checkpoint written before this change contains a breaker-tripped or `strict` marker: it must not resurrect either behavior on resume/continue.
- An in-flight run at upgrade time that was parked or drained *because of* a tripped breaker: continuing it must simply proceed, not re-park.
- Existing target repositories carry the committed pack at an older contract version: preflight fails with a message naming the required version and how to reinstall; it must not fail on profile-related checks that no longer exist.
- Operator scripts or CI that still pass a budget or profile option: the start is rejected and the error names the removed option, not a vague unknown-key error.
- Cost data unavailable for a session: informational total still computed from estimates; no phase may fail because cost is missing.
- Agent-root (sudo) under the single profile: any `sudo` command is permitted; markers, prompt note, and install logging still work and are tested.
- The drain-on-supersession mechanism (feature 026) shares "drain, don't kill" discipline with the breaker; it must keep working after the breaker is removed.

## Requirements *(mandatory)*

### Functional Requirements

**Cost budget / breaker removal**

- **FR-001**: The system MUST NOT stop, pause, drain, refuse, or fail any run, feature, phase, chunk, or remediation attempt on the basis of accumulated cost.
- **FR-002**: The system MUST NOT expose a spend budget setting anywhere (application config, environment, run start options, console forms, public API).
- **FR-003**: The system MUST continue to measure cost per phase attempt (actual when reported, estimate otherwise) and roll it up per feature and per run.
- **FR-004**: All operator surfaces (final report, status table, console, run records) MUST present cost as informational only, with no budget, headroom, reservation, or breaker-state wording.
- **FR-005**: A "breaker tripped" feature or run outcome MUST no longer exist as a terminal reason, report tally, or console state.
- **FR-006**: Any legacy budget option supplied to a run MUST cause the start to be rejected (no run begins), with an error naming the removed option.

**Containment profile removal**

- **FR-007**: The system MUST offer exactly one containment behavior, equivalent to the former `permissive` profile, for all orchestrator-driven sessions.
- **FR-008**: The system MUST NOT expose a containment-profile setting anywhere (config, environment, run start options, console forms, public API, resume/continue options); a supplied legacy profile option MUST reject the start with an error naming it.
- **FR-009**: Per-phase permissions MUST be the full-access set formerly granted under `permissive`, with no scoped variant remaining.
- **FR-010**: Run records, resume, and continue MUST NOT store, lock, compare, or require a profile value.
- **FR-011**: No operator surface (report, status table, console topbar/Run Detail/Configuration, PR body) MUST render a containment-profile label.
- **FR-012**: The target-pack preflight MUST drop all profile-dependent checks. The pack contract version MUST be bumped; preflight MUST fail on a target whose committed pack is older than the new contract, with a message naming the required version and the reinstall step.
- **FR-013**: The in-tree deny list for orchestrator-driven sessions and the origin-by-profile matrix it required MUST be removed; behavior for a human's own interactive session MUST remain unaffected (never denied).
- **FR-014**: The container MUST be documented and presented as the supported runtime for runs; a non-container start MUST emit a loud preflight warning and then proceed; it MUST NOT be blocked.
- **FR-015**: The closed `sudo` command grammar (formerly allowed only under `strict`) MUST be removed, since the single profile applies no deny list. The agent-root markers, the prompt note advertising root availability, and package-install logging MUST remain, with tests covering them.

**Cleanup and consistency**

- **FR-016**: All configuration keys, environment variables, defaults, validation, console fields, tests, fixtures, smoke checks, and documentation that exist solely for the budget or the profile distinction MUST be removed.
- **FR-017**: Stored data written before this change MUST remain readable; legacy budget/profile fields MUST NOT alter behavior.
- **FR-018**: The project constitution MUST be amended (with version bump and sync-impact note) so no principle requires a cost circuit breaker or a strict/permissive split; related templates and docs MUST agree.
- **FR-019**: Supersession drain and the independent drain-on-request behavior MUST continue to work unchanged.
- **FR-020**: The full automated test suite, formatter, and design-contract guard MUST pass with no warnings.

### Key Entities

- **Run cost record**: Per-phase attempt cost (actual or estimated), rolled up per feature and per run; informational only, carries no limit.
- **Run record**: Durable per-run state; no longer carries a budget, breaker state, or containment profile. Legacy fields tolerated on read.
- **Target pack**: Committed scaffold in the target repo providing settings and a contract-version marker; the former PreToolUse hook is removed, the contract version is bumped, and preflight rules lose profile-dependent elements.
- **Operator surfaces**: Final report, status table, console views, PR body — all lose budget and profile rendering.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A run whose reported spend is arbitrarily large (including multiples of the former default budget) completes every releasable feature with zero spend-caused halts, in 100% of tested scenarios.
- **SC-002**: Searching configuration, public options, console forms, and operator-facing output for budget or containment-profile settings finds none outside historical notes and migration messages.
- **SC-003**: 100% of operator surfaces that previously showed a profile or budget state render without them, and still show total spend as a plain figure.
- **SC-004**: Run records created before this change load and display without error in 100% of tested cases, and never reinstate removed behavior.
- **SC-005**: A start request carrying a removed option is answered with an explicit message naming that option in 100% of tested cases.
- **SC-006**: The full automated suite passes with zero warnings, and the container smoke checks that remain pass.
- **SC-007**: Constitution, runbook, enforcement guide, and container guide agree with each other and with behavior, verified by a documentation sweep finding no stale breaker or two-profile instructions.

## Assumptions

- "Cost breaker budget" means the whole mechanism: the budget setting, reservation accounting that gates new work, breaker-tripped state, and drain-on-trip behavior. Cost measurement and display stay.
- "Keep only the run over container that is permissive" means the former `permissive` behavior becomes the only behavior and the container is the supported runtime; the in-tree `strict` path and every option choosing between them are removed.
- Hard per-session timeouts, phase deadlines, shell timeouts, and attempt limits are not cost controls in the budget sense and are out of scope; they stay.
- Because `permissive` already applies no deny list, the hook's orchestrator-session deny logic becomes dead and is removed; a human interactive session stays unrestricted.
- Backward compatibility is limited to reading old stored records; old config keys and options are rejected, never honored.
- Behavior-changing amendments to the constitution are done as part of this feature (per the project's rule that semantic changes flow through a spec), not as a direct edit.
- Per-feature estimates for phases without reported cost remain in config as the informational fallback.
