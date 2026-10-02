# Research: Always-Containerized Runtime

All Technical Context unknowns are resolved below. Each entry: Decision, Rationale,
Alternatives considered. Code references are to the tree at `3f8e6d7`.

## R1. Outside-container boot refusal (FR-004, FR-005)

**Decision**: New `Autonomous.ContainerGuard`. Pure `decide(env_marker, required?)`
returns `:ok | {:error, :not_in_container}`; `check!/0` reads
`System.get_env("AUTONOMOUS_CONTAINER")` and `Application.get_env(:autonomous,
:require_container, true)` and raises with a message naming `scripts/autonomous
shell | console | release`. It is the first call in `Application.start/2`, before
`check_no_retired_settings!/0` and `Store.Boot.start!/0`, so nothing touches the
store. The image sets `ENV AUTONOMOUS_CONTAINER=1` in the `base` stage. The
`config :test` block in `config/config.exs` sets `require_container: false`, which
is the only override.

**Rationale**: `mix compile`, `mix deps.get`, `mix format` never start the app, so
they are unaffected without any special case. `mix test` starts the app but in
`:test`, where the guard is off. `iex -S mix`, `mix phx.server`, `mix run` and the
release all go through `Application.start/2`, so one check covers every operating
path. A config key (not `Mix.env/0`) works in releases, where Mix is absent.

Retired-setting env vars are refused by `config/runtime.exs` before the app starts;
that ordering is unchanged and still writes nothing.

**Alternatives considered**: checking `/.dockerenv` or cgroup paths (engine-specific,
spoofable both ways, and the spec chose an image-set marker); a host override env var
(rejected by clarification Q2).

## R2. Instance identity: segment, node name, store dir (FR-017, FR-018)

**Decision**: `Autonomous.Instance.derive(repo, partition, state_root)` (pure; `repo` is
carried into the struct for `assert_served!/1` and the owner record, see
[contracts/instance-identity.md](contracts/instance-identity.md)) maps the
existing `RepoIdentity.partition/1` output (`"o:<name>-<hash6>"` with an origin,
`"l:<name>-local-<hash6>"` without) to:

| Field | Value |
|---|---|
| `segment` | partition without the `o:`/`l:` prefix |
| `node_name` | `autonomous_<sanitized segment>@autonomous` (sanitize: any char outside `[A-Za-z0-9_-]` → `_`) |
| `store_dir` | `<state_root>/instances/<segment>/mnesia` |
| `lock_path` | `<state_root>/instances/<segment>/instance.lock` |
| `owner_path` | `<state_root>/instances/<segment>/instance.json` |
| `cookie_path` | `<state_root>/instances/<segment>/cookie` |

Compose pins `hostname: autonomous` on every service so the host part of the short
node name never changes across recreation. `RepoIdentity` already canonicalizes the
origin URL (scheme, user, `.git`, host case), so SSH vs HTTPS spellings of one repo
map to one segment.

**Rationale**: Reusing `RepoIdentity` keeps one derivation in the codebase; it is
already the key for worktrees/transcripts (`Layout`) and for run records
(`partition`). The fixed hostname is what makes `node()` stable; Docker otherwise
sets the hostname to the container id, which changes on every recreation and would
trigger `{:schema_node_mismatch, ...}` by design.

**Alternatives considered**: one fixed node name for every instance (rejected:
instances must never share a store, and a shared name hides cross-wiring); deriving
in shell (`git remote get-url | sha256sum`) — rejected, duplicates canonicalization
and drifts; long names (`--name`) — unnecessary, no clustering.

## R3. How the derived identity reaches the VM

**Decision**: The entrypoint obtains identity from Elixir before starting the VM:

- dev: `mise exec -- mix autonomous.instance --repo "$AUTONOMOUS_REPO" --format env`
  (Mix task, `@requirements []`, does not start the app; loads code only);
- release: `bin/autonomous eval 'Autonomous.Instance.print_env()'`.

