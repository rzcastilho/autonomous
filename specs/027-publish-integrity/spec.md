# Feature Specification: Publish Integrity

**Feature Branch**: `027-publish-integrity`

**Created**: 2026-09-23

**Status**: Draft

**Input**: User description: "Feature 027 — publish integrity: a feature's work must land on, and be published from, the branch the orchestrator created for it; a failed publish must stop the stacked chain instead of silently advancing it." (The full incident narrative and the three defects are summarised under Background below.)

## Background: the incident

This is the mod-player run of 2026-09-23, backlog feature `002-control-variants`:

1. The orchestrator created the feature's worktree on branch `feature/015-control-variants` (spec_number 015). It forked from the stack base `feature/014-design-tokens-and-type-scale` at `3d923c3`.
2. During `specify`, the model ran the target repository's mandatory `before_specify` extension hook (`speckit.git.feature`). That hook's branch script computed its own next number and switched the worktree to a new branch, `016-control-variants`.
3. Every later checkpoint and implement commit landed on `016-control-variants`. The orchestrator's branch `feature/015-control-variants` never moved off the base tip.
4. On `:done`, the publish step resolved the feature's branch by name (`feature/015-control-variants`) and pushed that empty branch. Opening the pull request then failed, because there were no commits between base and head.
5. The publish step is best-effort by design (019 FR-018). It logged a warning, then still advanced the stack onto the empty branch.
6. Feature `003` was therefore released on `3d923c3`, **without any of 002's code**. Its worktree drifted the same way, to `017-list-row-and-panel-components`.
7. The run kept spending budget on a broken chain until an operator stopped it by hand.

Three defects allowed this, and each is closed by one user story below:

- **(US1)** Nothing pins the branch the model's tooling may create.
- **(US2)** Nothing checks, after a phase, that the worktree is still on the orchestrator's branch.
- **(US3)** A failed or empty publish still advances the chain.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A failed or empty publish stops the chain (Priority: P1)

An operator starts an unattended stacked run over a backlog. One feature reaches `:done`, but publishing it fails. The cause might be that the branch has no commits beyond its stack base, that the push is rejected, or that the forge refuses to open the pull request. The run must not release the next feature on top of a branch that does not carry the previous feature's work. It stops the chain at that feature and parks the run. It records which feature stopped it and why, including the verbatim git/forge output. The operator sees this on every operator surface and can fix the publish, then continue or end the run.

**Why this priority**: This is the defect that turned one bad feature into a corrupted chain and wasted budget. Even if drift were never detected, stopping at an unpublishable feature bounds the damage to that one feature. It is the minimum viable fix.

