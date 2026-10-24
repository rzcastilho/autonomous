# Quickstart: validating the container engine sidecar

Two layers of validation:
- the **hermetic suite**, with no Docker needed: stub `docker`, stub CLI module;
- the **engine smoke**, run by hand against real images, on a Linux host with
  Docker Engine or on Docker Desktop.

The contracts are in [contracts/](./contracts/), and the states and environment
are in [data-model.md](./data-model.md).

## Prerequisites

- `mise trust mise.toml` has been run once.
- For the smoke: Docker with Compose ≥ 2.24.4, and a host that permits privileged
  containers.
- On macOS, the smoke script needs the GNU `timeout` and util-linux `script`
  shims (see the project memory note on container smoke on a macOS host).

## 1. Hermetic suite

```bash
mise exec -- mix test test/autonomous/container_engine_test.exs \
  test/autonomous/container_engine_cli_test.exs \
  test/autonomous/container_engine_step_test.exs \
  test/autonomous/container_engine_guard_test.exs \
  test/autonomous/feature_runner_engine_test.exs \
  test/autonomous/phase_request_test.exs \
  test/autonomous/web/config_live_test.exs
mise exec -- mix test          # full suite: everything pre-046 still passes unchanged (SC-004)
```

Expected:
- **Cleanup.** `cleanup/1` is `:skipped` with zero stub calls when not advertised.
  It is `:clean` on empty listings and `{:residue, …}` on non-empty, error,
  timeout or crash. The stub never receives `image prune`, `builder prune`,
  `system prune` or `rmi`.
- **Cleanup in `FeatureRunner`.** Exactly one cleanup per phase boundary: one for
  `:implement` across N chunks, plus pre-phase remediation and describe. It also
  runs when the step raises, diverts or fails. Phase outcomes are identical with
  and without a residue.
- **Wrapper.** `build --docker` passes `WITH_DOCKER=1` and builds `engine`. A
  failing sidecar `up` leads to `rm -sf engine` and exit 77 or 78. Without the
  flag, the recorded docker calls are byte-identical to the pre-046 baseline.
  `stop` adds the overlay only when the engine container is labelled.
  `reset-cache --engine` removes only the labelled storage volume.
- **Entrypoint hook.** Not requested: silent, `=0`, no docker call. Requested with
  a reachable stub: `=1 VERSION=<v>`. Unreachable stub: exit 78. An inherited
  `AUTONOMOUS_CONTAINER_ENGINE=1` is ignored.
- **Guard.** No `docker.sock` in any compose file or script. No `privileged`,
  `cap_add`, `devices` or `security_opt` on `dev`, `console` or `release` in
  `compose.engine.yaml`.
- **Configuration.** Not requested: no row, markup unchanged. Requested: the row
  shows `checking…`, then `available — engine <v>` or `unreachable — <cause>`.

## 2. Engine smoke (by hand)

```bash
scripts/autonomous build --docker --release
scripts/container-smoke.sh engine                         # dev image
SMOKE_IMAGE=autonomous-release:local scripts/container-smoke.sh engine   # release image (SC-006)
```

The section prints PASS, FAIL or SKIP for each step and names the failing step
(User Story 4.4).

| # | Step | Proves |
|---|---|---|
| 1 | `docker version`, `docker compose version` and `docker buildx version` succeed in the image | FR-001, FR-015 |
| 2 | Start `console --target <tmp> --docker`. The `docker version` server field is non-empty | User Story 1.1, FR-003, SC-005 (time to ready under 30 s, warm) |
| 3 | `docker run --rm -v <worktree>:<worktree> alpine sh -c 'cat f; echo x > g'` reads `f` and leaves `g`, owned by the operator's uid | User Story 1.2, FR-007, R1 ownership |
| 4 | `docker run -d -p 18080:80 <image>`; `curl localhost:18080` from the agent container | User Story 1.3, FR-008 |
| 5 | A two-service compose file in the worktree (service B reaches A by name; relative bind mount; published port; one service with `build:`): `up -d --wait`, probe, `down`. No containers or networks remain | User Story 1.4, FR-003a, SC-005a |
| 6 | From a session, `docker ps -a` lists none of the host's containers (including the agent and sidecar). On the host, `docker inspect` of the agent container shows `Privileged=false`, no `CapAdd`, no `Devices`, the same as an instance without the engine | User Story 2.1, User Story 2.3, FR-004, SC-002 |
| 7 | `docker run --rm -v /:/host alpine ls /host/home` shows the sidecar's filesystem, not the host's. `docker run --rm --privileged alpine sh -c 'ls /dev/sd* /dev/nvme* 2>/dev/null; mount /dev/<host disk> /mnt'` cannot reach a host disk | User Story 2.2, R1 |
| 8 | On the host, `docker port <engine>` lists only the console port; `2375` is not published | User Story 2.4, FR-006 |
| 9 | Run a cleanup boundary through the shell (`Autonomous.ContainerEngine.after_boundary/3`) with a compose stack up. Afterwards, no containers, networks or volumes remain, and the pulled images are still listed | User Story 3.3, FR-010a, SC-005b |
| 10 | Pull an image, `stop`, then start again: the image is present, with no download. `stop --purge`, then start: the engine storage is empty | User Story 3.1, User Story 3.2, User Story 3.4, SC-003 |
| 11 | Two targets with `--docker` at once: neither sees the other's containers or images | User Story 3.5, FR-009 |
| 12 | `reset-cache --target <tmp> --engine` on a stopped instance: only the storage volume is removed | User Story 3.6 |
| 13 | Configuration page: the row reads available with the version. `docker stop <engine>`, then reload: unreachable. An instance without `--docker` has no row | User Story 4.1, User Story 4.2, User Story 4.3 |
| 14 | Instance without `--docker`: no `engine` container, no `DOCKER_HOST`, no client in an image built without `--docker` | User Story 1.5, SC-004 |

Refusal paths (FR-012), checked by the hermetic wrapper test and spot-checked by
hand:
- **Image without the client.** `console --docker` exits 5 before anything is
  created.
- **Readiness bound exceeded.** With `AUTONOMOUS_ENGINE_TIMEOUT=1` and a cold
  engine, the wrapper exits 78, and `docker ps -a --filter
  label=com.docker.compose.project=<project>` is empty.

## 3. End-to-end acceptance (SC-001)

1. Start an engine-enabled instance against a target whose integration tests
   start dependencies through a compose file or a test-containers library.
2. Run the backlog.
3. Check two outcomes. `implement` passes with no change to the target
   repository. The run log shows one cleanup line per phase boundary and no
   residue.
