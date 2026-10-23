# Contract: `scripts/autonomous` changes

This extends `specs/031-containerized-runtime/contracts/wrapper-cli.md` and
`specs/041-user-defined-volumes/contracts/wrapper-cli.md`. Without `--docker`
(and without a detected sidecar on `stop`), every command's docker calls and
output are unchanged.

## Options

| Option | Commands | Effect |
|---|---|---|
| `--docker` | `build` | `WITH_DOCKER=1`; also builds the `engine` service image (`autonomous-engine:local`) |
| `--docker` | `shell`, `console`, `release` | Adds `compose.engine.yaml` (plus `compose.engine-viewer.yaml` instead of `compose.desktop-viewer.yaml` when `--viewer` is given) |
| `--engine` | `reset-cache` | Removes the target's engine-storage volume only |

`--docker` on any other command is an unknown option (exit 2). `--engine`
anywhere but `reset-cache` is likewise exit 2.

## Exit codes (new)

| Code | Meaning | Message names |
|---|---|---|
| 77 | The sidecar could not start | The cause (the host runtime refused a privileged container, or the first relevant log line) and the remedy (Docker Engine on Linux or Docker Desktop, with privileged containers allowed) |
| 78 | The engine was not ready within `AUTONOMOUS_ENGINE_TIMEOUT` (default 60 s), at the wrapper or at the entrypoint probe | The bound, the last engine log lines, and the remedy (`reset-cache --engine`, check host disk, raise the bound) |

Existing codes are reused for preconditions:
- **5** — the image was built without `--docker` (the client is missing), or
  `autonomous-engine:local` is not built.
- **3** — Compose is older than 2.24.4.

## Start sequence with `--docker` (`console` / `release`)

1. Resolve the target, require the image, and look up the identity using the
   **overlay-free** file list (unchanged).
2. **Preconditions** (before any container or volume exists): Compose ≥ 2.24.4;
   `autonomous-engine:local` present; `docker run --rm --entrypoint sh <image> -c
   'command -v docker && docker compose version && docker buildx version'`
   succeeds.
3. Validate the declared volumes, check the live instance (75), choose the port,
   and apply volumes, all as today. Then append `compose.engine.yaml`.
4. Run `docker compose -p <project> <files> up -d --no-build --pull never --wait
   --wait-timeout <bound> engine`.
   - On failure: classify it (77 or 78; research R6), run `docker compose -p
     <project> <files> rm -sf engine` (the storage volume is kept), and exit.
5. Run `up -d … <service>` as today.
6. `wait_for_console`. If the agent container exits (for example, the entrypoint
   probe returns 78), run `docker compose -p <project> <files> down`, without
   `-v`, then exit with the container's code. Today's 75 handling is unchanged.

## `shell --docker`

Steps 1–4 are as above. Then `docker compose … run --rm <tty> dev shell` runs
**without `exec`**. On every exit path (an `EXIT` trap) the wrapper runs `rm -sf
engine`, and it exits with the `run` status.

## `stop`

The wrapper looks for a container labelled
`com.docker.compose.project=<project>` and `com.docker.compose.service=engine`,
running or exited.
- **Found:** it adds `compose.engine.yaml` to the file list for `down`.
- **Not found:** `stop` is byte-identical.

With `--purge`, after `down -v`, the wrapper also removes every volume labelled
`dev.autonomous.kind=engine-storage` and `dev.autonomous.segment=<segment>`, and
prints `<name> removed` for each.

## `reset-cache --engine`

1. Refuse with 75 while any project container exists. This check is the same as
   today's.
2. Find the engine-storage volume by label kind and segment. None: print `engine
   storage not present` and exit 0.
3. Remove it and print `engine storage removed`. A removal failure exits 1.
4. Declared volumes are not touched unless `--volume` is also given. Both may be
   combined.

## `port` / `viewer`

These commands no longer use the first container of the project. They iterate
over the project's running containers and print the first published mapping for
`4000/tcp` (or `6080/tcp`). With a single container, which is the case without
the engine, the output is unchanged.
