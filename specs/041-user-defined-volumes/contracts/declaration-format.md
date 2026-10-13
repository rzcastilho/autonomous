# Contract: Volume Declaration Format (`volumes.toml`)

Host-only, one per target, at
`${XDG_CONFIG_HOME:-$HOME/.config}/autonomous/targets/<segment>/volumes.toml`.
Parsed by `scripts/volumes.py` with Python ≥ 3.11 `tomllib`. Field rules:
`data-model.md` → Volume entry. Reserved names: `research.md` R9.

## Shape

```toml
# Any number of entries; order matters (PATH order, output order).

[[volume]]
name = "rust-toolchains"                              # lowercase slug, unique
path = "/var/lib/autonomous/volumes/rust-toolchains"  # absolute container path
path_dirs = ["/var/lib/autonomous/volumes/rust-toolchains/cargo/bin"]  # optional
[volume.env]                                          # optional
RUSTUP_HOME = "/var/lib/autonomous/volumes/rust-toolchains/rustup"
CARGO_HOME  = "/var/lib/autonomous/volumes/rust-toolchains/cargo"

[[volume]]
name = "cargo-target"
path = "/var/lib/autonomous/volumes/cargo-target"
env = { CARGO_TARGET_DIR = "/var/lib/autonomous/volumes/cargo-target" }
```

- Only top-level key: `volume`. Entry keys: `name`, `path`, `env`, `path_dirs`.
- `env` values are literal strings — no `$VAR` expansion.
- Empty file, comments only, or `volume = []` ⇒ no volumes.

## Starter file (`volumes --init`)

Comment-only (zero active entries), containing: what the file is and that
sessions never see it; the field rules in one line each; the reserved list;
the recommended `/var/lib/autonomous/volumes/<name>` parent; commented worked
examples for Rust, Node + pnpm, Elixir and Python. Written atomically with
`0600` (directory `0700`); refused (exit 1, file unchanged) when the file
exists.

## Validation output

All violations, one line each, then a summary; exit 2; nothing created.

```
autonomous: /home/op/.config/autonomous/targets/t-1a2b/volumes.toml: 3 problems
autonomous:   entry Cargo Target: name must be a lowercase slug (a-z, 0-9, '-', starting with a letter or digit)
autonomous:   entry cache: path cache is not absolute
autonomous:   entries a, b: both set CARGO_HOME
autonomous: nothing was started; fix the declaration and retry
```

Malformed: `autonomous: <path>: not valid TOML: <parser message>` (exit 2).
Old Python: `autonomous: <path> needs python3 >= 3.11 (tomllib); found <v>` (exit 2).
