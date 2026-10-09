# Feature Specification: Container System Packages

**Feature Branch**: `037-container-system-packages`

**Created**: 2026-10-08

**Status**: Draft

**Input**: User description: "Container system packages: let target builds get the OS packages they need inside the isolated container. Incident: mod-player run reported "Tests: not run. The sandbox has no ALSA development headers or pkg-config, and I have no root to install them" — alsa-sys (via cpal) failed to build, so cargo test never ran. Today three layers block it: the image runs as the non-root host uid with no sudo binary; the strict scope_guard denies any `sudo`; and there is no way to declare extra apt packages at image build. US1 (P1) build-time packages: operator declares extra apt packages when building the image (`scripts/autonomous build --apt "libasound2-dev pkg-config"`, a no-op build arg when empty, same pattern as --web/--desktop/--android), applied to dev and release images; strict containment unchanged. US2 (P2) opt-in agent root: an image built with `--agent-root` carries sudo with passwordless rights for the container user (must work for any host uid, since compose overrides the image user); the entrypoint advertises AUTONOMOUS_AGENT_ROOT=1 only when `sudo -n true` actually succeeds; the strict scope_guard gains one narrow exception — `sudo apt-get`/`sudo apt`/`sudo dpkg` are allowed only when AUTONOMOUS_CONTAINER=1 and AUTONOMOUS_AGENT_ROOT=1, every other sudo still denied; hook pack contract bumps 4→5 with TargetPack.verify updated; implement/converge prompts tell the agent it may install system dependencies with sudo apt-get when agent root is available; permissive profile unchanged. US3 (P3) operator surfaces: docs/container.md "System packages" section, runbook, enforcement doc (the exception relies on the container as the boundary), and a `sysdeps` container smoke check. Non-goals: host installs, non-apt package managers, lifting the curl/wget deny. Without either flag, image and guard behaviour are byte-identical to today."

## Context

Observed 2026-10-08 on the mod-player instance: the implement phase finished
with "Tests: not run. The sandbox has no ALSA development headers or
pkg-config, and I have no root to install them." A native audio dependency of
the target needs operating-system development packages to compile; without
them the target's own test suite never ran, and every crate depending on the
audio crate went untested.

The operator runs the orchestrator inside an isolated container precisely so
that the build environment can be shaped to the target. Today it cannot be:

1. the image offers no way to declare extra operating-system packages when it
   is built;
2. sessions run as the operator's non-root user id with no privilege-elevation
   tool present, so nothing inside the container can install a package;
3. the `strict` containment pack denies every privilege-elevation command,
   even when the container itself is the outer boundary.

## Clarifications

### Session 2026-10-08

- Q: How does `strict` containment treat agent root, given Principle III? → A: `strict` gains the narrow package-manager exception (both markers required), with a MINOR constitution amendment to Principle III; no extra run annotation.
- Q: Where does the declared package list come from? → A: The build-script option only; the single shared image carries the combined list for every target (no per-target file or image).
- Q: Which privileged package-manager actions does `strict` allow? → A: Install-only — refresh the package index, install packages, and query the package database; remove/purge and every other action denied.
- Q: Agent root advertised but committed pack below the new contract — what does preflight do? → A: Warn (log and operator surfaces) and start the run; the older pack keeps denying privilege elevation.
- Q: How are packages the agent installs at runtime recorded? → A: One operator-visible log line per allowed privileged install, naming the packages; nothing persisted to the run record.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator declares the target's system packages at image build (Priority: P1)

Before a run, the operator knows (or learns from a failed run) that the target
needs certain operating-system packages. They rebuild the image naming those
packages. Every container started from that image — development console,
shell, or release — has them installed, and the orchestrated sessions build
and test the target without needing any elevated rights.

**Why this priority**: Deterministic, reproducible, and needs no change to
containment. It alone fixes the mod-player incident.

**Independent Test**: Build the image naming one package that the base image
does not carry; start a container; confirm the package is installed and a
session running as the operator's user can use it.

**Acceptance Scenarios**:

1. **Given** the operator builds the image naming two extra packages, **When**
   a container starts from it, **Then** both packages are installed and usable
   by the container user.
2. **Given** the operator builds the release image with the same package list,
   **When** the release container starts, **Then** the same packages are
   present there too.
3. **Given** the operator builds without naming any extra package, **When** the
   image is built, **Then** it is identical in content to an image built before
   this feature.
