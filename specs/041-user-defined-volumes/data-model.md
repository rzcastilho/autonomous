# Data Model: User-Defined Persistent Volumes (041)

No Mnesia change. No store schema bump. Every entity below lives either in a
host-only file, in the container engine, or in the container environment.

## Volume declaration (host file)

| Field | Value |
|---|---|
| Path | `${XDG_CONFIG_HOME:-$HOME/.config}/autonomous/targets/<segment>/volumes.toml` |
| Owner | the operator; created by `volumes --init` (mode `0600`, dir `0700`) or by hand |
| Read by | `scripts/autonomous` → `scripts/volumes.py`, on the host, at start / `volumes` / `reset-cache` |
| Never | mounted into a container; inside the state root, target repo, or source tree |
| States | **absent** (no volumes, FR-004) · **empty** (parses, zero `[[volume]]`; same as absent) · **valid** (≥ 1 entry, no violation) · **invalid** (≥ 1 violation; start refused) · **malformed** (unreadable / not TOML / wrong shape; start refused naming the file) |

Top level: only the key `volume` (array of tables) is allowed; any other key is
a violation (catches typos like `[[volumes]]`).

## Volume entry

| Field | Type | Required | Rules (FR) |
|---|---|---|---|
| `name` | string | yes | `^[a-z0-9][a-z0-9-]*$`, ≤ 63 chars; unique in the declaration (FR-006) |
| `path` | string | yes | absolute; normalized (no `.`/`..` segments, no `//`, no trailing `/`); no `:` `,` or control characters; not `/`; not equal to / inside / parent of any **protected path**; not equal to / nested with another entry's `path` (FR-007) |
| `env` | table string→string | no | key `^[A-Za-z_][A-Za-z0-9_]*$`; not reserved (R9); not set by another entry; value a string without NUL/newline (FR-008) |
| `path_dirs` | array of strings | no | each absolute, normalized, equal to or inside this entry's `path` (FR-008a) |

Unknown keys in an entry are violations. Order of entries is significant
(`PATH` order, output order).

### Protected paths (FR-007)

Supplied to the validator as context by the wrapper:

| Path | Source |
|---|---|
| target repo | `AUTONOMOUS_REPO` (same absolute path inside and outside) |
| worktree root | `AUTONOMOUS_WORKTREE_ROOT` from identity lookup |
| state root | `$HOME/.autonomous` (`AUTONOMOUS_ROOT`) |
| orchestrator source / build | `/workspace`, `/workspace/_build`, `/workspace/deps` |
| application install | `/app` |
| agent configuration | `/home/autonomous/.claude`, `/home/autonomous/.claude.json`, `/home/autonomous/.claude.host.json` |

"Parent of" makes `/`, `/home`, `/home/autonomous` refused automatically.

### Violation

```
{entry: <name or "#<index>" when name missing/invalid>, field, reason, detail}
```

Rendered one per line, all of them (FR-009):
`autonomous: volumes.toml: entry cargo-target: path /workspace/target is inside /workspace (orchestrator source)`.
Malformed file: one line naming file + parser message (FR-010).

## Instance volume (container engine)

| Attribute | Value |
|---|---|
| Name | `autonomous-<segment>_vol-<name>` |
| Labels | `dev.autonomous.kind=user-volume`, `dev.autonomous.segment=<segment>`, `dev.autonomous.volume=<name>` |
| Created | by the wrapper after validation, at start (`docker volume create`, idempotent) |
| Root ownership | `UID:GID` (provisioning step, every start) |
| Removed | only by `reset-cache` (declared, labels match) or `stop --purge` (labels match segment) |
| Reported as | `present` / `absent` (`volumes`), `removed` / `not present` (`reset-cache`), `kept, not declared` (present with segment label, not in declaration) |

Lifecycle: `absent → present` (start) → `present` (stop / start / image
rebuild) → `absent` (reset or purge) → `present` (next start, empty).

## Applied volume set (container environment)

`AUTONOMOUS_VOLUMES` — compact JSON, written by `scripts/volumes.py` into the
overlay, decoded by `Autonomous.AppliedVolumes`:

```json
{"version":1,"declaration":"/home/op/.config/autonomous/targets/mod-player-906276/volumes.toml",
 "volumes":[{"name":"cargo-target","path":"/var/lib/autonomous/volumes/cargo-target",
             "env":[["CARGO_TARGET_DIR","/var/lib/autonomous/volumes/cargo-target"]],
             "path_dirs":[]}]}
```

`env` is an ordered list of pairs (declaration order). Unset or empty ⇒ no
volumes. Unknown `version` or bad shape ⇒ `{:error, reason}`.

`AUTONOMOUS_VOLUME_PATH` — the path directories joined with `:`, in order; set
only when non-empty.

Elixir struct (pure):

```elixir
%Autonomous.AppliedVolumes.Volume{
  name: String.t(), path: String.t(),
  env: [{String.t(), String.t()}], path_dirs: [String.t()]
}
```

## Configuration view state

`Autonomous.Web.VolumesView.state/2(applied, usage)`:

- `:hidden` — `applied == []` → nothing rendered (FR-023);
- `{:refused, reason}` — `AUTONOMOUS_VOLUMES` unreadable → one refusal line;
- `{:rows, declaration_path, [row]}` with
  `row = %{name, path, env, path_dirs, usage}` and
  `usage :: :measuring | {:ok, bytes} | {:unknown, reason}`.

Usage text: `:measuring` → `measuring`, `{:ok, b}` → human size + exact KiB,
`{:unknown, r}` → `unknown (<r>)`; never `0` for unknown.
