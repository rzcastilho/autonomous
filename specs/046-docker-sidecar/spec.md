# Feature Specification: Container Engine Sidecar for Agent Sessions

**Feature Branch**: `046-docker-sidecar`

**Created**: 2026-10-23

**Status**: Draft

**Input**: User description: "docker-in-docker sidecar for autonomous container"

## Context

Orchestrated sessions run inside the autonomous container, which is the only
containment boundary (constitution Principle III). Targets whose build or tests
need a container engine (they build an image, run a database for integration
tests, or use a "test containers" library) cannot do that today: the image has no
container engine client, no engine is reachable, and the agent container has no
added privileges.

Two ways to give it one were rejected. Mounting the host engine's control socket
would give every model-authored command root-equivalent control of the host,
which removes the boundary. Running an engine inside the agent container would
make that container privileged. This feature adds an **isolated engine in a
separate companion container (sidecar)** for each instance. Only the sidecar
holds the elevated privileges an engine needs. The agent container stays
unprivileged, and the host engine is never exposed.

## Clarifications

### Session 2026-10-23

- Q: Must multi-container compose stacks work inside the container? → A: Yes. Running a compose stack (`docker compose up` and `down` on a target's compose file) is a first-class requirement, not just single containers.
- Q: What happens to engine containers and compose stacks a session leaves running? → A: The orchestrator cleans up at the end of every phase that started any, whatever the phase's terminal status. It removes all engine containers, networks and volumes, and keeps images and build cache.
- Q: If the sidecar can't start, or the engine never becomes ready, what does an engine-enabled start do? → A: It refuses to start. It exits non-zero, names the cause and the remedy, and leaves nothing running. It never falls back to starting without the engine.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sessions can build and run containers (Priority: P1)

An operator whose target needs a container engine opts in when building the
image and starting the instance. An orchestrated session can then use the
standard container engine client to build images, run containers and use
compose-style multi-container setups, exactly as a developer would on a laptop.
Nothing in the target repository has to change.

**Why this priority**: This is the whole point of the feature. Without it, a
target with container-based integration tests cannot reach a green `implement`.

**Independent Test**: Build the image with the option, then start an instance
against a target with the option. Inside the instance, run the client's version
query, then a throwaway container that prints a line, then an image build from a
small context in the target worktree, then a two-service compose stack brought
up and down from the worktree. All four succeed.

**Acceptance Scenarios**:

1. **Given** an image built with the engine option and an instance started with it, **When** a session queries the engine, **Then** it reports a reachable engine with its version.
2. **Given** that instance, **When** a session runs a container that mounts a directory from the feature worktree, **Then** the container sees the worktree's current files at the same path, and files it writes there are visible to the session.
3. **Given** that instance, **When** a session starts a container that listens on a port, **Then** the session can connect to that port.
4. **Given** that instance and a target with a compose file that declares two services which talk to each other and uses a relative-path bind mount, **When** a session brings the stack up from the worktree, **Then** both services start, they reach each other by service name, they see the worktree files through the relative mount, and a published service port is reachable from the session. Bringing the stack down removes its containers and network.
5. **Given** an image built without the engine option, or an instance started without it, **When** anything runs, **Then** the behaviour is identical to before this feature: no sidecar, no engine variables in the environment, and no client in the image.

---

### User Story 2 - The host stays out of reach (Priority: P1)

The operator relies on the container as the boundary. Turning the engine on must
not let a session reach the host's own engine, the host's containers, or host
paths outside the two mounts the instance already has: the target repository and
the state root.

**Why this priority**: Constitution Principle III makes the container the
boundary. A feature that quietly breaks it is worse than no feature.

**Independent Test**: In an instance with the engine on, list containers and
images. Only engine-local ones appear, never the host's. Then try to start a
container that mounts the host's root filesystem or a home directory. The mount
resolves inside the sidecar's own filesystem, not the host's.

**Acceptance Scenarios**:

1. **Given** the engine is on, **When** a session lists containers, **Then** the host's own containers (including the instance's agent container and the sidecar itself) do not appear.
2. **Given** the engine is on, **When** a session mounts a host path other than the target repository or the state root into a container, **Then** the container sees the sidecar's filesystem at that path, never the host's.
3. **Given** the engine is on, **When** the instance is inspected, **Then** the agent container has no added privileges, capabilities or devices compared with an instance started without the engine.
4. **Given** the engine is on, **When** the host's network interfaces are inspected, **Then** the engine's control endpoint is not published to the host.

---

### User Story 3 - Lifecycle, persistence and cleanup (Priority: P2)

The sidecar starts and stops with its instance. Pulled images and build cache
survive a restart, so the next run does not pull everything again. A purge
removes them.

**Why this priority**: Without persistence every restart costs a full pull and
build. Without cleanup, engine storage grows without bound.

**Independent Test**: Pull an image, stop the instance, then start it again. The
image is still present. Stop with purge, then start again. The image is gone.

**Acceptance Scenarios**:

