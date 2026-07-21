# Contract: `SpeckitOrchestrator.resume/2` (extended)

Extends the 005 resume contract with **id-only identity recovery** and **run-context
reapplication**. Signature and all existing distinct error outcomes are preserved;
the id-only form is additive (backward compatible).

```elixir
@spec resume(String.t(), keyword()) ::
        GenServer.on_start()
        | {:error, {:unknown_feature, String.t()}}
        | {:error, :no_checkpoint}
        | {:error, :corrupt_checkpoint}
        | {:error, {:unknown_phase, term()}}
def resume(feature_id, opts \\ [])
```

## Options (new/changed)

Existing (`:features`, `:runner`, `:owner`, `:prompt`, `:from`, and every `run/1`
opt) are unchanged. The six run-context opts (`:pr_workflow`, `:max_concurrency`,
`:budget_usd`, `:plan_stack`, `:pr_base`, `:pr_remote`) now act as **explicit
overrides** that win over recorded context (FR-007).

## Resolution order (deterministic, order-independent)

1. **Read checkpoint** (`Checkpoint.read/1`): `{:error, :no_checkpoint}` →
   `{:error, :no_checkpoint}`; `{:error, :corrupt}` → `{:error, :corrupt_checkpoint}`.
   Both start no run (FR-005). Corrupt never fabricates identity/context.
2. **Resolve identity (FR-002/003/004)**:
   - If an explicit/backlog feature for `feature_id` exists (`:features` supplied, or
     a best-effort `load_backlog/0` that finds it) → use it (explicit wins).
   - Else if the checkpoint carries `slug` + `path` → reconstruct
     `%Feature{id: feature_id, slug:, path:, status: :pending}`.
   - Else → `{:error, {:unknown_feature, feature_id}}`, no run (edge:
     unknown-feature). Backlog **need not** load or contain the feature (FR-004); a
     load failure is non-fatal and falls through to checkpoint identity.
3. **Resolve start phase (unchanged)**: `:from` override else checkpoint
   `last_phase`, validated by `Pipeline.phase?/1`; invalid →
   `{:error, {:unknown_phase, term()}}` (edge: invalid/overridden phase).
4. **Reapply run context (FR-007/008)**: `ctx = RunContext.from_map(record["context"])`;
   `{merged_opts, fell_back} = RunContext.merge(opts, ctx)`. If the record had no
   `"context"` or it was partial (`fell_back != []`), emit one `Logger.info`
   naming the fallen-back keys (FR-008 observability).
5. **Select worktree strategy (FR-009)** using the *effective* `pr_workflow`
   (from `merged_opts`):
   - `pr_workflow` false → inject `:runner` = resume runner (reuse the kept worktree,
     else recreate from the existing branch, else `{:error, :branch_missing}` via a
     `:failed` notify — unchanged from 005).
   - `pr_workflow` true → inject `:executor` = resume executor (same worktree
     reuse/recreate logic) and let `run_stacked/1` wrap it with stacking + preflight
     + PR-on-`:done`. A caller-supplied `:runner`/`:executor` still wins (test seam).
6. **Start the run**: `merged_opts |> put(:features, [feature]) |> put(runner|executor)
   |> run()`. The resumed feature runs at the resolved start phase, with
   `:resume_prompt` carried as before, under the reapplied context.

## Precedence (single documented rule)

- **Identity** (FR-003): explicit/backlog feature > checkpoint identity. Not
  argument-order dependent.
- **Context** (FR-007): explicit `resume` opt > recorded context > live
  Config/default. Live env/Config is **only** a fallback for unrecorded settings,
  never an override of a recorded value.

## Invariants preserved (FR-005 / SC-003)

- `no-checkpoint`, `corrupt-checkpoint`, `unknown-phase`, `unknown-feature`,
  `branch-missing` remain five distinct outcomes, each starting no run.
- A resumed PR-workflow feature runs sequentially (cap 1) with stacking/preflight and
  PR-on-completion (FR-009 / SC-002).
- Backward compatible: passing an explicit `:features` definition + existing options
  behaves exactly as in 005 (acceptance 3).
