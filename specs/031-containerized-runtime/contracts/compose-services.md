# Contract: Compose services and mounts

`compose.yaml` defines three services from one `Dockerfile`. Every service sets
`hostname: autonomous`, `user: ${UID}:${GID}`, `env_file: .env` (optional),
`shm_size: 1gb`, `init: true`, and `entrypoint: scripts/container-entrypoint.sh`.
No service is `privileged`, adds capabilities, or uses host networking.

**Image names are explicit and project-independent.** `dev` and `console` set
`image: autonomous-dev:local`; `release` sets `image: autonomous-release:local`. The
wrapper starts each target under its own Compose project (`-p autonomous-<segment>`),
and without an explicit `image:` Compose would tag the build `<project>-<service>`, so
`scripts/autonomous build` (any project) and a later instance start (another project)
would use different images. With fixed names, one `build` serves every target, and
"recreated from a rebuilt image" (SC-005) really runs the new image. Instance
commands pass `--pull never` / no `--build`, so starting an instance never rebuilds
silently.

**Build-artefact volumes are per project.** `autonomous-build` and `autonomous-deps`
are declared without `name:`, so Compose scopes them to the project
(`autonomous-<segment>_autonomous-build`). Each target therefore compiles once into its
own volume; two concurrent dev instances never write the same `_build`. The cost is one
`deps.get` + compile per target on first start; `scripts/autonomous stop --target …`
keeps the volumes, `stop --purge` removes them.

| Service | Image target | Command | Ports |
|---|---|---|---|
| `dev` | `dev` | `shell` (iex + endpoint) or `test …` | `127.0.0.1:${AUTONOMOUS_HOST_PORT:-}:4000` |
| `console` | `dev` | `console` (`mix phx.server`) | same |
| `release` | `release` | `release` (`bin/autonomous start`) | same |

## Mounts

| Source (host) | Target (container) | Mode | Services |
|---|---|---|---|
| `${AUTONOMOUS_REPO}` | `${AUTONOMOUS_REPO}` (same path) | rw | all |
| `${AUTONOMOUS_ROOT}` (`~/.autonomous`) | `${AUTONOMOUS_ROOT}` (same path) | rw | all |
| repository checkout | `/workspace` | rw | `dev`, `console` |
| volume `autonomous-build` | `/workspace/_build` | rw | `dev`, `console` |
| volume `autonomous-deps` | `/workspace/deps` | rw | `dev`, `console` |
| `~/.claude`, `~/.claude.json` | `/home/autonomous/.claude*` | rw | opt-in `compose.claude-login.yaml` |

Nothing else from the host is mounted writable (FR-007). Image filesystem outside
`/home/autonomous`, `/tmp` and the mounts is owned by root.

## Override files

| File | Adds |
|---|---|
| `compose.claude-login.yaml` | login mounts above |
| `compose.android.yaml` | `devices: ["/dev/kvm"]`, `group_add: [kvm gid]`, `extra_hosts: ["host.docker.internal:host-gateway"]` |
| `compose.desktop-viewer.yaml` | `127.0.0.1:${AUTONOMOUS_VIEWER_PORT:-}:6080`, `AUTONOMOUS_DISPLAY_VIEWER=1` |

## Entrypoint (`scripts/container-entrypoint.sh`) sequence

0. Dev shape only (`shell`, `console`, `test`, `segment`): prepare the build. When
   `deps/` has no `.mix_deps` marker for the current `mix.lock` hash, run
   `mise exec -- mix deps.get`; then `mise exec -- mix compile` (no-op when up to
   date). `MIX_ENV=test` for `test`, `dev` otherwise. This step needs network (Hex,
   GitHub for the pinned `jido_*` SHAs); it runs in the entrypoint, before any
   orchestrated session exists, so the `strict` hook is not involved. Failure exits
   non-zero with Mix's message; nothing below runs.
1. Derive identity (`mix autonomous.instance --format env` or release `eval`); export.
2. `mkdir -p` instance dir; `exec 9>"$AUTONOMOUS_INSTANCE_LOCK"`; `flock -n 9` or
   read `instance.json` and exit 75. (Skipped for `test`.)
3. Write `instance.json`; create `cookie` (0600) if absent.
4. `git config --global` `url.https://github.com/.pushInsteadOf git@github.com:`;
   `gh auth setup-git` when `GH_TOKEN` is set.
5. Warnings: no agent credentials; model pins unset; budget is per instance.
6. When `AUTONOMOUS_DISPLAY=1`: start `Xvfb :99`, export `DISPLAY=:99`; when
   `AUTONOMOUS_DISPLAY_VIEWER=1`: start x11vnc + websockify/noVNC on 6080.
7. `export AUTONOMOUS_INSTANCE_LOCKED="$AUTONOMOUS_INSTANCE_LOCK"`; `exec` the
   command (fd 9 inherited):
   - `shell`: `mise exec -- iex --sname "$name" --cookie "$(cat cookie)" -S mix`
   - `console`: `mise exec -- elixir --sname … --cookie … -S mix phx.server`
   - `release`: `exec bin/autonomous start`
   - `test …`: `mise exec -- mix test …`
   - `segment`: after step 0, print `mix autonomous.instance --repo "$AUTONOMOUS_REPO"
     --format segment` and exit (no lock, no `instance.json`, no VM). Used only by the
     wrapper to name the Compose project; see [wrapper-cli.md](wrapper-cli.md).
