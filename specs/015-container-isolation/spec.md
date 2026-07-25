# Feature Specification: Container Isolation for Autonomous Runs

**Feature Branch**: `015-container-isolation`

**Created**: 2026-07-24

**Status**: Draft

**Input**: User description: "Let's containerize this application to run isolated."

## Clarifications

### Session 2026-07-24

- Q: What lifecycle should the container entrypoint have — batch run-and-exit, idle service, or both? → A: Service by default with opt-in auto-start; the container boots idle (supervision tree + console) and, when an auto-start setting is present, launches a run on boot and stays up after it drains.
- Q: Does the image ship the orchestrator's source and build tooling, or a compiled self-contained release? → A: A compiled release. Runtime-evaluated environment configuration is the single configuration surface, the operator attaches through the release's own remote console, and neither orchestrator source nor its build tooling is present in the image.
- Q: Is the image built locally by each operator, or published to a registry? → A: Published to a registry as versioned images. Operators pull rather than build; the feature includes the automated publishing path, an immutable version tagging scheme, and registry authentication supplied at pull time. Building locally from source remains available for development.
- Q: Which platforms must the file-ownership guarantee be verified on? → A: A Linux container engine only. The container account's numeric identity is supplied explicitly at start. macOS and other host platforms are explicitly unsupported and unverified for this feature — containerized runs require a Linux host.
- Q: Must in-container paths match host paths, or may the container use fixed canonical mount points? → A: Mirror host paths — the target repository and the run-state root are mounted at their identical host absolute paths, and the container account's home is set so the run-state root resolves to that same path. No path translation anywhere.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run a backlog inside a container with unchanged outcomes (Priority: P1)

An operator has a target repository on their machine and credentials for the coding agent. Instead of running the orchestrator directly on their machine, they start it as a container, hand it the target repository and their credentials, and start a run. The run drives the same phase loop, produces the same branches, worktrees, transcripts, and final report as an on-machine run — the operator's machine never executes agent-authored commands.

**Why this priority**: This is the whole point of the feature. Without run parity the container is a curiosity; with it, every existing capability gains isolation for free. It is also the minimum viable slice — an operator can adopt it on its own and immediately stop running unreviewed agent output on their own machine.

**Independent Test**: Run the same backlog twice against a fixture target repository — once on the machine, once in the container — and compare the per-feature terminal statuses, produced branches, and generated artifacts. Delivers value the moment the containerized run matches.

**Acceptance Scenarios**:

1. **Given** a prepared target repository and valid agent credentials, **When** the operator starts the orchestrator as a container and launches a run, **Then** the run completes and each feature reaches the same terminal status it reaches on-machine.
2. **Given** a run executing in the container, **When** a feature's phase writes code, commits, and creates a feature branch, **Then** those changes are visible in the operator's target repository on the host after the run.
3. **Given** a target repository that pins its own language runtime, **When** a phase runs the target's build and test commands, **Then** the pinned runtime is resolved and used, not whatever version the base image happens to carry.
4. **Given** credentials supplied at start time, **When** the run makes agent calls, **Then** the calls succeed and no credential value is written into the container image or into any run artifact.
5. **Given** the auto-start setting is supplied at start time, **When** the container boots and preflight passes, **Then** the configured run begins with no operator action, and the container stays up after the run drains so the report, transcripts, and worktrees remain inspectable.

---

### User Story 2 - Bound the blast radius to the mounted repository (Priority: P2)

A phase produces a command that tries to write outside the work tree, or escalate privileges, or touch the operator's home directory. The container refuses it at the operating-system layer, independently of whether the in-repo guard hook caught it. The operator's machine is untouched no matter what the agent emits.

**Why this priority**: This is the isolation guarantee the operator is buying. It is separable from Story 1 — a container that merely runs the pipeline already has value — but without it the feature does not actually reduce risk.

**Independent Test**: Execute a red-team command set (out-of-tree writes, privilege escalation, home-directory writes, package installs into system paths) inside the container with the in-repo guard hook deliberately disabled, and confirm every attempt fails and the host filesystem is unchanged.

