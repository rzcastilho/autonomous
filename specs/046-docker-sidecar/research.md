# Research: Container Engine Sidecar for Agent Sessions

**Feature**: `046-docker-sidecar` | **Date**: 2026-10-23 | **Spec**: [spec.md](./spec.md)

Each entry gives the decision, why it was chosen, and the alternatives that were
considered and rejected.

---

## R1. The engine inside the sidecar runs rootless, as the operator's uid

**Decision**: The sidecar is built from the upstream `docker:<DOCKER_VERSION>-dind-rootless`
image, as a new `engine` stage in the repository `Dockerfile`. That stage adds a
user with the operator's `UID`/`GID` (the same build args the `dev` and `release`
images already take) and `/etc/subuid` and `/etc/subgid` ranges for it. The
container runs `privileged: true`, which the rootless image still needs for
`rootlesskit`'s user namespace and mounts. The **daemon itself** runs as the
operator's uid inside a user namespace.

**Rationale**:
- **Host reach.** Under a *rootful* engine in a privileged sidecar, a session could
  run `docker run --privileged …` and get a container with full capabilities on the
  host kernel. It could then mount a host block device and reach the host. That
  defeats User Story 2 and the intent of Principle III. A bind mount alone resolves
  inside the sidecar, but `--privileged`, `--device` and `--pid=host` do not. Under
  a rootless engine, "privileged" means privileged inside a user namespace whose
  root is the operator's uid. Host device nodes and host-root-owned files stay out
  of reach. The outer `privileged: true` is held by `rootlesskit`, not by anything
  a session can drive.
- **File ownership.** In engine containers, uid 0 maps to the operator's uid. Files
  a container writes into a bind-mounted worktree are therefore owned by the
  operator, as everything else in the worktree is (feature 031, FR-006). A rootful
  engine would leave root-owned files that the unprivileged agent can neither edit
  nor delete. That breaks `git` operations and worktree teardown.

**Alternatives considered**:
- **Rootful `docker:dind`.** Simpler, but host-root-equivalent for any session
  (see above). Rejected.
- **Rootful engine plus an authorization plugin** that refuses `--privileged`,
  `--device`, `--cap-add` and host namespaces. It adds a component that must parse
  every API body correctly, and every miss is a host escape. It also does nothing
  for file ownership. Rejected.
- **Sysbox, or another host-installed runtime.** Requires a host install that the
  feature cannot assume (spec Assumptions: Docker Engine on Linux, or Docker
  Desktop). Rejected.
- **The upstream rootless image unchanged** (its `rootless` user, uid 1000).
  Correct only when the operator's uid is 1000. Rejected for the ownership reason
  above.

**Known rootless limits, documented in `docs/container.md` (FR-016)**:
- **Container users other than root.** Files written to a bind mount by a
  non-root container user land on the host as a subordinate uid (for example
  `100998`).
- **Storage driver.** `overlay2` needs host kernel 5.11 or later; Docker
  Desktop's VM qualifies. Otherwise the engine falls back to `fuse-overlayfs` or
  `vfs`, which is slower.
- **Resource limits.** cgroup-based limits on engine containers depend on host
  cgroup v2 delegation.

---

## R2. Network: the agent container joins the sidecar's network namespace

**Decision**: Every agent service (`dev`, `console`, `release`) gets
`network_mode: "service:engine"` in the overlay. The sidecar owns the namespace,
so the sidecar now carries what the agent service carried before:
- `hostname: autonomous`, the Erlang node host part;
- the loopback console port `127.0.0.1:${AUTONOMOUS_HOST_PORT}:4000`;
- the `host.docker.internal:host-gateway` extra host.

The overlay removes those keys from the agent services with Compose's `!reset`
tag. Under the rootless engine, published container ports bind inside the
sidecar's namespace through `rootlesskit`'s port driver. That is the agent's own
namespace, so `localhost:<published port>` works in a session exactly as it does
on a laptop. The overlay sets `net.ipv4.ip_unprivileged_port_start=0` on the
sidecar, so a rootless engine can publish ports below 1024.

**Rationale**: With a separate network, the agent would reach published ports at
`engine:<port>`, not `localhost`. That breaks the common case behind SC-005a: a
target's tests connect to `localhost:5432` after `docker compose up`, and test
container libraries assume the engine's host is the local host. Sharing the
namespace satisfies both without any per-target setup (FR-003, FR-003a, FR-008).

