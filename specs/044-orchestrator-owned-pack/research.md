# Research: Orchestrator-Owned Target Pack (044)

All Technical Context unknowns resolved below. Each entry: Decision / Rationale /
Alternatives considered.

## R1 — Do headless sessions load `.claude/settings.local.json`?

**Decision**: Yes; rely on it. No `--setting-sources` change is needed.

**Rationale**: `ClaudeAgentSDK.Options` emits `--setting-sources` only when
`setting_sources` is non-nil (`deps/claude_agent_sdk/lib/claude_agent_sdk/options.ex:820-827`,
"Do not emit --setting-sources by default"), and neither `jido_claude` nor this repo
sets it (grep: no hits in `deps/jido_claude/lib` or `lib/`). With the flag absent the
CLI loads its default sources — user, project (`settings.json`) and local
(`settings.local.json`) — with local layered over project, and `--settings` (the launch
values from `PhaseRequest`, `phase_request.ex:156-170`) above both.

**Alternatives considered**:
- Pass the pack through `--settings` only and supply no file: the launch already carries
  the shell timeouts there; but the spec wants the marker/settings present in the
  worktree as the contract stamp (FR-003, FR-010), and an explicit `--setting-sources`
  would risk dropping the operator's own `settings.json` sources.
- Write `settings.json` in the worktree: rejected by the clarification — it is a
  tracked file whenever the target commits one (FR-005).

## R2 — How to keep the supplied files untracked for every worktree and the checkout

**Decision**: Append a marked block to the target's **common** git directory exclude
list, `$(git rev-parse --git-common-dir)/info/exclude`:

```text
# autonomous: orchestrator-supplied pack (feature 044) — do not edit this block
/.claude/autonomous-pack.json
/.claude/settings.local.json
```

Written idempotently (each line added only if absent; a pre-existing operator entry or a
`.gitignore` rule is left alone and does not cause duplication).

**Rationale**: Linked worktrees read `info/exclude` from the common dir, not from their
per-worktree `$GIT_DIR`, so one entry covers every worktree and the main checkout
(spec edge case 1). It modifies no tracked file and needs no `.gitignore` edit. Every
git path the orchestrator uses already respects it: `git add -A` (`Worktree.commit/2`,
`ChunkRunner`) never stages ignored files; `squash/3` (`reset --soft`) never touches
untracked files; `restore/1`'s `git clean -fd` (no `-x`) keeps ignored files;
`git status --porcelain` (`RunFeaturePhase.changed_paths/2`) hides them; `push` and the
PR diff carry only commits. Exclude has no effect on tracked paths, so a committed
marker is unaffected (US2).

**Alternatives considered**:
- Per-worktree `core.excludesFile` via `extensions.worktreeConfig`: changes the target's
  repository format extension — invasive, and older git/tools in the operator's
  environment may refuse the repo.
- Editing `.gitignore`: modifies a tracked file (FR-005).
- `git update-index --assume-unchanged` / `skip-worktree`: only for tracked files.
- Deleting the files before each commit: racy with sessions, and `restore/1` would need
  re-supply anyway.

## R3 — Where the orchestrator supplies the pack

**Decision**: One new function, `TargetPack.supply/1` (worktree path → `{:ok, report} |
{:error, reason}`), called from exactly two places in `Worktree`:

1. `Worktree.create/2`, after `git worktree add` and the scaffold assertion (a failure
   tears the half-made worktree down exactly like `:missing_scaffold`);
2. `Worktree.restore/1`, after `reset --hard` + `clean -fd`.

Every path that hands a worktree to a session goes through one of them: `run_fresh`,
`default_executor`, `seed_executor` (`run_spec/2`) all call `create/2`;
`resume_worktree/2` (resume, `resume_run/1`, `continue_run/1`) calls `create/2` for a
freed worktree and `restore/1` always. The publish-only route runs no session and needs
no pack.

**Rationale**: Keeps the supply at the git boundary module that already owns scaffold
assertions, so no caller can forget it (FR-003, US3-2). Idempotent: on a current
worktree it writes nothing.

**Alternatives considered**: calling it at the top of `FeatureRunner.run/2` — misses
`run_seeded`'s pre-runner seed step and puts I/O into the runner's start.

## R4 — What `supply/1` does, in order

**Decision**:

1. **Inspect the worktree's tracked tree** (`git -C wt ls-files` for the four paths and
   the working copy content): this is the worktree-level twin of the preflight, because
   a stacked base branch can differ from the target `HEAD` the preflight read.
   - tracked `.claude/settings.local.json` → `{:error, {:pack_local_tracked, rel, hint}}`;
   - tracked marker with `contract < 6` or undecodable → `{:pack_outdated, rel, hint}`;
   - tracked `settings.json` that registers `scope_guard.py` or carries a non-empty
     `permissions.deny` → `{:pack_outdated, rel, hint}`; not a JSON object →
     `{:invalid_settings, rel}`;
   - tracked `.claude/hooks/scope_guard.py` → `{:pack_outdated, rel, hint}`.
2. **Exclude** (R2) in the common dir.
3. **Install** via the reworked `install/2` against the worktree (R5).

Never writes, merges or deletes a tracked file: step 1 refuses every case where step 3
would have to.

**Rationale**: FR-005, FR-007, FR-008, FR-010. Refusal is the only response to a tracked
outdated pack (clarification Q2).