1. **Given** an instance started with the engine, **When** it is stopped, **Then** the sidecar stops too and no orphaned engine container is left running.
2. **Given** images were pulled in a prior session, **When** the instance restarts, **Then** those images are still available.
3. **Given** a phase that brought up a compose stack ends, whether it succeeded, failed or hit its session deadline, **When** the next phase starts, **Then** the engine has no containers, networks or volumes, while previously pulled images and build cache are still present.
4. **Given** an instance stopped with purge, **When** it is started again, **Then** engine storage starts empty.
5. **Given** two instances for two different targets run at the same time, **When** each uses its engine, **Then** neither sees the other's containers, images or storage.
6. **Given** the operator wants to free engine storage without a full purge, **When** they run the existing cache-reset command for the engine storage, **Then** only that storage is cleared.

---

### User Story 4 - The operator can see it and check it (Priority: P3)

The operator can tell whether the engine is on for an instance and whether it is
healthy. A smoke check proves the capability end to end.

**Why this priority**: Constitution Principle VII requires operator surfaces to
tell the truth. It matters less than the capability itself.

**Independent Test**: Open the console Configuration page with the engine on and
then off. Run the smoke check against an image with the engine option.

**Acceptance Scenarios**:

1. **Given** the engine is on and reachable, **When** the operator opens Configuration, **Then** a "container engine" row shows that it is available, with its version.
2. **Given** the engine was available at start but has since become unreachable, **When** the operator opens Configuration, **Then** the row says that it is unreachable. It never shows a healthy state it cannot confirm.
3. **Given** the engine is off, **When** the operator opens Configuration, **Then** no engine row appears, and the page is identical to before this feature.
4. **Given** the engine option, **When** the operator runs the engine smoke check, **Then** it passes for both the development image and the release image, or fails and names the failing step.

---

### Edge Cases

- **Engine not ready when a session starts**: instance start waits for the engine to answer, up to a bound. If the engine is still not ready after that, start refuses (FR-012): it exits non-zero, names the cause, and removes the sidecar and the agent container it created.
- **The host runtime refuses a privileged container** (for example, a rootless host engine or a policy that forbids it): the sidecar fails to start. Start refuses (FR-012): it exits non-zero, names the cause and the remedy, and leaves nothing running. It never starts without the engine and never falls back to mounting the host socket.
- **A session mounts a worktree path into a container**: this works because the sidecar mounts the target repository and state root at the same absolute paths as the agent container (the existing same-path rule).
- **A session mounts a path that only exists inside the agent container** (for example, its temp directory or home): the mount resolves to an empty or missing path in the sidecar. This is documented as a limitation, and sessions are told to stage files under the worktree.
- **Containers a session leaves running** when its phase ends: the orchestrator removes them during end-of-phase cleanup (FR-010a). This happens whatever the outcome: success, failure, escalation, halt, session deadline, session death or supersession drain. The next phase always starts with no engine containers, networks or volumes.
- **Cleanup itself fails** (for example, the engine is unreachable at phase end): the orchestrator logs a loud warning that names the phase and what is left behind. The phase's outcome does not change. The next phase's cleanup tries again, and that phase does not start against a dirty engine without the warning having been surfaced.
- **Implement chunks**: an implement phase spans several chunk sessions. Cleanup runs when the implement phase ends, not between chunks, so a later chunk can reuse a stack an earlier chunk brought up.
- **Compose stacks from different features or phases**: end-of-phase cleanup (FR-010a) removes every stack before the next phase starts, so names and in-sidecar ports never clash across phases or features.
- **Port collision between engine containers**: each container's ports are published only inside the sidecar's network namespace, not on the host, so they cannot collide with host ports.
- **Engine storage fills the disk**: an engine error is surfaced to the session as an ordinary command failure. The operator clears it with the cache-reset or purge commands.
- **Started outside the container**: the engine option does not exist outside the wrapper. The existing non-container warning still applies unchanged.
- **Release image**: the engine is available in the release image when that image was built with the option, with parity to the development image.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image build MUST offer an opt-in engine option that adds a container engine client and its multi-container compose tool to the dev and release images. Without the option, the image MUST be byte-identical to before this feature.
- **FR-002**: Instance start MUST offer an opt-in engine option that runs an isolated container engine in a separate sidecar container belonging to that instance. Without the option, start MUST be identical to before this feature: no sidecar, no engine environment.
- **FR-003**: When the engine is on, sessions MUST reach it through the standard client environment, with no per-target setup and no change to the target repository.
- **FR-003a**: Sessions MUST be able to bring a compose stack up and down from a target worktree. Services MUST resolve each other by name, relative-path bind mounts MUST resolve against the worktree, published service ports MUST be reachable from the agent container, and a service that builds its own image MUST build from the worktree context.
- **FR-004**: The agent container MUST NOT gain any privilege, capability, device or host-socket mount when the engine is on. Only the sidecar may run with the elevated privileges an engine requires.
- **FR-005**: The host's own container engine control socket MUST NEVER be mounted into the agent container or the sidecar, under any option or fallback path.
- **FR-006**: The engine's control endpoint MUST be reachable only from that instance's agent container. It MUST NOT be published to the host or reachable from other instances.
- **FR-007**: The sidecar MUST mount the target repository and the state root at the same absolute paths as the agent container, so that container mounts of worktree paths resolve to the same files.
- **FR-008**: Ports published by engine containers MUST be reachable from the agent container and MUST NOT be published on the host.
- **FR-009**: Engine storage (images and build cache) MUST persist across instance restarts in storage scoped to that instance's target, and MUST be isolated between targets.
- **FR-010**: Stopping an instance MUST stop its sidecar and every container that the sidecar's engine runs. Stop with purge MUST also remove the engine storage. The existing cache-reset command MUST be able to clear the engine storage on its own.
- **FR-010a**: At the end of every phase in which the engine is advertised, whatever the phase's terminal status (including failure, escalation, halt, session deadline, session death and supersession drain), the orchestrator MUST remove every container, network and volume on the engine. It MUST keep images and build cache. The same applies to remediation sessions. Cleanup MUST NOT change the phase's outcome, and a cleanup failure MUST be logged loudly with the phase and the residue named. Cleanup MUST be skipped entirely when the engine is not advertised.
- **FR-011**: Instance start MUST wait, up to a bounded time, for the engine to become ready before it advertises the engine to sessions. An engine that is not ready within the bound MUST make start refuse under FR-012.
- **FR-012**: If the sidecar cannot start (for example, privileged containers are refused) or the engine is not ready within the bound, an engine-enabled start MUST refuse: exit non-zero, name the cause and the remedy, and leave no sidecar or agent container running. It MUST NOT start the instance without the engine, and MUST NOT fall back to any host-socket path.
- **FR-013**: When the engine is advertised, session prompts for the phases that build and test (`implement`, `converge`) MUST say that a container engine is available, and MUST tell sessions to stage files they mount under the worktree. This is guidance, not enforcement.
- **FR-014**: The console Configuration page MUST show a "container engine" row only when the engine was requested. The row reports available (with version) or unreachable, and nothing else. With the engine off, the page MUST be identical to before this feature.
- **FR-015**: A smoke check subcommand MUST verify the capability end to end: client and compose tool present, engine reachable, a container runs, a worktree mount round-trips, a two-service compose stack comes up (with service-to-service reachability) and goes down cleanly, a container port is reachable, and the host's containers are not visible. It MUST run against both the development image and the release image.
- **FR-016**: The operator documentation MUST describe the option, the security trade-off (a privileged sidecar, never the host socket), the mount limitation, storage management and the smoke check.
- **FR-017**: No persisted run record or store schema MAY change. The engine is a runtime capability of the instance, not part of run state.

