# Enforcement & containment

There is one containment behaviour (feature 039, constitution 7.0.0
Principle III, Container-Bounded Execution). Every orchestrator-driven session
gets the same full tool set; the **container is the boundary**. Two pieces
remain on the orchestrator side:

1. **Container isolation** — the supported runtime and the outer boundary
   (see below and `docs/container.md`).
2. **Per-phase session permissions** — one full set, passed on every
   `RunRequest`.

A third piece is a precondition rather than a layer: the **committed target
pack** must meet the current pack contract (6), or the run refuses to start.

The `strict`/`permissive` containment profiles, the `scope_guard.py`
PreToolUse hook, its in-tree deny list and its closed `sudo` grammar, and the
`AUTONOMOUS_ORCHESTRATED` / `AUTONOMOUS_CONTAINMENT_PROFILE` session markers
were removed in 039. A `containment_profile` run option, app-env key or
`AUTONOMOUS_CONTAINMENT_PROFILE` env var is refused naming the key
(`{:error, {:preflight, [{:retired_option, :containment_profile}]}}` at run
start; boot aborts for app env / env).

## Per-phase session permissions

The Claude adapter's real SDK path passes `--permission-mode` (not
`--dangerously-skip-permissions`, which was a Phase 0 finding since superseded
— see `docs/harness-contract.md`). `PhaseRequest.build/3` sets the same
first-class `RunRequest` fields for every phase, remediation and describe
session:

- `permission_mode: :bypass_permissions`;
- `allowed_tools`: `Read Write Edit MultiEdit NotebookEdit Bash Grep Glob
  WebFetch WebSearch` (pre-approved so the headless CLI runs them
  non-interactively — Bash is required by the Spec Kit phase scripts);
- `disallowed_tools`: `Agent Task ScheduleWakeup Monitor`. These are headless
  exclusions, not containment: a subagent or background watcher lets the model
  end its turn "waiting", which ends a headless session (the incomplete-session
  gate then fails the phase), and `ScheduleWakeup` is meaningless in a one-shot
  session.

The launch env carries the shell timeouts (feature 032) and, when the
container advertises agent root, the `AgentRoot.session_env/1` markers. No
containment marker is sent.

The operator's own **interactive** Claude Code session in a target repo is
never denied by the pack: the pack carries no hook and no `permissions.deny`.

## Container isolation (feature 031)

The orchestrator and the `claude` CLI run inside the image from `/Dockerfile`,
started by `scripts/autonomous`. Only the target repo, its worktree root, and
the instance state directory are mounted read-write. The process runs as the
host user, never root; without `--agent-root` the image carries no `sudo`, so
system writes fail at the OS layer. This bounds blast radius to the mounted
paths. See `docs/container.md` for operation.

**Starting outside the container.** `ContainerGuard.check!/0` refuses a boot
outside the image whenever `require_container` is true, so a host start only
happens where that guard was deliberately disabled (host development, tests).
In that case every run start (`run/1`, `run_spec/2`, resume, continue) logs the
multi-line `RuntimeNotice.container_warning/1` text — the run is starting
outside the container, sessions have full tool access and no in-tree deny
list, `scripts/autonomous` is the supported runtime — and **proceeds**. The
console Trigger start-confirm shows the same warning.

### Agent root (feature 037)

`scripts/autonomous build --agent-root` builds passwordless `sudo` (any uid)
plus `APT::Get::Remove "false"`; the entrypoint exports
`AUTONOMOUS_AGENT_ROOT=1` only after `sudo -n true` succeeds. When advertised,
`implement`/`converge` sessions get a prompt note telling them to install
missing OS packages with `sudo apt-get update && sudo apt-get install -y
--no-install-recommends <pkgs>` and never to remove, purge or upgrade, and
`AgentRoot.log_installs/3` logs every install after each session. That note is
**guidance only**: the closed `sudo` grammar that used to be enforced by
`scope_guard.py` was removed in 039. With agent root enabled the session has
root inside the container; the container is the boundary, which is why
enabling `--agent-root` is an explicit operator decision per image.

### Open gaps

- **No egress restriction (FR-029).** The container has unrestricted outbound
  network, and sessions may use `WebFetch`/`WebSearch` and network-reaching
  Bash. An egress allowlist (Anthropic API host plus whatever a feature needs)
  is not implemented; add one at the Docker/host firewall level if the run
  needs it.