**Consequences, recorded in the contracts and docs**:
- **Reserved ports.** Ports the agent container already uses — console 4000,
  `epmd` 4369, the Erlang distribution port, the engine endpoint 2375 (R3) and
  the viewer 6080 — are taken in the shared namespace. An engine container that
  publishes one of them fails to start with the engine's ordinary "address
  already in use" error.
- **Host loopback.** Engine containers cannot reach the agent's loopback. The
  default `rootlesskit`/`slirp4netns` setup disables host-loopback access, so the
  console and the engine endpoint are not reachable from inside engine
  containers.
- **Port lookups.** The `port` and `viewer` wrapper commands must ask the
  container that publishes the port, which is now the sidecar
  (contracts/wrapper-cli.md).
- **`--viewer` combined with the engine.** The viewer port moves to the sidecar
  through a second small overlay, `compose.engine-viewer.yaml`.

**Alternatives considered**:
- **A private per-instance network, reaching the engine at `engine:`.** Breaks
  `localhost` in tests. Rejected.
- **Setting `TESTCONTAINERS_HOST_OVERRIDE=engine` and asking targets to read a
  host variable.** Breaks "no change to the target repository". Rejected.

---

## R3. Engine endpoint: TCP on the shared loopback, never a socket from the host

**Decision**: The daemon listens on `tcp://127.0.0.1:2375`, without TLS, inside the
shared namespace, and on its own rootless unix socket. The overlay sets
`DOCKER_HOST=tcp://127.0.0.1:2375` on the agent services. Nothing publishes 2375.
No path `docker.sock` appears in any compose file, wrapper or entrypoint, and a
hermetic guard test asserts that (FR-005).

**Rationale**:
- **Who can reach it.** Only the shared namespace can: the agent container and the
  sidecar (FR-006). Other instances have their own namespace, and the host has no
  published port.
- **No socket permissions.** A loopback endpoint avoids socket-permission plumbing
  between two containers that run as different users. `DOCKER_HOST` with a
  loopback TCP URL is the "standard client environment" (FR-003): the docker CLI,
  Compose, buildx and test container libraries all honour it.
- **No transport encryption needed.** The traffic never leaves a single namespace
  (spec Assumptions).
- **Implementation check.** Recent engine releases warn about or delay startup on
  an unauthenticated TCP listener that is not on loopback. The listener is on
  loopback; the implementation verifies the pinned version starts cleanly with it
  (smoke step "engine reachable").

**Alternatives considered**:
- **A unix socket on a shared named volume.** Needs the socket's group to match
  the agent's gid across two images, and test container libraries derive
  `localhost` from a unix `DOCKER_HOST` anyway. With the shared namespace, it
  adds nothing. Rejected.
- **Mounting the host socket.** Forbidden (FR-005).

**Test container libraries**: Their reaper container mounts the engine socket
path. The overlay sets `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` to the rootless
daemon's socket path *inside the sidecar*. The engine resolves the mount in its
own filesystem (R5), so that path is correct. It also sets
`TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1`. End-of-phase cleanup (R7) removes
whatever the reaper misses.

---

## R4. Image client: pinned static binaries, opt-in block in `base`

**Decision**: A new build arg, `WITH_DOCKER=0`, controls a no-op-unless-1 `RUN`
block at the end of the `base` stage, after the agent-root block. When it is `1`,
the block installs:
- the static `docker` CLI from `download.docker.com/linux/static/stable/<arch>/docker-${DOCKER_VERSION}.tgz`
  into `/usr/local/bin`;
- the `compose` and `buildx` CLI plugins, from their pinned GitHub releases, into
  `/usr/local/lib/docker/cli-plugins`, the system-wide plugin path that every uid
  can read;
- `/etc/autonomous/container-engine`, a file that records the pinned versions.

