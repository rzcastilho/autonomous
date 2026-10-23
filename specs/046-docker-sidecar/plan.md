# Implementation Plan: Container Engine Sidecar for Agent Sessions

**Branch**: `046-docker-sidecar` | **Date**: 2026-10-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/046-docker-sidecar/spec.md`

## Summary

Targets whose build or tests need a container engine cannot run today: the image
has no client, no engine is reachable, and the agent container is unprivileged.
This feature adds an opt-in **rootless engine in a per-instance sidecar** that
shares the agent container's network namespace.

1. **Image (FR-001, research R4)**. `scripts/autonomous build --docker` sets
   `WITH_DOCKER=1`.
   - **Client.** A no-op-unless-1 block at the end of `base` installs a pinned
     static `docker` CLI plus the `compose` and `buildx` plugins, and writes
     `/etc/autonomous/container-engine`. Both `dev` and `release` carry them.
   - **Sidecar image.** A new `engine` Dockerfile stage, `FROM
     docker:${DOCKER_VERSION}-dind-rootless`, adds the operator's uid/gid and its
     subordinate id ranges. It is built as `autonomous-engine:local`.
   - Without the option, image content is unchanged.
2. **Instance (FR-002–FR-012, R1–R3, R5, R6, R9)**. With `--docker`,
   `shell`/`console`/`release` add `compose.engine.yaml`.
   - **Sidecar service.** It holds `privileged: true` and runs a rootless engine
     on `tcp://127.0.0.1:2375`. It mounts the repo and the state root at the same
     paths as the agent container, and a project-scoped labelled storage volume.
     It owns the hostname, the console port and the extra host.
   - **Agent services.** They get `network_mode: service:engine`, with those keys
     removed (`!reset`), plus `DOCKER_HOST`, the `TESTCONTAINERS_*` overrides and
     `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`. They gain no privilege,
     capability, device or socket mount.
   - **Readiness and refusal.** The wrapper checks the preconditions, then
     `up --wait`s the sidecar within a bound. A failure removes what it created
     and refuses: exit 77 (the sidecar could not start) or 78 (the engine was not
     ready in time).
   - **Advertisement.** A new entrypoint step, `container_engine`, probes the
     engine, sweeps leftover containers, networks and volumes, and only then
     exports `AUTONOMOUS_CONTAINER_ENGINE=1`.
   - **`stop`.** It detects the sidecar and stops it. `--purge` also removes the
     engine storage, and a new `reset-cache --engine` clears it alone.
3. **Orchestrator (FR-010a, FR-013, R7, R8)**.
   - **Boundary module.** `Autonomous.ContainerEngine` reads the advertisement
     (env, injectable), supplies the implement/converge prompt note through a
     new `PhaseRequest` option `:container_engine`, and runs `cleanup/1`.
   - **What cleanup removes.** All containers, networks and volumes; never images
     or build cache.
   - **How cleanup runs.** It is bounded and runs in a `SessionSup` task.
   - **Where cleanup runs.** `FeatureRunner` calls it `try … after` around every
     phase step (implement = once, after the whole chunk loop), the pre-phase
     remediation and the describe session.
   - **Failure.** A failure logs loudly and never changes an outcome.
   - **Not advertised.** Zero calls, zero lines.
4. **Operator surfaces (FR-014–FR-016, R8)**.
   - **Console.** A "container engine" row on Configuration, shown only when the
     engine was requested, filled by a live async probe (`Web.ContainerEngineView`).
   - **Smoke.** A new `container-smoke.sh engine` section, run against both the
     dev and the release image.
   - **Docs.** `docs/container.md`, `docs/enforcement.md`, `docs/runbook.md` and
     `CLAUDE.md`.
   - **Constitution.** A MINOR amendment (7.2.0 → 7.3.0, R10) that writes the
     rootless requirement into Principle III.

No store or schema change (FR-017).

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28.5.0.6 (mise-pinned). POSIX `sh` for
the wrapper, entrypoint and smoke script. Dockerfile on Debian bookworm-slim, plus
an upstream `docker:<ver>-dind-rootless` (Alpine) stage. Compose YAML.

**Primary Dependencies**:
- **Docker Engine / Docker Desktop with Compose ≥ 2.24.4**, needed for `!reset`
  and `up --wait --wait-timeout`, and only when `--docker` is given.
- **Pinned Docker artifacts:** static Docker CLI, the `compose` and `buildx`
  plugins, and the `dind-rootless` image. One `DOCKER_VERSION` ARG is shared by
  the client and the sidecar.
- **No new Hex dependency.** The existing `Task.Supervisor` `Autonomous.SessionSup`
  hosts the cleanup task.