It prints `AUTONOMOUS_INSTANCE_SEGMENT`, `AUTONOMOUS_NODE_NAME`,
`AUTONOMOUS_STORE_DIR`, `AUTONOMOUS_INSTANCE_LOCK`, `AUTONOMOUS_COOKIE_PATH`. The
entrypoint exports them and starts `iex --sname <name> --cookie <cookie> -S mix` /
`RELEASE_NODE=<name>`. At boot, `Instance.verify!/0` re-derives from `Config.repo/0`
and refuses if `node()`, `Config.store_dir/0` or the lock env disagree
(`{:instance_mismatch, field, expected, actual}`).

**Rationale**: One source of truth (Elixir), double-checked at boot, so an operator
who adds `--sname foo` by hand gets a named refusal before Mnesia sees it (spec edge
case: ad hoc node name).

**Alternatives considered**: computing `store_dir` inside `runtime.exs` by calling
app modules (discouraged in releases, and the node name still has to come from
outside).

## R4. One live instance per target (FR-018a)

**Decision**: The entrypoint opens `lock_path` on file descriptor 9 and runs
`flock -n 9`. On success it writes `instance.json` (`compose_project`, `service`,
`started_at`, `console_port`, image id) and `exec`s the VM, which inherits fd 9, so
the kernel holds the lock exactly as long as the VM lives — a crash or
`docker rm -f` releases it. On failure it reads `instance.json` and exits 75 with
"target <repo> is already served by <compose_project>/<service> since <started_at>".
It exports `AUTONOMOUS_INSTANCE_LOCKED=<lock_path>`; `Instance.verify!/0` refuses
to boot without it in container mode. The wrapper also uses a deterministic Compose
project name `autonomous-<segment>` so `docker compose ps` lists instances by target.

**Rationale**: `flock` on a bind-mounted local filesystem is shared by every
container on one kernel, needs no daemon, and cannot go stale. The check happens
before the VM starts, so before the store opens.

**Alternatives considered**: Mnesia's own directory lock (not reliable across
separate VMs for disc tables; failure surfaces late and unnamed); PID files
(stale after a crash); Docker container-name uniqueness (`docker compose run`
creates a new container each time, so it does not refuse).

Limit: network filesystems may not honour `flock`; documented as unsupported for the
state root.

## R5. Repository guard on the operator API (FR-007)

**Decision**: `Instance.assert_served!(repo)` compares `Path.expand(repo)` with
`Path.expand(Config.repo())` (and, for `repo_id`-taking functions, the partition
string). Mismatch raises `Autonomous.Instance.NotServedError` naming both. Applied in
container mode only, at the top of every public facade function that accepts a
repository or repository id: `workers/1`, `current_run_id/1`, `resumable/1`, and any
`:repo` option on start/resume paths. In test mode (guard off) it is a no-op, so
existing tests that pass explicit repos keep working.

**Rationale**: Boundary violation ⇒ raise (Principle VI permits raising for boundary
violations). A single helper keeps the list auditable; tasks enumerate the call
sites by grepping `repo \\\\ Config.repo()` and `repo_id`.

**Alternatives considered**: tuple errors (inconsistent with list-returning
`workers/1`); silently ignoring the argument (Principle II forbids).

## R6. State root and same-path mounts (FR-017, FR-019, FR-020)

**Decision**: The wrapper mounts the host `$HOME/.autonomous` at the same absolute
path and the target repository at its host absolute path (`realpath`). A new env var
`AUTONOMOUS_ROOT` sets `:autonomous_root` in `runtime.exs` (needed because the
container `HOME` is `/home/autonomous`, not the host home). `AUTONOMOUS_STORE_DIR`
sets `:store_dir`. The old `<root>/mnesia` is never opened (fresh per-target store);
`<root>/worktrees/<segment>` and `<root>/transcripts/<segment>` are reused as is,
because `Layout` already keys them by the same segment.

