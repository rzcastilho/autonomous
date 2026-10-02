# Feature Specification: Always-Containerized Runtime

**Feature Branch**: `031-containerized-runtime`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "Always-containerized runtime for the autonomous orchestrator. Today the orchestrator runs directly on the operator's host, driving the coding agent, version control, the code-hosting client and the target-pack hook with the host's ambient credentials and full filesystem. The enforcement guide already recommends a container as the outermost containment layer (essential for permissive runs), but none exists. Goal: running inside a container becomes the only supported way to run the app — for interactive development and as a self-contained release — with opt-in capabilities for orchestrated sessions to test web, Linux desktop and Android target applications."

## Clarifications

### Session 2026-10-01

- Q: How are dependency downloads (package registries) handled for target tests under `strict`, given Principle III denies network access? → A: `strict` keeps denying network; dependencies are fetched outside gated sessions (operator-run step or the target's own pre-run setup); only offline test commands must be allowed.
- Q: What threat model does the outside-container boot refusal serve, and is there an override? → A: Accident prevention only — an image-set marker the app checks; no host override outside the test environment; docs state it is not a security boundary.
- Q: How many target repositories per container, and how is state shared? → A: One target per container instance. The host's `~/.autonomous` is the shared state root, mounted at its host absolute path. Each instance gets its own store directory and node name, derived from its target repository, so instances for different targets run at the same time; a second instance for the same target is refused loudly. The console listens on a random host port unless one is passed as a parameter. Host store history is not migrated (fresh store); existing worktrees under the shared root stay in place.
- Q: Which container engines must be supported and validated? → A: Docker Engine + Compose v2 only, validated on Linux; other engines unsupported.
- Q: With several instances running at once, is the cost budget per instance or shared? → A: Per instance — each instance's budget and breaker are independent, as today; docs and start output state that total spend is the sum across instances.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator runs the orchestrator only inside a container (Priority: P1)

An operator who today starts the orchestrator's interactive shell on their own machine instead starts it
inside a container, using one documented command. Inside, the full operator API (start a run, check
status, resume, continue, end) works exactly as it does on the host today, against a target repository
on the operator's machine, and the coding-agent sessions it starts can only touch what was deliberately
mounted into the container. Attempting to start the application directly on the host is refused with a
message that names the supported commands.

**Why this priority**: This is the feature. The container is the containment layer the enforcement guide
already promises (Principle III's "container recipe" layer); without it, a `permissive` run has no outer
boundary at all. Everything else builds on a container that can actually drive a run.

**Independent Test**: Build the development environment, start the interactive shell in it, run one
backlog feature end-to-end against a sibling target repository, and confirm a pull request is opened from
inside the container. Separately, start the application on the host and confirm it refuses.

**Acceptance Scenarios**:

1. **Given** a fresh checkout and a configured credentials file, **When** the operator starts the
   development environment's interactive shell, **Then** the application boots, the run state store opens,
   and the operator API is available.
2. **Given** the interactive shell inside the container and a prepared target repository, **When** the
   operator starts a run, **Then** the feature progresses through its phases, its worktree is created, and
   on success a pull request is opened using the configured code-hosting token.
3. **Given** the operator's host without the container, **When** the operator starts the application's
   interactive shell or web server directly, **Then** startup is refused with a message naming the
   supported container commands, and nothing is written to the run state store.
4. **Given** the host without the container, **When** the developer runs the test suite or compiles,
   **Then** both work as they do today.
5. **Given** the container, **When** the developer runs the test suite inside it, **Then** it passes.

---

### User Story 2 - Run state survives container restarts and recreation (Priority: P1)

The operator stops, removes and recreates the container (e.g. after rebuilding the image) and finds every
previous run, escalation, checkpoint, transcript and kept worktree still there, and can resume a halted
feature from its checkpoint. Worktrees created by the containerized orchestrator remain valid git worktrees
when inspected from the host.

**Why this priority**: The store is keyed to the node identity and its directory; a container that changes
either on every start would either lose history or refuse to boot (the store fails loud on a node mismatch
by design). An orchestrator that forgets its runs is unusable for resume/continue — so this is as
critical as US1.

**Independent Test**: Start a run, let a feature escalate or halt, destroy and recreate the container, then
check status and resume the feature.

**Acceptance Scenarios**:

1. **Given** a run with recorded history, **When** the container is removed and recreated from a rebuilt
   image, **Then** startup succeeds with no node-identity mismatch and the run's history is listed.
2. **Given** a kept worktree for a halted feature, **When** the operator lists the target repository's
   worktrees from the host, **Then** the worktree is listed as valid and its files are readable.
3. **Given** a halted feature after recreation, **When** the operator resumes it, **Then** it resumes at
   its checkpointed phase.

---

### User Story 3 - Operator watches the run from the web console (Priority: P2)

The operator opens the web console in a browser on their own machine while a containerized run is in
progress and sees it live. The console is not reachable from other machines on the network.

**Why this priority**: The console is the primary observability surface, but runs work without it.

**Independent Test**: Start the console service and load it from the host browser; attempt to reach it from
another machine on the same network.

**Acceptance Scenarios**:

1. **Given** the console service is running, **When** the operator opens the console address printed at start
   (the port they passed, or a random free one) on their
   machine, **Then** the console loads and live updates work.
2. **Given** the console service is running, **When** another machine on the network tries to reach it,
   **Then** the connection is refused.
3. **Given** the release shape, **When** it starts without the console's signing secret configured,
   **Then** startup is refused with a message naming the missing setting.

---

### User Story 4 - Self-contained release image (Priority: P2)

An operator runs the orchestrator from a self-contained release image — no source checkout, no build
toolchain at runtime — with the console served on startup, and attaches a remote interactive console to the
running instance to drive the operator API.

**Why this priority**: The development shape covers day-to-day use; the release shape is what makes the
orchestrator deployable on a dedicated machine. Valuable but not blocking.

**Independent Test**: Build the release image, start it with the same mounts and credentials, attach a remote
console, check status, restart it, and check status again.

**Acceptance Scenarios**:

1. **Given** the release image and a credentials file, **When** it starts, **Then** the console is served
   and the run state store opens.
2. **Given** a running release instance, **When** the operator attaches a remote console, **Then** the
   operator API is available.
3. **Given** a release instance with recorded history, **When** it is restarted, **Then** history persists
   with no node-identity mismatch.

---

### User Story 5 - Orchestrated sessions test the target's web and desktop applications (Priority: P2)

A feature being built for a target repository includes end-to-end tests of a web application (in the three
major browser engines, headless) or of a Linux desktop/Electron application (driven through a virtual
display with input automation and screenshots). The coding-agent session inside the container can run those
tests under the default `strict` containment profile. A human can optionally watch the virtual display.

**Why this priority**: Without it, implement phases for UI-bearing targets can't verify their own work, but
the orchestrator itself runs fine without it.

**Independent Test**: Build the environment with each capability enabled and run a sample browser test and a
sample desktop-app interaction test, both from a `strict` orchestrated session.

**Acceptance Scenarios**:

1. **Given** the web-testing capability is enabled, **When** a session runs a sample end-to-end browser
   test in each of the three engines, **Then** all pass without downloading anything at test time.
2. **Given** the desktop-testing capability is enabled, **When** a session launches a sample desktop
   application, clicks a control and takes a screenshot, **Then** the click takes effect and the screenshot
   is written.
3. **Given** a `strict` orchestrated session, **When** it runs these testing commands, **Then** the
   containment hook does not deny them, while the commands it denies today are still denied.
4. **Given** the optional viewer is enabled, **When** a human opens it on their machine, **Then** they see
   the virtual display live.
5. **Given** neither capability is enabled, **When** the image is built, **Then** it contains none of their
   components.

---

### User Story 6 - Orchestrated sessions test the target's Android application (Priority: P3)

A target repository containing an Android application has instrumented tests. The session inside the
container runs them against a headless emulator inside the container (when the host offers hardware
virtualization) or against an emulator/device on the host (when it does not).

**Why this priority**: Narrowest audience and heaviest image; useful only for Android targets.

**Independent Test**: With the capability enabled and virtualization passed through, boot the emulator and
run a sample instrumented test; repeat with the host-emulator fallback.

**Acceptance Scenarios**:

1. **Given** the Android capability and hardware virtualization, **When** the emulator is started,
   **Then** it finishes booting and a sample instrumented test passes.
2. **Given** the Android capability without hardware virtualization, **When** the operator points the
   container at an emulator or device on the host, **Then** a sample instrumented test passes against it.
3. **Given** the Android capability and no virtualization and no host device, **When** a session tries to
   start the emulator, **Then** it fails with a message naming both options.

---

### Edge Cases

- No coding-agent credentials at all (neither token nor mounted login): the container starts but warns
  loudly, naming both options; a run then fails at its first phase as it does on the host today.
- Model-alias pins unset: startup warns that runs are not reproducible (same guidance as the runbook).
- Both a token and a mounted login are present: the token wins, documented.
- Host user ids differ from the image default: the operator supplies their ids at build time; without that,
  mounted repositories may be read-only to the container and the docs say so.
- Target repository mounted at a different path than on the host: worktrees created inside would be invalid on
  the host; the docs require the identical path and the smoke test checks it.
- Existing store history from host runs: not migrated; each target's per-instance store starts empty.
  Documented as an intentional fresh store. Worktrees and exports already under `~/.autonomous` stay in place.
- Two instances started for the same target: the second is refused before opening the store, naming the target
  and the live instance.
- An operator API call inside an instance names a different repository: refused, naming the served repository.
- A requested console port is already in use on the host: the instance fails to start, naming the port; with no
  port passed, a free one is chosen and printed.
- Operator adds an ad hoc node name when starting the shell: the store refuses with its node-mismatch error
  (fail loud, unchanged behaviour); docs warn against it.
- A target's tests need a capability the image was not built with: the test fails with "command not found";
  the docs map each capability to its build option.
- Chromium's sandbox unavailable in the container's default security profile: documented workaround in
  the target's test configuration; the container does not gain extra privileges by default.
- iOS, macOS or Windows targets: out of the image; tests for them run on an external runner.
- A `strict` session's test needs a dependency that was not pre-fetched: if it fetches through a download tool
  the hook denies (`curl`, `wget`, web fetch/search), the hook refuses it, naming the profile and rule. A
  package-manager install (`npm install`, `pip install`, `mix deps.get`, Gradle) is **not** denied by the hook
  today and reaches the registry over the open egress (FR-029). Either way the operator is expected to
  pre-fetch (FR-027a); the package-manager path is a recorded open gap, not a guarantee.
- The legacy retired settings (run-mode flag, concurrency limit) set in the credentials file: still refused at
  boot, unchanged (Principle II).

## Requirements *(mandatory)*

### Functional Requirements

**Run shapes**

- **FR-001**: The project MUST provide a development environment that runs the application from the mounted
  source, supporting the interactive operator shell, the web console, compilation and the test suite.
- **FR-002**: The project MUST provide a self-contained release image that starts the application with the
  console served and accepts a remote interactive console.
- **FR-003**: Both shapes MUST be started with documented one-line commands from the repository root, using Docker
  Engine with Compose v2 on Linux (the only supported engine).

**Containment boundary**

- **FR-004**: The application MUST refuse to start (interactive shell, web server, or release) when it is not
  running inside the provided container, with a message naming the supported commands. The refusal MUST
  happen before the run state store is opened. Detection is a marker set by the provided image; the refusal
  guards against accidental host starts, not deliberate circumvention, and the docs MUST say it is not a
  security boundary. There is no override other than the test environment.
- **FR-005**: The test suite and compilation MUST keep working on the host (the refusal does not apply to them).
- **FR-006**: The container MUST run as a non-root user whose user/group ids are configurable at build time to
  match the host user.
- **FR-007**: Each container instance MUST serve exactly one target repository. Only that target repository and the
  orchestrator's state root MUST be writable from inside the container (plus the source checkout in the
  development shape and, opt-in, the operator's agent login). An operator API call naming any other repository
  MUST fail loudly, naming the repository the instance serves.
- **FR-008**: Mounted target repositories MUST be usable by version control without "unsafe repository"
  refusals.
- **FR-009**: The containment profiles (`strict`, `permissive`), the session markers, and every correctness
  gate MUST behave identically inside the container.

**Toolchain and tools**

- **FR-010**: Language/runtime versions inside the container MUST be taken from the repository's single
  pinned-versions file; no second copy of the versions may exist.
- **FR-011**: The container MUST include every external tool the orchestrator invokes — version control, the
  code-hosting client, the hook interpreter, and the coding-agent CLI at a pinned version.

**Credentials**

- **FR-012**: The coding agent MUST be authenticable either by token environment variables or by an optional,
  explicitly opted-into mount of the operator's existing interactive login; when both are present the token wins.
- **FR-013**: Pushing branches and opening pull requests MUST work from a code-hosting token supplied at run time.
- **FR-014**: Commit author/committer identity MUST be configurable at run time.
- **FR-015**: No secret MAY be baked into any image layer or committed; the repository MUST ship an example
  credentials file and ignore the real one.
- **FR-016**: Startup MUST warn when no coding-agent credentials are found and when model-alias pins are unset.

**State**

- **FR-017**: The state root MUST be the host's orchestrator state directory (`~/.autonomous`), shared by every
  instance and mounted at its host absolute path, so it persists across container restart, removal and
  recreation, including from a rebuilt image.
- **FR-018**: Each instance MUST use its own store directory and node identity inside the shared state root,
  both derived deterministically from its target repository's identity, so (a) recreating an instance for the
  same target never triggers the store's node-mismatch refusal and (b) instances for different targets never
  open the same store.
- **FR-018a**: Instances for different targets MUST be able to run at the same time. Starting a second instance
  for a target that already has a live instance MUST be refused loudly, naming the target and the live instance,
  before the store is opened.
- **FR-018b**: The cost budget and breaker MUST be per instance, unchanged from today (spend ≤ budget + one
  reservation, per instance). The start output and the docs MUST state that total spend across instances is the
  sum of their budgets; there is no machine-wide cap.
- **FR-019**: The target repository MUST be mounted at the same absolute path as on the host so worktrees are
  valid from both sides.
- **FR-020**: Store history recorded by host runs MUST NOT be read or migrated into a per-target store (fresh
  store, documented). Worktrees and exports already under the shared state root stay where they are.

**Console**

- **FR-021**: The console MUST be reachable from the operator's machine and MUST NOT be reachable from other
  machines by default. Each instance's console MUST be published on a host port passed as a start parameter,
  or on a random free host port when none is passed; the chosen address MUST be printed at start.
- **FR-022**: The console's listen address, port, public host and signing secret MUST be configurable at run
  time; the release shape MUST refuse to start without an explicitly provided signing secret.

**Target-application testing (opt-in)**

- **FR-023**: The image MUST support independent, opt-in build options for (a) headless web testing in the three
  major browser engines, (b) Linux desktop/Electron testing through a virtual display with input automation and
  screenshots, and (c) Android testing. With all options off the image MUST contain none of their components.
- **FR-024**: Browser engines MUST be pre-installed in a shared location so a target's tests use them without
  downloading at test time.
- **FR-025**: When desktop testing is enabled and requested, a virtual display MUST be available to sessions; an
  optional live viewer MUST be reachable only from the operator's machine.
- **FR-026**: Android testing MUST work against an in-container headless emulator when hardware
  virtualization is passed through, and against a host emulator/device otherwise; with neither, it MUST fail
  with a message naming both options.
- **FR-027**: Under the `strict` profile, the test commands these capabilities need MUST NOT be denied by the
  containment hook or per-phase permissions. Where they are denied today, the allowlist MUST be extended
  narrowly with tests proving the commands it denies today stay denied. Forcing `permissive` is not an acceptable
  resolution. The allowlist covers offline test execution only and MUST NOT remove any existing network denial:
  under `strict`, the hook keeps denying the download tools, web fetch and web search it denies today
  (Principle III). Package-manager downloads are not denied by the hook today; this feature neither adds nor
  removes that denial, and the enforcement guide MUST record it as an open gap alongside FR-029.
- **FR-027a**: The docs MUST describe how an operator pre-fetches a target's test dependencies (browser/desktop/
  Android toolchains and the target's own packages) outside gated sessions, so a `strict` session's tests run
  without network access.
- **FR-028**: iOS, macOS and Windows target testing are out of scope for the image; the docs MUST state that they
  run on an external runner.

**Scope limits and docs**

- **FR-029**: This feature MUST NOT restrict outbound network traffic from the container (egress allowlisting is
  deferred); the enforcement guide MUST record that as an open gap.
- **FR-030**: The runbook, the enforcement guide and the contributor guide MUST present the container as the
  primary run path, including credentials, mounts, the same-path rule, the state note, and the capability options.

### Key Entities

- **Run shape**: development environment or release image; determines what is mounted and how the app starts.
- **Instance**: one running container serving exactly one target repository, with its own console port.
- **State root**: the host's `~/.autonomous`, shared by all instances and mounted at its host path; holds a
  per-target store directory, the repository-segmented worktrees, and exports.
- **Per-target store**: the run store directory for one target inside the state root; opened by at most one live
  instance at a time.
- **Node identity**: the name the per-target store is keyed to; derived from the target repository's identity, so
  it is constant across restarts and recreation and distinct between targets.
- **Credentials set**: coding-agent token or mounted login, code-hosting token, commit identity, model pins,
  console secret — supplied at run time only.
- **Testing capability**: an opt-in image option (web, desktop, Android) and its runtime switches.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a fresh checkout with credentials filled in, an operator reaches a working operator shell inside
  the container with at most 2 documented commands.
- **SC-002**: 100% of attempts to start the application directly on the host are refused before any state is
  written; 0 host test-suite or compilation regressions.
- **SC-003**: The full test suite passes both on the host and inside the container.
- **SC-004**: A smoke run of one backlog feature against a sibling target repository, driven entirely from inside
  the container, ends with a pull request opened.
- **SC-005**: After the container is removed and recreated from a rebuilt image, 100% of previously recorded runs
  are listed and a halted feature resumes at its checkpoint.
- **SC-006**: Worktrees created inside the container are valid when listed from the host.
- **SC-007**: The console loads on the operator's machine and is unreachable from another machine on the network.
- **SC-007a**: Two instances serving two different targets run at the same time, each with its own console port and
  history; a second instance for an already-served target is refused 100% of the time.
- **SC-008**: The release image starts, accepts a remote console, and keeps its history across a restart.
- **SC-009**: With each testing capability enabled, its sample test passes from a `strict` orchestrated session
  (web: 3 engines; desktop: click + screenshot; Android: instrumented test via each of the two modes).
- **SC-010**: Every command the `strict` profile denies today is still denied (red-team cases unchanged and passing).
- **SC-011**: A run succeeds with each of the two coding-agent authentication modes.
- **SC-012**: A scan of every image layer and of the repository finds no secret values.

## Assumptions

- The only supported and validated engine is Docker Engine with Compose v2 on a Linux host. Podman, other OCI
  engines, and macOS/Windows hosts are unsupported (they may work, but are not validated or documented).
- The host user's ids are typically 1000/1000; others pass their ids at build time.
- Hardware virtualization for Android is available on Linux hosts only; elsewhere the host-emulator fallback applies.
- Network egress stays open (FR-029); the coding agent, package registries and the code host are reachable.
- The coding-agent CLI ships through a package registry that requires a JavaScript runtime in the image. That runtime
  is a tool dependency, not a frontend build step, so the constitution's no-frontend-build-pipeline rule is not
  affected.
- The constitution's Toolchain rule ("every command runs through the pinned version manager") is satisfied inside
  the development shape, which uses the same version manager and pinned file.
- Host runs remain possible for tests and compilation only; all real operation is containerized.
- The first image build may be slow because the runtime is built from the pinned versions; later builds are cached.
