# Data Model: Always-Containerized Runtime

No Mnesia schema change. The entities below are runtime values and on-disk files.

## Instance identity (`Autonomous.Instance`)

Derived purely from `(partition, state_root)`; see
[contracts/instance-identity.md](contracts/instance-identity.md).

| Field | Type | Rule |
|---|---|---|
| `repo` | absolute path | `Path.expand(Config.repo())`; host absolute path, mounted at the same path |
| `partition` | string | `RepoIdentity.partition(repo)` — `"o:<seg>"` or `"l:<seg>"` |
| `segment` | string | partition without prefix |
| `node_name` | atom | `:"autonomous_<sanitized segment>@autonomous"` |
| `store_dir` | absolute path | `<state_root>/instances/<segment>/mnesia` |
| `lock_path` | absolute path | `<state_root>/instances/<segment>/instance.lock` |
| `owner_path` | absolute path | `<state_root>/instances/<segment>/instance.json` |
| `cookie_path` | absolute path | `<state_root>/instances/<segment>/cookie` |

Validation (at boot, container mode only, `Instance.verify!/0`):

- `node() == node_name`, else `{:instance_mismatch, :node, expected, actual}`
- `Config.store_dir() == store_dir`, else `{:instance_mismatch, :store_dir, …}`
- `AUTONOMOUS_INSTANCE_LOCKED == lock_path`, else `{:instance_unlocked, lock_path}`

Invariant: same target ⇒ same identity across restart, removal, recreation and image
rebuild; different targets ⇒ different `segment` (collision only on a 24-bit hash
clash of two repos with the same name, already accepted by `Layout`).

## Owner record (`instance.json`)

Written by the entrypoint after `flock` succeeds; read only to name the live instance
in a refusal. Not authoritative (the kernel lock is).

| Key | Example |
|---|---|
| `segment` | `ledgerlite-3fa9c1` |
| `repo` | `/home/op/code/ledgerlite` |
| `compose_project` | `autonomous-ledgerlite-3fa9c1` |
| `service` | `dev` / `console` / `release` |
| `started_at` | ISO-8601 UTC |
| `console_port` | host port or `null` |
| `image` | image id |

## State root layout (host `~/.autonomous`, shared)

```text
~/.autonomous/
├── mnesia/                       # pre-031 host store — never opened, never deleted (FR-020)
├── instances/<segment>/          # NEW, one per target
│   ├── mnesia/                   # per-target store
│   ├── instance.lock             # flock target
│   ├── instance.json             # owner record
│   └── cookie                    # 0600, distribution cookie
├── worktrees/<segment>/…         # unchanged (Layout)
├── transcripts/<segment>/…       # unchanged (Layout)
└── exports/…                     # unchanged
```

## Run shape

| Shape | Compose service | Starts | Source | Console |
|---|---|---|---|---|
| dev shell | `dev` (`run --service-ports`) | `iex --sname … -S mix` with endpoint served | bind mount `/workspace` | yes |
| dev console | `console` | `mix phx.server` | bind mount | yes |
| release | `release` | `bin/autonomous start` | none | yes |

## Credentials set (`.env`, run time only)

`ANTHROPIC_API_KEY` | `CLAUDE_CODE_OAUTH_TOKEN` | mounted login (opt-in); `GH_TOKEN`;
`GIT_AUTHOR_*`, `GIT_COMMITTER_*`; `ANTHROPIC_DEFAULT_*_MODEL`;
`AUTONOMOUS_SECRET_KEY_BASE`. Full list: [contracts/environment.md](contracts/environment.md).

## Testing capability

| Capability | Build arg | Runtime switch | Compose override |
|---|---|---|---|
| web | `WITH_WEB=1` | — (browsers at `/opt/ms-playwright`) | — |
| desktop | `WITH_DESKTOP=1` | `AUTONOMOUS_DISPLAY=1`, `AUTONOMOUS_DISPLAY_VIEWER=1` | `compose.desktop-viewer.yaml` |
| android | `WITH_ANDROID=1` | `ADB_SERVER_SOCKET` (host fallback) | `compose.android.yaml` (`/dev/kvm`) |

## State transitions: instance start

```text
wrapper: resolve target realpath ─▶ build (if needed) ─▶ compose up/run
entrypoint: derive identity ─▶ flock -n ──fail──▶ exit 75 "already served by …"
                                  │ok
                                  ▼
            write instance.json, cookie (if absent), git/gh setup, warnings, Xvfb (opt)
                                  ▼
            exec VM (fd 9 inherited)
app: ContainerGuard.check! ─▶ retired settings ─▶ Instance.verify! ─▶ Store.Boot ─▶ children
                 │fail                                  │fail
                 ▼                                      ▼
          raise, store untouched              raise, store untouched
```
