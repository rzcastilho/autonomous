# Contract: Publish outcome and chain stop (US1)

## 1. Publisher: `publish_feature/3` (real) and the `:publisher` seam

The signature is unchanged: `(feature, base) -> {:ok, url} | {:error, reason}`. The real publisher now always returns a **normalized** error of the form `{:publish_failed, kind, detail}` (see data-model.md). The steps, in order:

1. If the store already holds a `pr_url` for this feature in the current run (for example, the operator ran `record_pr/3` after opening the PR by hand), return `{:ok, url}`. It does no push and no `gh` call.
2. `Worktree.commits_beyond(repo, branch, base)`. A result of 0 returns `{:error, {:publish_failed, :empty_branch, %{branch, base, branch_sha, base_sha}}}`.
3. `Worktree.push(wt, remote)`. An `{:error, r}` returns `{:error, {:publish_failed, :push_failed, %{branch, remote, output: <r rendered verbatim>}}}`.
4. `PullRequest.open/2`. `{:gh_failed, code, out}` returns `{:error, {:publish_failed, :pr_failed, %{branch, base, exit: code, output: out}}}`.

A seam publisher may return any `{:error, term}`. `pr_notify` wraps a non-normalized term as `{:publish_failed, :pr_failed, %{branch: <locate branch>, output: inspect(term)}}` so the chain-stop path is uniform.

New `Worktree.commits_beyond/3`:

```elixir
@spec commits_beyond(repo :: Path.t(), branch :: String.t(), base :: String.t()) ::
        {:ok, non_neg_integer(), %{branch_sha: String.t(), base_sha: String.t()}} | {:error, term()}
```

A git error here is treated as `:empty_branch`-class unpublishable, with `output` carried. It fails closed: an unverifiable branch never advances the chain.

## 2. `pr_notify/5`: the stop point

When the runner notifies `(id, :done, reason)`:

| group | publisher result | store write | stack | forwarded notification |
|---|---|---|---|---|
| backlog | `{:ok, url}` | `record_pr_url`; if the row is `:failed` with a publish reason (continue path), `record_feature_terminal(:done, :done)` | `StackTracker.push(branch)` | `(id, :done, reason)` |
| backlog | `{:error, pf}` | `record_feature_terminal(id, :failed, pf)` (keeps `pr_description`) | **not pushed** | `(id, :failed, pf)` |
| ad_hoc | `{:ok, url}` | `record_pr_url` | none (FR-028) | `(id, :done, reason)` |
| ad_hoc | `{:error, pf}` | none | none | `(id, :done, reason)` (FR-007, unchanged) |

Both error rows log a warning and emit `[:speckit, :publish, :failed]` with metadata `%{feature_id, kind, reason}`. The ok rows emit `[:speckit, :publish, :opened]`, unchanged.

A non-`:done` notification passes through untouched.

## 3. Coordinator

No code change. The forwarded `:failed` makes `Release.next/3` return `{:stopped, id, :failed}`, and `finish_run/1` parks the run with `%{stopped_by: id, status: :failed, reason: {:publish_failed, …}}`. The final report's `stopped_by.reason` is the same term.

## 4. Continue / resume: the publish-only route

In `resume/2`, after `find_feature_record/2`, check whether `feature_record.status == :failed` and `feature_record.terminal_reason` matches `{:publish_failed, _, _}`:

- If any of `:from`, `:prompt`, `:from_task_phase`, `:remediation_prompt`, `:remediation_model` is supplied, return `{:error, {:publish_only, feature_id}}`.
- Otherwise, skip `resolve_start_phase/2`, restore the run scope as today (`restore_run_scope/2`, `merge_resume_target/2`), and inject as the target executor:

  ```elixir
  fn feature, _base, notify ->
    Workers.spawn(run_key, feature.id, fn -> notify.(feature.id, :done, :republish) end)
    :ok
  end
  ```

  `run_stacked/4` wraps it with `pr_notify`, so §1 and §2 apply with the base `resolve_base/3` picks from the restored chain.

`continue_run/1` is unchanged. It reaches this route through its existing call to `resume(stopped_by, opts)`.

## 5. Stack seed fix

`stack_seed/1` maps each chain feature to `Worktree.locate(feature, worktree_create_opts(layout)).branch`, which is `feature/<spec_id>-<slug>`. The layout is needed only for `worktree_root`, which the branch name does not use, so `Worktree.locate/1` with defaults suffices.

## 6. Invariants

- A backlog feature's branch joins the chain **iff** its publish returned `{:ok, _}`.
- No feature is released after a backlog publish failure until an operator `:continue`s or `:end`s the run.
- A continue never runs a phase session for a publish-failed feature (SC-006).
