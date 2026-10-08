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
locations and stay valid.

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
no such record, so the committed target pack was silently dropped. The entrypoint now runs
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

Backstop: a session that still reports an untrusted workspace fails the phase under
`strict` (`{:untrusted_workspace, phase, obs}`, never retried; see `docs/runbook.md`) and
only warns under `permissive` — on host and container alike.

**Hook under untrusted workspaces.** Whether `scope_guard.py` runs while the workspace is
untrusted is checked by `SMOKE_AGENT=1 scripts/container-smoke.sh us-trust-hook`, which
prints one greppable `us-trust-hook claude=<version> untrusted|trusted: …` line each.
Finding (2026-10-08, pinned image, `claude` 2.1.286, authenticated run): with no trust
record the CLI prints the untrusted warning and ignores `permissions.allow`, **but the
PreToolUse hook still runs** — a strict orchestrated session asked to write `/tmp/outside`
was denied by `scope_guard` (`write_outside_worktree`) and no file was written; with the
trust record the outcome is the same minus the warning. So past strict runs ran
*narrower* (allow-list ignored), not wider; hook containment held. Re-run
`us-trust-hook` after CLI upgrades.

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
lines name the loopback address. `scripts/autonomous port --target <repo>` prints the
address of any running instance (shell, console or release).

- The image binds `0.0.0.0` *inside* the container; Compose publishes it as
  `127.0.0.1:<port>:4000`, so only the operator's machine reaches it (FR-021). From another
  machine on the LAN the connection is refused; tunnel with `ssh -L` to watch remotely.
- No `--port`: the wrapper picks a free loopback port and prints it. A busy `--port` exits
  76 naming it.
- `AUTONOMOUS_CONSOLE_HOST` (default `localhost`) feeds the endpoint URL; origin checks
  accept `//localhost` and `//127.0.0.1` on any port because the host port is chosen at
  start.

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

All three run from a `strict` session: the hook allows redirects to `/dev/null`,
`/dev/stdout` and `/dev/stderr` (exact match) and nothing else changed.

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

A `strict` session does not stop package-manager downloads (`npm install`, `pip install`,
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
