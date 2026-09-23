# Research: Publish Integrity (027)

All unknowns were resolved against the code on `main` at `61ba036` and against the evidence from the 2026-09-23 incident (mod-player, backlog 002).

## R1 — Where the drift entered, and why nothing noticed

**Finding.** The mod-player target carries the speckit git extension, and `.specify/extensions.yml` registers `before_specify: speckit.git.feature` with `optional: false`. That hook's `create-new-feature-branch.sh` computes the next number from the existing specs and branches (`feature/015-…` already existed, so it picked 016), then runs `git checkout -b 016-control-variants`. The worktree reflog for 003 shows the same event: `checkout: moving from feature/015-list-row-and-panel-components to 017-list-row-and-panel-components`.

The orchestrator only ever names the branch through `Worktree.locate/2` (`feature/<spec_id>-<slug>`, computed from the feature and never read back from git). Nothing between worktree creation and publish reads HEAD:

- `FeatureRunner`'s per-phase checkpoint commit (`Worktree.commit/2`) commits on whatever HEAD is. That is why every checkpoint landed on `016-control-variants`.
- The `:done` squash (`Worktree.squash/3`) also operates on HEAD.
- `publish_feature/3` pushes the name `Worktree.locate/2` gives.

Earlier features worked only because the model happened not to run the hook.

**Decision.** Add two layers: a pin (the prompt, US3) and a guarantee (a HEAD check after every session, US2). The pin alone is advisory, because the model decides whether to honour it.

## R2 — Where the drift check lives

**Decision.** Put it in `Actions.RunFeaturePhase.run/2`, immediately after `PhaseSession.reduce/2` returns and before `classify/4`, as the first classification clause (ahead of the incomplete-session gate). Every pipeline phase, every analyze run and re-run (`AnalyzeRunner` → `PhaseStep` → `"phase.run"`), and every implement chunk (`ChunkRunner` dispatches `"phase.run"` with a `scope`) already passes through this action. So one call site covers FR-009 for phases and chunks.

The two remediation actions (`RunAutoRemediation`, `RunRemediation`) drive their own sessions outside `RunFeaturePhase`, so each gets the same check after its `PhaseSession.reduce/2`.

The decision itself is a pure function, `BranchGuard.check(expected, observed)`, which satisfies FR-012 and Principle I. Only the extraction (`Worktree.current_branch/1`) touches git.

**Alternatives considered.**
- *Check once per phase in `FeatureRunner.loop`.* Rejected: it misses chunk sessions (the chunk boundary commit in `ChunkRunner.maybe_commit_boundary/4` runs before control returns to the loop, so it would commit on the stray branch first) and remediation sessions.
- *Check only before publish.* Rejected: the feature would spend the whole pipeline's budget on a branch that can never publish, and SC-003 requires 0 extra sessions after drift.
- *Silently check the expected branch back out.* Rejected by the spec (FR-011). The stray branch holds commits the orchestrator did not make on its own branch, and re-pointing would mis-attribute or strand them.

## R3 — How drift propagates to a terminal

**Decision.**
- **Phase path.** Drift sets `last_outcome: :error` with `last_signals: %{branch_drift: %{expected: b, observed: o}}`. A new `Pipeline.next(phase, :error, %{branch_drift: d})` clause, ahead of the incomplete-session clause, returns `{:failed, {:branch_drift, phase, d}}`.
- **Retry.** `PhaseStep.retry_reason/1` returns `nil` for `branch_drift` before any other test, including `transient?`. A drifted session is never retried (FR-011).
- **Chunk path.** `ChunkRunner.dispatch/4` reads `agent1.state.last_signals` and, when `branch_drift` is present, (a) skips `maybe_commit_boundary/4` and (b) passes `branch_drift` in the chunk signals. A new first row in `Chunking.next/2` returns `{:failed, {:branch_drift, :implement, d}, state}`, ahead of the session-error row.
- **Analyze loop.** A drifted analyze run is an `:error` outcome, so `Remediation.next/2` does not remediate. The final signals reach `Pipeline.next/3`, which returns the drift terminal.
- **Remediation.** A drifted remediation session ends the loop as failed with `terminal_reason {:branch_drift, :analyze, d}` (auto-remediation) or `{:branch_drift, :remediation, d}` (pre-phase remediation, feature 013).
- **Terminal handling.** `FeatureRunner.handle_worktree/5`'s non-`:done` clause normally runs `Worktree.commit/2` ("pipeline artifacts"), which would commit onto the stray branch. For a `{:branch_drift, _, _}` reason it skips the commit and only keeps the worktree.