**Acceptance Scenarios**:

1. **Given** the in-repo guard hook is disabled, **When** a command attempts to write to a path outside the mounted repository and the mounted run-state area, **Then** the write fails and nothing on the host outside those mounts changes.
2. **Given** a command attempts privilege escalation or a write to a system directory, **When** it executes, **Then** it fails because the container process is not privileged.
3. **Given** the run creates files in the mounted repository, **When** the operator inspects them on the host after the run, **Then** they are owned by the operator, not by a privileged account, and remain editable without elevation.
4. **Given** the container is running, **When** an operator inspects what the container can write, **Then** only the target repository and the run-state area are writable; everything else in the container's view is read-only or ephemeral.

---

### User Story 3 - Operate and observe the containerized run (Priority: P3)

While a containerized run is in flight, the operator needs the same operator surface they have today: the status report, the live console, transcripts, and the ability to unblock an escalated or halted feature. They also need a run to survive the container being stopped and restarted — the run state must live on a durable volume, not inside the container.

**Why this priority**: A run the operator cannot watch or unblock is unusable for the long unattended runs this pipeline is built for, but it is only reachable once Story 1 works.

**Independent Test**: Start a containerized run, reach the operator surface from the host while it is in flight, read a live status report, then stop and restart the container and confirm run state and transcripts are intact and the run can be resumed.

**Acceptance Scenarios**:

1. **Given** a run in flight in the container, **When** the operator opens the control-plane console from their host browser, **Then** the console loads and reflects live run state.
2. **Given** a run in flight, **When** the operator opens an interactive orchestrator session against the container, **Then** status reporting and the operator resolution and resume paths behave as on-machine.
3. **Given** a container is stopped mid-run, **When** it is started again, **Then** transcripts, run manifests, checkpoints, and worktrees from that run are still present and readable.
4. **Given** a stop is requested while a phase is in flight, **When** the container shuts down, **Then** the in-flight phase is allowed to finish or is recorded as interrupted with the cost tally intact — the shutdown never leaves the ledger or run manifest in a state that misreports spend.

---

### User Story 4 - Verify the environment before spending money (Priority: P4)

Before any feature work begins, the operator wants a single command that proves the containerized environment is complete: required external tools present at expected versions, credentials reachable, mounts writable, target repository prepared, run-state area durable. A missing piece stops the run immediately with a message stating exactly what is missing and how to supply it.

**Why this priority**: It converts the most common containerization failures — a missing tool, an unmounted volume, absent credentials — from a mid-run crash after real spend into a two-second, self-explanatory stop. Valuable but strictly a guard around the earlier stories.

**Independent Test**: Start the container with each required piece omitted in turn and confirm the preflight fails, names the missing piece, and does not begin any feature work.

**Acceptance Scenarios**:

1. **Given** a required external tool is absent from the environment, **When** preflight runs, **Then** it fails naming that tool and the version it expected, and no feature work starts.
2. **Given** credentials are not supplied, **When** preflight runs, **Then** it fails stating that credentials are missing and where they are expected, without printing any credential value.
3. **Given** the run-state area is not backed by a durable mount, **When** preflight runs, **Then** it warns or fails that run state would be lost when the container exits.
4. **Given** every requirement is met, **When** preflight runs, **Then** it reports success and records the resolved tool versions in the run's durable output so the run is reproducible and later drift is diagnosable.

---

### Edge Cases