**Storage**: No Mnesia or store change. One project-scoped Docker named volume,
`autonomous-<segment>_autonomous-engine`, holds engine storage. Image files:
`/etc/autonomous/container-engine` and `/usr/local/lib/docker/cli-plugins/*`.
Environment variables:
- `DOCKER_HOST`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE`,
  `TESTCONTAINERS_HOST_OVERRIDE` and `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED`,
  set by the overlay;
- `AUTONOMOUS_CONTAINER_ENGINE` and `AUTONOMOUS_CONTAINER_ENGINE_VERSION`,
  exported by the entrypoint.

**Testing**: ExUnit, all hermetic.
- **`container_engine_test`** — pure helpers, `cleanup/1` against a stub CLI
  module (clean, residue, timeout, crash, not advertised ⇒ zero calls).
- **`phase_request_test`** — the note appears on implement/converge only, and
  `false` is byte-identical.
- **`feature_runner_engine_test`** — cleanup once per phase, including implement
  across chunks, raise, failure, gate divert and drain. The outcome is unchanged
  when cleanup fails.
- **`container_engine_step_test`** — the real entrypoint `container-engine` hook
  with a stub `docker`.
- **`container_engine_cli_test`** — the real wrapper against a stub `docker`:
  - `build --docker` args;
  - start order and the 77/78 teardowns;
  - `stop` sidecar detection, `--purge`, `reset-cache --engine`;
  - no-flag call logs unchanged.
- **`container_engine_guard_test`** — no `docker.sock` in any compose file or
  script; no `privileged`, `cap_add`, `devices` or socket mount on an agent service
  in `compose.engine.yaml`.
- **`config_live_test`** — the row is hidden, checking, available or unreachable.

Docker-dependent checks run by hand (`scripts/container-smoke.sh engine`).

**Target Platform**: Linux host with Docker Engine (rootful, privileged containers
permitted), or macOS with Docker Desktop. Inside: Debian bookworm agent container
and Alpine rootless engine sidecar.

**Project Type**: OTP application plus container runtime scripts (wrapper,
entrypoint, compose overlays, Dockerfile stage).

**Performance Goals**:
- The engine is ready within 30 s on a warm host (SC-005). The default readiness
  bound is 60 s (`AUTONOMOUS_ENGINE_TIMEOUT`).
- The entrypoint probe and sweep take under 2 s on an empty engine.
- End-of-phase cleanup takes under 10 s typically, with a 120 s hard bound.
  It is not on the session's deadline.

**Constraints**:
- `warnings_as_errors`.
- No `docker.sock` path anywhere.
- No change to the agent container's privileges.
- Without `--docker`, every file, call, environment and page is unchanged
  (SC-004).
- The advertisement is set only after a positive probe.
- Cleanup never changes a phase outcome and never removes images or build cache.
- The sidecar is per instance; nothing is shared between targets.

**Scale/Scope**:
- **Image:** 1 Dockerfile `base` block, 1 new Dockerfile stage, 3 build args.
- **Compose:** 2 compose overlays (`compose.engine.yaml`,
  `compose.engine-viewer.yaml`).
- **Wrapper:** the `--docker` option on build and start, plus `reset-cache
  --engine`, start, stop and `port`/`viewer` adjustments, and 2 exit codes.
- **Entrypoint:** 1 step and smoke hook.
- **Orchestrator:** 1 new module plus a CLI submodule, 1 prompt pack, 1
  `PhaseRequest` option, 3 `FeatureRunner` call sites, 2 `Config` accessors.
- **Console:** 1 view module and 1 Configuration row.
- **Verification and docs:** 1 smoke section, docs ×4, the constitution
  amendment.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment | Status |
|---|---|---|
| I. Pure core, isolated contracts | `Pipeline`, `Release`, `Ledger` and `Feature` are untouched. The engine CLI is isolated behind `ContainerEngine.Cli`, injected through `Config`. Residue parsing and the prompt note are pure. The advertisement is one env read (`advertised?/1`, env injectable), exactly as in `AgentRoot` | PASS |
| II. Fail loud at boundaries | Preconditions are refused before anything is created: an image without a client (5), Compose too old (3), and a missing engine image (5). A sidecar that cannot start (77) or an engine not ready in the bound (78) refuses and tears down, with no degraded fallback (FR-012). A cleanup residue is logged at error level naming the phase and the residue. The Configuration row shows only a probed state | PASS |
| III. Container-bounded execution | The agent container gains nothing (FR-004). Only the sidecar is privileged, and the engine sessions drive is **rootless** (R1), so `docker run --privileged` cannot reach the host. The host socket never appears (FR-005, guard test). The endpoint lives on the shared loopback only (FR-006). This changes where the boundary sits, so it is recorded by a MINOR amendment (R10) landing first | PASS (with amendment) |
| IV. Cost transparency; drain, don't kill | No new sessions, retries or cost paths. Cleanup is not a session, and it runs on drain too, after the in-flight phase returns. Nothing is killed | PASS |
| V. Human-in-the-loop | No gate is touched. A cleanup result never alters a transition | PASS (n/a) |
| VI. Idiomatic OTP | No new long-lived process. Cleanup is a bounded `Task.Supervisor.async_nolink` under the existing `SessionSup` (yield, then shutdown), and the runner never blocks unbounded. Tagged-tuple results, `@spec` on public functions | PASS |
| VII. Operator surfaces tell the truth | The row appears only when the engine was requested, and shows only a live-probed state (`checking…`, available with version, or unreachable with cause). Hidden otherwise: byte-identical page. It uses existing tokens and classes, with no `inspect/1` (G-inspect). The label is the spec's "container engine" | PASS |
| Technology Stack | No Hex dependency. Docker artifacts are opt-in image contents, pinned | PASS |
| Quality & test discipline | All Elixir tests are hermetic, with a stub CLI module and stub `docker` scripts. The real wrapper and entrypoint run in tests. The Docker checks are an opt-in smoke | PASS |
| Development workflow | Spec Kit loop. Earlier features' contracts (031 wrapper CLI, 041 reset-cache) are extended by this feature's own contracts, not edited in place | PASS |

**Post-design re-check (after Phase 1)**: unchanged. The only governance item is
the Principle III amendment (R10). It is not a violation once it lands, so
Complexity Tracking records only the deliberate design deviations.

## Project Structure

### Documentation (this feature)

```text
specs/046-docker-sidecar/
├── plan.md                         # This file
├── research.md                     # Phase 0: R1–R10
├── data-model.md                   # Phase 1: entities, states, env contract
├── quickstart.md                   # Phase 1: validation scenarios (smoke + hermetic)
├── contracts/
│   ├── build-and-compose.md        # Dockerfile block/stage, compose.engine*.yaml
│   ├── wrapper-cli.md              # --docker, start sequence, exit 77/78, stop/purge/reset-cache --engine, port/viewer
│   ├── entrypoint-step.md          # container_engine step + `container-engine` smoke hook
│   ├── orchestrator.md             # ContainerEngine API, PhaseRequest option, cleanup call sites, logging/telemetry
│   └── configuration-surface.md    # "container engine" row
├── checklists/
└── tasks.md                        # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
Dockerfile                                   # + WITH_DOCKER block in base; + `engine` stage
compose.yaml                                 # + WITH_DOCKER build arg (dev, release)
compose.engine.yaml                          # NEW: engine service, agent-service resets + env, storage volume
compose.engine-viewer.yaml                   # NEW: viewer port on the engine service
scripts/
├── autonomous                               # --docker; start/stop/purge/reset-cache --engine; port/viewer
├── container-entrypoint.sh                  # + container_engine step, `container-engine` hook
└── container-smoke.sh                       # + `engine` section
priv/prompts/container_engine.md             # NEW prompt pack
lib/autonomous/
├── container_engine.ex                      # NEW: advertised?/requested?/prompt_note/probe/cleanup
├── container_engine/cli.ex                  # NEW: System.cmd boundary (behaviour + default impl)
├── config.ex                                # + container_engine_cli/0, container_engine_cleanup_timeout_ms/0
├── prompts.ex                               # + "container_engine" in the allow-list
├── phase_request.ex                         # + :container_engine option → note on implement/converge
├── feature_runner.ex                        # + cleanup around run_step, pre-phase remediation, describe
├── telemetry.ex                             # + [:speckit, :engine, :cleanup] in the default logger
└── web/
    ├── container_engine_view.ex             # NEW pure view state
    └── live/config_live.ex                  # + row, start_async probe