Git worktrees record absolute paths in both `<target>/.git/worktrees/<name>/gitdir`
and `<worktree>/.git`; identical paths on both sides make them valid from the host
(SC-006). The smoke script asserts `git -C <target> worktree list` from the host.

**Rationale**: Same-path is the only way git worktree metadata is valid on both sides
without rewriting.

**Alternatives considered**: mounting at `/target` and fixing paths with
`git worktree repair` (would need running on every boundary crossing); a named
volume for state (invisible to host tools, contradicts clarification Q3).

Legacy repo-relative roots (`worktree_root` default `../.speckit-worktrees`) are
pre-012 fallbacks not on any live write path; tasks include a check that no live
path writes relative to `cwd` inside the container.

## R7. Base image, toolchain and tools (FR-010, FR-011, FR-006)

**Decision**: `debian:bookworm-slim` base. Stage `toolchain` installs build deps,
then mise, copies only `mise.toml`, and runs `mise install` (Erlang compiled from
source; cached layer keyed on `mise.toml`). Tools: `git`, `python3`, `util-linux`
(`flock`), `ca-certificates`, `gh` from the official GitHub apt repo pinned by
`ARG GH_VERSION`, Node.js from NodeSource pinned by `ARG NODE_MAJOR` (22), and
`npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}` with
`ARG CLAUDE_CODE_VERSION` pinned in the Dockerfile. User `autonomous` created from
`ARG UID=1000`, `ARG GID=1000`; the wrapper passes `--build-arg UID=$(id -u)
GID=$(id -g)`. `git config --system safe.directory '*'` (FR-008; the container's
only repositories are the ones deliberately mounted).

**Rationale**: Debian matches mise's precompiled-friendly build deps and ERTS runtime
libs (openssl, ncurses) for the release stage. `mise.toml` is the single version
source: the image copies it, never restates it.

**Alternatives considered**: `hexpm/elixir` images (versions restated in the
Dockerfile tag — violates FR-010); Alpine (musl friction with Playwright, Android
emulator and npm natives).

## R8. Credentials (FR-012–FR-016)

**Decision**:

- Coding agent: `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` from `.env`;
  opt-in login mount via `AUTONOMOUS_MOUNT_CLAUDE_LOGIN=1`, which adds bind mounts of
  host `~/.claude` and `~/.claude.json` to `/home/autonomous/` (compose override file
  `compose.claude-login.yaml`). Token wins because the CLI itself prefers env
  credentials over stored login; documented, and SC-011 tests both modes.
- Code host: `GH_TOKEN`. The entrypoint runs `gh auth setup-git` (credential helper
  backed by `GH_TOKEN`) and sets
  `git config --global url."https://github.com/".pushInsteadOf git@github.com:`, so
  pushes from SSH-origin repos go over HTTPS. `pushInsteadOf` (not `insteadOf`) keeps
  `git remote get-url origin` unchanged, so `RepoIdentity` is unaffected.
- Commit identity: `GIT_AUTHOR_NAME/EMAIL`, `GIT_COMMITTER_NAME/EMAIL` from `.env`.
  Git env vars take precedence over `-c user.name=…`, which `Worktree.commit/2`
  passes today, so no code change is needed; a test asserts the precedence.
- `.env.example` committed; `.env` in `.gitignore` and `.dockerignore`. Build never
  receives secrets (no `ARG`/`COPY` of `.env`). Compose passes them with `env_file`.
- Warnings (FR-016): the entrypoint warns when neither token is set and no login is
  mounted, and when `ANTHROPIC_DEFAULT_OPUS_MODEL`/`ANTHROPIC_DEFAULT_SONNET_MODEL`
  are unset. Warnings, not refusals.

**Alternatives considered**: Docker secrets (needs Swarm or file juggling; env is
already how the app reads config); baking `gh` auth into the image (FR-015 forbids).

## R9. Console publishing (FR-021, FR-022)