4. **Given** the operator names a package that does not exist, **When** the
   image is built, **Then** the build fails loudly, naming the package, and no
   image is tagged.

---

### User Story 2 - Agent installs a missing system package itself (Priority: P2)

The operator opts in, at image build, to letting orchestrated sessions install
operating-system packages. When an implement or converge session finds the
target cannot build for want of a system package, it installs the package
through the system package manager and carries on, instead of reporting the
tests as not run.

**Why this priority**: Covers the packages the operator could not predict, but
it relaxes in-container containment, so it is opt-in and comes after US1.

**Independent Test**: Build the image with agent root enabled; start a `strict`
run against a scratch target whose build needs a package the image lacks;
confirm the session installs it and the target's tests run.

**Acceptance Scenarios**:

1. **Given** an image built with agent root enabled and any host user id,
   **When** a container starts, **Then** the container user can elevate
   privileges without a password, and the container advertises agent root to
   sessions.
2. **Given** an image built without agent root, **When** a container starts,
   **Then** no privilege-elevation tool is present and agent root is not
   advertised.
3. **Given** agent root is advertised and the run is `strict`, **When** a
   session runs a privileged system package-manager command, **Then** the pack
   allows it.
4. **Given** agent root is advertised and the run is `strict`, **When** a
   session runs any other privileged command, **Then** the pack denies it,
   naming the profile and the rule.
5. **Given** agent root is NOT advertised (any reason: not built in, the
   elevation check failed, or the session runs outside the container), **When**
   a `strict` session runs a privileged package-manager command, **Then** the
   pack denies it exactly as today.
6. **Given** agent root is advertised, **When** an implement or converge
   session starts, **Then** its instructions tell it that missing system
   packages may be installed with the system package manager; **When** it is
   not advertised, **Then** the instructions are unchanged from today.
7. **Given** a `permissive` run, **When** sessions run, **Then** behaviour is
   unchanged from today (no deny list), whether or not agent root is
   advertised.

---

### User Story 3 - Operator can find, verify, and reason about it (Priority: P3)

The operator learns from the container documentation how to declare packages
and when to enable agent root, sees in the enforcement documentation exactly
what the `strict` exception permits and why the container is the boundary it
relies on, and can verify a built image with a smoke check.

**Why this priority**: Makes US1/US2 discoverable and auditable; no runtime
behaviour of its own.

**Independent Test**: Run the system-packages smoke check against an image
built with and without each option; it passes and fails accordingly.

**Acceptance Scenarios**:

1. **Given** an image built with declared packages, **When** the operator runs
   the system-packages smoke check, **Then** it confirms each declared package
   is installed.
2. **Given** an image built with agent root, **When** the smoke check runs as
   the operator's user id, **Then** it confirms passwordless elevation works
   and a package can be installed.
3. **Given** the operator reads the runbook after a "tests not run: missing
   system package" outcome, **When** they follow it, **Then** they can either
   rebuild with the package or enable agent root and resume the feature.

---

### Edge Cases

- Host user id differs from the image's default user id (compose overrides the
  image user): elevation rights must still apply to the user the container
  actually runs as.
- Agent root built in but elevation fails at start (e.g. the container is run
  with privilege escalation disabled): agent root is not advertised, and
  `strict` behaves as today.
- A privileged package-manager command chained with another privileged command
  in one Bash call (e.g. separated by `&&`, `;`, `|`): denied unless every
  privileged part is a package-manager command.
- A privileged package-manager command that removes or purges a package (which
  could uninstall tools the orchestrator needs): denied.
- A privileged package-manager command wrapped to run something else (e.g. a
  shell spawned through it, or options that execute arbitrary commands): denied.
- A target repository committed with an older pack contract while agent root
  is advertised: preflight warns that the pack needs reinstalling, the run
  starts, and `strict` denies privilege elevation as today.
- Package installation fails inside a session (no network, unknown package):
  the session sees the failure as an ordinary command failure; no new
  orchestrator failure class.
- Packages installed by a session at runtime are lost when the container is
  recreated; the documentation points to US1 for anything that must persist.
- The package list contains shell metacharacters: rejected at build-script
  level before any build starts.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The image build MUST accept an operator-declared list of extra
  operating-system packages, given through the build script, and install them
  into both the development and release images.
