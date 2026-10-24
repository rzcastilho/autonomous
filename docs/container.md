# Containerized runtime

Feature 031. A Docker container is the only supported way to *operate* the
orchestrator; `mix compile` and `mix test` still run on the host. Entry point:
`scripts/autonomous` (contract: `specs/031-containerized-runtime/contracts/wrapper-cli.md`).
Day-to-day flow is in [runbook.md](runbook.md); this page holds the details behind it.

## State, identity and the same-path rule

- **One instance per target.** Node name, store directory, lock and cookie are derived
  from the target's `RepoIdentity` in `Autonomous.Instance` (never in shell) and live under
  `~/.autonomous/instances/<segment>/`. Same target ⇒ same identity across stop, remove,
  recreate and image rebuild.
- **Same-path mounts.** The target repository and `~/.autonomous` are mounted at the *same
  absolute path* inside and outside the container. `git worktree` records absolute paths;
  with the same path on both sides, `git -C <target> worktree list` is valid from the host
  and from the container. Do not move the target or the state root while an instance holds
  worktrees.
- **Fixed host name.** Every service sets `hostname: autonomous`, the host part of the
  Erlang node name. `Instance.verify!/0` refuses an ad hoc `--sname` (or a VM that is not
  distributed) before Mnesia opens.
- **Second instance refused.** The entrypoint takes `flock -n` on `instance.lock`; the VM
  inherits the descriptor, so the kernel holds the lock exactly as long as the VM lives (a
  crash or `docker rm -f` releases it). A second instance for the same target exits **75**
  naming the live one (`<project>/<service> since <started_at>`, read from `instance.json`).
  `instance.json` is informational; the kernel lock is authoritative.
- **`flock` limit.** `flock` is only reliable on a local filesystem. Keep `~/.autonomous` on
  a local disk; on NFS/SMB/FUSE mounts the lock may not exclude a second instance.
  Local-disk Docker bind mounts (the default) are fine.

### Fresh store (FR-020)

The per-target store is new: `~/.autonomous/instances/<segment>/mnesia`. The pre-031 host
store `~/.autonomous/mnesia` is **neither read nor deleted**. History written before 031 is
not visible to the containerized instance; delete the old directory yourself when you no
longer need it. Worktrees (`worktrees/<segment>/`), transcripts and exports keep their
locations and stay valid. Full agent conversations (feature 040) live under
`<transcript_root>/conversations/…` (owner-only), so they survive a container
rebuild and can be read from Transcripts afterwards.

### Working-directory audit (R6)

The legacy default `Config.worktree_root/0` (`../.speckit-worktrees`, relative to the
working directory) is reachable only through `Worktree.create/2` without a layout
(test/legacy path). Every live caller in `lib/autonomous.ex` passes the run's `%Layout{}`,
whose `worktree_root` and `transcript_root` are absolute paths under the state root. No live
write path depends on the container's `cwd` (`/workspace`).

## Agent login (`--with-login`)

`--with-login` mounts the host `~/.claude` directory read-write (the CLI
refreshes its own login) and the host `~/.claude.json` **read-only at a seed
path**, `/home/autonomous/.claude.host.json` (feature 034). At start the
entrypoint validates the seed as a JSON object (up to 5 tries, 200 ms apart, to
ride out a host CLI mid-write) and copies it atomically into a container-private
`~/.claude.json` (mode 600). Sessions read only that copy, so a host process
writing its own config can never tear what a session reads, and container writes
never reach the host.

- Login or project-trust changes made on the host **after** the container
  started are not seen; restart the container to re-seed.
- A seed that is still not valid JSON after the retries stops the start with
  `host CLI config <seed path> is not valid JSON: <parser message>` (non-zero exit).
- If `~/.claude.json` is itself a mount (an old compose override), the start
  fails naming the stale mount; remove it and use `--with-login`.
- Token-only runs (`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`) are unchanged.

## Workspace trust (036)

