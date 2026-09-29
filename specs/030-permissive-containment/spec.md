# Feature Specification: Permissive Containment Profile

**Feature Branch**: `030-permissive-containment`

**Created**: 2026-09-28

**Status**: Draft

**Input**: User description: "Adjust agent application to be more lenient and allow actions as I'm running Claude Code directly"

## Context

Today every target repository carries the orchestrator's enforcement pack. The
pack denies a fixed set of actions to any Claude Code session in that repository:
pushing to a remote, network access (download tools, web fetch, web search),
writes that land outside the repository, privilege escalation, and a list of
"dangerous" shell patterns. The same denials also hit the operator when they open
Claude Code themselves in the target repository, for example to resolve an
escalation. They also stop headless phase sessions from doing legitimate work,
such as fetching a dependency's documentation or reaching a sibling directory.

The operator wants the agent to be allowed the same actions they have when they
run Claude Code directly. Clarified scope (2026-09-28):

- **Sessions covered**: both the operator's own interactive sessions and the
  orchestrator-driven headless phase sessions.
- **Actions to allow**: pushing to a remote; network access (download tools, web
  fetch, web search); writes outside the repository; privilege escalation and the
  other shell patterns the pack denies today.

This change relaxes a constitution MUST (Principle III, Least-Privilege
Containment, Fail-Closed). The feature is therefore designed as an explicit,
visible, opt-in profile. The strict profile stays the default and stays
byte-identical to today. The feature cannot ship until a constitution amendment
ratifies it (FR-014).

## Clarifications

### Session 2026-09-28

- Q: Keep a host-destroying block list (`rm -rf /`, `rm -rf ~`, fork bomb, `chmod -R 777 /`) under `permissive`? → A: No. `permissive` blocks nothing at the pack level; no floor.
- Q: Do read-only phases (clarify reviewer, analyze) stay read-only for file edits under `permissive`? → A: No. Every phase gets full write and Bash access under `permissive`.
- Q: Which profile is the shipped default? → A: `strict`. The operator opts in per run, or sets `permissive` as the global configuration default.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator's own Claude Code session is not blocked (Priority: P1)

The operator opens Claude Code interactively inside a target repository that
carries the pack (the main checkout or a kept feature worktree). They ask it to
push a branch, fetch a web page, run a download command, or edit a file in a
sibling directory. Claude Code does these actions under the operator's own
normal permission prompts. The pack does not deny them.

**Why this priority**: The operator hits this friction every time they resolve an
escalation or inspect a kept worktree. The risk is low because a human watches
and approves each action. The fix is valuable without any change to the
autonomous runs.

**Independent Test**: Install the pack into a scratch repository. Start an
interactive Claude Code session there, not through the orchestrator. Request each
of the four action classes. Confirm the pack denies none of them. Start an
orchestrator-driven session in the same repository with the strict profile.
Confirm the same four requests are still denied.

**Acceptance Scenarios**:

1. **Given** a target repository with the pack installed, **When** the operator
   runs Claude Code directly and asks it to push the current branch, **Then** the
   pack does not deny the push.
2. **Given** the same repository, **When** the operator's session requests a web
   fetch, a web search, or a download command, **Then** the pack does not deny it.
3. **Given** the same repository, **When** the operator's session writes a file
   outside the repository root, **Then** the pack does not deny the write.
4. **Given** the same repository, **When** an orchestrator-driven session runs
   under the strict profile and makes any of the requests above, **Then** the
   pack denies them exactly as it does today.

---

### User Story 2 - Operator opts a run into the permissive profile (Priority: P2)

The operator starts a run and selects the permissive containment profile, from
the Trigger Run page or from the run options. Every headless session in that
run (phases, implement chunks, remediation steps, auto-remediation steps) may
push, use the network, write outside the worktree, and run the shell commands
the strict profile denies. The only exception is the headless-only tool
exclusions in FR-008.

**Why this priority**: This is the main ask for autonomous runs. It depends on
the profile concept and on the operator surfaces from Story 3, so it ranks after
the no-risk human case.

**Independent Test**: Start a run with the permissive profile against a scratch
target. Use a feature whose phases need a web fetch and a write to a sibling
directory. Confirm both succeed and the feature reaches `:done`. Start the same
run with the default profile. Confirm the same actions are denied as today.

**Acceptance Scenarios**:

