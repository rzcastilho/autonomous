# Feature Specification: Container Workspace Trust

**Feature Branch**: `036-container-workspace-trust`

**Created**: 2026-10-08

**Status**: Draft

**Input**: User description: "Container workspace trust: when the orchestrator runs inside the container (scripts/autonomous console/release/shell), every Claude Code session it starts warns "Ignoring N permissions.allow entries from .claude/settings.json: this workspace has not been trusted", because the container's private ~/.claude.json has no projects[<path>].hasTrustDialogAccepted entry for the target repository or its worktrees. The committed target pack's .claude/settings.json is therefore only partly effective in orchestrated sessions. The container entrypoint should mark the target repository ($AUTONOMOUS_REPO) and the instance's worktree root ($AUTONOMOUS_ROOT/worktrees/<segment>) as trusted in the container-private ~/.claude.json before any session starts — merged into whatever the file already holds (including a config seeded from the host by --with-login), written atomically (feature 034's torn-read lesson), never touching the host's own ~/.claude.json, and idempotent across restarts. It must not widen trust beyond those paths. Also establish whether the PreToolUse scope_guard hook runs in an untrusted workspace (strict containment depends on it) and record the finding. Covered by scripts/container-smoke.sh and docs/container.md; the host (non-container) path is unchanged."

## Context

Observed 2026-10-08 on the mod-player instance (run `r000003`): every session
the containerized orchestrator started logged
`Ignoring 6 permissions.allow entries from .claude/settings.json: this
workspace has not been trusted`. The container's agent CLI keeps its own
private configuration file; nothing ever records the target repository or the
instance's worktrees as trusted in it, so the target pack the operator
committed — the very settings the orchestrator depends on — is only partly
honoured inside the container, while the same pack works fully on the host.
The operator has no way to answer a trust prompt: orchestrated sessions are
headless.

## Clarifications

### Session 2026-10-08

- Q: What happens when a containerized session still starts in an untrusted workspace? → A: Under the `strict` containment profile the phase fails with a distinct untrusted-workspace reason; under `permissive` it is logged as a warning and the session continues.
- Q: Does the untrusted-session check (FR-013) also apply to runs on the host, outside the container? → A: Yes — it applies everywhere; the host gets no trust changes from this feature, but a `strict` host run whose session reports an untrusted workspace fails the same way.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Orchestrated sessions honour the committed pack in the container (Priority: P1)

An operator starts an instance for a target through the container
(console, release, or shell). Every session the orchestrator then starts —
in the target repository or in any of the instance's feature worktrees —
treats the workspace as trusted, so the target pack's committed settings
apply in full and no "workspace has not been trusted" warning appears.

**Why this priority**: This is the defect. Today every containerized run
silently operates with a partially applied pack, which differs from the host
and from what the operator committed.

**Independent Test**: Start an instance for a scratch target whose pack has
allow entries; run one orchestrated session in a worktree; confirm the
session log carries no untrusted-workspace warning and the allow entries are
in effect.

**Acceptance Scenarios**:

1. **Given** a fresh container for a target, **When** the orchestrator starts
   its first session in a feature worktree, **Then** the session reports no
   untrusted-workspace warning.
2. **Given** a fresh container, **When** a session starts with its working
   directory at the target repository itself, **Then** it is likewise trusted.
3. **Given** a container that has been stopped and started (or recreated)
   several times, **When** sessions start, **Then** they are trusted, and the
   CLI configuration holds exactly one trust record per trusted location (no
   duplicates accumulate).
4. **Given** a `strict` run whose session nonetheless reports an untrusted
   workspace, **When** the phase ends, **Then** the phase fails with a
   distinct untrusted-workspace reason that operator surfaces name, and it is
   not retried.
5. **Given** a `permissive` run in the same situation, **When** the session
   reports an untrusted workspace, **Then** a warning naming the workspace is
   logged and the phase proceeds.

---

### User Story 2 - Trust never reaches beyond this instance's own locations (Priority: P1)

Only the instance's target repository and the instance's own worktree root
are trusted. Any other directory visible inside the container — another
target's worktrees, the orchestrator's own source, the home directory, the
filesystem root — remains untrusted. The host's own CLI configuration is
never written.

