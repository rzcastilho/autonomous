# Quickstart: User-Defined Persistent Volumes (041)

Validation guide (FR-028): three real targets on three stacks, each end to end.
Format: `contracts/declaration-format.md`. CLI: `contracts/wrapper-cli.md`.
Configuration group: `contracts/configuration-surface.md`.

## Prerequisites

- Image built: `scripts/autonomous build` (add `--release` for the release shape).
- Host `python3 >= 3.11` (only needed once a declaration exists).
- Targets checked out as siblings: `../mod-player`, `../fretboard-master`, this repo.
- Hermetic suite green first: `mise exec -- mix test`.

Recommended mount parent: `/var/lib/autonomous/volumes/<name>`.

Worktrees are unchanged (FR-025a): they stay host directories under the
bind-mounted state root (`~/.autonomous/worktrees/<segment>/…`), so their
contents already persist between phases and restarts. Declare volumes only for
data you want *outside* the worktree (toolchains, caches, build output).

---

## A. mod-player (Rust: toolchains + build output) — the r000003 incident

```sh
scripts/autonomous volumes --target ../mod-player --init
# autonomous: wrote ~/.config/autonomous/targets/<segment>/volumes.toml
scripts/autonomous volumes --target ../mod-player --init    # refuses, file unchanged (exit 1)
```

Edit the printed file:

```toml
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

```sh
scripts/autonomous volumes --target ../mod-player           # entries, "absent", "declaration valid (2 volumes)"
scripts/autonomous console --target ../mod-player
```

Expected start output (after target/instance/console lines):

```
autonomous: volumes  ~/.config/autonomous/targets/<segment>/volumes.toml
autonomous: volume   rust-toolchains -> /var/lib/autonomous/volumes/rust-toolchains (2 variables, 1 path dir)
autonomous: volume   cargo-target -> /var/lib/autonomous/volumes/cargo-target (1 variable, 0 path dirs)
```

Verify in an operator shell (`docker compose -p autonomous-<segment> exec console bash`):

```sh
echo "$CARGO_TARGET_DIR"; echo "$PATH" | cut -d: -f1   # declared value; .../cargo/bin first
touch "$CARGO_TARGET_DIR/probe" && ls -ld "$CARGO_TARGET_DIR"   # owned by the container user
curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none
cd ../mod-player && cargo build --workspace                   # installs 1.95.0 from rust-toolchain.toml
```

Open Configuration: the "declared volumes" group lists both, "as applied at
start", with space used (cargo-target grows after reload).

Persistence:

```sh
scripts/autonomous stop --target ../mod-player
scripts/autonomous console --target ../mod-player
# in the shell: probe still present; `cargo build --workspace` does no rebuild work (SC-001)
git -C ../mod-player status --short; ls ../mod-player/target 2>/dev/null   # no new build output (SC-002)
```

Reset:

```sh
scripts/autonomous reset-cache --target ../mod-player          # exit 75: running, names stop command
scripts/autonomous stop --target ../mod-player
scripts/autonomous reset-cache --target ../mod-player --volume cargo-target   # "cargo-target removed"
scripts/autonomous reset-cache --target ../mod-player --volume cargo-target   # "not present", exit 0
scripts/autonomous reset-cache --target ../mod-player --volume nope           # exit 2, lists declared
```

Next start: toolchain kept, `cargo-target` empty.

---

## B. fretboard-master (Node + pnpm: package store, mise-managed node)

```toml
[[volume]]
name = "mise-data"
path = "/var/lib/autonomous/volumes/mise-data"
env = { MISE_DATA_DIR = "/var/lib/autonomous/volumes/mise-data" }

[[volume]]
name = "pnpm-store"
path = "/var/lib/autonomous/volumes/pnpm-store"
env = { npm_config_store_dir = "/var/lib/autonomous/volumes/pnpm-store" }
```

Start output adds one notice (FR-008b):

```
autonomous: volume mise-data: MISE_DATA_DIR overrides image value /opt/mise with /var/lib/autonomous/volumes/mise-data
```

Expect the first dev-shape start to reinstall the orchestrator's own
Erlang/Elixir into `mise-data` (long, once — research R8); the release shape
skips it. Verify: `pnpm store path` prints the declared store;
`pnpm install` in a worktree, restart, `pnpm install --offline` succeeds.
Reset `pnpm-store` alone and confirm `mise-data` is unchanged.

---

## C. autonomous (Elixir: mise data, Mix/Hex caches, deps, build output)

```toml
[[volume]]
name = "mise-data"
path = "/var/lib/autonomous/volumes/mise-data"
env = { MISE_DATA_DIR = "/var/lib/autonomous/volumes/mise-data" }

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

Three override notices at start (`MISE_DATA_DIR`, `MIX_HOME`, `HEX_HOME`).
`MIX_DEPS_PATH`/`MIX_BUILD_ROOT` are shared by every worktree of the instance —
fine for a sequential run (one feature at a time); reset `mix-build` if a
branch switch leaves stale artefacts. Verify: `mix hex.info` works offline
after restart; `mix compile` in a worktree after restart compiles nothing new.

---

## Python snippet (docs only)

```toml
[[volume]]
name = "python"
path = "/var/lib/autonomous/volumes/python"
path_dirs = ["/var/lib/autonomous/volumes/python/venv/bin"]
[volume.env]
VIRTUAL_ENV = "/var/lib/autonomous/volumes/python/venv"
PIP_CACHE_DIR = "/var/lib/autonomous/volumes/python/pip-cache"
```

---

## Rejections (US2) — each exits 2, no container, no volume

| Edit | Expected line |
|---|---|
| two entries `name = "a"` | `entries a, a: duplicate name a` |
| `name = "Cargo Target"` | `name must be a lowercase slug …` |
| `path = "cache"` | `path cache is not absolute` |
| `path = "/workspace/x"` | `… is inside /workspace (orchestrator source)` |
| `path` = target repo path | `… collides with the target repo` |
| nested paths across entries | names both entries |
| `env = { PATH = "/x" }` / `AUTONOMOUS_X` / `GH_TOKEN` | `PATH is reserved` |
| same var in two entries | names both + variable |
| `path_dirs = ["/usr/bin"]` | `… is outside this entry's path` |
| `path = "/a:b"` | `contains ':'` |
| `[[volume` (broken TOML) | `not valid TOML: …` |

After each: `docker ps -a --filter label=com.docker.compose.project=autonomous-<segment>`
and `docker volume ls --filter label=dev.autonomous.segment=<segment>` show
nothing new.

## Isolation and purge

Declare `cargo-target` in two targets; write in one, the other's stays empty.
`stop --purge` on one removes its declared volumes (says so) and leaves the
other target's untouched.

## No declaration (SC-005)

Remove/rename the file; start output is byte-identical to before (apart from
port/timestamp); Configuration has no volumes group; `mise exec -- mix test`
passes unchanged.

## Smoke

`scripts/container-smoke.sh volumes` automates the persistence, isolation,
rejection, reset and purge checks above against a throwaway target.