**Independent Test**: Drive a stacked run through the publisher seam. Make the publisher return an error (or make the feature's branch identical to its base) for the first feature. Verify that no second feature is released, that the run is parked, that `stopped_by` names the first feature with a publish-failure reason carrying the output, and that the stack was not advanced onto the failed branch.

**Acceptance Scenarios**:

1. **Given** a stacked run where feature A reaches `:done` and its branch has zero commits beyond its stack base, **When** the publish step runs, **Then** no push and no pull-request creation is attempted, the run parks with `stopped_by` naming A and a reason identifying an empty branch (branch, base, and both commit ids), and feature B is never released.
2. **Given** feature A's branch carries work but the push is rejected, **When** the publish step runs, **Then** the run parks with `stopped_by` naming A, and the reason carries the push failure output verbatim.
3. **Given** the push succeeds but opening the pull request fails, **When** the publish step runs, **Then** the run parks with `stopped_by` naming A, and the reason carries the forge's failure output verbatim.
4. **Given** a publish that succeeds, **When** the next feature is released, **Then** behaviour is unchanged from today: the PR URL is recorded, the stack advances to A's branch, and B branches from it.
5. **Given** an ad-hoc feature (which never advances the chain) whose publish fails, **When** the run continues, **Then** behaviour is unchanged from today: the failure is logged and emitted, and no parking is triggered by it.
6. **Given** a run parked by a publish failure, **When** the operator repairs the publish (for example, opens the PR by hand and records it) and issues the existing `:continue` decision, **Then** the chain resumes from the next feature, stacked on the parked feature's branch, without rebuilding the parked feature.

---

### User Story 2 - Branch drift fails the phase that caused it (Priority: P1)

After any phase session in a feature's worktree, the orchestrator verifies that the worktree is still on the branch it created for that feature. If the model's tooling switched branches during the session (as the target's speckit git extension did), that phase fails loudly at once. The failure records the expected and observed branch. The orchestrator must not silently continue on, or silently re-point, a branch it did not create.

**Why this priority**: This is the direct detector for the incident's root cause. It catches drift at the phase where it happens (here, `specify`), so no further budget is spent building on the wrong branch, and no later publish can mis-attribute the work. It is P1 alongside US1 because either one alone would have stopped the incident's cascade.

**Independent Test**: Give a feature a worktree whose phase session switches HEAD to another branch (a stubbed session that runs `git checkout -b other`). Verify that the phase is recorded as failed with a drift reason naming both branches, that the feature ends `:failed` with its worktree kept, and that no later phase runs.

**Acceptance Scenarios**:

1. **Given** a feature running in worktree W on branch `feature/NNN-slug`, **When** a phase session ends with W's HEAD on a different branch, **Then** the phase fails with a branch-drift reason recording the expected branch and the observed branch (or "detached" if HEAD is detached).
2. **Given** a detected drift, **When** the feature terminates, **Then** no commit, squash, or checkpoint is written on either branch after detection, the worktree is kept for post-mortem, and the stray branch is left untouched.
3. **Given** a phase session that ends on the expected branch, **When** the check runs, **Then** it passes silently, and the phase outcome is exactly what it would have been without the check.
4. **Given** an implement step split into chunks, **When** any single chunk session ends off-branch, **Then** that chunk fails with the drift reason, and no later chunk runs.
5. **Given** a remediation session (the analyze auto-remediation loop) that ends off-branch, **When** the check runs, **Then** it fails the same way.

---

### User Story 3 - The orchestrator's branch is pinned for spec tooling (Priority: P2)

When the orchestrator asks the model to run `specify`, it tells the target repository's spec tooling the exact branch name to use: the branch the orchestrator already created for the feature. It also allows that branch to already exist. A target repository whose spec tooling auto-creates a feature branch (as mod-player's mandatory `before_specify` hook does) therefore reuses the orchestrator's branch instead of inventing a new one, and the run proceeds normally.

**Why this priority**: This is prevention, not detection. It makes targets that carry the speckit git extension work instead of just failing loudly. It is P2 because US1 and US2 already make the failure safe and visible; this makes it rare.

**Independent Test**: Build the specify request for a feature and verify that it carries the orchestrator's branch name as the exact branch override, alongside the already-pinned spec directory. Then run against a scratch target carrying the git extension's branch script, and verify that the worktree HEAD after `specify` is still `feature/NNN-slug`.

**Acceptance Scenarios**:

1. **Given** a feature with spec id `NNN` and slug `slug`, **When** the specify request is built, **Then** it names `feature/NNN-slug` as the exact branch to use and states that the branch already exists and must be reused, not recreated.
2. **Given** a target repository with no branch-creating hook, **When** `specify` runs, **Then** behaviour is unchanged.
3. **Given** a model that ignores the instruction and switches branch anyway, **When** the phase ends, **Then** US2's gate fails the phase. The pin is a mitigation; the gate is the guarantee.

---

### Edge Cases

- **Base resolved past merged links.** The stack base the PR targets may be the trunk, because earlier links were merged and skipped. The "commits beyond base" check MUST be measured against the same base the pull request will target, not the original stack predecessor.
- **Remote branch already exists from an earlier run and equals the base.** In the incident, `origin/feature/015-control-variants` existed at the base tip. The emptiness check runs before any push, so a stale-but-equal remote branch never hides an empty local branch.
- **Detached HEAD after a session.** This counts as drift, with observed branch recorded as detached.
- **Drift and a successful transcript in the same session.** Drift takes precedence: the phase fails even though the session reported success, in the same family as the incomplete-session gate.
- **Drift gate retry policy.** Drift MUST NOT be auto-retried. A retry would run on a worktree whose HEAD is not the orchestrator's branch. Unlike the artifact and incomplete-session gates, the right response is to stop.
- **Resume of a drift-failed feature.** An operator may restore the worktree to the orchestrator's branch by hand (for example, by moving the stray commits back) and use the existing `resume/2` / `resolve/1` paths. The gate then passes because HEAD matches.
- **Breaker trips during publish.** Publishing is not a spend-bearing phase. A tripped breaker does not change publish-failure handling, and parking for a publish failure still records the publish reason.
- **Run with only one remaining feature.** A publish failure on the last backlog feature still parks the run rather than draining it as complete. The operator must see that the last feature was built but not published.
- **Seam-injected (test) runs.** Existing tests that inject `:publisher` / `:executor` / `:runner` keep working. A publisher returning `{:error, _}` now parks the run in those tests too, which is the new, intended behaviour.

## Requirements *(mandatory)*

### Functional Requirements

**Publish integrity (US1)**

- **FR-001**: Before publishing a backlog feature that reached `:done`, the system MUST verify that the feature's branch contains at least one commit not reachable from the base the pull request will target. If it contains none, the publish MUST fail with an empty-branch reason (branch, base, and both commit ids) without pushing or opening a pull request.
- **FR-002**: A failed publish of a backlog feature (empty branch, push failure, or pull-request creation failure) MUST stop the stacked chain. The system MUST NOT advance the stack onto that feature's branch and MUST NOT release any later feature.
- **FR-003**: On such a failure, the run MUST be parked through the same mechanism a non-`:done` terminal uses today: a parked run, a final report whose `stopped_by` names the feature, and a refusal of new work until the operator resolves the park with `:continue` or `:end`. The recorded reason MUST identify the failure as a publish failure and carry the git/forge output verbatim.
- **FR-004**: The publish-failure reason MUST be visible on every surface that shows today's `stopped_by`: the run report, `status/0` / `print_status/0`, and the operator console's run and feature views. A telemetry event MUST also be emitted (the existing publish-failed event, still carrying the reason).
- **FR-005**: A feature whose build succeeded but whose publish failed MUST be distinguishable, in the durable record and on operator surfaces, from both a successfully published `:done` feature and a build failure. Its built branch MUST NOT be discarded, and resolving the park MUST NOT require re-running its phases.
- **FR-006**: On `:continue` after a publish-failure park, the chain MUST resume with the next feature stacked on the parked feature's branch (the stack advance withheld in FR-002 is applied then). On `:end`, the run closes as today.
- **FR-007**: Ad-hoc features, which never advance the chain, MUST keep today's best-effort publish behaviour: log and emit telemetry, no parking.
- **FR-008**: A successful publish MUST behave exactly as today: record the PR URL, emit the opened event, and advance the stack.

**Branch-drift gate (US2)**

- **FR-009**: After every session the orchestrator drives inside a feature's worktree (each pipeline phase, each implement chunk, each auto-remediation attempt), the system MUST compare the worktree's current branch to the branch the orchestrator created for that feature.
- **FR-010**: On mismatch, including a detached HEAD, the session's phase MUST fail with a branch-drift reason recording the expected branch and the observed branch (or detached plus commit id). The failure MUST be durably recorded on the phase attempt and surfaced wherever phase failure reasons are surfaced today.
- **FR-011**: A branch-drift failure MUST NOT be auto-retried, and the system MUST NOT commit, squash, checkpoint, check out, reset, or delete any branch in that worktree after detecting it. The worktree is kept for post-mortem, as for any non-`:done` terminal.
- **FR-012**: The drift check MUST be decided by a pure function over extracted signals (expected branch, observed branch), consistent with how the other gates are decided. Only the extraction reads git.

**Branch pinning (US3)**

- **FR-013**: The `specify` request MUST name the orchestrator's branch for the feature as the exact branch the spec tooling is to use, and MUST state that the branch already exists and is to be reused, not created. It MUST do so alongside the existing pinned spec directory.
- **FR-014**: Branch pinning MUST NOT change the orchestrator's branch naming (`feature/<spec_id>-<slug>`), spec-directory naming, or behaviour on targets without branch-creating tooling.

**Compatibility**

- **FR-015**: No new operator-configurable setting is introduced. Publish-failure parking and the drift gate are always on for backlog features in stacked runs.
- **FR-016**: Existing records (runs, feature runs, phase attempts written before this feature) MUST remain readable. Any new recorded field MUST be additive under the store's existing migration discipline.

### Key Entities *(include if feature involves data)*

- **Publish outcome**: the result of publishing one feature. It is either opened (with URL) or failed, and a failure has a kind (empty branch / push rejected / PR creation failed), the branch, the target base, and the verbatim tool output. It is attached to the feature's run record and, on failure, to the run's `stopped_by`.
- **Branch-drift signal**: the expected branch, the observed branch (or detached plus commit id), and the session it was observed after (phase, chunk index, or remediation attempt). It is the input to the drift gate and is recorded on the failing phase attempt.
- **Stopped-by record**: the existing parking record (feature, status, reason), extended so its reason can express a publish failure.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Replaying the incident shape (a feature whose branch ends equal to its base, or whose publish fails for any reason) releases 0 subsequent features. The run is parked in every case, with `stopped_by` naming that feature.
- **SC-002**: In 100% of publish failures, the operator can read the exact failure output (the git or forge message) from the run report and the console without opening log files.
- **SC-003**: A session that leaves the worktree off the orchestrator's branch is detected before any further phase of that feature runs: 0 additional phase sessions are spent after drift.
- **SC-004**: Against a target repository carrying the speckit git extension's mandatory branch hook, a feature completes `specify` with its worktree still on the orchestrator's branch, with no operator intervention.
- **SC-005**: Runs where every publish succeeds and no drift occurs produce the same feature order, stack shape, PR bases, and final report as before this feature (apart from any new field that is empty on success).
- **SC-006**: After resolving a publish-failure park with `:continue`, 0 phases of the parked feature are re-run, and the next feature's base is the parked feature's branch.

## Assumptions

- The stacked sequential run (019) is the only run shape, and publishing is part of it. "Non-publishing runs" therefore means seam-injected test runs and the ad-hoc group; there is no separate publish-off switch to preserve.
- The operator's recovery from a publish-failure park is manual: open or fix the PR, optionally record it with the existing `record_pr/3`, then `continue_run/1`. Automating that recovery is out of scope.
- Recovering the 2026-09-23 incident's data (002's work on local `016-control-variants`) is a manual operator step and out of scope, as are changes to any target repository's speckit extension configuration.
- The target's spec tooling honours an exact-branch-name override with reuse-if-exists semantics (the speckit git extension's `GIT_BRANCH_NAME` plus allow-existing-branch). Targets whose tooling ignores it are covered by the drift gate, not by the pin.
- A worktree's "current branch" is the symbolic ref of its HEAD. A detached HEAD is never the expected branch.
- Constitution Principle II (fail loud at boundaries) and Principle V (worktree retained on non-`:done` terminals) govern this feature. No constitution amendment is expected, since the behaviour tightens rather than relaxes existing gates.
