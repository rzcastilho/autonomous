# Research: Container Isolation for Autonomous Runs

**Feature**: `015-container-isolation` | **Date**: 2026-07-24 | **Spec**: [spec.md](./spec.md)

Phase 0 output. Every `NEEDS CLARIFICATION` from the plan's Technical Context is
resolved below. Findings are grounded in the current tree (`lib/`, `config/`,
`deps/jido_claude/`) — where a fact came from code, the path is cited.

---

## R1. Release packaging — how the orchestrator ships without source

**Decision**: `MIX_ENV=prod mix release` producing an ERTS-embedded release named
`speckit_orchestrator`, built in a multi-stage image; only `_build/prod/rel/…` is
copied into the runtime stage. `releases:` is added to `mix.exs` (currently
absent) with `include_executables_for: [:unix]`, `include_erts: true`.

**Rationale**: FR-003 requires a compiled, self-contained release with no
orchestrator source and no build tooling in the runnable image. An ERTS-embedded
release needs no Erlang/Elixir installed at runtime, which also satisfies "MUST
NOT depend on any runtime present only on the operator's machine". `priv/` is
included in a release by default, so the console's vendored JS/CSS/fonts
(`priv/static/…`, constitution "no Node/npm build pipeline") and the target pack
(`priv/target_pack/…`, consumed by `TargetPack.install/2`) travel automatically.

**Consequences to handle**:

- ERTS is glibc-linked — **builder and runtime stages MUST share the same Debian
  release** (bookworm). A slim/alpine mismatch produces a release that will not
  boot.