### Key Entities

- **Engine sidecar**: the per-instance companion container that runs the isolated engine. It is started and stopped with its instance, and is the only container with elevated privileges.
- **Engine storage**: the per-target persistent storage for images and build cache. It survives restarts and is removed by purge or by the targeted cache reset. Engine containers, networks and volumes are scoped to a single phase and never persist past it (FR-010a).
- **Engine advertisement**: the marker, set only after a successful readiness probe, that tells sessions and the console that the engine is available.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A target whose test suite needs a container engine reaches a passing `implement` phase in an engine-enabled instance, with no changes to the target repository.
- **SC-002**: In 100% of smoke runs, a session in an engine-enabled instance cannot see or control any host container, and the agent container's privilege set is identical to that of an engine-disabled instance.
- **SC-003**: After a restart, starting a container from a previously pulled image needs no network download.
- **SC-004**: With the engine off, the image, the instance start and the Configuration page are byte-identical to before this feature, verified by the existing tests and smoke checks passing unchanged.
- **SC-005**: An engine-enabled instance is ready for sessions within 30 seconds of start on a warm host. Otherwise start refuses within the readiness bound, and the refusal names the cause.
- **SC-005a**: A target whose integration tests start their dependencies through a compose file passes those tests in an engine-enabled instance, with no edit to the compose file.
- **SC-005b**: In 100% of phases that start engine containers, including failed and timed-out ones, no engine container, network or volume survives into the next phase. When one does, the cleanup failure has already been logged with the phase named.
- **SC-006**: The engine smoke check passes against both the development image and the release image.

## Assumptions

- Option 2 from the design discussion (an isolated engine in a sidecar) is the chosen approach. Mounting the host socket and running a rootless engine in the agent container are explicitly out of scope.
- The operator accepts that the sidecar runs with elevated privileges on the host. That is the documented trade-off for keeping the agent container unprivileged and the host engine unreachable.
- The host runtime permits privileged containers (Docker Engine on Linux, or Docker Desktop on macOS). Hosts that forbid them get a clear refusal, not a degraded mode.
- The engine traffic between the agent container and the sidecar stays on a private per-instance network, so it needs no transport encryption.
- Engine containers get outbound network access the same way the agent container does. This feature adds no egress policy.
- Image pull credentials for private registries are out of scope. Sessions can log in the way they would anywhere else, and that login lasts for the instance's lifetime.
- No CPU or memory limits are imposed on the sidecar beyond what the host runtime enforces. Limits can be a follow-up.
- The feature follows the existing opt-in pattern (`--apt`, `--agent-root`, volumes): a build option, a start option, an entrypoint advertisement step, a Configuration row that appears only when relevant, and a smoke subcommand.
