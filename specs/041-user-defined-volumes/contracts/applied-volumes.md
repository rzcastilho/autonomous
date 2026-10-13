# Contract: Applied result → container (overlay, env, entrypoint)

## `scripts/volumes.py` interface (host, stdlib only)

```
python3 scripts/volumes.py plan   --declaration <file> --context <json>   # stdout: plan JSON | stderr: violations, exit 2
python3 scripts/volumes.py show   --declaration <file> --context <json> [--present <json>]
python3 scripts/volumes.py init   --declaration <file>
python3 scripts/volumes.py select --declaration <file> [--volume <name>]...  # reset selection
```

`--context`: `{"repo","worktree_root","state_root","segment","uid","gid","image_env":[ "K=V", … ]}`.

`plan` stdout (consumed by the wrapper only):

```json
{"volumes":[{"name","path","docker_name","env":[[k,v]],"path_dirs":[]}],
 "notices":["volume mise-data: MISE_DATA_DIR overrides image value /opt/mise with /var/lib/…"],
 "overlay":{ …compose overlay below… }}
```

Pure core: `parse(text)`, `validate(decl, ctx) -> [violation]`,
`plan(decl, ctx) -> dict`, `starter() -> str`, `select(decl, names)`. Unit
tested via `System.cmd("python3", …)` from ExUnit.

## Compose overlay (`applied.compose.json`)

```json
{
  "services": {
    "dev":     {"volumes": [V…], "environment": E},
    "console": {"volumes": [V…], "environment": E},
    "release": {"volumes": [V…], "environment": E}
  },
  "volumes": {
    "vol-cargo-target": {"external": true, "name": "autonomous-<segment>_vol-cargo-target"}
  }
}
```

- `V` = `{"type":"volume","source":"vol-<name>","target":"<path>"}`.
- `E` = declared variables (declaration order) + `"PATH": "<dirs>:<image PATH>"`
  (only when ≥ 1 path dir) + `"AUTONOMOUS_VOLUMES": "<applied set JSON>"` +
  `"AUTONOMOUS_VOLUME_PATH": "<dirs>"` (only when ≥ 1 path dir).
- Written atomically (`tmp` + rename), `0600`, regenerated every start.

## Entrypoint (`scripts/container-entrypoint.sh`)

Only change — VM handover in the dev shape:

```sh
# when AUTONOMOUS_VOLUME_PATH is non-empty, re-prepend it inside `mise exec`
exec mise exec -- sh -c 'PATH="$AUTONOMOUS_VOLUME_PATH:$PATH"; exec "$@"' sh iex …    # shell
exec mise exec -- sh -c 'PATH="$AUTONOMOUS_VOLUME_PATH:$PATH"; exec "$@"' sh elixir … # console
```

The inner `sh` expands `$PATH` *after* `mise exec` has set it; an outer
`env PATH="…:$PATH"` would expand before mise and drop the mise tool directories.
Smoke hook: `container-entrypoint.sh vm-handover <cmd…>` (stubbed `mise` in tests).

Unset/empty → today's exact commands. `prepare_build`, trust, agent root,
identity, lock: unchanged. Release shape: unchanged (overlay `PATH` holds).

## Session visibility (FR-014)

Container env → entrypoint → BEAM → `claude` CLI (launch env merged over the
inherited environment) → every phase, implement chunk, remediation and PR
describe session; operator shell via `docker compose exec` sees the container
env directly. `PhaseRequest`, tool set, permission mode, exclusions, deadlines:
unchanged (FR-025).