1. **Given** a run started with the permissive profile, **When** a phase session
   requests a web fetch, **Then** the request is not denied by the pack or by
   per-phase permissions.
2. **Given** a run started with the permissive profile, **When** a phase session
   runs a push command, **Then** the push is not denied.
3. **Given** a run started with the permissive profile, **When** a session writes
   outside the feature worktree, **Then** the write is not denied.
4. **Given** a run started without a profile choice, **When** any session makes
   the requests above, **Then** they are denied exactly as today.
5. **Given** a run started with the permissive profile, **When** a session ends
   on a branch other than the orchestrator's branch, **Then** the branch-drift
   gate still fails the phase. Artifact, incomplete-session, analyze and clarify
   gates also behave exactly as today.

---

### User Story 3 - The profile is always visible (Priority: P3)

Whenever a run uses the permissive profile, every operator surface shows it:
the run's final report, the status snapshot, Mission Control, Run Detail, and
the Configuration page. A reviewer who reads the pull request of a feature built
under the permissive profile sees a note that says so.

**Why this priority**: Constitution Principle VII (operator surfaces tell the
truth) needs this for any relaxation of a safety guarantee. It adds no new
capability, so it ranks last. It must ship in the same release as Story 2.

**Independent Test**: Run one feature under each profile. Compare the report,
console pages, and PR body. Only the permissive run shows the profile marker.
The strict run's surfaces are unchanged from today.

**Acceptance Scenarios**:

1. **Given** a run under the permissive profile, **When** the operator opens Run
   Detail or Mission Control, **Then** the page shows the run is under the
   permissive profile.
2. **Given** a feature under the permissive profile reaches `:done` and opens a
   PR, **When** a reviewer reads the PR body, **Then** it states the feature was
   built with relaxed containment.
3. **Given** a run under the strict profile, **When** the operator views any
   surface, **Then** no permissive marker appears and output is byte-identical to
   today.

---

### Edge Cases

- A run is resumed, continued, or superseded. The resumed or continued work keeps
  the profile recorded on the original run. A profile change needs a fresh run.
- The operator picks the permissive profile against a target whose committed pack
  predates this feature. The preflight fails loudly and names the pack upgrade.
  The run does not start silently under strict rules.
- The hook gets malformed input under the strict profile. It still fails closed.
  Under the permissive profile, malformed input still denies file writes and Bash
  (fail closed). Only well-formed requests get the relaxed rules.
- A permissive session pushes to the orchestrator's feature branch before the
  orchestrator publishes. The publish step still runs. The run does not fail only
  because the remote branch already exists with the same commits.
- A permissive session pushes to a branch other than the orchestrator's branch.
  The orchestrator does not treat that push as a publish. The branch-drift gate
  judges only the checked-out branch at session end.
- An analyze session under `permissive` edits the spec, plan, or tasks it
  reviews. The analyze gate still decides only from the findings that analyze
  reports. The edits stay in the worktree and are committed with the feature.
- A host-destroying command (for example `rm -rf /`) is requested under the
  permissive profile. The pack does not deny it (FR-006). The container recipe
  is the only protection left.
- The operator's interactive session is started from a directory that holds an
  orchestrator worktree. It is still treated as a human session, because the
  orchestrator did not start it.

## Requirements *(mandatory)*

### Functional Requirements

**Profiles**

- **FR-001**: The system MUST define two containment profiles: `strict` (today's
  behavior) and `permissive`.
- **FR-002**: `strict` MUST be the default for every run. A run with no profile
  choice MUST behave byte-identically to today at the pack, at per-phase
  permissions, and on every operator surface.
- **FR-003**: The operator MUST be able to select the profile per run, from the
  run options and from the Trigger Run page. The operator MUST also be able to
  set a global default in configuration. The shipped global default MUST be
  `strict`. A per-run choice overrides the global default.
- **FR-004**: The profile MUST be recorded on the run when the run starts. Resume,
  continue, and publish-only resume MUST reuse the recorded profile. They MUST NOT
  pick up a changed configuration default.

**Permissive behavior for orchestrator sessions**

- **FR-005**: Under `permissive`, orchestrator-driven sessions MUST NOT be denied
  these actions, by the pack or by per-phase permissions: pushing to a remote;
  network access (download tools, web fetch, web search); writes that land outside
  the feature worktree; privilege escalation and the other shell patterns the
  strict profile denies. The only exception is FR-008.