- **Host user identity mismatch.** The account inside the container differs from the operator's account on the host, so files the run creates in the mounted repository are unusable or root-owned on the host. The feature must map identity so created files are owned by the operator.
- **Repository ownership rejection.** A version-control tool refuses to operate on a mounted repository it considers owned by a different user. Repository operations must succeed on mounted repositories without the operator hand-configuring trust.
- **A mount is not at its host path.** Because path identity is the mechanism that keeps work trees and recorded paths valid on both sides, a container started with a mount whose in-container path differs from its host path must be rejected at start rather than producing artifacts that are valid on only one side.
- **Run-state root resolves elsewhere.** The run-state root derives from the account's home directory; if the container's home is not set so that it resolves to the mounted host path, runs must fail loudly rather than silently writing state to an ephemeral path.
- **Interrupted shutdown.** The container receives a stop signal mid-phase; cost accounting and the run manifest must remain truthful rather than losing the in-flight phase's spend.
- **Toolchain fetch on first use.** The first run against a target repository pinning an unfamiliar runtime must acquire that runtime, and must fail with a clear message if it cannot, rather than silently falling back to a different version.
- **Repeated runs and disk growth.** Acquired toolchains, dependency caches, and transcripts accumulate; the design must state what is cached across runs and what an operator can safely delete.
- **Long-running or blocked commands.** A phase that starts a foreground process must not leave the container wedged with no operator recourse.
- **Concurrent containers.** Two containers pointed at the same target repository or the same run-state area must not silently corrupt each other's work trees or manifests.

## Requirements *(mandatory)*

### Functional Requirements

**Packaging and image**

- **FR-001**: The project MUST provide a reproducible build recipe that produces a runnable orchestrator image from the repository source, with no manual steps after the build command. The same recipe MUST be usable directly by a developer for local builds.
- **FR-002**: The image MUST contain every external tool the pipeline invokes — the coding-agent command-line tool, the spec-kit command-line tool, version control, the repository-hosting client used by the pull-request workflow, and the scripting runtime the enforcement hook requires — each at a pinned, recorded version.
- **FR-003**: The image MUST carry the orchestrator as a compiled, self-contained release that embeds its own language runtime, built against the repository's committed toolchain pin. The orchestrator's source and its build tooling MUST NOT be present in the runnable image, and the release MUST NOT depend on any runtime present only on the operator's machine. This constrains the orchestrator only — the target-toolchain manager of FR-004 remains present.
- **FR-004**: The image MUST include the toolchain manager needed to resolve a target repository's own pinned runtimes at run time, so a single image can drive target repositories of different stacks.
- **FR-005**: The image MUST NOT contain credentials, tokens, or operator-specific configuration in any layer; all secrets are supplied at start time.
- **FR-006**: The build MUST exclude local build output, dependency caches, version-control metadata, and run artifacts from the image, so image content is a function of committed source alone.
- **FR-007**: The published image MUST record its own identity — source revision, orchestrator version, and pinned tool versions — in a form readable from a running container.
- **FR-008**: Versioned images MUST be published to a container registry by an automated path triggered from the repository, so a release requires no manual build-and-push by an operator.
- **FR-009**: Published images MUST carry an immutable version tag identifying the exact source revision they were built from; an existing version tag MUST NOT be overwritten by a later build. A moving tag for the newest release MAY exist in addition, and MUST be documented as unsuitable for reproducible runs.
- **FR-010**: The normal operator path MUST be pulling a published image, not building one. Registry credentials, where the registry is not public, MUST be supplied by the operator at pull time and MUST NOT be baked into any image or committed to the repository.

**Runtime isolation**

- **FR-011**: The container MUST run the orchestrator as an unprivileged account; privilege escalation from inside MUST fail.
- **FR-012**: Exactly two areas MUST be writable from inside the container: the mounted target repository (with its associated work-tree area) and the mounted run-state area. Every other path MUST be read-only or ephemeral.
- **FR-013**: Files created inside the container within the mounted target repository MUST be owned on the host by the operator who started the container, and MUST remain editable and removable without elevation. The container account's numeric identity MUST be supplied explicitly at start to achieve this.
- **FR-014**: A Linux container engine is the only supported and verified host platform. Documentation MUST state this plainly, and MUST state that other host platforms — including macOS desktop engines — are unverified for this feature, so a containerized run requires a Linux host.
- **FR-015**: Version-control operations MUST succeed on the mounted repository without requiring the operator to manually mark it as trusted, and MUST record commits under a configurable identity.
- **FR-016**: The isolation guarantee MUST be documented as covering filesystem writes, privileges, and process scope — explicitly **not** network egress, which is unrestricted (see Assumptions).
- **FR-017**: The in-repo enforcement hook and per-phase permissions MUST continue to operate unchanged inside the container; the container is an additional layer, never a replacement for either.
- **FR-018**: The target repository and the run-state area MUST each be mounted at the identical absolute path they occupy on the host, so every path recorded in a run artifact and every per-feature work tree is valid from inside the container and from the host without translation.
- **FR-019**: The container account's home MUST be configured so the run-state root resolves to that same mounted host path. A start where the resolved run-state root does not match a writable mounted path at the identical host path MUST fail loudly before any run begins.

