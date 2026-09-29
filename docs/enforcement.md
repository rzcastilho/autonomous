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

# 3. Write a real constitution with checkable MUSTs, then commit everything
git add .specify .claude && git commit -m "spec kit + enforcement pack"

# 4. Preflight (fails while the template constitution marker is present, or if
#    the constitution is uncommitted / scaffold missing)
Autonomous.TargetPack.verify("/path/to/target/repo")  # => :ok

# 4a. A run that will use `containment_profile: :permissive` additionally
#     requires the committed pack to be at contract 3 (this hook + this
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

## Container isolation (optional, recommended for `permissive`)

The scope-guard hook has known enforcement gaps on some CLI versions, and
under `permissive` it enforces nothing at all. For defense in depth, run the
whole orchestrator + CLI inside a devcontainer/Docker with only the repo
mounted:

- Mount the target repo (and worktree root) read-write; mount nothing else
  writable.
- Drop network egress except the Anthropic API host (the constitution's
  "no network access" MUST is about the *product*, not the agent's API calls)
  — a `permissive` run's whole point is usually that one feature needs
  broader network access, so scope the egress allowlist to what that feature
  actually needs rather than opening it wide.
- Run as a non-root user so `sudo`/system writes fail at the OS layer even if
  the hook is bypassed or its deny list is empty.

This bounds blast radius to the mounted repo (and allowed egress) regardless
of hook coverage — the one layer `permissive` cannot remove.