- **FR-006**: Under `permissive`, the pack MUST NOT keep any deny list for
  well-formed requests. This includes host-destroying commands such as recursive
  deletion of the filesystem root or of the home directory.
- **FR-007**: Under `permissive`, every phase MUST get the same full tool set,
  including file writes, Bash, and network access. This includes phases that are
  read-only under `strict` (clarify reviewer, analyze). Under `strict`, per-phase
  narrowing MUST stay exactly as today.
- **FR-008**: Under both profiles, headless sessions MUST keep today's exclusion of
  the subagent and scheduling tools. These exclusions prevent sessions that end
  while waiting on background work. They are not containment.
- **FR-009**: Under both profiles, the branch-drift, artifact-substance,
  incomplete-session, analyze, and clarify gates, the cost breaker, and the
  session deadlines MUST behave exactly as today.
- **FR-010**: Malformed hook input MUST still deny file writes and Bash under both
  profiles (fail closed).

**Human sessions**

- **FR-011**: A Claude Code session that the orchestrator did not start, in a
  repository that carries the pack, MUST NOT be denied the actions in FR-005 by the
  pack. That session remains subject to the operator's own Claude Code permission
  settings and prompts.
- **FR-012**: The way the pack tells orchestrator sessions from human sessions
  MUST fail toward strict. If a session's origin cannot be decided, and the
  session could be orchestrator-driven, the pack MUST apply the run's profile. If
  no run profile is known, the pack MUST apply `strict`.

**Pack, preflight, visibility, governance**

- **FR-013**: Pack install and preflight MUST support both profiles from one
  committed pack. Preflight MUST fail loudly when the operator selects
  `permissive` and the target's committed pack cannot honor it.
- **FR-014**: Before implementation merges, a constitution amendment MUST ratify
  the permissive profile as an opt-in exception to Principle III. The amendment
  MUST keep strict as the default and record that `permissive` has no deny list.
- **FR-015**: Under `permissive`, the run report, the status snapshot, Mission
  Control, Run Detail, and the Configuration page MUST show the active profile.
  Every PR body for a feature built under `permissive` MUST state that it was built
  with relaxed containment. Under `strict`, these surfaces MUST NOT change.
- **FR-016**: Every denial under either profile MUST name the profile that applied
  and the rule that fired.
- **FR-017**: The runbook, the enforcement guide, and the project guidance file
  MUST describe both profiles and human-session behavior. They MUST recommend
  the container recipe for `permissive` runs, because no deny list remains. These docs
  are updated in the same change as the code.

### Key Entities

- **Containment profile**: A named set of rules (`strict` | `permissive`) that
  decides which actions a session may take. It belongs to one run and is fixed
  when the run starts.
- **Session origin**: Whether the orchestrator started a Claude Code session
  (orchestrated) or a human did (interactive). It decides whether the pack applies
  a run profile at all.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In the operator's own interactive sessions in a target repository,
  0 of the four action classes in FR-005 are denied by the pack.
- **SC-002**: Under `permissive`, a scripted probe run with one request per action
  class, including a host-destroying pattern checked only against the guard (not
  executed), gets 0 pack or per-phase denials.
- **SC-003**: Under `strict` (default), the existing containment red-team suite
  passes unchanged, and every existing operator-surface snapshot is byte-identical.
- **SC-004**: Every run under `permissive` shows the profile on 100% of the listed
  operator surfaces, and every PR it opens carries the relaxed-containment note.
- **SC-005**: A resumed or continued run keeps its original profile in 100% of the
  tested cases, including after the configuration default changes.

## Assumptions

- "Running Claude Code directly" means the operator starts the CLI themselves.
  Their own Claude Code settings and prompts then govern the session. The pack
  does not replace those prompts. It only stops adding its own denials.
- The operator accepts the risk: under `permissive`, an unreviewed autonomous
  session can push to remotes, reach the network, and change files outside the
  worktree. The container recipe (enforcement layer 3) stays available as an
  optional outer boundary.
- The operator's selection of "sudo / other dangerous Bash" is honored in full.
  `permissive` keeps no deny list (Clarifications 2026-09-28).
- Gates that protect pipeline correctness (branch drift, artifact substance,
  incomplete session) are not containment. They stay unchanged under both
  profiles.
- Mixed profiles inside one run (per phase or per feature) are out of scope. The
  profile is per run.
- The orchestrator's own publish step still owns the canonical push and PR. A
  session push under `permissive` is a side effect, not a replacement for publish.