`DOCKER_VERSION` is one ARG, shared by the client download and by the `engine`
stage's `FROM` tag, so client and daemon never drift. The implementation sets it
to the current stable release and verifies that the tag and the tarball both
exist. `COMPOSE_VERSION` and `BUILDX_VERSION` are separate pins. The block sits in
`base`, so `dev` and `release` both carry the client (FR-001, Edge case "Release
image").

**Rationale**:
- **Opt-in pattern.** This follows the `--apt` and `--agent-root` precedent
  (feature 037). As there, "byte-identical" in FR-001 and SC-004 means the image's
  *filesystem content*: an image built without `WITH_DOCKER=1` has no `docker`
  binary, no plugin directory and no `/etc/autonomous/container-engine`. Layer
  digests change whenever a `RUN` line is added, which 037 accepted the same way.
- **Static binaries.** They avoid adding Docker's apt repository and its signing
  key to the image.

**Alternatives considered**:
- **Debian's `docker.io` package.** Old, and not pinned to the sidecar's version.
  Rejected.
- **Installing the client at container start.** Needs network access on every
  start and is not reproducible. Rejected.

---

## R5. Same-path mounts in the sidecar

**Decision**: The sidecar mounts `${AUTONOMOUS_REPO}` and `${AUTONOMOUS_ROOT}` at
the same absolute paths as the agent container. The worktree root
(`Layout.worktree_root/2` = `<state root>/worktrees/<segment>`) is under the state
root, so feature worktrees resolve on both sides (FR-007). The dev-only
`.:/workspace` source mount is **not** given to the sidecar. A session that mounts
`/workspace`, `$HOME` or `/tmp` into a container gets the sidecar's own (empty or
unrelated) path. That limitation is documented, and the prompt note (R8) tells
sessions to stage mounted files under the worktree.

**Rationale**: The engine resolves bind-mount sources in its own filesystem, not
the client's. The existing same-path rule (feature 031, FR-017/FR-019) already
exists for `git worktree`, and it extends to the engine unchanged. A Compose
relative bind mount is made absolute by the Compose CLI, which runs in the agent
container, before the API call. So it resolves to the same worktree path in the
sidecar (FR-003a).

**Alternatives considered**: Mounting more host paths into the sidecar would widen
what a session can reach (User Story 2.2). Rejected.

---

## R6. Lifecycle, readiness and refusal belong to the wrapper; advertisement belongs to the entrypoint

**Decision**:
- **Wrapper — before anything starts.** `scripts/autonomous … --docker` checks
  three things and refuses if any fails:
  - the image carries the client (a cheap `docker run --rm --entrypoint sh <image>
    -c 'command -v docker …'`; exit 5, "built without --docker");
  - the engine image exists (exit 5);
  - Compose is at least v2.24.4, which `!reset` needs (exit 3).
- **Wrapper — start the sidecar first.** It runs `docker compose … up -d --wait
  --wait-timeout ${AUTONOMOUS_ENGINE_TIMEOUT:-60} engine`. The sidecar's
  healthcheck is `docker -H tcp://127.0.0.1:2375 info`.
  - The sidecar fails to start (for example, privileged containers are refused,
    or the host engine is rootless): the wrapper removes the sidecar and exits
    **77**, naming the cause and the remedy (FR-012).
  - The engine does not become healthy within the bound: the wrapper removes the
    sidecar and exits **78** (FR-011, FR-012).
- **Wrapper — start the agent service.** The agent service then starts as today.
  It has `depends_on: engine: condition: service_healthy`.
- **Entrypoint step `container_engine`.** This new step runs after `agent_root`.
  It always unsets `AUTONOMOUS_CONTAINER_ENGINE` first. When
  `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`, set by the overlay only, it probes
  `docker version --format '{{.Server.Version}}'`, bounded. It sweeps the engine
  (R7: no containers, networks or volumes survive an instance restart). Then it
  exports `AUTONOMOUS_CONTAINER_ENGINE=1` and `…_VERSION`, and says one line.
  - If the probe fails: the step exits **78** (FR-011). `wait_for_console` sees
    the exit, and the wrapper tears the project down (`down`, keeping volumes)
    and passes the code through, so nothing is left running.
  - When requested is unset (no `--docker`), the step is silent and changes
    nothing. The step is also a smoke hook, `container-engine`, in the style of
    `agent-root`.
- **`shell`.** `shell` is foreground `run --rm`, so it can no longer `exec`. The
  wrapper runs it, then removes the sidecar (`rm -sf engine`) on every exit path.
- **`lookup_identity`.** It keeps using the overlay-free file list. A
  `run --no-deps` against a `network_mode: service:engine` service would fail,
  because the sidecar is not running yet.

