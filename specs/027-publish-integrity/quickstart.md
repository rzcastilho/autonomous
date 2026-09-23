# Quickstart: validating Publish Integrity (027)

Run every command through mise. `warnings_as_errors` is on.

## 1. Unit and seam tests (default suite)

```bash
mise exec -- mix test
```

Expected new coverage:

| Scenario | Where | Expect |
|---|---|---|
| `BranchGuard.check/2` table (same, other branch, detached) | `branch_guard_test.exs` | `:ok` / `{:drift, …}` |
| `Worktree.current_branch/1` and `commits_beyond/3` against a real temp git repo | `worktree_test.exs` | branch name / `{:detached, sha}`; count 0 and >0 |
| A phase session that runs `git checkout -b other` in the worktree (stubbed harness) | `run_feature_phase_test.exs` | `last_outcome: :error`, `last_signals.branch_drift` names both branches |
| Drift is not retried | `phase_step_test.exs` | exactly one session |
| `Pipeline.next(:specify, :error, %{branch_drift: d})` | `pipeline_test.exs` | `{:failed, {:branch_drift, :specify, d}}` |
| Chunk drift | `chunking_test.exs`, `chunk_runner_test.exs` | `{:failed, {:branch_drift, :implement, d}, _}`; no boundary commit on either branch |
| Drift terminal writes no commit | `feature_runner_test.exs` | stray branch tip and orchestrator branch tip unchanged after terminal; worktree kept |
| Stacked run, publisher returns `{:error, _}` for feature 1 | `stacked_run_test.exs` | feature 2 never released; run parked; `stopped_by.reason` is `{:publish_failed, …}`; tracker chain has no feature 1 |
| Stacked run, ad-hoc publish fails | same | run continues; ad-hoc is `:done` |
| Empty branch (real temp repo, branch == base) | `stacked_run_test.exs` (real temp repo) | `{:publish_failed, :empty_branch, _}`; no push attempted (no remote configured, so a push would error differently) |
| `continue_run/1` after a publish park, publisher now ok | `resume_test.exs` / parked-run tests | 0 phase sessions for the parked feature; its row back to `:done` with `pr_url`; next feature's base is the parked branch |
| `continue_run/1` with `pr_url` pre-recorded via `record_pr/3` | same | publisher never called |
| `resume/2` with `:from` on a publish-failed feature | same | `{:error, {:publish_only, id}}` |
| `stack_seed/1` with `spec_number` ≠ `number` | stacked test | chain entries are `feature/<spec_id>-<slug>` |
| Specify prompt | `phase_request_test.exs` | contains `GIT_BRANCH_NAME=feature/<spec_id>-<slug>` and the reuse sentence |
| `PublishOutcome.describe/1` table | `publish_outcome_test.exs` | exact strings; `nil` for other terms |
| Design contract | `design_contract_test.exs` | still green |

## 2. Live replay against a scratch target (manual)

This covers SC-001, SC-003 and SC-004.

1. Create a scratch target that carries the speckit git extension with `before_specify: speckit.git.feature` mandatory. mod-player's `.specify/` is a ready source. Install the target pack.
2. Two-feature backlog. Start `SpeckitOrchestrator.run/1` with a small budget.
3. **Pin (US3).** After feature 1's `specify`, `git -C <worktree> branch --show-current` is `feature/<spec_id>-<slug>`.
4. **Drift (US2).** Re-run with the pin sentence removed from the prompt (a local patch). Expect feature 1 `:failed`, reason `branch_drift in :specify — expected feature/…, HEAD on NNN-…`, worktree kept, no further sessions, run parked.
5. **Publish stop (US1).** Point `pr_remote` at a remote that rejects pushes (for example, a bare repo with a `pre-receive` hook that exits 1). Expect feature 1 `:failed` with `publish_failed :push_failed — …` shown in `print_status/0` and in the console's parked banner; feature 2 is never released.
6. Fix the remote and run `SpeckitOrchestrator.continue_run/0`. Expect a PR for feature 1, no feature-1 phase sessions in the transcripts, and feature 2 branching from feature 1's branch.