**Decision**: `runtime.exs` (non-test) reads `AUTONOMOUS_CONSOLE_IP` (default
`127.0.0.1` on host — irrelevant now — and `0.0.0.0` inside the image via `ENV`),
`AUTONOMOUS_CONSOLE_PORT` (container port, default 4000), `AUTONOMOUS_CONSOLE_HOST`
(default `localhost`), `AUTONOMOUS_SECRET_KEY_BASE`. `check_origin` becomes
`["//localhost", "//127.0.0.1"]` (host match, any port), because the host port is
chosen at start. In `:prod` the secret is required (`System.get_env` + raise naming
`AUTONOMOUS_SECRET_KEY_BASE`); dev keeps the compile-time default.

Compose maps `"127.0.0.1:${AUTONOMOUS_HOST_PORT:-}:4000"`. An empty value yields
`127.0.0.1::4000`, which Docker resolves to a random free loopback port. The wrapper
prints `docker compose port <service> 4000` after start. A busy requested port makes
Docker fail; the wrapper turns that into "console port <n> is already in use".
Publishing on `127.0.0.1` makes the console unreachable from other machines (SC-007).

For `scripts/autonomous shell` (a `docker compose run`), the wrapper passes
`--service-ports` and starts the endpoint (`PHX_SERVER=true` →
`config :autonomous, Autonomous.Web.Endpoint, server: true`) so the shell and the
console share one VM.

**Alternatives considered**: host networking (exposes everything and breaks
per-instance ports); fixed ports per target (collisions, clarification chose random).

## R10. Release shape (FR-002, US4)

**Decision**: `mix.exs` `releases: [autonomous: [include_executables_for: [:unix],
applications: [autonomous: :permanent]]]`. `rel/env.sh.eex` sets
`RELEASE_DISTRIBUTION=sname`, `RELEASE_NODE=$AUTONOMOUS_NODE_NAME`,
`RELEASE_COOKIE=$(cat $AUTONOMOUS_COOKIE_PATH)`. The cookie is generated once per
instance by the entrypoint (`0600`, under the state root) — never in the image. The
release stage copies the release onto the `base` + tools + capabilities stages
(not `toolchain`): no mise, no Elixir sources at runtime. `scripts/autonomous remote`
runs `docker compose exec release bin/autonomous remote`.

