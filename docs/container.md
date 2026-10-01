# Containerized runtime

Feature 031. A Docker container is the only supported way to *operate* the
orchestrator; `mix compile` and `mix test` still run on the host. Entry point:
`scripts/autonomous` (contract: `specs/031-containerized-runtime/contracts/wrapper-cli.md`).
Day-to-day flow is in [runbook.md](runbook.md); this page holds the details behind it.

## State, identity and the same-path rule

- **One instance per target.** Node name, store directory, lock and cookie are derived
  from the target's `RepoIdentity` in `Autonomous.Instance` (never in shell) and live under
  `~/.autonomous/instances/<segment>/`. Same target ⇒ same identity across stop, remove,
  recreate and image rebuild.
- **Same-path mounts.** The target repository and `~/.autonomous` are mounted at the *same
  absolute path* inside and outside the container. `git worktree` records absolute paths;
  with the same path on both sides, `git -C <target> worktree list` is valid from the host
  and from the container. Do not move the target or the state root while an instance holds
  worktrees.
- **Fixed host name.** Every service sets `hostname: autonomous`, the host part of the
  Erlang node name. `Instance.verify!/0` refuses an ad hoc `--sname` (or a VM that is not
  distributed) before Mnesia opens.
- **Second instance refused.** The entrypoint takes `flock -n` on `instance.lock`; the VM
  inherits the descriptor, so the kernel holds the lock exactly as long as the VM lives (a
  crash or `docker rm -f` releases it). A second instance for the same target exits **75**
  naming the live one (`<project>/<service> since <started_at>`, read from `instance.json`).
  `instance.json` is informational; the kernel lock is authoritative.
- **`flock` limit.** `flock` is only reliable on a local filesystem. Keep `~/.autonomous` on
  a local disk; on NFS/SMB/FUSE mounts the lock may not exclude a second instance.
  Local-disk Docker bind mounts (the default) are fine.

### Fresh store (FR-020)

The per-target store is new: `~/.autonomous/instances/<segment>/mnesia`. The pre-031 host
store `~/.autonomous/mnesia` is **neither read nor deleted**. History written before 031 is
not visible to the containerized instance; delete the old directory yourself when you no
longer need it. Worktrees (`worktrees/<segment>/`), transcripts and exports keep their
locations and stay valid.

### Working-directory audit (R6)

The legacy default `Config.worktree_root/0` (`../.speckit-worktrees`, relative to the
working directory) is reachable only through `Worktree.create/2` without a layout
(test/legacy path). Every live caller in `lib/autonomous.ex` passes the run's `%Layout{}`,
whose `worktree_root` and `transcript_root` are absolute paths under the state root. No live
write path depends on the container's `cwd` (`/workspace`).

## Release shape

`scripts/autonomous build --release` builds `autonomous-release:local`: a `mix release` on
the base image (git, `gh`, the agent CLI) with no mise, no Erlang/Elixir install and no
sources at runtime.

```bash
scripts/autonomous release --target ../ledgerlite    # detached
scripts/autonomous remote  --target ../ledgerlite    # remote console (iex) into it
scripts/autonomous port    --target ../ledgerlite    # console address
```

- **Secret.** The release refuses to start without `AUTONOMOUS_SECRET_KEY_BASE` (≥ 64
  bytes), naming the variable. Generate one and put it in `.env` (git-ignored):
  `openssl rand -base64 48` yields 64 characters.
- **Cookie.** Generated once per instance by the entrypoint (`0600`, under the instance
  directory); never baked into an image.
- **Persistence.** The store is under the state root, so `docker compose restart release`
  keeps history with no node mismatch.

## Console

`scripts/autonomous console --target <repo> [--port <n>]` starts a detached
`mix phx.server` (the `console` service) and returns once the console answers; the start
lines name the loopback address. `scripts/autonomous port --target <repo>` prints the
address of any running instance (shell, console or release).

- The image binds `0.0.0.0` *inside* the container; Compose publishes it as
  `127.0.0.1:<port>:4000`, so only the operator's machine reaches it (FR-021). From another
  machine on the LAN the connection is refused; tunnel with `ssh -L` to watch remotely.
- No `--port`: the wrapper picks a free loopback port and prints it. A busy `--port` exits
  76 naming it.
- `AUTONOMOUS_CONSOLE_HOST` (default `localhost`) feeds the endpoint URL; origin checks
  accept `//localhost` and `//127.0.0.1` on any port because the host port is chosen at
  start.

## Stopping cleanly

Leave `iex` with `System.stop()` (or `:init.stop()`). A hard halt (`System.halt/1`,
Ctrl+C twice) right after a write can lose the tail of the Mnesia log: in the smoke check a
run was written and the VM halted immediately, and the recreated container listed no runs;
the same write followed by `:init.stop()` survived. A container restart (`docker compose restart release`, SIGTERM) kept history in
the release smoke check.