**Why this priority**: Trust lets a repository's committed settings take
effect. Widening it would let content the operator never chose to trust take
effect too — a containment regression, equal in weight to the defect itself.

**Independent Test**: After start, read the container's CLI configuration and
confirm the trusted set is exactly the two instance locations; confirm the
host configuration file is byte-identical before and after the container ran.

**Acceptance Scenarios**:

1. **Given** a running instance, **When** the container's CLI configuration
   is inspected, **Then** exactly the target repository and the instance
   worktree root are marked trusted by this feature, and no ancestor of
   either (home, `/`, the shared state root) is.
2. **Given** an instance started with the host login seeded in, **When** the
   container runs, **Then** the host's configuration file is unchanged, and
   trust entries the host already had are carried over untouched but not
   added to by this feature for any other path.
3. **Given** a second instance for a different target, **When** both run,
   **Then** neither container trusts the other's repository or worktrees.

---

### User Story 3 - Existing configuration survives the trust step intact (Priority: P2)

Whatever the container's CLI configuration already holds — credentials and
settings seeded from the host by the login option, or state the CLI itself
wrote on an earlier start — is preserved when trust is added. The step never
leaves a half-written file for a concurrently starting session to read.

**Why this priority**: Feature 034 showed that a torn CLI configuration kills
every session at startup. The trust step writes the same file and must not
reintroduce that class of failure or discard the operator's login.

**Independent Test**: Seed a configuration with unrelated keys and an
existing trust entry, start the container, and confirm every original key and
value is unchanged and only the trust records were added; confirm the file is
replaced in one step, never written in place.

**Acceptance Scenarios**:

1. **Given** a seeded host configuration with credentials and other settings,
   **When** the container starts, **Then** every pre-existing key is present
   with its original value after the trust step.
2. **Given** a configuration that is not valid structured data, **When** the
   container starts, **Then** startup fails loudly naming the file, rather
   than overwriting it or starting sessions without trust.
3. **Given** no configuration file exists yet, **When** the container starts,
   **Then** a private one is created holding only the trust records, readable
   only by the container user.

---

### User Story 4 - The operator knows whether strict containment held while untrusted (Priority: P2)

Strict containment's first layer is a pre-tool hook committed in the target
pack. Whether the agent CLI runs that hook in a workspace it does not trust
has never been checked. The finding is established by a reproducible test
and recorded in the operator documentation, so the operator knows whether
past containerized runs were strictly contained.

**Why this priority**: If the hook did not run while untrusted, earlier
strict runs in the container ran without their first containment layer — an
operator needs to know that, and future regressions of it must be caught.

**Independent Test**: In a container with trust withheld, start a strict
orchestrated session that attempts a write the hook denies; observe whether
the denial occurs; repeat with trust granted.

**Acceptance Scenarios**:

1. **Given** an untrusted workspace and a strict session, **When** the session
   attempts an out-of-tree write, **Then** the outcome (denied or not) is
   recorded in the container documentation with the date and CLI version.
2. **Given** a trusted workspace and a strict session, **When** the session
   attempts the same write, **Then** it is denied.

---

### Edge Cases

- The target repository path or worktree root contains spaces or other
  characters that need care when used as a configuration key.
- The worktree root does not exist yet at container start (first run of a
  target): it is still trusted, so the first worktree created under it is.
- The CLI itself is writing its configuration at the moment the trust step
  runs: the trust step runs before any session starts, so no CLI process
  exists in the container yet.
- The seeded host configuration already marks one of the two locations
  trusted or explicitly untrusted: the instance's two locations end up
  trusted; nothing else changes.
- The host CLI configuration is mid-write when the container seeds from it:
  handled by feature 034's validated seed; the trust step only ever reads the
  container's private copy.
- A `strict` run on the host against a target the operator never trusted
  interactively: the phase fails with the untrusted-workspace reason, telling
  the operator to trust the target (or use the container) before re-running.