## R5 — `install/2` rework

**Decision**: `install/2` keeps its signature and its three behaviours (never clobber the
constitution, honour the operator's tracked `env`, remove a stale hook file), with these
changes:

- writes the pack settings to `.claude/settings.local.json`; never writes
  `.claude/settings.json`;
- the settings it writes are `local_settings(pack, tracked)`: the pack's
  `priv/target_pack/.claude/settings.json` with every `env` key the existing
  `settings.json` already sets **removed** (so the operator's value is the one in effect —
  local outranks project, R1), all other keys verbatim;
- writes the marker only when absent or not current (a tracked current marker is left
  byte-identical);
- writes `settings.local.json` only when its bytes differ (idempotent).

`merge_settings/2` is replaced by `local_settings/2` (pure, `@spec`'d).

**Rationale**: FR-006, FR-013, clarification Q3. Keeping the stale-hook removal is for
manual operator calls on a checkout; in a worktree a stale hook is always tracked and
refused by R4 step 1 first, so `install/2` never deletes a tracked file there.

**Alternatives considered**: writing the full pack settings and relying on precedence —
would make the pack's `env` override the operator's tracked `env` (local > project),
reversing the 032 precedence.

## R6 — Preflight (`verify/2` / `check_pack_contract/2`) changes

**Decision**:
- drop `require_file(".claude/settings.json")`;
- `check_pack_contract/2` (committed tree by default) becomes:
  marker **absent** → ok (supplied); present → `contract >= 6`;
  `settings.json` absent → ok; present → no scope-guard hook, no deny, JSON object;
  stale hook file absent; `settings.local.json` **not tracked**
  (`git ls-files --error-unmatch`; with `committed? = false` it is skipped);
- the `@outdated_hint` names both remedies: "update the tracked file to pack contract 6
  and commit it, or remove the pack files from version control
  (`git rm --cached .claude/autonomous-pack.json …`) so the orchestrator supplies them".

`verify/2` still runs on `run/1`, `run_spec/2`, `resume/2`, `continue_run/1` (call sites
`autonomous.ex:2366` and `:2654` unchanged), before any flip, so a refused continue stays
parked byte-identical (FR-012, feature 035).

**Rationale**: FR-001, FR-002, FR-007, FR-008, FR-010.

## R7 — Pack contract number

**Decision**: Stays **6**.

**Rationale**: The contract defines the marker and the settings content; neither changes.
Only who writes it and the file name of the settings change. An older orchestrator never
meets a 044 worktree (worktrees are orchestrator-local), and a committed contract-6 pack
remains valid under 044 (US2-1). A bump would force every target to reinstall again —
the exact friction this feature removes.

## R8 — Pack source for the console

**Decision**: `TargetPack.source/1` (repo → `{:ok, %{source: :supplied | :committed,
contract: pos_integer()}} | {:error, reason}`): `:committed` when the target's `HEAD`
tracks the marker and it is current (contract read from it), `:supplied` when it does
not (contract = `contract/0`), `{:error, reason}` for the refusals of R6. Rendered by a
new pure `Web.PackView` (`state/1` → `{:supplied, n} | {:committed, n} | {:refused,
text}`) as a "target pack" row in Configuration, next to "agent root". The refusal text
comes from `Report.format_reason/1` (new clauses for `:pack_local_tracked` and
`:invalid_settings`). Computed once per mount/refresh in a `Task` (two `git` reads), not
in a callback others await (Principle VI).

**Alternatives considered**: storing the source on the run record — rejected; the spec
says no migration and the record does not store the pack.

## R9 — Commit messages, PR body and describe

**Decision**: No code change; covered by a test. `Describe` reads the spec and the real
diff/commits of the branch; excluded files are in neither (R2). A test asserts
`git diff --name-only <fork>..HEAD` and `git status --porcelain` never name either file
after a supplied run's commit + squash (FR-014, SC-002).

## R10 — Operator calling `install/2` by hand on the target checkout

**Decision**: Still works (FR-013) and writes the marker + `settings.local.json` into the
checkout; documented as unnecessary and as affecting the operator's own interactive
sessions there (the allow list and timeouts would apply). The orchestrator itself never
calls `install/2` on the checkout — only `supply/1` on worktrees (FR-016).

## R11 — Constitution amendment

**Decision**: 7.1.0 → 7.2.0 (MINOR), made through `/speckit-constitution` as the first
implementation task, with a Sync Impact Report. Rewrites:
- Principle III bullet 3: "a run MUST NOT start against a target-repo pack — committed
  or orchestrator-supplied — that does not meet the current pack contract. The
  orchestrator supplies the pack into each worktree, untracked; a committed pack is
  optional and, when present, MUST meet the contract or preflight fails loudly naming
  both remedies. Supplying the pack MUST NOT modify a tracked file."
- Principle III bullet 4: the supplied files exist only in feature worktrees, so a
  human-started session in the target checkout never sees them.
- Development Workflow: "the committed `.specify/` scaffold and the target's own
  `.claude/` content MUST travel into each worktree; the orchestrator pack is supplied
  into it."

**Rationale**: FR-018. No MUST is removed; the contract-6 guarantee holds for both
sources, so MINOR (same reasoning as 7.1.0, 6.1.0).