The `claude` CLI ignores a repo's committed `permissions.allow` /
`permissions.additionalDirectories` until the workspace is *trusted*
(`projects["<path>"].hasTrustDialogAccepted` in `~/.claude.json`). A fresh container has
no such record, so the target pack (supplied into each worktree, or committed) was silently dropped. The entrypoint now runs
a `trust_workspaces` step (also `container-entrypoint.sh trust-config`) after config
seeding that merges **exactly two** records into the container-private `~/.claude.json`:

- `$AUTONOMOUS_REPO` (realpath) — load-bearing: a worktree's project key resolves to the
  main repo, so this one record covers every `feature/NNN-slug` worktree.
- `$AUTONOMOUS_WORKTREE_ROOT` (realpath; the sixth identity variable, derived by
  `Layout.worktree_root/2`) — bounded and forward-compatible.

The step is atomic (`O_EXCL` temp file, `fsync`, `rename`, mode `0600`), idempotent (no
write when both records exist), preserves every other key, refuses a config that is not a
JSON object (startup stops, file untouched), and never touches the host's
`~/.claude.json`. Login-seeded trust records are carried over untouched. No ancestor
directory, `$HOME` or `/workspace` is ever trusted.

Backstop: a session that still reports an untrusted workspace (the CLI's stderr line,
parsed by `WorkspaceTrust`) logs a warning and the phase continues — on host and
container alike. Since 039 this is warn-only for every run; the
`{:untrusted_workspace, phase, obs}` failure gate and the `us-trust-hook` smoke check
(which exercised the hook removed in 039) are gone. Check the trust step itself with
`scripts/container-smoke.sh trust`.

## System packages (037)

A target whose build or tests need operating-system packages (headers,
`pkg-config`, native libraries — the mod-player incident was `libasound2-dev`) gets
them in one of two ways. Both are opt-in; a build with neither option is
byte-identical to before.

**Declare them at build time (`--apt`).**

```bash
scripts/autonomous build --apt "libasound2-dev pkg-config"
scripts/autonomous build --release --apt libasound2-dev --apt pkg-config
```

- The option is repeatable; names are separated by whitespace or commas. Each name must
  look like a Debian package (`name`, optional `:arch`, optional `=version`) or the
  wrapper exits 2 (`autonomous: invalid package name '<token>'`) before any `docker` call.
- The packages land in the shared `base` stage, so the dev and the release image both
  carry them. The list is written one name per line to `/etc/autonomous/apt-packages`
  (only when non-empty).
- An unknown package fails the build and apt names it (`E: Unable to locate package …`).
- The list is fixed per image: **rebuilding without `--apt` drops it.** Restart the
  instance afterwards.

**Let the agent install (`--agent-root`).**

```bash
scripts/autonomous build --agent-root
```

- Builds `sudo` with a passwordless grant for any uid (the container runs as your host
  uid) plus `APT::Get::Remove "false"`, so apt refuses any install that would remove a
  package. Without the option there is no `sudo` in the image.
- At start the entrypoint runs `sudo -n true`; only on success does it export
  `AUTONOMOUS_AGENT_ROOT=1` (a value from `.env` is never trusted) and print
  `agent root: available`. If the probe fails — e.g. the runtime sets
  `no-new-privileges` or the uid has no passwd entry — it warns with the uid and the
  capability is **not** advertised.
- When advertised, implement/converge sessions are told they may run
  `sudo apt-get update && sudo apt-get install -y --no-install-recommends <pkgs>`, and
  never to remove, purge or upgrade. That is guidance in the prompt, not an enforced
  grammar (the hook that enforced one was removed in 039); the container is the
  boundary — see `docs/enforcement.md`.
- The Configuration page shows an "agent root" row only when it is advertised.
- Installs last only for this container. Every allowed install is logged as
  `agent root: feature <n> (<phase>) installed system packages: <pkgs> — add them to
  scripts/autonomous build --apt to persist`; promote those packages to `--apt`.

Check an image with `scripts/container-smoke.sh sysdeps` (`SMOKE_IMAGE=autonomous-release:local`
for the release image; `SMOKE_SYSDEPS_PROBE` overrides the probe package, default `pkg-config`).