**Configuration and credentials**

- **FR-020**: Environment configuration evaluated at boot MUST be the single configuration surface: every setting — target repository, concurrency cap, budget, pull-request workflow settings, preferred plan stack, model pins, auto-start — MUST be supplyable at container start without rebuilding the image, and a required setting that is absent MUST fail the boot loudly rather than falling back to a compiled-in default.
- **FR-021**: Agent credentials MUST be injectable at start time by at least two means: a direct secret value, and a mounted pre-authenticated agent configuration.
- **FR-022**: The target repository path MUST be configurable, and a run MUST fail loudly at start if the configured path is not a mounted, writable repository.
- **FR-023**: The run-state root MUST resolve to a durable mounted location by default, and a start with an ephemeral run-state root MUST be surfaced to the operator rather than silently accepted.

**Operation and observability**

- **FR-024**: The control-plane console MUST be reachable from the operator's host machine, bound so that it is not exposed beyond the host by default.
- **FR-025**: The operator MUST be able to attach an interactive session to the running release inside the container — through the release's own remote console, requiring no build tooling — and use the existing status, resolution, and resume operations there.
- **FR-026**: Transcripts, run manifests, checkpoints, and per-feature work trees MUST be written to the durable run-state mount so they survive container exit and are readable from the host without entering the container.
- **FR-027**: A stop request MUST shut the orchestrator down without corrupting cost accounting or the run manifest; an in-flight phase MUST either complete or be recorded as interrupted.
- **FR-028**: Container logs MUST carry the orchestrator's existing phase and terminal-state events so an operator can follow a run without an interactive session.
- **FR-029**: The container MUST boot into an idle, serviceable state — supervision tree and console running, no run started — so container lifetime is independent of run lifetime and an operator may start, observe, and unblock successive runs in one container.
- **FR-030**: When an auto-start setting is supplied, the container MUST launch the configured run once preflight passes, and MUST remain running after the run drains rather than exiting, so the final report and preserved worktrees stay inspectable. Container exit MUST be operator-initiated.
- **FR-031**: When an auto-start run is requested but preflight fails, the container MUST NOT start the run, MUST stay up in the idle state with the preflight failure visible in its logs and operator surface, and MUST NOT report success.

**Preflight**

- **FR-032**: A preflight MUST run before any feature work and MUST verify: required external tools present at expected versions, credentials reachable, target repository mounted and writable, run-state root durable and writable, and the target repository's enforcement pack present and committed.
- **FR-033**: A preflight failure MUST name the specific missing item and the single action that fixes it, and MUST stop the run before any agent spend.
- **FR-034**: A successful preflight MUST record the resolved tool and runtime versions into the run's durable output.
- **FR-035**: Preflight output and every error message MUST never print credential values.

**Documentation**

- **FR-036**: Operator documentation MUST provide a start-to-finish path — pull, start, preflight, run, observe, stop — for a first-time operator on a Linux machine with only a container engine and credentials, and MUST separately document the local build path for development.
- **FR-037**: Documentation MUST state exactly what the isolation does and does not protect against, superseding the current advisory container note in the enforcement guide.
- **FR-038**: Documentation MUST state what persists across runs, what is cached, and what an operator may safely delete to reclaim disk.

### Key Entities