**Alternatives considered**: shipping the dev image as "release" (fails "no build
toolchain at runtime").

## R11. Testing capabilities (FR-023–FR-026, FR-028)

**Decision**: Build args `WITH_WEB`, `WITH_DESKTOP`, `WITH_ANDROID` (default `0`).
Each capability is a `RUN if [ "$WITH_X" = 1 ]; then …; fi` block, so when off the
layer adds no files (verified by `container-smoke.sh` listing the absent binaries).

- **Web**: `npx playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium firefox
  webkit` into `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` (world-readable);
  `ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`. A target's Playwright version must match
  the pinned one to reuse browsers; documented. `shm_size: 1gb` in compose. Chromium
  sandbox: Playwright's default in a non-root container works under Docker's default
  seccomp on current kernels; where it does not, the documented workaround is
  `chromiumSandbox: false` in the target's config. No `--privileged`, no
  `SYS_ADMIN`.
- **Desktop**: `xvfb`, `xdotool`, `imagemagick` (`import` for screenshots), `x11vnc`,
  `novnc`+`websockify`, `dbus-x11`, fonts, Electron runtime libs (`libnss3`,
  `libgtk-3-0`, `libasound2`, `libgbm1`, `libxss1`). `AUTONOMOUS_DISPLAY=1` makes the
  entrypoint start `Xvfb :99` and export `DISPLAY=:99` to the VM, so sessions inherit
  it. `AUTONOMOUS_DISPLAY_VIEWER=1` (override file `compose.desktop-viewer.yaml`)
  starts x11vnc + noVNC on container port 6080, published on `127.0.0.1` only.
- **Android**: JDK 17, Android cmdline-tools, `platform-tools`, `emulator`, one
  system image pinned by `ARG ANDROID_SYSTEM_IMAGE`, an AVD created at build time
  under `/opt/android`. `compose.android.yaml` adds `devices: ["/dev/kvm"]` and
  `group_add` for the kvm group. `scripts/android-emulator` (on `PATH`) starts
  `emulator -no-window -no-audio -accel on` and waits on `adb wait-for-device` +
  `sys.boot_completed`; without `/dev/kvm` it checks
  `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037` (compose `extra_hosts:
  host.docker.internal:host-gateway`) and uses the host's adb server; with neither it
  exits non-zero naming both options (FR-026).
- iOS/macOS/Windows: docs state an external runner (FR-028).

**Alternatives considered**: separate images per capability (combinatorial tags); a
runtime install on first use (needs network inside `strict` sessions).

## R12. `strict` hook audit for capability commands (FR-027, SC-010)

**Finding**: Against `DANGEROUS_BASH` in `scope_guard.py`, the capability commands
(`npx playwright test`, `xvfb-run`, `xdotool`, `import -window root shot.png`,
`adb …`, `scripts/android-emulator`, `./gradlew connectedAndroidTest`) match no rule.
Per-phase permissions under `strict` already grant `Bash` to implement/converge
(`PhaseRequest` `@write_bash_tools`). The one rule they do hit is
`bash_redirect_outside_worktree`: the regex `>>?\s*"?(/[^"\s]+)` matches
`>/dev/null`, `2>/dev/null` and `&>/dev/null`, which are routine in emulator and
display start lines.

**Decision**: Before the outside-worktree check, skip a redirect whose target is
exactly `/dev/null`, `/dev/stdout` or `/dev/stderr`. No other change. Red-team
additions: those three targets allowed; `/dev/sda`, `/dev/nullx`, `/dev/null/../etc/x`,
`/tmp/x`, `/etc/passwd` still denied; every existing case unchanged. `PACK_CONTRACT`
stays 3: the change only removes a denial under `strict`; an older installed pack is
stricter, never looser, and `permissive` verification semantics are untouched.
Targets get the allowance on their next `TargetPack.install/2`.

**Recorded gap (for `/speckit-analyze`)**: the hook denies `curl`/`wget`, `WebFetch`
and `WebSearch`, but not package-manager downloads (`npm install`, `pip install`,
`mix deps.get`). The spec edge case "the download is denied by the hook" therefore
holds only for those download tools. Adding package-manager denials would *tighten*
`strict` and could break existing targets, which is outside this feature's scope
(FR-027 forbids loosening, it does not mandate tightening). Decision: keep the hook
as is, set `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` so pre-installed browsers are used,
and record the package-manager gap next to the egress gap in `docs/enforcement.md`
(FR-029). The spec edge-case wording should be aligned during analyze.

## R13. Dev shape mounts and build artefacts (FR-001, FR-005, SC-003)

**Decision**: Source checkout bind-mounted at `/workspace`; `_build` and `deps` are
named volumes (`autonomous-build`, `autonomous-deps`) so host-compiled artefacts and
container-compiled artefacts never mix (different OTP builds/paths), and host
`mix test` keeps working untouched. `scripts/autonomous test` runs
`mise exec -- mix test` in the dev service. The dev service's mise data dir is baked
into the image (no runtime install).

**Alternatives considered**: sharing `_build` (stale-artifact and permission
conflicts between host and container compiles).

## R14. Engine scope and validation (FR-003)

**Decision**: Docker Engine + Compose v2 on Linux only. The wrapper checks
`docker compose version` (v2) and exits with a named message otherwise. Validation is
`scripts/container-smoke.sh`, covering SC-001…SC-012 where automatable; the
full-feature smoke (SC-004) and second-machine reachability (SC-007) remain manual
steps in `quickstart.md`.

## R15. Secret scanning (SC-012)

**Decision**: The smoke script runs `docker history --no-trunc` and
`docker save | tar -x` + `grep` for the values present in the operator's `.env`
(read locally, never printed), and `git grep` for the same values. No new tool
dependency.