## R4 — Representing "built but not published" (spec FR-005)

**Decision.** Use the existing lifecycle status `:failed` with a distinct, structured `terminal_reason`: `{:publish_failed, kind, detail}`, where `kind ∈ [:empty_branch, :push_failed, :pr_failed]`.

**Rationale.**
- `Release.next/3` already stops the chain on any non-`:done` terminal, and the Coordinator already parks on that stop. US1 then needs no change to `Release`, the Coordinator's finish logic, or `Writer.park_run/2`.
- `speckit_feature_run.terminal_reason` is a free term column, so there is no schema migration (FR-016).
- The reason tag makes the feature distinguishable (FR-005) on every surface that already renders `terminal_reason` / `stopped_reason`.
- There is no new status atom, so the design constitution's status-colour inventory and `CoreComponents.status_class/1` are untouched.

**Alternatives considered.**
- *A new `:unpublished` status.* Rejected: it touches `Feature`, `Release`, `Coordinator.classify/1`, the reports, Recovery's `persisted_status/1`, and the console's status tokens and design contract, all for a state the operator resolves the same way as a stop.
- *Keep `:done` and add a new `publish_failure` column (schema v6).* Rejected: `Release` would treat the feature as done and release the next feature, which is exactly the bug. A second, parallel stop mechanism would also be needed.

**Recovery safety.** `Recovery.Reconcile.status(:failed, _, _)` returns `:failed` unconditionally (reconcile.ex:62), so a resume never "corrects" a publish-failed feature back to `:done` from its done-signal evidence.

## R5 — Where the publish failure becomes a stop

**Decision.** `pr_notify/5` (lib/speckit_orchestrator.ex) already intercepts the runner's `:done` notification before the Coordinator sees it. For a **backlog** feature, when `publish_and_advance/4` fails, it now:

1. rewrites the store row `:done → :failed` with the publish reason (`Writer.record_feature_terminal/5`; the `pr_description` is kept, since the function only deletes the checkpoint on `:done`, which already happened);
2. does **not** call `StackTracker.push/2`;
3. forwards `notify.(id, :failed, {:publish_failed, kind, detail})` instead of `:done`.

The Coordinator then parks the run through the existing path, with `stopped_by` naming the feature and `stopped_reason` holding the publish reason (FR-002, FR-003). An **ad-hoc** feature keeps today's behaviour: warning, telemetry, `:done` forwarded (FR-007).

## R6 — The empty-branch check

