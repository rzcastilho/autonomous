# Contract: Target pack, orchestrator-supplied (044)

Amends `specs/039-remove-budget-strict-profile/contracts/target-pack.md`. Pack
contract stays **6** (research R7). Decisions: research R2–R6.

## Pack contents (`priv/target_pack/.claude/`) — bytes unchanged

| Source path | Lands in a worktree as | Contract 6 |
|---|---|---|
| `settings.json` | `.claude/settings.local.json` (minus tracked `env` keys) | `env`, `permissions.defaultMode`, `permissions.allow`; no `hooks`, no `deny` |
| `autonomous-pack.json` | `.claude/autonomous-pack.json` (unless tracked) | `{"contract": 6}` |
| `.specify/memory/constitution.md` | only by a manual `install/2` where none exists | template (unchanged) |

## `TargetPack.supply(worktree_path)` — new

Called by `Worktree.create/2` (after scaffold assertion) and `Worktree.restore/1` (after
reset + clean). Never called on the target checkout.

1. Worktree tracked-tree check (`git ls-files` + working copy), first failure wins:
   - tracked marker, `contract < 6` or undecodable → `{:pack_outdated, ".claude/autonomous-pack.json", hint}`
   - tracked `settings.json`: not an object → `{:invalid_settings, ".claude/settings.json"}`;
     scope-guard `PreToolUse` hook or non-empty `permissions.deny` → `{:pack_outdated, ".claude/settings.json", hint}`
   - tracked `.claude/hooks/scope_guard.py` → `{:pack_outdated, ".claude/hooks/scope_guard.py", hint}`
   - tracked `.claude/settings.local.json` → `{:pack_local_tracked, ".claude/settings.local.json", hint}`
2. Exclude block appended to `<git-common-dir>/info/exclude` (idempotent).
3. `install/2` on the worktree.

Returns `{:ok, %{source, wrote, excluded}}`. MUST NOT write, merge, or delete any
tracked path. On error `create/2` removes the half-made worktree and returns
`{:error, {:pack_supply, reason}}`; `restore/1` returns the same error (callers wrap as
`{:worktree, …}` today).

## `TargetPack.install(dir, opts)` — changed

- Writes `.claude/settings.local.json` = `local_settings(pack, existing settings.json)`,
  only when bytes differ. **Never writes `.claude/settings.json`.**
- Writes `.claude/autonomous-pack.json` only when absent or not current.
- Removes a stale `.claude/hooks/scope_guard.py` (and empty `hooks/`) — unchanged.
- Never clobbers the constitution — unchanged.
- `{:error, {:invalid_settings, ".claude/settings.json"}}` before writing anything when
  the existing `settings.json` is not a JSON object — unchanged.
- Idempotent: second call → same bytes, `settings: false, marker: false` in summary.

Summary map: `%{settings: boolean, marker: boolean, stale_hook_removed: boolean,
constitution_skipped: boolean}` (`settings`/`marker` now mean "written this call").

`merge_settings/2` → replaced by `local_settings/2 :: (map, map | nil) -> map`.

## `TargetPack.verify(repo, opts)` — changed

Options unchanged (`check_git`, `check_remote`). Checks:

1. `.claude/skills` dir present; constitution present, customized, non-empty,
   committed — unchanged (FR-002).
2. **Removed**: `.claude/settings.json` required.
3. `check_pack_contract(repo, committed? \\ true)`, reading `git show HEAD:<path>`:
   - marker absent → ok; present → decodes and `contract >= 6`;
   - `settings.json` absent → ok; present → object, no scope-guard hook, no deny;
   - stale hook file absent;
   - `settings.local.json` not tracked (skipped when `committed? = false`).

Hint text (both remedies) — `@outdated_hint`:

> pack is older than contract 6 — either update the tracked file to contract 6 and
> commit it, or remove the pack files from version control
> (`git rm --cached <file>`, commit) so the orchestrator supplies them

`:pack_local_tracked` hint:

> the orchestrator supplies `.claude/settings.local.json` into each worktree — stop
> tracking it (`git rm --cached .claude/settings.local.json`, commit) and re-run

Call sites and timing unchanged: `run/1`, `run_spec/2`, `resume/2`, `continue_run/1`,
before any store write or run flip.

## `TargetPack.source(repo)` — new

`{:ok, %{source: :supplied | :committed, contract: n}} | {:error, reason}` — see
data-model.md "Pack source". Same reads as step 3 of `verify/2`.

## `Worktree`

- `@scaffold_files` drops `.claude/settings.json` (scaffold = `.specify`,
  `.claude/skills`).
- `create/2` option `:supply_pack` (default `true`) — `false` only for unit tests of git
  plumbing.
- `restore/1` re-supplies after `clean -fd` (excluded files survive the clean; re-supply
  covers a pre-044 worktree that never had them).

## Sessions — unchanged

`PhaseRequest` still sets `permission_mode: :bypass_permissions`, `@allowed_tools`,
headless exclusions, launch-env shell timeouts + `--settings`, agent-root markers
(FR-009). Effective configuration is identical for both pack sources (SC-003).

## Guarantees (tests)

| # | Guarantee | Requirement |
|---|---|---|
| G1 | target with no pack files passes `verify/2` | FR-001, US1-1 |
| G2 | after `create/2`, both files exist and `git status --porcelain` is empty in worktree and checkout | FR-003/004, US1-2/4 |
| G3 | after `commit/2` + `squash/3`, `git diff --name-only fork..HEAD` names neither file | FR-004/014, US1-3 |
| G4 | committed current pack: tracked files byte-identical after supply; tracked `env` key absent from local file | FR-005/006, US2-1 |
| G5 | committed outdated pack refused by `verify/2` and by `supply/1`, hint names both remedies | FR-007, US2-2 |
| G6 | non-pack tracked `settings.json` (no marker, no deny/hook) passes, untouched | FR-008 |
| G7 | tracked `settings.local.json` refused | FR-008 |
| G8 | `restore/1` on a pre-044 worktree (committed pack or none) supplies files, no tracked change | FR-011, US3 |
| G9 | `supply/1` twice → second `wrote: [], excluded: []`; exclude block not duplicated | FR-003, edge case |
| G10 | target checkout has neither file after a run | FR-016 |