- **No in-tree deny list.** Nothing inside the container stops a session from
  writing anywhere the container user can write, `git push`ing, or running
  package-manager downloads. Those effects are bounded by the mounts and the
  container, not by the pack.

## Target pack (contract 6)

The pack lives in `priv/target_pack/.claude/` and travels into every worktree
because it is committed in the target's base repo:

| Path | Contract 6 |
|---|---|
| `settings.json` | `env` (032 shell timeouts), `permissions.defaultMode`, `permissions.allow`. No `hooks`, no `permissions.deny`. |
| `autonomous-pack.json` | `{"contract": 6}` — the contract marker |
| `skills/` | Spec Kit skills (unchanged) |

### What `TargetPack.verify/2` checks

`verify/2` runs on **every** run, resume, continue and `run_spec/2` (there is
no `:profile` option). Reading the committed tree, it requires:

1. `.claude/settings.json` and `.claude/skills/` present;
2. a real constitution — the template marker gone, non-empty, and committed;
3. the pack contract (`check_pack_contract/2`):
   - `.claude/autonomous-pack.json` exists, decodes, and `contract >= 6`;
   - `.claude/settings.json` registers no `scope_guard.py` hook and carries no
     `permissions.deny`;
   - `.claude/hooks/scope_guard.py` is not committed.

A pack-contract failure is `{:pack_outdated, path, hint}`, `path` naming the
offending file and the hint reading "pack is older than contract 6 — run
TargetPack.install/2 in the target repo, commit the result, and re-run".
Because worktrees come from the committed tree, no session can ever meet an old
hook.

### Installing the pack in a target repo

```
# 1. Bootstrap Spec Kit (creates .specify/ and .claude/skills/)
specify init . --integration claude --integration-options="--skills"

# 2. Install the orchestrator pack (settings.json + autonomous-pack.json;
#    installs a template constitution only if none exists — never clobbers
#    yours) from iex against the repo path:
Autonomous.TargetPack.install("/path/to/target/repo")
#    (returns {:error, {:invalid_settings, _}} if the target's settings.json
#    is not valid JSON; an existing settings.json `env` is kept, every other
#    key is the pack's)

# 3. Write a real constitution with checkable MUSTs, then commit everything
git add .specify .claude && git commit -m "spec kit + autonomous pack"

# 4. Preflight (fails while the template constitution marker is present, if
#    the constitution is uncommitted / scaffold missing, or if the committed
#    pack is older than contract 6)
Autonomous.TargetPack.verify("/path/to/target/repo")  # => :ok
```

### Reinstalling an outdated pack

A target last installed before 039 (pack contracts 2–5) fails preflight with
`{:pack_outdated, path, hint}`. To fix it:

1. In iex: `Autonomous.TargetPack.install("/path/to/target/repo")`. It writes
   `autonomous-pack.json`, merges `settings.json` (pack wins every key but
   `env`, so the old `hooks.PreToolUse` scope-guard entry is dropped), deletes
   `.claude/hooks/scope_guard.py` (and the empty `hooks/` directory), and
   leaves the constitution alone. It is idempotent.
2. Commit the result in the target:
   `git add -A .claude && git commit -m "autonomous pack contract 6"`.
3. Re-run (`run/1`, `resume/2` or `continue_run/1`); `TargetPack.verify/1`
   now returns `:ok`.

## Upgrade procedure (reconcile with Spec Kit)

Spec Kit ships weekly and its files also live under `.claude/`. To upgrade
without losing the pack:

1. **Back up the constitution** — `cp .specify/memory/constitution.md /tmp`.
   **Never** run `specify init --force` (it overwrites the constitution, §4.3).
2. Run `specify self upgrade` (or re-init **without** `--force`).
3. **Re-diff `.claude/`**: confirm `settings.json` and `autonomous-pack.json`
   still exist and were not replaced by Spec Kit's defaults. Re-run
   `TargetPack.install/2` to restore them if needed (it does not touch the
   constitution). Commit the result — preflight reads the committed tree and
   rejects an outdated pack (`{:pack_outdated, path, hint}`).
4. Re-run `TargetPack.verify/1` and diff `constitution.md` against the backup.
5. `specify self check` to confirm the CLI version, and record the tag in
   `config.exs` (`:speckit_version`).
