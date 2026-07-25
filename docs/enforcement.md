# Enforcement & containment

The Claude adapter runs the CLI with `--dangerously-skip-permissions` (Phase 0
finding), so the CLI's own permission prompts are **not** the containment layer.
Containment is three overlapping layers:

1. **PreToolUse scope-guard hook** — `priv/target_pack/.claude/hooks/scope_guard.py`.
   Denies file writes (`Write`/`Edit`/`MultiEdit`/`NotebookEdit`) resolving
   outside the worktree, and dangerous Bash (`rm -rf /`, `sudo`, `git push`,
   `curl|sh`, redirects to absolute paths outside the tree). Fails **closed** on
   unparseable input. This is the layer that works regardless of adapter flags.
2. **Per-phase RunRequest permissions** — `PhaseRequest.build/3` sets
   `permission_mode`/`allowed_tools`/`disallowed_tools` per phase (analyze
   read-only via `:plan`; implement scoped writes via `:accept_edits`). The
   adapter forwards these (Phase 0 finding). Belt-and-suspenders with the hook.
3. **Container isolation (optional, defense in depth)** — see below.

## Installing the pack in a target repo

The pack travels into every worktree because it is committed in the base repo.

```
# 1. Bootstrap Spec Kit (creates .specify/ and .claude/skills/)
specify init . --integration claude --integration-options="--skills"

# 2. Install the orchestrator enforcement pack (settings.json + hook; installs a
#    template constitution only if none exists — never clobbers yours)
#    from iex against the repo path:
SpeckitOrchestrator.TargetPack.install("/path/to/target/repo")

# 3. Write a real constitution with checkable MUSTs, then commit everything
git add .specify .claude && git commit -m "spec kit + enforcement pack"

# 4. Preflight (fails while the template constitution marker is present, or if
#    the constitution is uncommitted / scaffold missing)
SpeckitOrchestrator.TargetPack.verify("/path/to/target/repo")  # => :ok
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
   constitution).
4. Re-run `TargetPack.verify/1` and diff `constitution.md` against the backup.
5. `specify self check` to confirm the CLI version, and record the tag in
   `config.exs` (`:speckit_version`).

## Container isolation (optional)

The scope-guard hook has known enforcement gaps on some CLI versions. For
defense in depth, run the whole orchestrator + CLI inside a devcontainer/Docker
with only the repo mounted:

- Mount the target repo (and worktree root) read-write; mount nothing else
  writable.
- Drop network egress except the Anthropic API host (the constitution's
  "no network access" MUST is about the *product*, not the agent's API calls).
- Run as a non-root user so `sudo`/system writes fail at the OS layer even if the
  hook is bypassed.

This bounds blast radius to the mounted repo regardless of hook coverage.