## User-defined volumes (041)

A target can keep toolchains, package caches and build output across stop/start and image
rebuilds in operator-declared **Docker named volumes**. Nothing is declared by default; with
no declaration the start path is byte-identical to before (no docker call, no output, no
overlay).

- **Where.** `${XDG_CONFIG_HOME:-$HOME/.config}/autonomous/targets/<segment>/volumes.toml` —
  host-only, one per target. Sessions never see the file, and it is refused when its parent
  resolves inside the state root, the target repo or the orchestrator source tree.
  `scripts/autonomous volumes --target <repo> --init` writes a commented starter (`0600`,
  directory `0700`, never overwrites); without `--init` it prints the path, entries,
  present/absent per volume, `kept, not declared` leftovers and the validation result.
- **Format.** Any number of `[[volume]]` entries (order matters): `name` (lowercase slug,
  unique), `path` (absolute container path; recommended parent
  `/var/lib/autonomous/volumes/<name>`), optional `env` (literal strings, no `$VAR`
  expansion) and `path_dirs` (directories inside the entry's own `path`). Needs host
  `python3 >= 3.11` (`tomllib`) once a declaration exists.
- **Validation.** Every violation is reported (entry + reason) before any container, volume or
  overlay exists; exit 2. Refused: duplicate or non-slug names; relative, non-normalized or
  `:`/`,`/control-character paths; a path equal to, inside or enclosing the target repo, the
  worktree root, the state root, `/workspace` (incl. `_build`, `deps`), `/app`, the agent
  config (`/home/autonomous/.claude`, `.claude.json`) or `/`, `/home`, `/home/autonomous`;
  two entries equal or nested; a variable set by two entries.
- **Reserved variables.** `AUTONOMOUS_*`, `RELEASE_*`, `PATH`, `HOME`, `SHELL`, `USER`,
  `MIX_ENV`, `PHX_SERVER`, `COMPOSE_PROJECT_NAME`, `DISPLAY`, `GH_TOKEN`, `ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
  `CLAUDE_CONFIG_DIR`, `MISE_TRUSTED_CONFIG_PATHS`, `MISE_YES`. A suite test fails when the
  entrypoint or `compose.yaml` starts setting a variable that is in neither this list nor the
  overridable set (`MISE_DATA_DIR`, `MIX_HOME`, `HEX_HOME`, `PLAYWRIGHT_BROWSERS_PATH`, …).
- **`PATH`.** `path_dirs` are prepended (entry order, then listed order) to the image `PATH`
  for the container, every session and the operator shell (the dev-shape entrypoint
  re-prepends them inside `mise exec`).
- **Overriding an image variable** (e.g. `MISE_DATA_DIR`) is allowed and prints a notice at
  start. Consequence: the volume starts empty, so the first dev-shape start reinstalls the
  orchestrator's own Erlang/Elixir into it (long, once); the release shape has no mise.
- **Mechanics.** Each start: `docker volume create` with labels `dev.autonomous.kind=user-volume`,
  `dev.autonomous.segment`, `dev.autonomous.volume`; one provisioning container
  (`--user 0:0`, non-recursive `chown` of mount roots) so the container user can write; a
  regenerated `applied.compose.json` overlay (`0600`) appended with `-f`. The applied set is
  exported as `AUTONOMOUS_VOLUMES` (JSON, `version: 1`) and shown in Configuration.
- **Worktrees are unchanged** (FR-025a): they stay host directories under the state root.
  Declare volumes only for data that should live *outside* the worktree.
- **Isolation.** Volume names are `autonomous-<segment>_vol-<name>`: two targets using the same
  `name` never share data.
- **Reset.** `scripts/autonomous reset-cache --target <repo> [--volume <name>]...` (all when no
  `--volume`) removes declared volumes of a **stopped** instance (exit 75 while any container of
  the project exists); idempotent (`not present`); a volume lacking our labels is never
  removed (exit 1). `stop --purge` additionally removes every `user-volume` of the segment.
- **No longer declared.** Removing an entry does not delete its volume: `volumes` lists it as
  `kept, not declared — remove with: docker volume rm <name>`.
- **Security.** Volumes are container-engine storage with no host path; the declaration's
  contents never reach a container or log beyond the applied set.

Worked examples (more in `specs/041-user-defined-volumes/quickstart.md`):

```toml
# Rust — toolchains + build output
[[volume]]
name = "rust-toolchains"
path = "/var/lib/autonomous/volumes/rust-toolchains"
path_dirs = ["/var/lib/autonomous/volumes/rust-toolchains/cargo/bin"]
[volume.env]
RUSTUP_HOME = "/var/lib/autonomous/volumes/rust-toolchains/rustup"
CARGO_HOME  = "/var/lib/autonomous/volumes/rust-toolchains/cargo"

[[volume]]
name = "cargo-target"
path = "/var/lib/autonomous/volumes/cargo-target"
env = { CARGO_TARGET_DIR = "/var/lib/autonomous/volumes/cargo-target" }
```

```toml
# Node + pnpm — package store (adding MISE_DATA_DIR keeps mise-managed node; see override note)
[[volume]]
name = "pnpm-store"
path = "/var/lib/autonomous/volumes/pnpm-store"
env = { npm_config_store_dir = "/var/lib/autonomous/volumes/pnpm-store" }
```

```toml
# Elixir — Mix/Hex caches, deps and build output
[[volume]]
name = "mix-hex"
path = "/var/lib/autonomous/volumes/mix-hex"
[volume.env]
MIX_HOME = "/var/lib/autonomous/volumes/mix-hex/mix"
HEX_HOME = "/var/lib/autonomous/volumes/mix-hex/hex"

[[volume]]
name = "mix-build"
path = "/var/lib/autonomous/volumes/mix-build"
[volume.env]
MIX_DEPS_PATH  = "/var/lib/autonomous/volumes/mix-build/deps"
MIX_BUILD_ROOT = "/var/lib/autonomous/volumes/mix-build/_build"
```

```toml
# Python — venv + pip cache
[[volume]]
name = "python"
path = "/var/lib/autonomous/volumes/python"
path_dirs = ["/var/lib/autonomous/volumes/python/venv/bin"]
[volume.env]
VIRTUAL_ENV = "/var/lib/autonomous/volumes/python/venv"
PIP_CACHE_DIR = "/var/lib/autonomous/volumes/python/pip-cache"
```

## Release shape

`scripts/autonomous build --release` builds `autonomous-release:local`: a `mix release` on
the base image (git, `gh`, the agent CLI) with no mise, no Erlang/Elixir install and no
sources at runtime.

```bash
scripts/autonomous release --target ../ledgerlite    # detached
scripts/autonomous remote  --target ../ledgerlite    # remote console (iex) into it
scripts/autonomous port    --target ../ledgerlite    # console address
```

- **Secret.** The release refuses to start without `AUTONOMOUS_SECRET_KEY_BASE` (≥ 64
  bytes), naming the variable. Generate one and put it in `.env` (git-ignored):
  `openssl rand -base64 48` yields 64 characters.
- **Cookie.** Generated once per instance by the entrypoint (`0600`, under the instance
  directory); never baked into an image.
- **Persistence.** The store is under the state root, so `docker compose restart release`
  keeps history with no node mismatch.

## Console

`scripts/autonomous console --target <repo> [--port <n>]` starts a detached
`mix phx.server` (the `console` service) and returns once the console answers; the start
lines name the loopback address. The entrypoint spells `phx.server` out as
`serve_endpoints` + `mix run --no-halt`, so an agent session's `pkill -f phx.server`
(aimed at the target's own server) cannot match the orchestrator's VM. `scripts/autonomous port --target <repo>` prints the
address of any running instance (shell, console or release).

- The image binds `0.0.0.0` *inside* the container; Compose publishes it as
  `127.0.0.1:<port>:4000`, so only the operator's machine reaches it (FR-021). From another
  machine on the LAN the connection is refused; tunnel with `ssh -L` to watch remotely.
- No `--port`: the wrapper picks a free loopback port and prints it. A busy `--port` exits
  76 naming it.
- `AUTONOMOUS_CONSOLE_HOST` (default `localhost`) feeds the endpoint URL; origin checks
  accept `//localhost` and `//127.0.0.1` on any port because the host port is chosen at
  start.

## Container engine sidecar (046)

Opt-in. For targets whose build or tests start containers (compose files,
test-containers libraries). Without `--docker` nothing here applies and every docker call
the wrapper makes is unchanged.

```bash
scripts/autonomous build --docker [--release]            # client in the image + autonomous-engine:local
scripts/autonomous console --target <repo> --docker      # also: shell, release
scripts/autonomous stop --target <repo> [--purge]
scripts/autonomous reset-cache --target <repo> --engine  # removes only the engine storage volume
```

**Architecture.** A `privileged` sidecar (`engine` service, `compose.engine.yaml`) runs a
**rootless** engine as the operator's uid on `tcp://127.0.0.1:2375`. The agent container
joins the sidecar's network namespace (`network_mode: service:engine`), so `DOCKER_HOST`
and published ports are plain loopback. The agent container gains no privilege,
capability, device or socket mount; the host's `docker.sock` is never mounted (a guard
test fails if it appears). A privileged container started by a session is privileged only
inside the rootless engine, so it cannot reach the host. Port `2375` is not published;
only the console port is.

