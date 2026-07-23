# Contract: `Worktree.squash/3` and `Worktree.restore/1` (extensions)

Two new functions on `SpeckitOrchestrator.Worktree`. Both operate only on the
feature's own worktree/branch and use the existing private `git/2` plumbing.

## `squash/3` — collapse per-phase commits at completion (FR-004)

```elixir
@spec squash(t(), String.t(), String.t()) :: :ok | :noop | {:error, term()}
def squash(worktree, base_ref, message)
```

- `base_ref` — the branch's fork point. Computed by the caller as
  `git merge-base HEAD <pr_base-or-create-base>`; when unknown, the caller passes
  the base the worktree was created from.
- Behavior: `git -C <path> reset --soft <base_ref>` (moves branch ref to base,
  **keeps** working tree + index), then a single commit with `message` using the
  orchestrator author. Returns `:noop` when there is nothing staged (a feature
  that produced no changes), `{:error, term}` on a git failure.
- Called by `FeatureRunner.handle_worktree/3` on `:done`, **replacing** the single
  terminal `Worktree.commit/2` — the per-phase commits already captured the work;
  squash rewrites them into one, then the existing PR/remove flow proceeds.
- On kept terminals (`:escalated`/`:halted`/`:failed`) squash is **not** called —
  per-phase commits remain as the post-mortem trail.

**Invariant**: the post-squash tree is byte-identical to pre-squash HEAD (only
history changes). Only the unpublished feature branch is rewritten.

## `restore/1` — discard partial output before a resumed phase (FR-003)

```elixir
@spec restore(t()) :: :ok | {:error, term()}
def restore(worktree)
```

- Behavior: `git -C <path> reset --hard HEAD` then `git -C <path> clean -fd`,
  returning the worktree to the last phase-boundary commit (drops any uncommitted
  partial output from the interrupted phase).
- Called by the resume path (per-feature `resume/2` runner and the `resume_run/1`
  resume-aware runner) **before** re-running the interrupted phase.
- `clean -fd` respects `.gitignore`, so `.speckit_logs/` transcripts are **not**
  removed (they are the audit trail).

## Test contract (integration — `--include integration`, real git)

- **squash**: create a branch, make N per-phase commits, `squash/3` to the fork
  point → `git rev-list --count <base>..HEAD == 1`; `git diff <pre-squash-HEAD>
  HEAD` is empty.
- **restore**: commit a clean tree, write an uncommitted partial file, `restore/1`
  → the partial file is gone, tracked files match the last commit,
  `.speckit_logs/` (gitignored) survives.
