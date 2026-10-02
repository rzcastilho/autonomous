# Contract: `scripts/autonomous`

The only documented entry point for operating the orchestrator (FR-003). POSIX
shell, run from the repository root. Requires Docker Engine + Compose v2 on Linux.

## Commands

| Command | Effect | Compose call |
|---|---|---|
| `build [--web] [--desktop] [--android] [--release]` | Build `autonomous-dev:local` (and `autonomous-release:local` with `--release`) with host UID/GID and the chosen capabilities | `docker compose build dev [release]` with `--build-arg UID GID WITH_*` |
| `shell --target <path> [--port <n>]` | Interactive `iex` with the operator API and the console served | `docker compose -p autonomous-<segment> run --rm --service-ports dev shell` |
| `console --target <path> [--port <n>]` | Detached `mix phx.server` | `docker compose -p … up -d console` |
| `release --target <path> [--port <n>]` | Detached release instance | `docker compose -p … up -d release` |
| `remote --target <path>` | Remote console into a running release | `docker compose -p … exec release bin/autonomous remote` |
| `port --target <path>` | Print the console address of a running instance | `docker compose -p … port <service> 4000` |
| `stop --target <path> [--purge]` | Stop and remove the instance containers (state root untouched); `--purge` also removes the target's build volumes | `docker compose -p … down [-v]` |
| `test [mix test args]` | Run the suite inside the dev image | `docker compose run --rm dev mise exec -- mix test …` |

Common options: `--with-login` mounts the host agent login (adds
`compose.claude-login.yaml`); `--android` / `--viewer` at start add
`compose.android.yaml` / `compose.desktop-viewer.yaml`.

`--target` is required for every instance command and is resolved with `realpath`;
it becomes both the bind-mount source and target and `AUTONOMOUS_REPO`. The segment
for the Compose project name is obtained from the image, never computed in shell.

**Segment lookup.** Before any instance command, the wrapper runs a one-off container
under a fixed bootstrap project. `AUTONOMOUS_REPO` and `AUTONOMOUS_ROOT` are exported
first, so the service's own same-path mounts (compose-services.md) bring the target in:

```sh
AUTONOMOUS_REPO="$target" AUTONOMOUS_ROOT="$HOME/.autonomous" \
  docker compose -p autonomous-bootstrap run --rm --no-deps -T dev segment
```

The entrypoint's `segment` command (compose-services.md) prepares the build if needed,
prints the bare segment and exits; it takes no lock and starts no VM. The wrapper then
uses `autonomous-<segment>` as the project name. For `release`/`remote`, the same lookup
runs against the release image (`release segment`, which uses `bin/autonomous eval`).
The bootstrap project's build volumes are separate from the per-target ones, so the
first lookup compiles once into `autonomous-bootstrap_*` and later lookups are fast.

**Images.** `build` tags fixed names (`autonomous-dev:local`, and with `build --release`
`autonomous-release:local`) that every project reuses; instance commands never build.
A missing image exits 5 naming `scripts/autonomous build`.

## Output

On start, the wrapper prints, in this order:

```text
autonomous: target   /home/op/code/ledgerlite
autonomous: instance autonomous_ledgerlite-3fa9c1@autonomous
autonomous: console  http://127.0.0.1:49213/
autonomous: budget   per instance (AUTONOMOUS_BUDGET_USD=25.0); total spend is the sum across running instances
```

plus entrypoint warnings (no agent credentials; model pins unset).

## Exit codes and messages

| Code | When | Message (prefix `autonomous:`) |
|---|---|---|
| 0 | success | — |
| 2 | usage error / missing `--target` | `usage: …` |
| 3 | not Docker Compose v2 | `Docker Compose v2 is required (found: …); other engines are unsupported` |
| 4 | target not a git repository | `target <path> is not a git repository` |
| 5 | image not built | `image <name> not found; run scripts/autonomous build` |
| 75 | target already served | `target <path> is already served by <project>/<service> since <started_at>` |
| 76 | requested console port busy | `console port <n> is already in use on 127.0.0.1` |
| other | propagated from Docker | Docker's message |