**Decision.** `publish_feature/3` first computes `Worktree.commits_beyond(repo, branch, base)` = `git rev-list --count <base>..<branch>` in the base repo. Zero gives `{:error, {:publish_failed, :empty_branch, %{branch, base, branch_sha, base_sha}}}` with no push and no `gh` call (FR-001). `base` is the `base` argument the stacked runner already passes to the publisher, which is the base `resolve_base/3` picked (merged links skipped). The PR targets that same ref, which satisfies the "base resolved past merged links" edge case. The check runs before `Worktree.push/2`, so a stale remote branch equal to the base (the incident's `origin/feature/015-control-variants`) cannot mask it.

Push errors become `{:publish_failed, :push_failed, %{branch, remote, output}}`. That includes `{:remote_branch_moved, …}` refusals, whose detail is kept. `PullRequest.open/2`'s `{:gh_failed, code, out}` becomes `{:publish_failed, :pr_failed, %{branch, base, exit: code, output}}` (FR-003, "verbatim output").

## R7 — Continuing a publish-failure park

**Finding.** `continue_run/1` → `resume/2` → `resolve_start_phase(feature_record.checkpoint, …)`. A publish-failed feature reached `:done` first, and `record_feature_terminal(:done)` deleted its checkpoint, so today's path would return `{:error, :no_checkpoint}`. The worktree is also gone (`handle_worktree(:done)` removes it). Only the branch remains, and that is all publishing needs.

**Decision.** In `resume/2`, a feature whose record is `status: :failed, terminal_reason: {:publish_failed, _, _}` takes a **publish-only** route:

- There is no start-phase resolution and no worktree. The target executor is `fn feature, _base, notify -> Workers.spawn(run_key, id, fn -> notify.(id, :done, :republish) end) end`. The stacked runner wraps it in `pr_notify`, so the ordinary publish path (R5/R6) runs with the base the restored chain resolves.
- On success, the store row goes back to `:done` (reason `:done`), the URL is recorded, the stack advances onto the branch, and the next feature releases (FR-006, SC-006: zero phases re-run).
- On failure, it parks again with the new reason. The operator loses nothing.
- If the operator already opened the PR by hand and recorded it with `record_pr/3`, the publisher sees the recorded `pr_url` and returns `{:ok, url}` without pushing or calling `gh`, because `gh pr create` would fail with "already exists".
- `:from` (or any phase-shaped option) on a publish-failed feature returns `{:error, {:publish_only, feature_id}}`. Rebuilding is `resolve/1`'s job, not a continue.

## R8 — Latent stack-seed naming bug (found while tracing R7)

**Finding.** `stack_seed/1` builds chain entries as `"feature/#{&1.id}-#{&1.slug}"`, which uses the backlog **number**. Since feature 022, the real branch is `feature/<spec_id>-<slug>` (`Worktree.locate/2`), which uses the repo-monotonic **spec_number**. In mod-player, backlog 001 is spec 014, so any resumed or continued run seeds `feature/001-…` / `feature/002-…`: names that do not exist. `Worktree.merged?/4` reads an absent branch as merged, so the chain silently collapses to `pr_base`, and the next feature branches from and targets the trunk, without its predecessors. That is the same failure class as the incident.

**Decision.** In scope, because R7 depends on it (FR-006's "stacked on the parked feature's branch"): `stack_seed/1` maps each feature through `Worktree.locate/2` (which honours `spec_number` via `Feature.spec_id/1`). Restored features already carry `spec_number` (`Recovery.to_feature/1`).

## R9 — Branch pinning in the specify prompt

**Finding.** The git extension's `speckit.git.feature` command honours `GIT_BRANCH_NAME` ("uses the exact value as the branch name, bypassing all prefix/suffix generation"). The branch script accepts `--allow-existing-branch` ("Switch to branch if it already exists instead of failing"). With both, a model that runs the mandatory hook ends up on the orchestrator's branch, which is a no-op checkout because it is already there.

**Decision.** `PhaseRequest`'s `:specify` prompt adds, after the existing `SPECIFY_FEATURE_DIRECTORY` pin: `Use GIT_BRANCH_NAME=<worktree branch>. That branch already exists and is checked out: reuse it (allow existing branch); never create or switch to another branch.` The branch string comes from the same `Worktree.locate/2` naming, so there is one source of truth. Targets without the extension ignore the text (FR-014).

## R10 — Operator surfaces

**Finding.** `Report.format_reason/1` falls back to `inspect/1`. The console renders `stopped_reason` with `inspect/1` (`MissionControlLive` parked banner, `RunDetailLive`, `RunsLive`) and `terminal_reason` through `RunDetailLive`'s `format_reason`.

**Decision.** Add one pure renderer, `PublishOutcome.describe/1`, for `{:publish_failed, kind, detail}` and `{:branch_drift, phase, d}`. It produces text in the system's vocabulary (Principle VII): kind atom, branch, base, then the verbatim output. `Report.format_reason/1` and the console's three `inspect(stopped_reason)` sites plus `RunDetailLive.format_reason` delegate to it for those tags and keep `inspect/1` for everything else. The output text sits in the existing mono span (no new CSS token, no inline style), so the design-contract guard stays clean. Telemetry: `[:speckit, :publish, :failed]` metadata gains `kind` alongside the full `reason` (FR-004).
