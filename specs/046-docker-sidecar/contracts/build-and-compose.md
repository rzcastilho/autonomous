# Contract: Image build and Compose overlays

## Dockerfile

### Build args (new)

| Arg | Default | Used in |
|---|---|---|
| `WITH_DOCKER` | `0` | `base` block (client) |
| `DOCKER_VERSION` | pinned current stable | `base` client tarball, **and** the `engine` stage `FROM` tag (one pin) |
| `COMPOSE_VERSION` | pinned | `base` compose plugin |
| `BUILDX_VERSION` | pinned | `base` buildx plugin |

### `base` block (after the agent-root block)

- `WITH_DOCKER != 1`: no-op. No file is added and no package is installed.
- `WITH_DOCKER = 1`:
  - `/usr/local/bin/docker` comes from the static tarball for `$(uname -m)`.
  - `/usr/local/lib/docker/cli-plugins/docker-compose` and `…/docker-buildx` are
    `0755` and readable by every uid.
  - `/etc/autonomous/container-engine` holds lines
    `docker=<v>`, `compose=<v>` and `buildx=<v>`.
  - A download failure fails the build: no `|| true`.

### `engine` stage (new, last in the file)

```text
FROM docker:${DOCKER_VERSION}-dind-rootless AS engine
ARG UID=1000
ARG GID=1000
# user/group with UID/GID (reuse when they already exist, as base does),
# /etc/subuid + /etc/subgid range for that user,
# data root directory owned by UID:GID (seeds the named volume's ownership),
USER ${UID}
```

The stage only adds those layers. Building `dev` or `release` never builds it.

## `compose.yaml`

Add `WITH_DOCKER: "${WITH_DOCKER:-0}"` to the `build.args` of `dev` and `release`.
Nothing else changes.

## `compose.engine.yaml` (new)

The wrapper adds this file only with `--docker`, on `build`, `shell`, `console`
and `release`, and on `stop` when a sidecar is detected.

```yaml
# Opt-in (feature 046): isolated rootless container engine in a sidecar.
services:
  engine:
    image: autonomous-engine:local
    pull_policy: never
    build: { context: ., target: engine, args: { UID: …, GID: …, DOCKER_VERSION: … } }
    privileged: true                       # the ONLY privileged container (FR-004)
    hostname: autonomous                   # node host part moves here (R2)
    command: [--host=tcp://127.0.0.1:2375, --tls=false, ...]   # never published
    environment: { DOCKER_TLS_CERTDIR: "" }
    sysctls: { net.ipv4.ip_unprivileged_port_start: "0" }
    extra_hosts: ["host.docker.internal:host-gateway"]
    ports: ["127.0.0.1:${AUTONOMOUS_HOST_PORT:-}:4000"]
    volumes:
      - "${AUTONOMOUS_REPO}:${AUTONOMOUS_REPO}"
      - "${AUTONOMOUS_ROOT}:${AUTONOMOUS_ROOT}"
      - "autonomous-engine:<data root>"
    healthcheck: { test: [CMD, docker, -H, "tcp://127.0.0.1:2375", info], interval: 1s, retries: <large> }
  dev:     &agent
    network_mode: "service:engine"
    hostname: !reset null
    ports: !reset []
    extra_hosts: !reset []
    depends_on: { engine: { condition: service_healthy } }
    environment:
      DOCKER_HOST: "tcp://127.0.0.1:2375"
      TESTCONTAINERS_HOST_OVERRIDE: "127.0.0.1"
      TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE: "<rootless socket path in the sidecar>"
      AUTONOMOUS_CONTAINER_ENGINE_REQUESTED: "1"
  console: *agent
  release: *agent
volumes:
  autonomous-engine:
    labels:
      dev.autonomous.kind: engine-storage
      dev.autonomous.segment: "${AUTONOMOUS_INSTANCE_SEGMENT}"
```

The sketch above is illustrative. The binding rules are:
1. **Only `engine` is elevated.** No agent service gets `privileged`, `cap_add`,
   `devices` or `security_opt`, and no volume entry contains `docker.sock` (guard
   test).
2. **The endpoint is never published.** `2375` never appears under `ports`.
3. **Same-path mounts.** The repo and the state root are mounted at identical
   paths, and nothing else from the host is (R5).
4. **Agent services lose their network keys.** They carry no `hostname`, `ports`
   or `extra_hosts` after merge, because `network_mode: service:` forbids them.
5. **The storage volume is project-scoped.** It has no `name:` and is labelled
   with kind and segment.

## `compose.engine-viewer.yaml` (new)

The wrapper adds it only when both `--docker` and `--viewer` are given, in place of
`compose.desktop-viewer.yaml`. It puts `127.0.0.1:${AUTONOMOUS_VIEWER_PORT:-}:6080`
on `engine`, and `AUTONOMOUS_DISPLAY` and `AUTONOMOUS_DISPLAY_VIEWER` on the agent
services.