**Same-path mount.** The sidecar mounts the repo and the state root at the same paths as
the agent, so `-v <worktree>:<worktree>` from a session resolves. Bind mounts outside
those trees are not visible to the engine: stage files under the worktree.

**Rootless limits.** Files written by containers as non-root users appear owned by
subordinate ids, not the operator's. overlay2 needs a kernel ≥ 5.11; cgroup resource
limits may be unavailable. Compose ≥ 2.24.4 is required on the host.

**Reserved.** The sidecar owns the hostname, the console port and the extra host; the
agent services have those keys reset.

**Storage and cleanup.** Pulled images persist in a labelled volume
(`dev.autonomous.kind=engine-storage`) across `stop`; `stop --purge` also removes it and
`reset-cache --engine` clears it alone (exit 75 while any project container exists).
The orchestrator removes all containers, networks and volumes (never images or build
cache) at every phase boundary; a failure logs loudly and never changes an outcome.

**Exit codes.** `77` — the sidecar could not start (host refused a privileged container;
use Docker Engine on Linux or Docker Desktop with privileged containers allowed). `78` —
the engine was not ready within `AUTONOMOUS_ENGINE_TIMEOUT` (seconds, default 60), at the
wrapper or at the entrypoint probe. Both remove what the wrapper created. `5` — image
built without `--docker`, or `autonomous-engine:local` missing; `3` — Compose too old.