test/autonomous/
├── container_engine_test.exs                # NEW
├── container_engine_cli_test.exs            # NEW (real wrapper, stub docker)
├── container_engine_step_test.exs           # NEW (real entrypoint hook, stub docker)
├── container_engine_guard_test.exs          # NEW (no docker.sock, agent services unprivileged)
├── feature_runner_engine_test.exs           # NEW
├── phase_request_test.exs                   # + cases
└── web/config_live_test.exs                 # + cases
docs/container.md, docs/enforcement.md, docs/runbook.md, CLAUDE.md
.specify/memory/constitution.md              # 7.2.0 → 7.3.0 (R10)
```

**Structure Decision**: This is the existing single OTP project. The new
orchestrator code is one boundary module with a CLI submodule, beside
`agent_root.ex`, and one pure view module beside `agent_root_view.ex`. Container
runtime changes go in the existing wrapper, entrypoint and Dockerfile, plus two
compose overlays. The overlays follow the `compose.android.yaml` and
`compose.desktop-viewer.yaml` precedent.

## Complexity Tracking

> Deliberate design choices that a reviewer might expect to be simpler.

| Deviation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Rootless engine in a custom `engine` stage, not stock `docker:dind` | Under a rootful engine, `docker run --privileged` from a session reaches the host. Container root would also write root-owned files into worktrees | Stock rootful dind breaks User Story 2 and the file-ownership rule. Stock rootless (uid 1000) is wrong whenever the operator's uid ≠ 1000 (R1) |
| Agent services join the sidecar's network namespace (`network_mode: service:engine`, keys moved with `!reset`, Compose ≥ 2.24.4) | Tests and test container libraries connect to `localhost:<published port>` | A separate network would put ports at `engine:<port>`, which needs target changes (R2). It violates FR-003 and SC-005a |
| Readiness checked twice (wrapper `up --wait`, entrypoint probe) | Only the wrapper can guarantee "nothing left running" on refusal. Only the entrypoint can advertise to the VM after a positive probe | Either alone leaves a gap: a generic Compose error, or an advertisement without a probe (R6) |
