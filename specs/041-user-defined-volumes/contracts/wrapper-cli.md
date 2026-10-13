# Contract: Wrapper CLI changes (`scripts/autonomous`)

Extends `specs/031-containerized-runtime/contracts/wrapper-cli.md`. Exit codes
keep their meaning: 2 usage / invalid declaration, 4 target not a git repo, 5
image not built, 75 instance running/served.

## New: `volumes --target <repo> [--init]`

Needs the dev image (identity lookup). Changes nothing unless `--init`.

Without `--init` (FR-005b), stdout:

```
autonomous: declaration /home/op/.config/autonomous/targets/<segment>/volumes.toml
autonomous: volume cargo-target  /var/lib/autonomous/volumes/cargo-target  present
autonomous:   CARGO_TARGET_DIR=/var/lib/autonomous/volumes/cargo-target
autonomous: volume old-cache  kept, not declared — remove with: docker volume rm autonomous-<segment>_vol-old-cache
autonomous: declaration valid (2 volumes)
```

- File absent → path + `no declaration (create one with --init)`, exit 0.
- Invalid → entries as parsed, then the violation lines; exit 2.
- Works whether or not the instance runs.

With `--init` (FR-005c): creates the starter file, prints its path, exit 0;
existing file → `autonomous: <path> already exists; not changed`, exit 1.

## New: `reset-cache --target <repo> [--volume <name>]...`

Algorithm: `research.md` R11. Output:

```
autonomous: cargo-target removed
autonomous: rust-toolchains not present
```

| Case | Exit | Effect |
|---|---|---|
| all selected removed / absent | 0 | as reported |
| container of the instance exists | 75 | `target <repo> is served by <container>; stop it first: scripts/autonomous stop --target <repo>` — nothing removed |
| unknown `--volume` | 2 | `volume x is not declared; declared: a, b` — nothing removed |
| no declaration / zero entries | 0 | `no declared volumes` |
| malformed file, invalid name | 2 | violation lines — nothing removed |
| present volume without our labels | 1 | named, never removed |

`--volume` repeatable; `--volume=<name>` accepted; only valid for `reset-cache`.

## Changed: `shell` / `console` / `release`

Sequence (new steps marked ★), each start:

1. resolve target, require image, identity lookup (unchanged; transient
   bootstrap container, serves no session);
2. ★ if the declaration file exists: `volumes.py plan` with context (repo,
   worktree root, state root, segment, UID/GID, image env JSON). Violations →
   exit 2 before step 4; nothing created;
3. live-instance check, choose port, `print_summary` (unchanged);
4. ★ when ≥ 1 entry: `docker volume create` each (labels per data-model),
   provisioning container (R5), write `applied.compose.json`, append
   `-f <overlay>`, print volume lines + override notices (R10);
5. `up -d` / `run` (unchanged otherwise).

No declaration / zero entries: steps 2★ (absent: skipped) and 4★ produce no
output, no files, no docker calls — byte-identical to today (FR-004, SC-005).

## Changed: `stop --purge`

After `down -v`, removes every volume with labels
`dev.autonomous.kind=user-volume` and `dev.autonomous.segment=<segment>`,
printing `autonomous: <volume> removed`. Usage line becomes:
`stop --target <repo> [--purge]   stop the instance; --purge also removes build volumes and declared volumes`.
Plain `stop` unchanged.

## Usage text

Adds:

```
  volumes --target <repo> [--init]       print the target's volume declaration path, entries and
                                         validation result; --init writes a commented starter file
  reset-cache --target <repo> [--volume <name>]...
                                         remove declared volumes of a stopped instance (all when no
                                         --volume)
```
