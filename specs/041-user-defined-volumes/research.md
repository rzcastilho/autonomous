# Research: User-Defined Persistent Volumes (041)

All Technical Context unknowns are resolved below. Each entry: **Decision**,
**Rationale**, **Alternatives considered**. Grounding: `scripts/autonomous`,
`scripts/container-entrypoint.sh`, `compose.yaml` (+ overlays), `Dockerfile`,
`lib/autonomous/instance.ex`, `lib/autonomous/web/live/config_live.ex`.

---

## R1 — Where the declaration lives

**Decision**: `${XDG_CONFIG_HOME:-$HOME/.config}/autonomous/targets/<segment>/volumes.toml`
on the host, where `<segment>` is `AUTONOMOUS_INSTANCE_SEGMENT` from the
existing identity lookup (`lookup_identity`). The wrapper resolves the path
(`realpath` of the parent) and refuses (exit 2) when it falls inside the state
root (`$HOME/.autonomous`), the target repo, or the orchestrator source tree —
for example an `XDG_CONFIG_HOME` pointed into one of them (FR-005).

**Rationale**: `$HOME/.config` is never mounted by any compose file (the state
root, the target repo, `/workspace` and, with `--with-login`, `~/.claude` are
the only host mounts). Keying by segment rather than by repo path reuses the
one identity the orchestrator already trusts: the same target gets the same
file from dev, console and release shapes, and two targets never share one.

**Alternatives considered**:
- Inside the state root (`~/.autonomous/instances/<segment>/volumes.toml`) —
  rejected: the state root is bind-mounted read-write, so sessions could read
  and edit it (clarification 2).
- In the target repo (`.autonomous/volumes.toml`) — rejected: travels with the
  repo, reachable by sessions in every worktree (clarification 1).
- Keyed by a hash of the repo path — rejected: a second identity derivation in
  shell; the wrapper header forbids recomputing identity outside Elixir.

## R2 — Declaration format

**Decision**: TOML, one array-of-tables entry per volume:

```toml
[[volume]]
name = "cargo-target"
path = "/var/lib/autonomous/volumes/cargo-target"
path_dirs = []                       # optional
[volume.env]                         # optional
CARGO_TARGET_DIR = "/var/lib/autonomous/volumes/cargo-target"
```

Parsed on the host with Python's stdlib `tomllib` (Python ≥ 3.11). See
`contracts/declaration-format.md`.

**Rationale**: the starter file must be commented (FR-005c) — JSON cannot
carry comments. `[[volume]]` keeps declaration order (FR-008a needs it) and,
unlike INI sections, lets two entries share a name so the duplicate is
*reported* (FR-006) rather than silently merged or rejected by the parser
before the other violations are collected (FR-009 "report all"). `python3` is
already a host requirement of the wrapper (`port_busy`, `free_port`, owner
record); `tomllib` is stdlib from 3.11.

