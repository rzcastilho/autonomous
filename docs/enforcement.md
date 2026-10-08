# Enforcement & containment

The Claude adapter's real SDK path passes `--permission-mode` (not
`--dangerously-skip-permissions`, which was a Phase 0 finding since superseded
— see `docs/harness-contract.md`), so per-phase permissions genuinely govern
tool access; the scope-guard hook remains the layer that works regardless of
those flags.

## Two containment profiles (feature 030)

Every run picks one of two profiles, recorded once at `run/1` and locked for
its lifetime (resume/continue never renegotiate it):

- **`strict`** (default). Byte-identical to the pre-030 behaviour described
  below: the hook denies out-of-tree writes and dangerous Bash for every
  orchestrator-driven session, and each phase gets scoped
  `permission_mode`/`allowed_tools`.
- **`permissive`** (opt-in, per run). The hook applies no deny list and every
  phase gets full write/Bash/network access
  (`permission_mode: :bypass_permissions`, `WebFetch`/`WebSearch` allowed;
  only `Agent`/`Task`/`ScheduleWakeup` stay excluded, FR-008). Choose this only
  when the target genuinely needs push/network/out-of-tree access a feature
  can't get otherwise, and prefer the container recipe below alongside it —
  `permissive` removes the hook's own safety net.

The operator's own **interactive** Claude Code session in a target repo is
never denied by the pack, under either profile — origin (human vs.
orchestrated) is resolved from `AUTONOMOUS_ORCHESTRATED`/
`AUTONOMOUS_CONTAINMENT_PROFILE` env markers the orchestrator sets on every
session it starts, falling back to `CLAUDE_CODE_ENTRYPOINT=cli` to detect a
human shell. Anything undecided resolves to `strict`'s rule set (fail closed).
A permissive run is visible everywhere it applies — the final report, the
console topbar/Run Detail/Configuration page, and the PR body all show
`containment: permissive` (or omit the marker entirely under `strict`, so that
surface stays byte-identical). See `contracts/operator-surfaces.md` under
`specs/030-permissive-containment/`.

### Strict package-manager exception (feature 037, pack contract 5)

Under `strict`, `sudo` stays denied (`bash_sudo`) **except** when both
`AUTONOMOUS_CONTAINER=1` (image `ENV`) and `AUTONOMOUS_AGENT_ROOT=1` (exported by the
entrypoint only after `sudo -n true` succeeds) are present *and* every `sudo` in the
command matches this closed grammar:

```text
sudo [-n] [DEBIAN_FRONTEND=noninteractive]
     apt-get|apt  update
   | apt-get|apt  install  (-y|--yes|--assume-yes|-q|-qq|--quiet|--no-install-recommends | <package>)+
   | apt          list|show|policy …
   | dpkg         -l|--list|-s|--status|-L|--listfiles|-S|--search|--get-selections …
```

`sudo` must start its segment (`&&`, `||`, `;`, `|`, `&`, newline); redirects are left to
the unchanged `bash_redirect_outside_worktree` rule. Still denied: `remove`, `purge`,
`autoremove`, `upgrade`/`dist-upgrade`, `-o`/`-c`/`--option`, local package files
(`./x.deb`, any `/`), `dpkg -i`, `sh -c`, `-E`, `-u`, command/process substitution,
backticks, subshells, unbalanced quotes, and every other sudo'd program. Every other
strict rule (`git push`, `curl`/`wget` at the start, `rm -rf /`, …) still judges the whole
command, and `permissive` / interactive sessions are unchanged.

**Why `NOPASSWD: ALL` is acceptable.** Narrowing sudoers to apt would not be a boundary
— `apt-get -o APT::Update::Pre-Invoke=…` and maintainer scripts execute arbitrary code.
The policy is the hook grammar above (which refuses `-o` and local packages); the outer
boundary is the container itself, which is why the exception needs the in-container
marker. Enabling `--agent-root` is an explicit operator decision per image.

Containment is otherwise the same three overlapping layers:

1. **PreToolUse scope-guard hook** — `priv/target_pack/.claude/hooks/scope_guard.py`.
   Under `strict`, denies file writes (`Write`/`Edit`/`MultiEdit`/`NotebookEdit`)
   resolving outside the worktree, dangerous Bash (`rm -rf /`, `sudo`,
   `git push`, `curl|sh`, redirects to absolute paths outside the tree), and
   `WebFetch`/`WebSearch`. Fails **closed** on unparseable input under every
   origin/profile. Under `permissive`, the hook allows everything (no rule
   list consulted). `settings.json` carries no `permissions.deny` of its own
   any more — every denial decision lives in the hook, since a
   `permissions.deny` entry used to block the operator's own interactive
   sessions too.