- `config/runtime.exs` is the only config evaluated in a release. `config.exs` is
  baked at build time. This is exactly the FR-020 "environment configuration
  evaluated at boot is the single configuration surface" shape, but it means
  every setting FR-020 enumerates must have a runtime.exs branch — today
  `runtime.exs` only covers `repo`, `pr_*`, `max_concurrency`, `budget_usd`,
  `plan_stack`. Gap list in [R9](#r9-configuration-surface-gaps).
- `mix phx.server` does not exist in a release. Today the endpoint only binds a
  port under `mix phx.server` (see the comment in `config/config.exs`), so the
  release needs `server: true` set in `runtime.exs`.

**Alternatives rejected**:

- *Ship source + `mix run --no-halt`* — violates FR-003 outright; also drags the
  whole Hex dep tree and build toolchain into the runnable image.
- *Escript* — cannot carry OTP applications/supervision trees or `priv/`, and
  gives no remote console (FR-025).
- *Burrito / self-extracting binary* — extra dependency and build surface for no
  gain over a plain release once the image is the distribution unit.

---

## R2. Base images

**Decision**:

| Stage | Image | Why |
|---|---|---|
| builder | `hexpm/elixir:1.20.2-erlang-<OTP28.x>-debian-bookworm-<date>` | Carries the exact `.tool-versions` pin (`1.20.2-otp-28`) with OTP prebuilt |
| runtime | `debian:bookworm-slim` | glibc match with builder; smallest base that can host `git`/`gh`/`python3`/`mise` |

Both pinned **by digest** in the `Dockerfile` (`FROM image@sha256:…`), with the
human-readable tag kept in a comment. The exact builder tag is resolved once at
implementation time (hexpm publishes `<elixir>-erlang-<otp>-debian-bookworm-<date>`
and `-slim` variants) and recorded in the Dockerfile.

**Rationale**: The constitution pins Elixir `1.20.2-otp-28` via `.tool-versions`
and declares Erlang system-provided. `hexpm/elixir` is the canonical image that
matches an (elixir, otp, distro) triple exactly, so the release is built against
the committed pin with no source builds in CI. Digest pinning makes image content
a function of committed inputs (FR-006, SC-010).

**Alternatives rejected**:

- *`debian:bookworm-slim` + mise for Elixir **and** Erlang in the builder* —
  mise's Erlang provider builds OTP from source (many minutes per CI run) because
  no `erlang` line exists in `.tool-versions` by policy. Rejected on build time;
  it also duplicates what hexpm already publishes.
- *Alpine runtime* — musl/glibc mismatch with any ERTS built on Debian, and the
  target toolchains mise fetches at run time (R5) are overwhelmingly
  glibc-prebuilt. Would force source builds inside the operator's container.
- *`distroless` runtime* — cannot host `git`, `gh`, `bash`, `python3`, or a
  package-installing toolchain manager. FR-002/FR-004 make a shell-capable base
  mandatory.

---

## R3. External tools in the image (FR-002)

**Decision** — each installed at a pinned version in the runtime stage, each
version captured into the image manifest (R8):

| Tool | Install method | Pin mechanism |
|---|---|---|
| `git` | `apt-get install git` | apt version pinned in the Dockerfile; recorded from `git --version` |
| `gh` (GitHub CLI) | official `cli/cli` release tarball, checksum-verified | `ARG GH_VERSION` |
| `python3` | `apt-get install python3-minimal` | apt; the scope-guard hook is invoked as `python3` (`priv/target_pack/.claude/settings.json:28`) |
| `claude` | native installer (`curl -fsSL https://claude.ai/install.sh \| bash <version>`) | `ARG CLAUDE_CODE_VERSION`; the installer accepts an explicit version |
| `specify` (Spec Kit CLI) | `uv tool install --from git+https://github.com/github/spec-kit.git@<tag> specify-cli` | `ARG SPECKIT_VERSION`, defaulted to `Config.speckit_version/0` (`"v0.12.11"`) |
| `uv` | static binary from `astral-sh/uv` releases, checksum-verified | `ARG UV_VERSION` |
| `mise` | static binary from `jdx/mise` releases, checksum-verified | `ARG MISE_VERSION` |
| `coreutils` (`timeout`) | in base | — the adapter's command template calls `timeout 180 claude …` (`deps/jido_claude/lib/jido_claude/adapter.ex:141`) |
| `bash`, `ca-certificates`, `curl` | apt | — `.specify/scripts/bash/*.sh` are bash scripts |

**Rationale**: `deps/jido_claude/lib/jido_claude/adapter.ex:130` declares
`runtime_tools_required: ["claude"]` and probes with `claude --help`; the
adapter's command template additionally requires a POSIX shell and `timeout`.
`System.cmd` call sites in `lib/` require `git` (`worktree.ex`,
`repo_identity.ex`, `target_pack.ex`, `recovery/evidence.ex`,
`run_feature_phase.ex`, the facade) and `gh` (`pull_request.ex:31`).

**Note on `specify`**: nothing in `lib/` shells out to the `specify` binary — the
phase loop drives `/speckit.*` **skills** that live in the target repo's
committed `.claude/skills/`, and those call `.specify/scripts/bash/*.sh`. FR-002
still mandates the CLI in the image; it serves the pack bootstrap/upgrade path
documented in `docs/enforcement.md` ("Upgrade procedure"), not the run loop. The
plan installs it and says so, rather than silently dropping it.

**Alternatives rejected**:

- *`npm install -g @anthropic-ai/claude-code`* — pulls Node + npm into the
  runtime image purely as a package manager, against the constitution's
  no-Node-toolchain stance for this project. The native installer is a single
  versioned binary. Kept as a documented fallback if the native installer proves
  unusable on a given host arch.
- *`pipx` for `specify`* — needs a full Python packaging stack; `uv` is one
  static binary and is already the Spec Kit-recommended installer.

---

## R4. Host identity, file ownership, and git trust

**Decision**: run with `--user <uid>:<gid>` supplied explicitly at start, and:

1. `HOME` set to the operator's **host** home path (e.g. `/home/alice`), because
   the run-state root is `Path.expand("~/.autonomous")`
   (`lib/speckit_orchestrator/config.ex:71`) — `Path.expand/1` resolves `~` from
   `$HOME` on Unix.
2. Git identity supplied by environment, not by `~/.gitconfig`:
   `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` /
   `GIT_COMMITTER_EMAIL`. This is the FR-015 "configurable identity" and it
   removes the need for a `/etc/passwd` entry for the numeric UID.
3. Git ownership trust supplied by environment:
   `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=safe.directory`,
   `GIT_CONFIG_VALUE_0=*`. Injected by the entrypoint, not by the operator.
4. Optional, documented: bind-mount host `/etc/passwd` and `/etc/group`
   read-only so tools that resolve the UID to a name see the real account.

**Rationale**: `--user` with the host's numeric UID/GID is the only mechanism
that makes files created in the bind-mounted repository owned by the operator on
the host (FR-013, SC-004) on a Linux container engine. It leaves the UID
nameless inside the container, which breaks two things and only two: git's
"unable to auto-detect email address" and git's `dubious ownership` refusal
(FR-015, and the "Repository ownership rejection" edge case). Both are fixed
with environment variables, which is strictly simpler than `nss_wrapper` or an
OpenShift-style group-writable `/etc/passwd`, and works under a read-only root
filesystem.

**Alternatives rejected**:

- *Build a fixed-UID user into the image* — breaks the moment the operator's UID
  is not that number; contradicts FR-013's "supplied explicitly at start".
- *`nss_wrapper` / `LD_PRELOAD`* — an extra runtime dependency and a preload
  shim in every child process (including `claude` and target builds) to fix
  something two env vars already fix.
- *Group-writable `/etc/passwd` + entrypoint append* — incompatible with the
  read-only root filesystem in R6, and requires `--group-add 0`.
- *Podman rootless `--userns=keep-id`* — the right answer on Podman, but the
  feature verifies one engine (FR-014); noted in docs as a likely-working
  variant, explicitly unverified.

---

## R5. Target toolchains at run time (FR-004)

**Decision**: `mise` is the toolchain manager in the image. Its data and cache
directories are pointed at the **durable run-state mount**:

```
MISE_DATA_DIR=$HOME/.autonomous/mise/data
MISE_CACHE_DIR=$HOME/.autonomous/mise/cache
MISE_TRUSTED_CONFIG_PATHS=$SPECKIT_REPO
MISE_YES=1
```

**Rationale**: This repository already runs every Elixir command through mise
(constitution, Quality & Test Discipline), so it is the toolchain manager the
project already trusts, and it reads the `.tool-versions` / `mise.toml` a target
repository commits — which is exactly the FR-004 requirement and the "Toolchain
fetch on first use" edge case. Routing `MISE_DATA_DIR` into the run-state mount
makes an acquired runtime survive container exit and be reused by the next run
(the "Repeated runs and disk growth" edge case), while keeping every write
inside the two writable areas FR-012 allows. `MISE_TRUSTED_CONFIG_PATHS` avoids
an interactive trust prompt that would wedge a headless run.

**Disk-reclaim story (FR-038)**: `$HOME/.autonomous/mise/cache` is always safe to
delete (re-fetched on demand); `…/mise/data` is safe to delete at the cost of
re-downloading toolchains; `…/transcripts/<segment>/…` is post-mortem evidence;
`…/worktrees/<segment>/…` holds preserved worktrees of escalated/halted features
and MUST NOT be deleted while a feature is awaiting resolution.

**Alternatives rejected**:

- *Bake every plausible language runtime into the image* — unbounded image size,
  and still wrong whenever a target pins a version that was not baked (SC-008).
- *asdf* — mise is the project's existing choice; introducing a second manager
  would need a Governance justification for zero benefit.
- *`MISE_DATA_DIR` on a tmpfs* — re-downloads the target toolchain on every
  container start; measurable against SC-009.

---

## R6. Writable surface and OS-level containment (FR-011, FR-012)

**Decision** — container flags, all emitted by the launcher script (R10):

```
--read-only                      # root filesystem is immutable
--user <uid>:<gid>
--cap-drop ALL
--security-opt no-new-privileges # blocks setuid escalation (FR-011)
--tmpfs /tmp:rw,nosuid,nodev,size=1g
--tmpfs $HOME:rw,nosuid,nodev,mode=0700,uid=<uid>,gid=<gid>
-v $SPECKIT_REPO:$SPECKIT_REPO
-v $HOME/.autonomous:$HOME/.autonomous
--pids-limit 4096
-p 127.0.0.1:$PORT:$PORT
```

Nested-mount ordering: the container engine applies bind mounts sorted by path
depth, so `$HOME/.autonomous` lands **inside** the `$HOME` tmpfs. That gives
exactly the FR-012 shape: two writable durable areas (target repo, run-state),
`$HOME` and `/tmp` ephemeral, everything else read-only.

**Rationale**: `--read-only` + `--cap-drop ALL` + `no-new-privileges` is what
makes the isolation an OS-layer guarantee that holds with the in-repo guard hook
disabled (User Story 2, SC-002). The ephemeral `$HOME` is load-bearing: the
`claude` CLI, `gh`, and `mise` all want to write under `$HOME`, and a tmpfs
satisfies them without granting a durable escape hatch.

**Deliberately not restricted**: network egress. FR-016 and the spec's
Assumptions scope the claim to filesystem, privileges, and process scope. The
launcher script does **not** emit `--network` restrictions, and
`docs/enforcement.md`'s current advisory line ("Drop network egress except the
Anthropic API host") is superseded per FR-037 — it was never implemented and
overstates the guarantee.

**Alternatives rejected**:

- *Writable `$HOME` bind mount from the host* — would put a third writable area
  on the host filesystem, violating FR-012 and widening blast radius to the
  operator's dotfiles.
- *`--cap-add` for anything* — no pipeline operation needs a capability; target
  builds run unprivileged.
- *gVisor / Kata* — stronger isolation, but a host-runtime prerequisite that
  contradicts SC-003's "only a container engine".

---

## R7. Credentials at start time (FR-021, FR-005, FR-035)

**Decision** — two supported paths, both start-time only:

1. **Direct secret value**: `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`)
   passed via `--env-file`, never `--env KEY=value` on a command line.