- A shell started for a target (`scripts/autonomous shell`) where a human
  runs the CLI interactively: same trusted set, same behaviour.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: On every container start for a target, before any orchestrated
  session can start, the container's private CLI configuration MUST mark the
  instance's target repository and the instance's worktree root as trusted.
- **FR-002**: Trust MUST apply to sessions whose working directory is the
  target repository or any location beneath the instance worktree root.
- **FR-003**: The trust step MUST NOT mark any other location trusted —
  including any ancestor of the two locations, any other instance's
  worktrees, and the orchestrator's own source.
- **FR-004**: The trust step MUST preserve every pre-existing key and value
  in the container's configuration, including those seeded from the host,
  changing only the trust records of the two instance locations.
- **FR-005**: The configuration MUST be replaced atomically — a reader sees
  either the previous complete file or the new complete file, never a
  partial one — and keep owner-only permissions.
- **FR-006**: Repeating the trust step (restart, recreate) MUST produce the
  same configuration as running it once.
- **FR-007**: The host's own CLI configuration MUST never be written by the
  container.
- **FR-008**: If the container configuration exists but cannot be read as
  structured data, startup MUST fail with a message naming the file; it MUST
  NOT overwrite it.
- **FR-009**: The same trusted set MUST apply to every container shape that
  runs sessions for a target (console, release, shell).
- **FR-010**: Whether the target pack's pre-tool hook runs in an untrusted
  workspace MUST be established by a reproducible check and recorded in the
  container documentation, with the CLI version it was observed on.
- **FR-011**: The container smoke checks MUST cover: no untrusted warning in
  a session, exact trusted set, pre-existing keys preserved, idempotence
  across restart, and the host configuration unchanged.
- **FR-012**: Running the orchestrator directly on the host (not in the
  container) MUST make no trust changes of its own; the only host-visible
  change is FR-013's untrusted-session check.
- **FR-013**: When a session reports that its workspace is untrusted, a run
  under the `strict` containment profile MUST fail that phase with a distinct
  untrusted-workspace reason (naming the workspace) that the run report and
  console render; the failure MUST NOT be retried. A run under `permissive`
  MUST log a warning naming the workspace and continue. This applies to every
  run, containerized or on the host.

### Key Entities

- **Container CLI configuration**: the agent CLI's private per-container
  settings file; holds credentials, CLI state, and per-location trust
  records. Distinct from the host's file, which may only seed it.
- **Trusted location**: a directory recorded in that configuration as one
  whose committed settings apply in full. For this feature: exactly the
  target repository and the instance worktree root.
- **Instance worktree root**: the directory under the shared state root
  holding all feature worktrees for one target instance.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a containerized run, 0 sessions report an untrusted-workspace
  warning (from every session today).
- **SC-002**: The trusted set inside a running container is exactly 2
  locations per instance, verified by smoke check after 1, 2, and 5
  restarts.
- **SC-003**: 100% of pre-existing configuration keys are preserved through
  the trust step, verified with a seeded configuration.
- **SC-004**: The host's CLI configuration is byte-identical before and after
  a container run in 100% of smoke runs.
- **SC-005**: The hook-under-untrusted-workspace finding is documented with a
  reproducible procedure an operator can repeat in under 10 minutes.
- **SC-006**: The full default test suite passes; existing tests change only
  where they assert the new untrusted-workspace behaviour.
- **SC-007**: A `strict` session that reports an untrusted workspace fails its
  phase in 100% of cases (container and host), never silently running with a
  partially applied pack.

## Assumptions

- The agent CLI decides trust from a per-location record in its own
  configuration file, and a record for a directory covers sessions started in
  directories beneath it (to be confirmed during planning; if it does not,
  each worktree is trusted when it is created, still within the instance
  worktree root only).
- Granting trust is the operator's intent: they chose to run the orchestrator
  against this target and committed its pack; no extra opt-in is required.
- No agent CLI process runs in the container before the entrypoint finishes,
  so the trust step has no concurrent writer.
- Release and console shapes share the entrypoint; one change covers both.
- The finding in User Story 4 is informational: this feature records it and
  makes trust the default, but does not retroactively re-evaluate past runs.