**Smoke.** `scripts/container-smoke.sh engine` (dev image) and
`SMOKE_IMAGE=autonomous-release:local scripts/container-smoke.sh engine` (release).
See `specs/046-docker-sidecar/quickstart.md`.

## Stopping cleanly

Leave `iex` with `System.stop()` (or `:init.stop()`). A hard halt (`System.halt/1`,
Ctrl+C twice) right after a write can lose the tail of the Mnesia log: in the smoke check a
run was written and the VM halted immediately, and the recreated container listed no runs;
the same write followed by `:init.stop()` survived. A container restart (`docker compose restart release`, SIGTERM) kept history in
the release smoke check.

## Testing capabilities (opt-in)

Orchestrated sessions can test web, desktop and Android applications **inside the
container**. Each capability is a build option; with none set the image carries none of
them (FR-023) and the default build is unchanged.

| Capability | Build option | Adds | Start option |
|---|---|---|---|
| Web | `--web` | Playwright (`PLAYWRIGHT_VERSION`) with Chromium, Firefox and WebKit in `/opt/ms-playwright` | — |
| Desktop | `--desktop` | Xvfb, `xdotool`, ImageMagick (`import`), `x11vnc` + noVNC, fonts, Electron libraries | `--viewer` |
| Android | `--android` | JDK 17, Android cmdline-tools, `platform-tools`, `emulator`, one pinned system image and an AVD | `--android` |

