# Contract: entrypoint `container_engine` step

`scripts/container-entrypoint.sh`. The step runs as step **4e**, immediately
after `agent_root` (4d) and before the warnings (5). It runs in every shape that
reaches step 4: `shell`, `console` and `release`.

```text
container_engine():
  unset AUTONOMOUS_CONTAINER_ENGINE AUTONOMOUS_CONTAINER_ENGINE_VERSION
  [ "${AUTONOMOUS_CONTAINER_ENGINE_REQUESTED:-}" = 1 ] || return 0      # silent no-op
  command -v docker || die(78) "the engine was requested but this image has no docker client (build with --docker)"
  poll `docker version --format '{{.Server.Version}}'` until it succeeds or ${AUTONOMOUS_ENGINE_TIMEOUT:-60}s pass
     timeout → say last error; exit 78
  sweep: rm -f -v all containers; network prune -f; volume prune -af       # instance-start sweep (R7)
     sweep failure → warn naming the residue (does not refuse: the engine answered)
  export AUTONOMOUS_CONTAINER_ENGINE=1 AUTONOMOUS_CONTAINER_ENGINE_VERSION=<v>
  say "container engine: available (engine <v> at $DOCKER_HOST)"
```

Rules:
- **Never honour an inherited advertisement.** A value from `.env` or compose for
  `AUTONOMOUS_CONTAINER_ENGINE` is always cleared first.
- **Silent when not requested.** No output, no `docker` invocation. This is the
  byte-identical path.
- **stdout stays clean.** All output goes to stderr (`say`/`warn`), as in the
  other steps.

## Smoke hook

`container-entrypoint.sh container-engine` runs only this step, before any
build or identity work, as the `agent-root` hook does. It then prints exactly one
line:

```text
AUTONOMOUS_CONTAINER_ENGINE=<1|0> VERSION=<v or empty>
```

It exits 0 when not requested or when advertised, and 78 on a probe timeout or a
missing client. The hermetic `container_engine_step_test` drives it with a stub
`docker` on a private `PATH`.
