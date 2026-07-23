# Quickstart: Crash Recovery — validation guide

Runnable scenarios that prove the feature end-to-end. Prefer the hermetic ExUnit
scenarios (fakes for runner/manifest/ledger, no CLI/`claude` spend) for the
control-plane logic; the real-git and full-run scenarios are `--include
integration` because they touch worktrees and spend money.

All Elixir commands run through mise (Principle: pinned toolchain).

```bash
mise exec -- mix deps.get
mise exec -- mix compile           # warnings_as_errors — must be clean
mise exec -- mix test              # hermetic default suite
mise exec -- mix test --include integration   # real-git + real-harness
```

See contracts: [run_manifest](./contracts/run_manifest.md),
[checkpoint-progress](./contracts/checkpoint-progress.md),
[worktree-squash-restore](./contracts/worktree-squash-restore.md),
[ledger-restore](./contracts/ledger-restore.md),
[resume_run](./contracts/resume_run.md). Data shapes:
[data-model](./data-model.md).

---

## Scenario A — Per-phase checkpoint & phase-boundary commit (US1, hermetic)

**Proves**: FR-001, FR-003; a cleanly-running feature leaves a resume pointer.

1. Run a feature through several phases with a fake phase executor.
2. Assert after each phase a `checkpoint.json` exists with `status ==
   "in_progress"`, `last_phase ==` the just-completed phase, and a `context`
   object; the file is **overwritten** (not appended) each phase.
3. Assert a phase-boundary commit exists on the feature branch after each phase
   (integration variant, real git).

**Expected**: at any phase boundary, checkpoint + worktree are sufficient to
resume with no in-memory state (SC-005).

## Scenario B — Resume a crashed feature from its last completed phase (US1, integration)

**Proves**: US1 s1–s2, FR-009/010/011, SC-002.

1. Run a feature through `plan`, then simulate a crash during `tasks` (kill the
   runner; leave an uncommitted partial file in the worktree).
2. `SpeckitOrchestrator.resume(feature_id)`.
3. Assert: the resume starts at `tasks` (the interrupted phase — the phase after
   the last completed `plan`); `Worktree.restore/1` removed the partial file;
   `specify…plan` artifacts are byte-unchanged (not regenerated); the feature
   reaches a terminal state.

**Expected**: 100% of pre-crash-completed phases preserved; only `tasks` re-runs.

## Scenario C — Squash on completion, no checkpoint-commit noise (FR-004, integration)

**Proves**: the final branch shows one clean commit.

1. Run a feature to `:done` (fake or real).
2. Assert `git rev-list --count <fork-base>..<feature-branch> == 1` and the single
   commit's tree equals the sum of the per-phase work; no `checkpoint after
   <phase>` commits remain.
3. Assert a **kept** terminal (force an `:escalated`) leaves the per-phase commits
   in place as the post-mortem trail.

## Scenario D — Resume an entire crashed run (US2, hermetic)

**Proves**: US2 s1–s2, FR-005/006/007; done features not re-run, pending release
in DAG order.

1. Start a multi-feature run with a fake runner and fake manifest; drive features
   to mixed states (some `:done`, one `:running`, some `:pending`); capture the
   manifest the `Coordinator` wrote.
2. Simulate a fresh node: stop the `Coordinator`, then `resume_run/1` reading that
   manifest.
3. Assert: `:done` features are **not** re-run; the `:running` feature is released
   and resumed (its checkpoint drives `start_phase`); `:pending` features release
   in prereq order under the recorded cap; the run reaches the same terminal
   report it would have without the crash (SC-001).

## Scenario E — Detect-only, never auto-start (FR-008/014, SC-006, hermetic)

**Proves**: recovery is operator-initiated.

1. Write a manifest with unfinished features.
2. `resumable_run/0` → reports the resumable run **and starts nothing** (no
   `Coordinator` process appears).
3. Boot the app → assert no run auto-starts.

## Scenario F — Cost continuity across a crash (US3, hermetic)

**Proves**: US3 s1–s2, FR-012/013, SC-003.

1. Run until a known committed spend `S`; capture the manifest `spend == S`.
2. `resume_run/1` → assert `Ledger.spent(Ledger) >= S` after restore (not 0).
3. Set the manifest `spend` at/above budget → after restore, `breaker_tripped?`
   is true and `resume_run/1` releases **zero** new features (drain, not kill);
   the invariant `committed < budget + max single reservation` holds.

## Scenario G — Human gate retained across a crash (US1 s3, FR-015, SC-004)

**Proves**: recovery never auto-passes a gate.

1. Manifest with a feature `:escalated` (or `:halted`) at crash.
2. `resume_run/1` → assert that feature keeps its `:escalated`/`:halted` status,
   is **not** released/re-run, and its `resolve/1` path still applies.

## Scenario H — Fail loud on untrustworthy state (edge cases, FR-016/017)

**Proves**: never resume from fabricated/ambiguous state.

1. Corrupt the manifest JSON → `resume_run/1` returns `{:error, :corrupt_manifest}`
   and starts nothing.
2. Delete a checkpointed feature's branch → its resume yields `{:worktree,
   :branch_missing}` (steer to full restart); the run does not crash.
3. With a live unfinished `Coordinator` present, `resume_run/1` without `:force`
   returns `{:error, {:active_run, pid}}` (no clobber, FR-017).
4. Grep the dependency tree — assert **no** datastore dependency is present
   (SC-007); all recovery state is git commits + JSON.

---

## Definition of done for this feature

- Scenarios A–H pass (hermetic ones in the default suite; B/C in `--include
  integration`).
- `mise exec -- mix compile` clean under `warnings_as_errors`.
- Pure-core coverage stays above 90% (`RunManifest` and the reconstruction/
  restore logic unit-tested through seams).
- No new dependency; `run.json` + per-feature `checkpoint.json` + git commits are
  the only persisted recovery state.