2. **Mounted pre-authenticated agent configuration**: the operator's host
   `~/.claude` directory bind-mounted **read-only** at a staging path
   (`/run/secrets/claude`); the entrypoint copies it into the ephemeral
   `$HOME/.claude` (tmpfs) with `CLAUDE_CONFIG_DIR=$HOME/.claude`, so the CLI can
   write session state without any host write-back.

`gh` authentication for the PR workflow uses `GH_TOKEN` from the same env file.

**Rationale**: `deps/jido_claude/lib/jido_claude/runtime_config.ex:6-17` forwards
a fixed `@known_env_keys` set (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_API_KEY`, `ANTHROPIC_BASE_URL`, the three
`ANTHROPIC_DEFAULT_*_MODEL` pins, …) into the CLI process, so path 1 needs no
orchestrator change. `validate_auth_contract!/0` in the same module is defined
but **called from nowhere** in `deps/` or `lib/` (verified by grep), so path 2
(OAuth credentials with no API key in the environment) is not blocked by the
harness — a real risk worth stating, since a future harness bump that starts
calling it would break the mounted-config path. The copy-into-tmpfs step is what
reconciles "the CLI mutates its config directory" with FR-012's two-writable-areas
rule.

**Never-print rule (FR-035)**: the preflight report records credential
*presence* and *source* (`:env | :mounted_config | :absent`) — never a value,
never a prefix, never a length. The same rule applies to the image manifest and
to container logs.

**Alternatives rejected**:

- *Bake credentials into an image layer* — FR-005; also fails SC-005.
- *`--env ANTHROPIC_API_KEY=…` inline* — lands in shell history and in
  `docker inspect` output. `--env-file` keeps it out of the command line (it is
  still visible in `docker inspect`; documented).
- *Writable bind-mount of host `~/.claude`* — lets container-side CLI state
  mutate the operator's host credentials.

---

## R8. Image self-identification, tagging, and publishing (FR-007..FR-010)

**Decision**:

- **Labels**: OCI standard labels set at build —
  `org.opencontainers.image.revision` (full source SHA),
  `org.opencontainers.image.version`, `org.opencontainers.image.source`,
  `org.opencontainers.image.created`.
- **In-container manifest**: `/etc/autonomous/image.json`, world-readable,
  written in the runtime stage, carrying source revision, orchestrator version,
  and the resolved version of every tool from R3. Surfaced by a new
  `SpeckitOrchestrator.ImageInfo` module and included in the preflight report.
- **Publishing**: `.github/workflows/image.yml` (the repo has no `.github/`
  today) — triggered by a `v*` tag push and by `workflow_dispatch`. Builds with
  Buildx, pushes to `ghcr.io/rzcastilho/autonomous`, authenticating with the
  workflow's `GITHUB_TOKEN` (`packages: write`).
- **Tag scheme**: `v<semver>` (immutable, one per release), `sha-<short-sha>`
  (immutable, informational), `latest` (moving). A **pre-push guard step** runs
  `docker buildx imagetools inspect ghcr.io/…:v<semver>` and fails the job if the
  tag already resolves, so an existing version tag is never overwritten (FR-009,
  SC-010). The pushed digest is recorded in the job summary and in the GitHub
  release notes.
- **Secret scan (SC-005)**: a `trivy image --scanners secret --exit-code 1` step
  gates the push.

**Rationale**: GHCR is the zero-extra-credential registry for a GitHub-hosted
repo, which is what makes FR-011's "zero manual build-or-push steps" reachable.
Registry-side tag-immutability rules are not uniformly available or
configurable from a workflow, so immutability is enforced by the guard step —
verifiable, and it fails the pipeline rather than silently clobbering.

**Alternatives rejected**:

- *Docker Hub* — needs an operator-provisioned credential pair stored as repo
  secrets; more moving parts for the same result.
- *Digest-only, no version tags* — unusable for SC-003's three-command
  onboarding.
- *Trusting a registry immutability policy alone* — not verifiable from the
  workflow, and silently divergent across registries.

---

## R9. Configuration surface gaps

FR-020 requires **every** setting to be supplyable at boot. Today
`config/runtime.exs` covers `repo`, `pr_workflow`, `pr_base`, `pr_remote`,
`max_concurrency`, `budget_usd`, `plan_stack`, plus the `ANTHROPIC_DEFAULT_*`
model pins (which are read by the harness, not by `Config`). **Missing** and to
be added:

| Setting | Env var | Notes |
|---|---|---|
| `models` (per-phase routing) | `SPECKIT_MODEL_<PHASE>` | Values restricted to `Config.valid_models/0` (`opus`/`sonnet`); unknown alias fails boot |
| `implement_max_turns` | `SPECKIT_IMPLEMENT_MAX_TURNS` | integer |
| `phase_max_retries` | `SPECKIT_PHASE_MAX_RETRIES` | integer |
| `autonomous_root` | `AUTONOMOUS_ROOT` | defaults to `~/.autonomous`; overriding it must still land on a durable mount |
| `specs_root` | `SPECKIT_SPECS_ROOT` | |
| `speckit_version` | `SPECKIT_VERSION` | preflight compares against the installed `specify` |
| console bind/port | `AUTONOMOUS_CONSOLE_PORT`, `AUTONOMOUS_CONSOLE_IP` | `server: true` + `check_origin` derived from these |
| release cookie | `RELEASE_COOKIE` | supplied by the launcher, never baked (FR-005) |
| auto-start | `AUTONOMOUS_AUTOSTART` | see R11 |
| path-identity assertions | `AUTONOMOUS_HOST_REPO`, `AUTONOMOUS_HOST_HOME` | see R10 |
| git identity | `GIT_AUTHOR_*`, `GIT_COMMITTER_*` | R4 |

**Decision**: a required setting that is absent fails the boot loudly
(FR-020) — `SPECKIT_REPO` already uses `System.fetch_env!/1`; the new required
ones follow the same shape. Optional settings keep the "only apply when set"
pattern already in `runtime.exs`, so compile-time defaults stand.

---

## R10. Path identity enforcement (FR-018, FR-019)

**Decision**: the launcher script derives every mount from host values and
passes the host-side truth in as `AUTONOMOUS_HOST_REPO` and
`AUTONOMOUS_HOST_HOME`. Preflight, inside the container, asserts:

1. `AUTONOMOUS_HOST_REPO == SPECKIT_REPO` and the path exists, is a git work
   tree, and is writable.
2. `AUTONOMOUS_HOST_HOME == System.get_env("HOME")`.
3. `Config.autonomous_root/0` expands to a path that is (a) writable and (b) a
   **mount point** — determined by reading `/proc/self/mountinfo` and matching
   the resolved path against a mount target.

Any failure stops the boot before a run starts.

**Rationale**: the spec's "A mount is not at its host path" and "Run-state root
resolves elsewhere" edge cases both require detection **from inside**, where the
host path is otherwise unknowable. Passing the host truth as an assertion — not
as configuration — makes a wrong `-v` flag a loud start-time failure instead of
artifacts that are valid on one side only. `/proc/self/mountinfo` is the check
that distinguishes "durable mount" from "a directory the tmpfs `$HOME` happens to
contain" (FR-023, Story 4 scenario 3).

**Alternatives rejected**:

- *Compare device/inode with a host-side probe* — needs a host agent; the engine
  gives no such channel.
- *Trust the operator's flags* — precisely the failure mode the edge cases name.
- *Canonical in-container paths + translation* — settled by the spec's
  clarification session: mirror host paths, no translation anywhere.

---

## R11. Container lifecycle, auto-start, and shutdown (FR-027, FR-029..FR-031)

**Decision**:

- **Entrypoint**: `exec bin/speckit_orchestrator start` (foreground). The release
  boot script forwards `SIGTERM` to the VM, which runs `init:stop` and terminates
  the supervision tree in order.
- **Idle by default**: the application starts `PubSub`, `Ledger`,
  `ConsoleProjection`, `RunnerSup`, and `Endpoint` (already the tree in
  `lib/speckit_orchestrator/application.ex`) and starts **no run**. The
  `Coordinator` stays per-run, as today.
- **Auto-start**: a new supervised `SpeckitOrchestrator.Boot` child, started last.
  It runs preflight, then — only if `AUTONOMOUS_AUTOSTART` names a run — calls
  the facade. Preflight failure logs, persists the failed report, and leaves the
  container idle without starting a run and without a success signal (FR-031).
- **Never exit on drain**: `Boot` does not stop the VM when a run drains; the
  container stays up until the operator stops it (FR-030).
- **Graceful stop**: `Coordinator` and `Ledger` gain `trap_exit` +
  `terminate/2` that flush the run manifest and the ledger tally. An in-flight
  phase that does not finish inside the engine's stop grace period is recorded
  as `interrupted` in the manifest with its reservation intact, so the reported
  spend never under-counts (FR-027, SC-006, Constitution IV).

**Rationale**: FR-029 wants container lifetime decoupled from run lifetime;
making auto-start a supervised child rather than the entrypoint is what buys
that, and it keeps the boot decision out of the entrypoint shell script where it
could not observe preflight results. `Boot` must not block the supervisor's
`init` — it performs its work in a `handle_continue`, per Constitution VI's
"no blocking the scheduler".

**Operational note**: `docker stop` defaults to a 10s grace period, far shorter
than a phase. Documentation and the launcher script use
`--stop-timeout <seconds>` and tell the operator to prefer draining via the
console/remote console over a hard stop.

**Alternatives rejected**:

- *Run-and-exit entrypoint* — rejected in the spec's clarification session;
  loses the post-drain inspectable state FR-030 requires.
- *Auto-start from the entrypoint shell* — cannot see preflight's structured
  result, and would have to duplicate the checks in bash.
- *`docker kill`-style shutdown* — corrupts the tally that Constitution IV makes
  a hard invariant.

---

## R12. Operator surfaces (FR-024, FR-025, FR-028)

**Decision**:

- **Console**: bind `0.0.0.0:<port>` *inside* the container (a loopback bind
  inside a network namespace is unreachable from the host), publish with
  `-p 127.0.0.1:<port>:<port>` so it is not exposed beyond the host.
  `check_origin` is derived from the configured port for both `localhost` and
  `127.0.0.1`, matching the existing `config/config.exs` reasoning.
- **Interactive session**: `docker exec -it <name> bin/speckit_orchestrator remote`
  — an IEx remote console into the running release, requiring no build tooling
  (FR-025). Distribution is `RELEASE_DISTRIBUTION=sname` with the node bound to
  loopback (`inet_dist_use_interface {127,0,0,1}`) and `RELEASE_COOKIE` supplied
  at start.
- **Logs**: `Telemetry.attach_default_logger/0` is invoked at boot so phase and
  terminal-state events reach stdout and therefore `docker logs` (FR-028).

**Rationale**: the console is FR-035-by-spec a single-operator, unauthenticated
surface; publishing on `127.0.0.1` is the containment. The release's own remote
console is the only interactive path that satisfies "requiring no build tooling",
since `iex -S mix` does not exist in a source-free image.

**Alternatives rejected**:

- *`-p <port>:<port>`* (all interfaces) — exposes an unauthenticated console to
  the network; explicitly out of scope per the spec's Assumptions.
- *`docker exec … sh` + manual attach* — no orchestrator API surface.
- *SSH into the container* — a daemon, a key surface, and a privilege footprint
  for something `docker exec` already does.

---

## R13. Verification approach

| Success criterion | How it is proven |
|---|---|
| SC-001 run parity | Integration script runs the reference backlog on-machine and in-container against a fixture target; diffs terminal statuses + branch set |
| SC-002 red team | `test/integration/container_red_team_test.exs` (`--include integration`) executes ≥10 hostile commands in the container with the guard hook removed; asserts every failure and a host-tree checksum match |
| SC-003 onboarding | `quickstart.md` walked end-to-end on a clean Linux host, timed |
| SC-004 ownership | Post-run `stat -c %u:%g` over every file the run created equals the invoking UID/GID |
| SC-005 no secrets | `trivy image --scanners secret` in CI, `--exit-code 1` |
| SC-006 stop/restart | Stop mid-run, restart, compare manifest + ledger tally before/after |
| SC-007 preflight messages | One unit test per seeded failure mode asserting the named item and the fix action |
| SC-008 target toolchain | Fixture target pinning a runtime different from the orchestrator's; assert the recorded version in the preflight report |
| SC-009 ≤10% overhead | Wall-clock of the same backlog on-machine vs in-container |
| SC-010/SC-011 publishing | Guard step rejects a duplicate tag; digest equality on a repeat pull |

Unit-testable logic (preflight evaluation, env-config parsing, image-manifest
parsing, mountinfo parsing) is pure and lives in the default hermetic suite.
Everything needing a container engine sits behind `--include integration` per the
constitution's Quality & Test Discipline.

---

## Open risks

1. **Builder image tag drift** — the exact `hexpm/elixir:1.20.2-erlang-28.x-…`
   tag is resolved at implementation time and pinned by digest. If no such image
   exists for the pinned triple, the fallback is `hexpm/erlang:28.x-debian-bookworm`
   plus a mise-installed Elixir 1.20.2 in the builder stage only.
2. **`validate_auth_contract!/0` is currently uncalled** (R7). A `jido_claude`
   SHA bump that starts calling it would break the mounted-config credential
   path. The integration suite must cover both credential paths so the bump
   fails loudly.
3. **Nested-mount ordering** (`$HOME` tmpfs + `$HOME/.autonomous` bind) is engine
   behaviour, not a documented guarantee. Preflight's mount-point assertion
   (R10) is what turns a wrong ordering into a loud failure rather than silent
   data loss.
4. **`docker stop` grace period** vs. multi-minute phases (R11) — mitigated by
   `--stop-timeout` and by recording an interrupted phase truthfully rather than
   pretending it completed.
