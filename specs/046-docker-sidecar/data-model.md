# Data Model: Container Engine Sidecar for Agent Sessions

No persisted run record or store schema changes (FR-017). The entities below are
runtime ones: container resources, environment markers and in-memory values.

## Engine sidecar (container)

| Attribute | Value |
|---|---|
| Compose service | `engine` (in `compose.engine.yaml`), in project `autonomous-<segment>` |
| Image | `autonomous-engine:local`, built from the `engine` Dockerfile stage (`FROM docker:${DOCKER_VERSION}-dind-rootless`, plus the operator's `UID`/`GID` and `/etc/subuid` and `/etc/subgid` ranges) |
| Privilege | `privileged: true`. This is the **only** elevated container. The daemon runs rootless as `UID` (research R1) |
| Network | Owns the instance's network namespace. `hostname: autonomous`. Publishes `127.0.0.1:${AUTONOMOUS_HOST_PORT}:4000`, and `6080` only with the viewer overlay. Extra host `host.docker.internal:host-gateway`. Sysctl `net.ipv4.ip_unprivileged_port_start=0` |
| Endpoint | `tcp://127.0.0.1:2375`, no TLS, never published. Also the rootless unix socket, inside the sidecar only |
| Mounts | `${AUTONOMOUS_REPO}` and `${AUTONOMOUS_ROOT}` at the same paths. Engine storage at the data root. No `/workspace`, no `$HOME`, no host socket |
| Health | `docker -H tcp://127.0.0.1:2375 info`, interval 1 s. The wrapper's `--wait-timeout` is the bound |
| Lifecycle | Started first by the wrapper and removed on refusal. Stopped by `stop`. Removed after a `shell` session ends |

## Agent container, with the engine on

The same `dev`, `console` or `release` service, with:

| Attribute | Change |
|---|---|
| `network_mode` | `service:engine` |
| `hostname`, `ports`, `extra_hosts` | `!reset` (moved to the sidecar) |
| `depends_on` | `engine: {condition: service_healthy}` |
| `environment` | `DOCKER_HOST=tcp://127.0.0.1:2375`, `TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=<rootless socket path in the sidecar>`, `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1` |
| `privileged`, `cap_add`, `devices`, `security_opt`, socket mounts | **unchanged** (none). The guard test checks this (FR-004) |

## Engine storage (Docker named volume)

| Attribute | Value |
|---|---|
| Name | `autonomous-<segment>_autonomous-engine` (project-scoped, declared without `name:`) |
| Labels | `dev.autonomous.kind=engine-storage`, `dev.autonomous.segment=<segment>` |
| Content | Images and build cache. Containers, networks and volumes are swept at instance start and at every phase end, so in practice only images and cache persist |
| Removed by | `stop --purge` and `reset-cache --engine` (both by label and segment). Never by plain `stop` |
| Isolation | One per target segment. Never mounted by another project |

## Environment contract

| Variable | Set by | Meaning |
|---|---|---|
| `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED` | overlay | `1` = the instance was started with `--docker`. Drives the visibility of the Configuration row |
| `DOCKER_HOST`, `TESTCONTAINERS_*` | overlay | Standard client environment. Sessions inherit it (FR-003) |
| `AUTONOMOUS_CONTAINER_ENGINE` | entrypoint `container_engine` step | Always unset first. Exported as `1` **only** after a positive probe and sweep: the advertisement |
| `AUTONOMOUS_CONTAINER_ENGINE_VERSION` | entrypoint | The server version from the probe, informational |

Without `--docker`, none of these exist (User Story 1.5).

## Engine advertisement (Elixir)

`ContainerEngine.advertised?(env)` is true iff `AUTONOMOUS_CONTAINER=1` and
`AUTONOMOUS_CONTAINER_ENGINE=1`. `ContainerEngine.requested?(env)` is true iff
`AUTONOMOUS_CONTAINER=1` and `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`.

These are the only env reads. `FeatureRunner` resolves the advertisement once per
feature run, and the `:engine` option overrides it for tests.

## Cleanup result (Elixir value)

```text
cleanup_result ::
    :skipped                                  # not advertised: zero commands
  | :clean                                    # verification listings all empty
  | {:residue, residue, cause}

residue :: %{containers: non_neg_integer, networks: non_neg_integer, volumes: non_neg_integer}
cause   :: {:exit, step, status, excerpt} | :timeout | {:crash, term}
step    :: :list | :rm | :network_prune | :volume_prune | :verify
```

A residue count is `-1` when the verification listing itself could not run
(unknown). It renders as "unknown".

**Transitions, per phase boundary**:

```text
phase step returns (any outcome) or raises
  └─ advertised? ──no──▶ :skipped (nothing logged)
        └─yes─▶ rm containers → prune networks → prune volumes → verify
                  ├─ all empty ──────────────▶ :clean        (debug log, telemetry)
                  └─ non-empty / error / timeout ▶ {:residue,…} (error log naming feature, phase, residue; telemetry)
outcome of the phase: unchanged in every branch
```

## Configuration row state (`Web.ContainerEngineView`)

```text
state :: :hidden | :checking | {:available, version :: String.t()} | {:unreachable, cause :: String.t()}
```

| Condition | State | Rendered value |
|---|---|---|
| not `requested?` | `:hidden` | No `<dt>`/`<dd>` (page byte-identical) |
| requested, probe pending | `:checking` | `checking…` |
| requested, probe ok | `{:available, v}` | `available — engine <v>` |
| requested, probe failed or crashed | `{:unreachable, cause}` | `unreachable — <cause>` |

The probe is `ContainerEngine.probe/1`: `docker version --format
'{{.Server.Version}}'`, bounded to 5 s, run in `start_async`. It runs on every
mount and refresh. A value cached at instance start is never shown (User Story 4.2).