- **FR-002**: When no extra package is declared, the image build MUST produce
  the same content as before this feature.
- **FR-003**: An unknown or uninstallable declared package MUST fail the image
  build loudly, naming it.
- **FR-004**: The build script MUST reject a package list containing anything
  other than valid package names before starting a build.
- **FR-005**: The image build MUST accept an opt-in agent-root option; only
  when given does the image carry a privilege-elevation tool configured for
  passwordless use by the container user, whatever user id the container runs
  as.
- **FR-006**: Without the agent-root option, the image MUST carry no
  privilege-elevation tool (unchanged from today).
- **FR-007**: At container start, the container MUST advertise agent root to
  every session it starts only after positively verifying that passwordless
  elevation works; otherwise it MUST NOT advertise it.
- **FR-008**: Under `strict`, the pack MUST allow a privileged command only when
  both the in-container marker and the agent-root marker are present and every
  privileged part of the command invokes the system package manager to refresh
  its package index, install packages, or query the package database (removing
  or purging packages, and every other action, stays denied); every other privileged
  command MUST remain denied, naming the profile and the rule.
- **FR-009**: The `strict` exception MUST NOT allow privileged package-manager
  invocations that execute arbitrary commands or spawn a shell.
- **FR-010**: Under `strict`, without both markers, privilege-elevation handling
  MUST be identical to today.
- **FR-011**: Under `permissive`, and for interactive human sessions, pack
  behaviour MUST be unchanged.
- **FR-012**: The pack's contract version MUST increase. When agent root is
  advertised and the committed pack is below the new contract, preflight MUST
  warn — in the log and on operator surfaces — that the pack must be
  reinstalled for the exception to apply, and MUST still start the run (the
  older pack keeps denying privilege elevation). With agent root absent, the
  older contract is accepted silently.
- **FR-013**: Implement and converge session instructions MUST tell the agent
  it may install missing system packages with the system package manager when
  agent root is advertised, and MUST be unchanged when it is not.
- **FR-014**: The deny lists for download tools (curl/wget) MUST be unchanged.
- **FR-015**: The container documentation MUST describe declaring packages and
  enabling agent root; the enforcement documentation MUST state what the
  `strict` exception permits and that it relies on the container as the outer
  boundary; the runbook MUST cover recovering a feature whose tests did not run
  for want of a system package.
- **FR-016**: A system-packages smoke check MUST verify declared packages and,
  when built in, passwordless elevation plus one package installation as the
  operator's user id.
- **FR-017**: The constitution MUST be amended (MINOR) so Principle III names the
  `strict` package-manager exception and its two required markers.
- **FR-018**: Every privileged package-manager command the `strict` exception
  allows MUST produce one operator-visible log line naming the feature and the
  packages requested, so the operator can promote them to the declared package
  list; nothing is persisted to the run record.

### Key Entities

- **Declared package list**: operator-supplied, image-build-time set of
  operating-system package names; part of the image, not of a run.
- **Agent-root capability**: image-build-time opt-in plus a start-time
  verification; surfaced to sessions as a marker.
- **Pack contract version**: the version preflight compares to decide whether
  the committed pack can honour the exception.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Re-running the mod-player feature on an image built with its
  audio development packages declared, the session's tests run (zero "tests
  not run: missing system package" outcomes).
- **SC-002**: With agent root enabled and no packages declared, the same
  feature's session installs the missing packages itself and its tests run,
  with no operator intervention.
- **SC-003**: 100% of the pack's red-team matrix (origin × profile × markers ×
  command shape) behaves as specified: package-manager commands allowed only in
  the one specified cell, every other privileged command denied.
- **SC-004**: An image built with neither option is content-identical to one
  built before this feature, and the full existing test suite passes
  unchanged.
- **SC-005**: An operator new to the feature can rebuild with a needed package
  and resume a feature in under 10 minutes by following the documentation.

## Assumptions

- The container image is Debian-based and its system package manager is apt;
  other package managers are out of scope.
- The container is the outer boundary the operator relies on; agent root never
  applies to sessions on the host.
- Runtime-installed packages are ephemeral; persistence is US1's job.
- One image serves every target, so declared packages are present for all
  targets built from it; per-target package files or images are out of scope.
- Network access for the system package manager is available inside the
  container; offline installation is out of scope.
- The existing opt-in capability flags (web, desktop, Android) are the model
  for how build options are passed and documented.