- **Orchestrator image**: The registry-published, immutably version-tagged artifact containing the control plane as a compiled release plus every external tool the pipeline invokes. Carries no secrets and no orchestrator source; identifies its own source revision and pinned tool versions.
- **Run container**: A running instance of the image. Unprivileged, with a mapped operator identity, a defined set of writable mounts, injected configuration and credentials, and a published console port.
- **Target repository mount**: The operator's repository, mounted writable. The only place agent-authored code changes may land.
- **Run-state mount**: The durable area holding per-feature work trees, transcripts, run manifests, and checkpoints. Survives container exit; readable from the host.
- **Credential set**: Agent authentication and, when the pull-request workflow is used, repository-hosting authentication. Supplied at start; never baked in; never printed.
- **Environment preflight report**: The record produced before a run — tool versions, runtime versions, mount status, target-repository readiness — persisted into the run's durable output.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A backlog run executed in the container produces the same per-feature terminal statuses and the same set of feature branches as the equivalent on-machine run, across 100% of features in the reference backlog.
- **SC-002**: In a red-team suite of at least ten hostile commands executed with the in-repo guard hook disabled, 100% fail and the host filesystem outside the declared mounts is byte-for-byte unchanged.
- **SC-003**: An operator on a Linux host with only a container engine and credentials reaches a started, preflight-passing run by pulling a published image in no more than three commands and under fifteen minutes on a first attempt, following the documentation alone.
- **SC-004**: On the supported Linux host platform, 100% of files created by a run inside the mounted repository are owned by the invoking operator on the host and require no elevation to edit or delete.
- **SC-005**: An automated scan of the published image finds zero credential values, tokens, or operator-specific configuration in any layer.
- **SC-006**: After a mid-run container stop and restart, 100% of that run's transcripts, manifests, and checkpoints are present and readable, and the recorded spend equals the spend recorded before the stop.
- **SC-007**: Every preflight failure mode names the missing item and its fix in a single message; an operator resolves each seeded failure without consulting source code.
- **SC-008**: A run against a target repository pinning a runtime different from the orchestrator's own completes its build and test commands using the target's pinned version, verified from the run's recorded versions.
- **SC-009**: Total operator-visible overhead of running in the container versus on-machine stays within 10% of end-to-end run wall-clock on the reference backlog, measured on the supported Linux host platform.
- **SC-010**: Every released version is pullable by its immutable version tag, and pulling the same version tag twice yields an identical image; no released tag is ever overwritten.
- **SC-011**: Publishing a release requires zero manual build-or-push steps by an operator — the automated path produces the published image from the repository alone.

## Assumptions

- **One container, mounted repositories** — isolation is a single long-lived orchestrator container; the target repository and run-state area are mounted from the host. Per-phase throwaway containers were considered and rejected for this feature as a much larger design surface; nothing here forecloses them later.
- **Network egress is unrestricted** — the isolation claim covers filesystem writes, privileges, and process scope, not exfiltration. Target builds fetch dependencies freely and the agent reaches its own service. An egress allowlist is a separate, later decision and is out of scope here.
- **Target runtimes resolve at run time** — the image carries a toolchain manager rather than every possible language runtime; a target repository's pinned runtime is acquired on first use. This assumes the target repository commits a toolchain pin, which the toolchain preflight work already contemplates.
- **The operator supplies a prepared target repository** — spec-kit scaffolding, the enforcement pack, and a real constitution are already committed in the target. The container verifies this; it does not bootstrap it.
- **The container is an added deployment option, not a replacement** — on-machine runs remain supported, and the existing operator surfaces keep working unchanged.
- **The console remains a single-operator, unauthenticated surface** — publishing it is scoped to the operator's own machine; exposing it beyond the host is out of scope.
- **Existing enforcement layers stay in force** — the in-repo guard hook and per-phase permissions are unchanged by this feature; the container is the third, outermost layer of the same defense-in-depth scheme.
- **A single container per target repository at a time** — concurrent containers sharing one target repository or run-state area are not a supported configuration in this feature.