**Alternatives considered**:
- JSON — no comments. YAML — no stdlib parser on the host or in Elixir.
- INI (`configparser`) — strict mode raises on the first duplicate section
  (can't report all), non-strict silently merges duplicates; nested `env`
  needs key-prefix hacks.
- A Python older than 3.11 on the host: the wrapper refuses by name
  (`volumes.toml needs python3 >= 3.11 (tomllib); found 3.9`) only when a
  declaration file exists — an operator with no declaration never needs it
  (FR-004).

## R3 — Where validation runs

**Decision**: a single stdlib-only host script, `scripts/volumes.py`, invoked
by the wrapper. It owns parsing, validation, starter-file generation, the
applied-overlay rendering and reset selection. All logic is pure functions
over (declaration text, context dict); the `main` shim does the I/O. Tested
from the default ExUnit suite through `System.cmd("python3", …)`, the pattern
`container_trust_step_test.exs` and `container_build_options_test.exs` already
use (hermetic: no docker, temp dirs only).

**Rationale**: FR-005/FR-005a require the declaration to be read on the host
and never enter a container. The Elixir code only runs inside the image (the
identity lookup is a bootstrap container), so validating in Elixir would mean
piping the declaration into a container. Elixir also has no stdlib TOML, and
the constitution bars adding a dependency for this.

**Alternatives considered**:
- Elixir pure module run through the bootstrap container with the declaration
  on stdin — rejected: the declaration's content enters a container (FR-005a)
  and needs a TOML dependency.
- Validation in POSIX `sh` inside the wrapper — rejected: path normalization,
  nesting checks and "report every violation" are fragile in `sh`, and
  untestable as pure functions.

Recorded in plan Complexity Tracking (host-side Python, not the Elixir pure
core).

## R4 — Volume storage, naming and scoping

**Decision**: one Docker named volume per entry per instance, created by the
wrapper with `docker volume create` **after** validation passes:

- name: `autonomous-<segment>_vol-<name>` (the Compose `<project>_<key>`
  shape, with a `vol-` key prefix that no orchestrator volume uses);
- labels: `dev.autonomous.kind=user-volume`, `dev.autonomous.segment=<segment>`,
  `dev.autonomous.volume=<name>`;
- referenced from the generated overlay as `external: true` with that `name:`.

Every removal path (reset, purge) selects by **exact name and matching
labels** — never by prefix (FR-022).

**Rationale**: `external: true` keeps `docker compose down` (plain `stop`) and
`down -v` from touching them implicitly; the wrapper decides removal
explicitly. Segment scoping gives FR-011; volumes survive container removal
and image rebuilds (FR-012). The dev, console and release services all belong
to project `autonomous-<segment>`, so every shape sees the same volumes
(FR-016, edge case "release and dev").

**Alternatives considered**:
- Compose-managed project volumes (non-external) — rejected: `down -v` would
  remove them only when the overlay happens to be passed to `stop`, and a
  no-longer-declared entry's volume would never be purged.
- Host bind mounts — out of scope (FR-015).

## R5 — Writable by the container user on first start

**Decision**: after creating the volumes and before `up`/`run`, the wrapper
runs one short provisioning container from the instance's own image as root:
`docker run --rm --user 0:0 --entrypoint /bin/sh -v <vol>:/v/<name> … <image>
-c '<chown roots not owned by UID:GID>'` — non-recursive, mount roots only,
idempotent, every start (FR-013). Skipped entirely when there are no entries.

**Rationale**: a fresh named volume's root is `root:root 0755`; services run as
`user: UID:GID` with no root, so the entrypoint cannot fix it. Docker copy-up
(image dir ownership copied to an empty volume) only happens when the mount
path already exists in the image, which the recommended
`/var/lib/autonomous/volumes/<name>` does not. Mounting at `/v/<name>` in the
provisioning container leaves the volume empty, so copy-up still happens at
the first real mount if the operator chose an image path that exists.

**Alternatives considered**:
- Pre-create `/var/lib/autonomous/volumes` in the Dockerfile owned by the user
  — only covers paths under that one parent; mount paths are free-form.
- `sudo chown` in the entrypoint — `sudo` exists only with `--agent-root`.
- `local` driver `o=uid=` — tmpfs only, not persistent.

## R6 — Delivering the applied result to the container

**Decision**: the wrapper writes a generated Compose overlay (JSON, which
Compose parses as YAML) to
`<config>/targets/<segment>/applied.compose.json` (host-only, atomic replace,
regenerated every start, never edited by hand) and adds it as a `-f` file to
`shell`/`console`/`release` starts only when ≥ 1 entry is declared. For each of
`dev`, `console`, `release` it adds:

- `volumes:` long syntax `{type: volume, source: <key>, target: <path>}`;
- `environment:` every declared variable, `PATH` (R7), `AUTONOMOUS_VOLUMES`
  (the applied set as compact JSON, for Configuration), and
  `AUTONOMOUS_VOLUME_PATH` (the colon-joined path directories, R7).

See `contracts/applied-volumes.md`.

**Rationale**: the container gets mounts and variables, never the declaration
file (FR-005a). Compose merges overlay `volumes` lists and `environment` maps
into the base services, the same mechanism `compose.claude-login.yaml` uses.
`environment:` beats `env_file: .env`, so a stray `.env` value cannot undo a
declared variable. Container-configured environment reaches the entrypoint,
the BEAM, every session (the launch env is merged over the inherited
environment — `PhaseRequest` adds only markers and timeouts) and
`docker compose exec` operator shells (FR-014).

**Alternatives considered**:
- `docker compose run -e/-v` flags — `up -d` (console/release) has no such
  flags.
- A temp file deleted after start — `shell` `exec`s into `docker compose`, so
  there is no "after"; a stable path is also inspectable.

## R7 — `PATH` prepending

**Decision**: the wrapper reads the image's `PATH` from
`docker image inspect -f '{{json .Config.Env}}' <image>` and sets
`PATH=<path_dirs in declaration order>:<image PATH>` in the overlay. In the dev
shape the entrypoint additionally re-prepends `$AUTONOMOUS_VOLUME_PATH` at VM
handover *inside* `mise exec` (which itself prepends the mise tool
directories), guarded so an unset/empty value changes nothing.

**Rationale**: Compose cannot reference the image's `PATH`, so it must be
materialized. `mise exec` would otherwise put mise tool directories ahead of
the kept directories for the BEAM and therefore every session; re-prepending
keeps FR-008a ("ahead of the image's own directories"). The image's entries
all remain. The release shape has no mise; the overlay value already holds.

**Alternatives considered**: prepend only in the entrypoint — the operator
shell (`docker compose exec`) does not run the entrypoint, so it would see a
different `PATH` (FR-014 requires the same).

## R8 — Overriding image variables (FR-008b)

**Decision**: the same `docker image inspect` output gives the image's
environment; every declared variable present there yields one notice line at
start: `autonomous: volume <name>: <VAR> overrides image value <old> with <new>`.
Allowed unless reserved (R9). Known image variables today: `MISE_DATA_DIR`,
`MISE_CACHE_DIR`, `MIX_HOME`, `HEX_HOME`, `PLAYWRIGHT_BROWSERS_PATH`,
`NODE_PATH`, `ANDROID_HOME`, `LANG`, `DEBIAN_FRONTEND`,
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`.

**Consequence documented, not managed**: overriding `MISE_DATA_DIR` hides
`/opt/mise`; in the dev shape `prepare_build`'s `mise exec` then installs the
orchestrator's own Erlang/Elixir into the volume on the first start (long,
once), and the volume keeps them afterwards. The release shape carries its own
ERTS and is unaffected.

## R9 — Reserved variable names

**Decision**: fixed list in `scripts/volumes.py` and in
`docs/container.md`:

- prefix `AUTONOMOUS_*`, prefix `RELEASE_*` (`rel/env.sh.eex`);
- `PATH`, `HOME`, `SHELL`, `USER`;
- start-sequence owned/relied on: `MIX_ENV`, `PHX_SERVER`,
  `COMPOSE_PROJECT_NAME`, `DISPLAY`, `GH_TOKEN`, `ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, `CLAUDE_CONFIG_DIR`,
  `MISE_TRUSTED_CONFIG_PATHS`, `MISE_YES`.

Name syntax: `^[A-Za-z_][A-Za-z0-9_]*$`.

**Rationale**: each listed variable is set by `compose.yaml`, the entrypoint,
the release env script, or read by the start sequence to decide credentials,
identity, build mode or trust (FR-008). Toolchain locations
(`MISE_DATA_DIR`, `MIX_HOME`, …) are deliberately *not* reserved
(clarification 7).

## R10 — Start output and FR-004 byte-identity

**Decision**: absent declaration file → the wrapper never runs
`scripts/volumes.py`, writes no overlay, prints nothing new. Present file with
zero entries → validated (malformed still refuses, FR-010), still no overlay,
no output. ≥ 1 entry → after `print_summary`:

```
autonomous: volumes  ~/.config/autonomous/targets/<segment>/volumes.toml
autonomous: volume   cargo-target -> /var/lib/autonomous/volumes/cargo-target (1 variable, 0 path dirs)
autonomous: volume <name>: MISE_DATA_DIR overrides image value /opt/mise with /var/lib/…
```

**Rationale**: reconciles FR-005 ("path printed by start output") with FR-004
/ SC-005 ("no new output" without a declaration): the path is printed whenever
anything was applied.

## R11 — Reset semantics

**Decision**: `scripts/autonomous reset-cache --target <repo> [--volume <name>]...`

1. identity lookup → segment; project `autonomous-<segment>`;
2. refuse (exit 75) if **any** container of the project exists
   (`docker ps -a --filter label=com.docker.compose.project=…`): a running one
   is named with `scripts/autonomous stop --target <repo>`; an exited one
   (detached console that died) still pins the volume, so the same refusal
   applies;
3. read the declaration — parse errors and invalid names refuse (exit 2); mount
   path/variable violations do **not** block a reset (the operator may be
   resetting precisely to fix things);
4. unknown `--volume` names refuse listing the declared names (exit 2), nothing
   removed;
5. per selected name: `docker volume inspect` → absent ⇒ `not present`;
   present with matching labels ⇒ `docker volume rm` ⇒ `removed`; present
   without our labels ⇒ refuse (exit 1) naming it — never removed.

No `--volume` = every declared entry. Exit 0 when every selected volume is
removed or absent (FR-021). Not-declared-but-present volumes are listed by
`volumes --target` as `kept, not declared` with the exact
`docker volume rm <name>` to run (edge case "entry removed").

## R12 — Full purge

**Decision**: `stop --purge` keeps `down -v` (orchestrator build volumes) and
then removes every volume labelled `dev.autonomous.kind=user-volume` **and**
`dev.autonomous.segment=<segment>`, declared or not; usage text says so
(FR-017). Plain `stop` touches no user volume.

## R13 — Configuration page and space used

**Decision**: pure `Autonomous.AppliedVolumes.parse/1` decodes
`AUTONOMOUS_VOLUMES` (unset/empty ⇒ `[]`; malformed ⇒ `{:error, reason}`,
rendered as a refusal line, never hidden). `Autonomous.VolumeUsage.measure/2`
runs `du -sk -x <path>` with a timeout (default 30 s) and returns
`{:ok, bytes} | {:unknown, reason}`. `ConfigLive` measures in
`start_async` on mount (page load; a reload re-measures), so a slow `du` on an
81 GB tree never blocks the page. Pure `Autonomous.Web.VolumesView` shapes rows
(`:hidden` when empty → nothing rendered, FR-023). Unknown size renders
`unknown (<reason>)`, never `0`.

**Alternatives considered**: Elixir recursive `File.stat` walk — slower and
heap-heavy on millions of files; caching sizes — the spec says measured when
the page loads.

## R14 — Smoke checks

**Decision**: new `scripts/container-smoke.sh volumes` subcommand (hand-run, not
in the suite), using a throwaway git repo target and `XDG_CONFIG_HOME` in a temp
dir: persistence across restart, isolation across two targets, each rejected
class (name, path, variable, path dir, malformed file) leaving no container
and no volume, reset (by name, all, running refusal, unknown name,
idempotence), purge. Needs the GNU tooling noted in the macOS smoke memory.
