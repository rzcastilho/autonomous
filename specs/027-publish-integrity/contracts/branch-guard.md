# Contract: Branch-drift gate (US2)

## 1. Pure decision: `SpeckitOrchestrator.BranchGuard`

```elixir
@spec check(expected :: String.t(), observed :: String.t() | {:detached, String.t()}) ::
        :ok | {:drift, %{expected: String.t(), observed: String.t() | {:detached, String.t()}}}
```

- `observed == expected` returns `:ok`.
- Anything else (a different branch name, or `{:detached, sha}`) returns `{:drift, %{expected: expected, observed: observed}}`.
- It has no side effects and is unit-tested exhaustively.

## 2. Extraction: `Worktree.current_branch/1`

```elixir
@spec current_branch(Worktree.t()) :: {:ok, String.t() | {:detached, String.t()}} | {:error, term()}
```

- `git -C <path> symbolic-ref --quiet --short HEAD` exits 0 → `{:ok, name}`.
- If it exits non-zero, `git -C <path> rev-parse --short HEAD` → `{:ok, {:detached, sha}}`.
- If both fail, it returns `{:error, reason}`. The caller treats this as drift, with `observed: {:detached, "unknown"}`. This fails closed (Principle II): an unreadable HEAD is never assumed to be correct.

## 3. Call sites (FR-009)

The worktree check runs only when `state.worktree` is a `%Worktree{}` with a path. A `nil` worktree (dry run or unit test) skips it.

| Session | Site | On drift |
|---|---|---|
| Pipeline phase, analyze run, implement chunk | `Actions.RunFeaturePhase.run/2`, right after `PhaseSession.reduce/2`, first clause of `classify/4` | `last_outcome: :error`, `last_signals: %{branch_drift: d}`; history entry outcome `:error` |
| Auto-remediation attempt | `Actions.RunAutoRemediation.run/2` after `reduce/2` | attempt recorded failed; loop ends `{:failed, {:branch_drift, :analyze, d}}` |
| Pre-phase remediation (013) | `Actions.RunRemediation.run/2` after `reduce/2` | `FeatureRunner` ends `{:failed, {:branch_drift, :remediation, d}}` |

## 4. Propagation

- **`PhaseStep.retry_reason/1`**: `branch_drift` present gives `nil`, checked **first**, so a drifted session is never retried, not even as a transient one.
- **`Pipeline.next/3`**: the new clause `next(phase, :error, %{branch_drift: d}) when phase in @ordered -> {:failed, {:branch_drift, phase, d}}` sits ahead of the incomplete-session clause.
- **`ChunkRunner.dispatch/4`**: if `agent1.state.last_signals[:branch_drift]` is present, it skips `maybe_commit_boundary/4` and adds `branch_drift: d` to the chunk signals.
- **`Chunking.next/2`**: a new first row, `Map.has_key?(signals, :branch_drift) -> {:failed, {:branch_drift, :implement, d}, state}`.
- **`FeatureRunner.handle_worktree/5`**: when the reason is `{:branch_drift, _, _}`, it skips `Worktree.commit/2` and only calls `keep_for_inspection/1` (FR-011).
- **Boundary checkpoint commit**: this is unreachable on drift, because the outcome is `:error`, so no `{:cont, _}` transition occurs.

## 5. Invariants

- After drift is detected, the orchestrator runs **no** git write in that worktree: no commit, squash, checkout, reset, or branch deletion.
- A session that ends on the expected branch produces exactly the outcome and signals it produced before 027. The only change is the absence of the `branch_drift` key.