**Rationale**:
- **Readiness is checked twice, on purpose.** The wrapper owns container
  lifecycle and is the only place that can guarantee "leave nothing running". The
  entrypoint is the only place that can set an environment the VM inherits,
  because the advertisement must come after a positive probe. Both checks are
  cheap.
- **Unset before export.** This mirrors `agent_root`: a value from `.env` or
  compose is never honoured.

**Alternatives considered**:
- **Relying only on `depends_on: service_healthy`.** Compose's error is generic,
  and the wrapper cannot tell "refused privileged" from "slow". Rejected as the
  only mechanism; it stays as the ordering guarantee.
- **Starting without the engine on failure.** Forbidden (FR-012, Clarification Q3).

**Privileged refusal classification**: The wrapper matches the sidecar's
`up` output and logs case-insensitively for `privileged`, `operation not
permitted`, `rootless` and `cannot be run in`. On a match it names the cause:
"the host runtime refused a privileged container". It names the remedy: run on
Docker Engine (Linux) or Docker Desktop, with privileged containers allowed. Any
other failure is reported with the last 20 log lines, as `wait_for_console`
already does.

---

## R7. End-of-phase cleanup runs in the orchestrator, at the phase boundary

**Decision**: A new boundary module, `Autonomous.ContainerEngine`, offers
`cleanup/1`. It runs only when the engine is advertised and does nothing
otherwise: zero commands, zero log lines (FR-010a "skipped entirely"). It runs
four steps in order:
1. `docker ps -aq`, then, if the list is non-empty, `docker rm -f -v <ids>`;
2. `docker network prune -f`;
3. `docker volume prune -af`, which also removes named volumes;
4. a verification listing: `docker ps -aq`,
   `docker network ls -q --filter type=custom` and `docker volume ls -q`.

Images and build cache are never touched: there is no `image prune`,
`builder prune` or `system prune`. A non-empty verification, a non-zero exit or a
timeout is a residue. Residue is reported as
`{:residue, %{containers: n, networks: n, volumes: n}, cause}`. The caller logs it
with `Logger.error`, naming feature, phase and residue, and emits
`[:speckit, :engine, :cleanup]` telemetry. The phase outcome is never changed
(FR-010a).

**Call sites**, all in `FeatureRunner`, each wrapped `try … after` so a raise
still cleans up:
- **`loop/12`, around `run_step/8`.** This covers every pipeline phase. For
  `:implement`, `run_step` is the *whole* chunk loop (`run_chunked_phase`), so
  cleanup runs once per implement phase, not between chunks (Edge case "Implement
  chunks"). For `:analyze`, it is the whole auto-remediation loop.
- **The pre-phase remediation session** (`maybe_run_remediation`).
- **The PR describe session**, for uniformity. It is the remaining session site.

A cleanup failure leaves the next boundary's cleanup to try again (Edge case
"Cleanup itself fails"). The loud log line has already been written before the
next phase starts.

**Boundary mechanics**:
- Commands run through an injected CLI module (`Config.container_engine_cli/0`,
  default `ContainerEngine.Cli`, a `System.cmd/3` wrapper).
- Each cleanup runs inside `Task.Supervisor.async_nolink(Autonomous.SessionSup,
  …)` with `Task.yield/2` then `Task.shutdown/2`, bounded by
  `Config.container_engine_cleanup_timeout_ms/0` (default 120 000). A hung engine
  cannot hang the runner, and a crash in the boundary cannot take it down
  (Principle VI, feature 034 precedent).
- The advertisement is read once per feature run (`ContainerEngine.advertised?/1`
  over the env) and can be overridden by a `FeatureRunner` option, `:engine`.
  That keeps the default suite hermetic: with no env, it is skipped.

**Rationale**:
- **Phase-boundary placement.** This is the single place that sees every terminal
  status: success, gate divert, failure, a session deadline (`PhaseSession`
  returns normally), session death (returned as a value) and supersession drain
  (the phase still returns). A raise is covered by `after`.
- **Not inside the session.** Cleanup inside the session or the `PhaseSession`
  fold would run per chunk and would fall within the session deadline.

**Alternatives considered**:
- **A session `Stop` hook.** Sessions are model-driven and can be killed by the
  deadline before a hook runs. Rejected.
- **`docker system prune -af --volumes`.** Removes images and build cache
  (SC-003). Rejected.
