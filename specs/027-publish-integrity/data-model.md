# Data Model: Publish Integrity (027)

This feature needs no schema migration. Every new fact is a term inside an existing column (`speckit_feature_run.terminal_reason`, `speckit_run.stopped_reason`, `speckit_phase_attempt` outcome/signals) or transient agent state.

## Publish failure reason

This is the value stored in `feature_run.terminal_reason` and `run.stopped_reason` when a backlog feature's publish fails.

```
{:publish_failed, kind, detail}

kind   :: :empty_branch | :push_failed | :pr_failed
detail :: %{
  required(:branch) => String.t(),       # the orchestrator's branch, feature/<spec_id>-<slug>
  optional(:base) => String.t(),         # the ref the PR targets (resolve_base/3's pick)
  optional(:remote) => String.t(),       # :push_failed
  optional(:branch_sha) => String.t(),   # :empty_branch
  optional(:base_sha) => String.t(),     # :empty_branch
  optional(:exit) => non_neg_integer(),  # :pr_failed (gh exit status)
  optional(:output) => String.t()        # verbatim git/gh output (:push_failed, :pr_failed)
}
```

| kind | produced when | side effects already done |
|---|---|---|
| `:empty_branch` | `git rev-list --count base..branch` is 0 | none (no push, no `gh`) |
| `:push_failed` | `Worktree.push/2` returns `{:error, _}`, including the `{:remote_branch_moved, …}` refusal | none on the remote |
| `:pr_failed` | `PullRequest.open/2` returns `{:gh_failed, code, out}` | branch pushed |

**Validation:** `branch` is always present. `output` is carried verbatim and never truncated or reformatted (SC-002).

## Branch-drift signal and reason

These are the agent signal (`last_signals.branch_drift`) and the terminal reason.

```
branch_drift :: %{expected: String.t(), observed: String.t() | {:detached, sha :: String.t()}}

terminal reason: {:branch_drift, phase, branch_drift}
phase :: Pipeline.phase() | :remediation     # :implement for a chunk; :analyze for auto-remediation
```

Recorded on the failing `phase_attempt` (implement chunks: the `:implement_chunk` row) through the existing outcome/signals path, and on `feature_run.terminal_reason`.

## Feature-run status transitions added

```
            FeatureRunner                     pr_notify (backlog, publish ok)
:running ──────────────▶ :done ─────────────────────────────▶ :done  (+ pr_url, stack advances)
                            │
                            │ pr_notify (backlog, publish fails)
                            ▼
                         :failed  reason {:publish_failed, kind, detail}   → run :in_flight → :parked
                            │
                            │ continue_run/1 → resume/2 publish-only route
                            ├── publish ok  ──▶ :done (reason :done, + pr_url), run continues
                            └── publish fails ─▶ :failed (new reason), run re-parked

:running ──(session ends off-branch)──▶ :failed  reason {:branch_drift, phase, d}
                                         worktree kept, no further commit
```

Ad-hoc features never take the publish-failure edge. They stay `:done` (FR-007).

## Stack chain entries (fix, R8)

`stack_seed/1` chain entry = `Worktree.locate(feature, opts).branch` = `"feature/#{Feature.spec_id(feature)}-#{slug}"` (was `"feature/#{id}-#{slug}"`).
