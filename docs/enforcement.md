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
3. **Container isolation (the outermost layer, OS-level)** — see below.

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

## Container isolation (feature 015)

The scope-guard hook has known enforcement gaps on some CLI versions, and
per-phase permissions are the adapter's own cooperative contract, not an OS
boundary. The orchestrator can also run as a published container image
(`docs/container.md`) — the **third and outermost** containment layer, and
the only one that holds regardless of hook coverage or adapter behavior:
`--user <uid>:<gid>` (unprivileged), `--read-only` root filesystem,
`--cap-drop ALL`, `--security-opt no-new-privileges`, and exactly two durable
writable mounts — the target repository and the run-state root, each at its
identical host path. Proven independently of the in-repo hook by a red-team
suite that runs with the hook disabled (`test/integration/container_red_team_test.exs`,
SC-002): every hostile command the OS layer can refuse — writes outside the
two mounts, privilege escalation, system-directory writes, package installs
into system paths — fails, and the host filesystem outside the two mounts is
byte-for-byte unchanged.

**It is never a replacement** for the scope-guard hook or per-phase
permissions — the container is one more layer, not a substitute for the
other two, and all three run together in a containerized deployment.

**What it protects**: filesystem writes (only the two declared mounts are
writable and durable; everything else is read-only or ephemeral tmpfs),
process privileges (unprivileged user, no capabilities, no privilege
escalation), and process scope (`--pids-limit` bounds a runaway fork bomb).

**What it explicitly does not protect**: network egress. The container
intentionally emits no `--network` restriction — the agent's outbound API
calls are unrestricted, same as an on-machine run. (An earlier draft of this
section stated egress was dropped except to the Anthropic API host; that was
never implemented and is corrected here — see `contracts/container-run.md`
§4 in the feature's spec folder for the authoritative privilege posture.)
