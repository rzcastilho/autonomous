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
paths. Operator-declared volumes (feature 041) are container-engine storage with no host path and
sit inside the same boundary; their declaration file stays host-only and is never mounted. See
`docs/container.md` for operation.

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

### Container engine sidecar (feature 046)

Constitution 7.3.0 amends Principle III: an **opt-in** container-engine sidecar MAY hold
elevated privileges, but (1) the agent container MUST NOT gain any privilege, capability,
device or socket mount for it, (2) the host engine's control socket MUST NEVER be mounted,
and (3) the engine sessions control MUST run unprivileged (rootless).

**Trade-off.** `compose.engine.yaml` marks the `engine` service `privileged: true` so the
rootless engine can set up user namespaces. That privilege belongs to the sidecar, not to
sessions. A session can ask the engine for a `--privileged` container or a `-v /:/host`
mount, but both resolve inside the rootless engine's own filesystem and uid mapping, so
neither reaches host disks or host root. Rootless is therefore load-bearing: a later
"simplify to rootful dind" would silently give sessions host-root reach, which is why it
is written into the constitution.

**Guard.** `container_engine_guard_test.exs` fails if any compose file or script mentions
`docker.sock`, or if `dev`, `console` or `release` gain `privileged`, `cap_add`, `devices`
or `security_opt` in `compose.engine.yaml`. Port `2375` is never published.

**Advertisement.** The entrypoint step `container_engine` exports
`AUTONOMOUS_CONTAINER_ENGINE=1` only after probing the engine; `ContainerEngine` then adds
a prompt note on `:implement`/`:converge` and runs boundary cleanup. Not advertised: zero
docker calls, zero log lines. See `docs/container.md`, `specs/046-docker-sidecar/`.

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

Feature 044: **the orchestrator owns the pack.** A target does not need to commit
any orchestrator file. `TargetPack.supply/1` writes the pack into every feature
worktree (at `Worktree.create/2` and again at `Worktree.restore/1`), untracked:

| Path in the worktree | Source (`priv/target_pack/.claude/`) | Contract 6 |
|---|---|---|
| `.claude/settings.local.json` | `settings.json`, minus any `env` key the target's tracked `settings.json` sets | `env` (032 shell timeouts), `permissions.defaultMode`, `permissions.allow`. No `hooks`, no `permissions.deny`. |
| `.claude/autonomous-pack.json` | `autonomous-pack.json` | `{"contract": 6}` — the contract marker (not written if the target tracks one) |
| `.claude/skills/` | — (the target's Spec Kit skills, committed) | unchanged |

Both supplied files stay out of git through a marked block in the target's
common-dir `info/exclude` (shared by the checkout and every linked worktree), so
they never reach a commit, the squash, the PR diff or the checkout itself. Claude
Code ranks local settings above project settings, so an `env` key the target sets
in its own `.claude/settings.json` wins: the local file simply does not restate it.
Supplying never writes, merges or deletes a tracked file. Session configuration
(`PhaseRequest`) is identical whichever way the pack arrives.

### What `TargetPack.verify/2` checks

`verify/2` runs on **every** run, resume, continue and `run_spec/2` (there is
no `:profile` option). Reading the committed tree, it requires:

1. `.claude/skills/` present;
2. a real constitution — the template marker gone, non-empty, and committed;
3. the pack contract (`check_pack_contract/2`) for whatever pack the target
   commits — **absent files are fine**; present ones must meet it:
   - `.claude/autonomous-pack.json` decodes with `contract >= 6`;
   - `.claude/settings.json` is a JSON object that registers no `scope_guard.py`
     hook and carries no `permissions.deny`;
   - `.claude/hooks/scope_guard.py` is not committed;
   - `.claude/settings.local.json` is not committed (the orchestrator owns it).

A failure is `{:pack_outdated, path, hint}` (older than contract 6),
`{:invalid_settings, path}` (tracked `settings.json` not a JSON object) or
`{:pack_local_tracked, path, hint}`. `supply/1` applies the same rules to the
worktree's own tracked tree, so no session can ever meet an old hook.

### Three target states

| Target `HEAD` | Preflight | In the worktree |
|---|---|---|
| no pack files | passes | pack supplied, untracked |
| committed pack at contract 6 | passes | tracked files used as-is; local file adds the pack settings (tracked `env` keys win) |
| committed pack older than contract 6, a tracked `settings.local.json`, or an unparseable `settings.json` | refused before any store write or session | — |
| non-pack tracked `settings.json` (no marker, no deny/hook) | passes | left untouched; local file layered on top |

Configuration shows a **target pack** row: `supplied by the orchestrator`,
`committed in the target`, or the refusal text.

### Setting up a target repo

```
# 1. Bootstrap Spec Kit (creates .specify/ and .claude/skills/)
specify init . --integration claude --integration-options="--skills"

# 2. Write a real constitution with checkable MUSTs, then commit
#    (the shipped template is AUTONOMOUS_TEMPLATE-marked and is refused)
git add .specify .claude/skills && git commit -m "spec kit"

# 3. Preflight (fails while the template constitution marker is present, if
#    the constitution is uncommitted / skills missing, or if a committed pack
#    is older than contract 6)
Autonomous.TargetPack.verify("/path/to/target/repo")  # => :ok
```

There is no install step: the orchestrator supplies the pack. `TargetPack.install/2`
remains as an **optional** manual path — it writes `settings.local.json` and the
marker into the directory you give it (never `settings.json`, never clobbering a
constitution) — useful only for sessions you drive yourself in the target checkout.

### Fixing a refused pack

A target last installed before 039 (pack contracts 2–5) fails preflight with
`{:pack_outdated, path, hint}`. Either remedy works:

1. **Hand the pack to the orchestrator** (preferred): remove the pack files from
   version control and commit —
   `git rm --cached .claude/autonomous-pack.json .claude/settings.json` (only the
   files the refusal names; keep a `settings.json` that holds your own settings but
   delete its `hooks.PreToolUse` scope-guard entry and any `permissions.deny`),
   `git rm .claude/hooks/scope_guard.py`, commit.
2. **Keep it committed**: update the tracked file to contract 6 — marker
   `{"contract": 6}`, no scope-guard hook, no `permissions.deny`, no
   `scope_guard.py` — and commit.

A tracked `.claude/settings.local.json` is refused the same way:
`git rm --cached .claude/settings.local.json`, commit. Then re-run (`run/1`,
`resume/2` or `continue_run/1`); a refused continue leaves the run parked.

## Upgrade procedure (reconcile with Spec Kit)

Spec Kit ships weekly and its files also live under `.claude/`. To upgrade
without losing the pack:

1. **Back up the constitution** — `cp .specify/memory/constitution.md /tmp`.
   **Never** run `specify init --force` (it overwrites the constitution, §4.3).
2. Run `specify self upgrade` (or re-init **without** `--force`).
3. **Re-diff `.claude/`**: confirm `.claude/skills/` is intact and that Spec Kit
   did not add a `permissions.deny` or hook to a tracked `settings.json`. The
   orchestrator pack needs no restoring — it is supplied into each worktree.
   Commit the result — preflight reads the committed tree and rejects an
   outdated committed pack (`{:pack_outdated, path, hint}`).
4. Re-run `TargetPack.verify/1` and diff `constitution.md` against the backup.
5. `specify self check` to confirm the CLI version, and record the tag in
   `config.exs` (`:speckit_version`).
