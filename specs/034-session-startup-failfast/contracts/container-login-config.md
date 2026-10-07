# Contract: Container CLI Config Isolation (US2)

Applies only to `scripts/autonomous … --with-login`
(`compose.claude-login.yaml`). Token-only modes are unchanged (FR-018).

## Mounts

```yaml
services:
  dev:
    volumes: &login-mounts
      - "${HOME}/.claude:/home/autonomous/.claude"                    # unchanged, rw
      - "${HOME}/.claude.json:/home/autonomous/.claude.host.json:ro" # was: rw at ~/.claude.json
  console:
    volumes: *login-mounts
```

`scripts/autonomous` keeps its existing precondition (`$HOME/.claude` and
`$HOME/.claude.json` must exist on the host).

## Entrypoint seeding (`scripts/container-entrypoint.sh`)

The seeding runs before the credentials warning (§5) and before the BEAM
starts.

| Condition | Behavior |
|---|---|
| `/home/autonomous/.claude.host.json` absent | No-op (token mode) |
| Seed parses as a JSON object (within ≤ 5 attempts, 200 ms apart) | Write to `$HOME/.claude.json.tmp.$$`, `chmod 600`, then `mv` atomically to `$HOME/.claude.json` |
| Seed still invalid after 5 attempts | `die "host CLI config <seed path> is not valid JSON: <parser message>"` (non-zero exit, FR-016) |
| `$HOME/.claude.json` is itself a mount point (old compose override in use) | `die` naming the stale mount and the fix |

## Guarantees

- **G1.** No orchestrator session reads a file that a host process is
  writing. The container's `~/.claude.json` is a private copy (FR-014).
- **G2.** Container writes to `~/.claude.json` never reach the host (FR-017).
- **G3.** Authentication and per-project trust present on the host at
  container start apply to every session (FR-015). Host changes made later
  need a container restart (documented in `docs/container.md`, FR-019).

## Smoke (`scripts/container-smoke.sh`)

| Check | Spend |
|---|---|
| Valid seed → `$HOME/.claude.json` is a regular file, not a mount, and byte-equal to the seed | none |
| Invalid seed (`{`) → entrypoint exits non-zero, and the message names the seed path | none |
| `SMOKE_AGENT=1`: `claude -p` succeeds with the seed mount plus `~/.claude` (replaces the old direct-mount check) | a few cents |