```bash
scripts/autonomous build --release --web --desktop --android   # any subset
scripts/autonomous console --target <repo> --viewer            # desktop viewer on loopback
scripts/autonomous viewer  --target <repo>                     # prints http://127.0.0.1:<port>/vnc.html
```

Set `AUTONOMOUS_DISPLAY=1` in `.env` to have the entrypoint start Xvfb on `:99` (and export
`DISPLAY=:99`) without the viewer. `--viewer` implies it and publishes noVNC on
`127.0.0.1` only (`AUTONOMOUS_VIEWER_PORT` picks the port; empty = Docker picks one).

All three run from an ordinary orchestrated session; nothing extra is needed.

### Web

- **Match the Playwright version.** The target's `@playwright/test` (or `playwright`) must be
  the version the image carries, or it looks for a browser build that is not there. Build with
  `PLAYWRIGHT_VERSION=<x.y.z> scripts/autonomous build --web`, or pin the target to the
  image's version (default `1.49.1`). `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` is set,
  so a mismatch fails fast instead of downloading.
- **Chromium sandbox.** The container has no extra privileges, so Chromium cannot create its
  own sandbox. Launch with `chromiumSandbox: false` (Playwright option) rather than adding
  `--privileged` or `SYS_ADMIN`. Firefox and WebKit need nothing.
- `shm_size: 1gb` is already set in `compose.yaml`; browsers crash with the 64 MB default.

### Desktop

Run a program under the display, click and capture: `xdotool mousemove 10 10 click 1`,
`import -window root shot.png`. The screen size is `AUTONOMOUS_DISPLAY_SIZE`
(default `1280x800x24`). The viewer is for a human watching; it needs no password because it
is reachable only from the operator's machine.

### Pre-fetching dependencies (FR-027a)

An orchestrated session may run package-manager downloads (`npm install`, `pip install`,
`mix deps.get`, Gradle), but the build should not depend on them mid-run. Fetch before the
run, outside the orchestrated session: run `npm ci`, `mix deps.get` or
`./gradlew --refresh-dependencies` in the target (or in `scripts/autonomous shell`) so the
tests then work from the local cache.

### Not supported

iOS, macOS and Windows applications cannot run in a Linux container. Use an external runner
(a macOS/Windows CI machine or device farm) and have the session call it; this feature does
not provide one (FR-028).

## Android

Two ways to get a device, chosen at runtime by `android-emulator` (on `PATH` in an
`--android` image):

1. **In-container emulator.** Needs `/dev/kvm` on the host. `--android` at start adds
   `compose.android.yaml`, passing `/dev/kvm` through with the device's group id
   (`AUTONOMOUS_KVM_GID`, read from the host by the wrapper — on most distros the `kvm` group).
   `android-emulator` then starts `emulator -avd autonomous -no-window -no-audio -accel on`
   and waits for `sys.boot_completed`. No privileged mode, no added capabilities.
2. **Host adb fallback.** Without `/dev/kvm`, point at an adb server on the host: run
   `adb -a -P 5037 nodaemon server` there (device or emulator attached), and the container
   reaches it at `host.docker.internal:5037` (mapped to the host gateway in `compose.yaml`).
   Set `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037` or let `android-emulator` detect it.

With neither, `android-emulator` exits non-zero and prints both options. Without `/dev/kvm`
the wrapper warns and does not add the override, so the fallback still starts.

The image grows by several GB with `--android` (JDK, SDK, emulator, one system image).
The system image and platform are the `ANDROID_SYSTEM_IMAGE` / `ANDROID_PLATFORM` build args
in the `Dockerfile` (edit the default to change them); the AVD is created at build time under
`/opt/android` and is writable by any uid.