2. **Per-phase RunRequest permissions** — `PhaseRequest.build/3` sets
   `permission_mode`/`allowed_tools`/`disallowed_tools` per phase and per
   containment profile (analyze read-only via `:plan` under `strict`;
   implement scoped writes via `:accept_edits` under `strict`; full access
   under `permissive`). The adapter forwards these. Belt-and-suspenders with
   the hook under `strict`; under `permissive` this layer also grants full
   access, so the hook is the only thing standing between the session and the
   host — hence the container recommendation.
3. **Container isolation (optional, defense in depth)** — see below;
   recommended whenever a run uses `permissive`.

## Installing the pack in a target repo

The pack travels into every worktree because it is committed in the base repo.

```
# 1. Bootstrap Spec Kit (creates .specify/ and .claude/skills/)
specify init . --integration claude --integration-options="--skills"

# 2. Install the orchestrator enforcement pack (settings.json + hook; installs a
#    template constitution only if none exists — never clobbers yours)
#    from iex against the repo path:
Autonomous.TargetPack.install("/path/to/target/repo")
#    (returns {:error, {:invalid_settings, _}} if the target's settings.json
#    is not valid JSON; an existing settings.json `env` is kept, pack keys added)

# 3. Write a real constitution with checkable MUSTs, then commit everything
git add .specify .claude && git commit -m "spec kit + enforcement pack"

# 4. Preflight (fails while the template constitution marker is present, or if
#    the constitution is uncommitted / scaffold missing)
Autonomous.TargetPack.verify("/path/to/target/repo")  # => :ok

# 4a. A run that will use `containment_profile: :permissive` additionally
#     requires the committed pack to be at contract 4 or later (this hook + this
#     settings.json, both committed) — verify explicitly:
Autonomous.TargetPack.verify("/path/to/target/repo", profile: "permissive")  # => :ok
```

## Upgrade procedure (reconcile with Spec Kit)

Spec Kit ships weekly and its files also live under `.claude/`. To upgrade
without losing enforcement:

1. **Back up the constitution** — `cp .specify/memory/constitution.md /tmp`.
   **Never** run `specify init --force` (it overwrites the constitution, §4.3).
2. Run `specify self upgrade` (or re-init **without** `--force`).
3. **Re-diff `.claude/`**: confirm `settings.json` and `hooks/scope_guard.py`
   still exist and were not replaced by Spec Kit's defaults. Re-run
   `TargetPack.install/2` to restore them if needed (it does not touch the
   constitution). Commit the result — a `permissive` run's preflight rejects
   an uncommitted or pre-030 pack (`{:pack_outdated, path, hint}`).
4. Re-run `TargetPack.verify/1` (and, if this repo runs `permissive` runs,
   `TargetPack.verify/2` with `profile: "permissive"`) and diff
   `constitution.md` against the backup.
5. `specify self check` to confirm the CLI version, and record the tag in
   `config.exs` (`:speckit_version`).

## Container isolation (feature 031)

The container layer is real: the orchestrator and the `claude` CLI run inside
the image from `/Dockerfile`, started by `scripts/autonomous`. Only the target
repo, its worktree root, and the instance state directory are mounted
read-write. The process runs as the host user, never root, so `sudo` and system
writes fail at the OS layer even if the hook is bypassed or its deny list is
empty (`permissive`). See `docs/container.md` for operation.

This bounds blast radius to the mounted paths regardless of hook coverage — the
one layer `permissive` cannot remove.

### Open gaps

- **No egress restriction (FR-029).** The container has unrestricted outbound
  network. An egress allowlist (Anthropic API host plus whatever a feature
  needs) is not implemented; add one at the Docker/host firewall level if the
  run needs it.
- **Package-manager downloads are not denied by the hook.** `npm install`,
  `pip install` and `mix deps.get` pass `scope_guard.py` under `strict`. They
  write inside the worktree and the container, and are bounded by the container
  layer, not the hook.
- **`bash_curl` / `bash_wget` are anchored at command start (R12).** A download
  that is not the first token of the command (for example after `cd x &&` or in
  a pipeline) is not matched. Recorded gap, not fixed in 031.
