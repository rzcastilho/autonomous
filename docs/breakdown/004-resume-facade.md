# 004 — `resume/2` operator facade

## Summary

Add the operator entry point `SpeckitOrchestrator.resume/2` that restarts a
halted/escalated feature at its checkpointed phase, reusing the feature branch
and the human's committed fix, with an optional guidance prompt.

## Context

`SpeckitOrchestrator.resolve/1` only removes the kept worktree, so the next
`run/1` re-runs the whole pipeline from `specify` (`speckit_orchestrator.ex:115-134`).
With checkpoint persistence (001), the resume entry point (002), and prompt
injection (003) in place, a surgical resume path can restart at the halted phase
instead of the beginning.

## User value

An operator resolves the cause on the feature branch, then runs
`SpeckitOrchestrator.resume(id, prompt: "...")` and the feature resumes at its
halted phase — no re-`specify`, no clobbering the human's edits, no re-paying
already-committed phases.

## Prerequisites

- 001 Resume checkpoint persistence
- 002 FeatureRunner resume entry point
- 003 Operator prompt injection at the resume phase

## In scope

- New `SpeckitOrchestrator.resume(feature_id, opts \\ [])`:
  - `:prompt` — operator guidance injected into the resume phase (optional).
  - `:from` — override the start phase (default: `checkpoint.last_phase`).
  - plus the same run opts as `run/1`.
- Flow:
  1. `Checkpoint.read/1` → `{:error, :no_checkpoint}` when absent.
  2. Resolve `start_phase = opts[:from] || checkpoint.last_phase`.
  3. Build a one-feature wave (`:features => [feature]`) with a **resume runner**
     that reuses the kept worktree or recreates it from the branch
     (`Worktree.create` already reuses an existing branch), then calls
     `FeatureRunner.run` with `start_phase:` + `resume_prompt:`.
  4. Return the coordinator `on_start` tuple (as `run/1`).
- Keep `resolve/1` unchanged for the full-restart path.

## Out of scope

- Multi-feature resume; UI. One feature per call.

## Acceptance

- With a fake runner and a fixture checkpoint, `resume/2` starts at
  `checkpoint.last_phase`; a `:from` opt overrides it.
- `{:error, :no_checkpoint}` when no checkpoint exists for the id.
- `{:error, {:unknown_feature, id}}` for an unknown id (matches `resolve/1`).
- The operator prompt reaches the resumed phase (integration with 003).
- Compile clean under `warnings_as_errors`; tests green.

## Technical notes

- Mirror the one-feature-wave + runner-wrapper pattern already proven by
  `run_spec` / `seed_runner` / `run_seeded` (`speckit_orchestrator.ex:85-102,
  247-289`).
- Branch reuse on worktree recreate is handled by `Worktree.create`
  (`worktree.ex:154-168`).