- **Per-phase engine labels or contexts, removing only what a phase created.**
  Sessions start containers with arbitrary flags and libraries, so labels cannot
  be enforced. "Everything except images and cache" is exact and simple.
  Rejected.

---

## R8. Prompt note, session environment and Configuration row

**Decision**:
- **Prompt note.** `priv/prompts/container_engine.md`, a new prompt pack loaded
  through the `Prompts` allow-list, is appended to the `:implement` and
  `:converge` prompts only, after the agent-root note. It applies only when
  `ContainerEngine.advertised?/1` is true; it is a `PhaseRequest` option,
  `:container_engine`, defaulting lazily to the advertisement. It says three
  things:
  - a container engine is available through `DOCKER_HOST`, including `docker
    compose`;
  - files to mount must live under the worktree, never `/tmp` or `$HOME`;
  - engine containers, networks and volumes are removed when the phase ends.

  When the option is `false`, the request is byte-identical (FR-013, SC-004).
- **Session environment.** No launch-env change. `DOCKER_HOST` and the
  `TESTCONTAINERS_*` overrides come from the container environment, and sessions
  inherit it untouched (feature 041, `session_env_inheritance_test`).
- **Configuration row.** It appears only when
  `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1` (FR-014). Its value comes from a live
  probe in `start_async`, as in 044's pack row: `checking…`, then
  `available — engine <version>` or `unreachable — <cause>`. The row trusts no
  value cached at start, because a sidecar can die after start (User Story 4.2).
  The pure view module is `Web.ContainerEngineView`. When not requested, the
  probe never starts and the markup is unchanged.

**Rationale**: This mirrors `AgentRoot` and `AgentRootView`, the existing opt-in
capability with the same shape. That keeps one pattern for operators and
reviewers.

---

## R9. Engine storage, stop, purge and cache reset

**Decision**:
- **Storage volume.** The overlay declares a project-scoped volume,
  `autonomous-engine` (no `name:`), labelled `dev.autonomous.kind=engine-storage`
  and `dev.autonomous.segment=<segment>`, mounted at the sidecar's data root.
  Compose names it `autonomous-<segment>_autonomous-engine`, so it is per target
  and isolated (FR-009, User Story 3.5). Its ownership comes from the image
  directory, which is owned by the build-time uid: Docker seeds an empty named
  volume from the image path.
- **`stop`.** The wrapper detects a project container whose compose label is
  `com.docker.compose.service=engine`. When there is one, it adds the overlay to
  `down`, so the sidecar and every engine container stop with the instance
  (FR-010). Without such a container, `stop` is byte-identical.
- **`stop --purge`.** In addition, the wrapper removes the labelled engine-storage
  volume of the segment, whether or not a sidecar is running. This mirrors the
  user-volume loop added in 041.
- **`reset-cache --target <repo> --engine`.** A new option. It removes only the
  engine-storage volume. It refuses (exit 75) while any project container exists,
  as reset-cache already does. Without `--engine`, reset-cache is unchanged.

**Alternatives considered**:
- **Reserving `--volume engine`.** It would collide with an operator-declared
  volume named `engine`. Rejected.
- **A bind-mounted host directory under the state root.** The agent container
  could then read and write engine storage directly. It would also need host
  root, because the rootless data root holds subordinate uids. Rejected.

---

## R10. Constitution: MINOR amendment to Principle III (7.2.0 → 7.3.0)

**Decision**: As the first implementation task, add one Principle III bullet. It
sets four rules:
- An opt-in container-engine sidecar MAY hold elevated privileges.
- The agent container MUST NOT gain any privilege for it.
- The host engine's control socket MUST NEVER be mounted.
- The engine that sessions control MUST run unprivileged (rootless), so that
  privilege requested through it cannot reach the host.

**Rationale**: Principle III names the container as *the* boundary that bounds
every session's privileges. A privileged companion that sessions can drive
changes where that boundary sits. That is material, but it removes no MUST, so it
is MINOR (precedent: 6.1.0, feature 037). Writing the rootless requirement into
the constitution keeps a later "simplify to rootful dind" from silently
reintroducing host-root reach.

**Alternatives considered**: No amendment, on the reading that the sidecar is
"part of the container". That reading lets the rootless choice be undone without
a governance record. Rejected.
