# Quickstart: validating the orchestrator-owned pack (044)

Contracts: [target-pack.md](contracts/target-pack.md),
[operator-surfaces.md](contracts/operator-surfaces.md). Data shapes:
[data-model.md](data-model.md).

## Prerequisites

- `mise trust mise.toml` once; every Elixir command via `mise exec --`.
- `git` ≥ 2.20 (linked worktrees read the common-dir `info/exclude`).

## 1. Default suite

```bash
mise exec -- mix compile          # warnings_as_errors
mise exec -- mix test test/autonomous/target_pack_test.exs test/autonomous/worktree_test.exs
mise exec -- mix test             # full suite, incl. design_contract_test
```

Expected: green. `target_pack_test.exs` covers G1, G4–G7, G9 (three target states:
no pack, current committed, outdated committed); `worktree_test.exs` covers G2, G3, G8,
G10 against temp git repos.

## 2. Manual: target with no pack (US1)

```bash
T=$(mktemp -d) && cd "$T" && git init -q && mkdir -p .claude/skills .specify/memory
printf '# Real constitution\n' > .specify/memory/constitution.md
touch .claude/skills/.gitkeep && git add -A && git commit -qm scaffold
```

```elixir
# mise exec -- iex -S mix
Autonomous.TargetPack.verify(t, check_remote: false)   #=> :ok
Autonomous.TargetPack.source(t)                        #=> {:ok, %{source: :supplied, contract: 6}}
f = %Autonomous.Feature{id: "001", number: 1, slug: "demo", group: :backlog}
{:ok, wt} = Autonomous.Worktree.create(f, repo: t, worktree_root: Path.join(t, "../wt"))
```

```bash
ls "$wt_path/.claude"            # autonomous-pack.json settings.local.json skills
git -C "$wt_path" status --porcelain   # empty
git -C "$T" status --porcelain         # empty
tail -3 "$(git -C "$T" rev-parse --git-common-dir)/info/exclude"   # the 044 block
```

Re-run `Worktree.restore(wt)` twice: exclude block appears once, files unchanged.

## 3. Manual: committed current pack with operator `env` (US2-1)

Commit `{"contract":6}` marker and a `settings.json` holding the pack keys plus
`"env": {"BASH_DEFAULT_TIMEOUT_MS": "60000"}`. Create a worktree. Expect: `git diff`
empty; `settings.local.json` has no `BASH_DEFAULT_TIMEOUT_MS`; `source/1` →
`:committed`.

## 4. Manual: committed outdated pack (US2-2)

Commit `{"contract":5}` (or a `permissions.deny`). `verify/2` →
`{:error, [{:pack_outdated, rel, hint}]}`; hint names both remedies. `Autonomous.run/1`
→ `{:error, {:preflight, …}}`, no session, no store write. Then `git rm --cached` the
pack files, commit → `verify/2` → `:ok`, `source/1` → `:supplied` (US2-4).

## 5. Manual: tracked `settings.local.json` (edge case)

Commit `.claude/settings.local.json` → `verify/2` → `{:pack_local_tracked, …}`.

## 6. Resume across the upgrade (US3)

On a target with a parked pre-044 run: `Autonomous.continue_run(run_id)` → restarts at
the checkpointed phase; `git -C <worktree> status --porcelain` empty; both files present.
A refused continue (step 4 state) leaves `speckit_run` byte-identical and parked.

## 7. Console (US4)

`mise exec -- iex -S mix`, open Configuration: "target pack" row shows
`supplied by the orchestrator — contract 6` / `committed in the target — contract 6` /
a refusal, for the three targets above.

## 8. End-to-end (opt-in)

Container run against a scratch target with no pack (`scripts/autonomous …`), one
backlog feature: after publish, `gh pr diff` and `git log -p origin/feature/…` contain
neither `.claude/autonomous-pack.json` nor `.claude/settings.local.json` (SC-001/002).
