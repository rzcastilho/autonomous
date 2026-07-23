# Phase 0 Research: Crash Recovery

All spec `NEEDS CLARIFICATION` were resolved in the spec's Clarifications
sessions (2026-07-21 / 2026-07-22). This document records the design decisions
that follow from those answers and the existing codebase, plus the alternatives
rejected. No open unknowns remain.

## D1 — Per-phase checkpoint: reuse `Checkpoint`, add an in-progress record

**Decision**: Extend `FeatureRunner.loop/7` to call `Checkpoint.write/1` after
each successful phase with `status: :in_progress` and `last_phase:` = the phase
that just completed. `Checkpoint` already serializes `status`/`last_phase` via
`Atom.to_string/1` and stores `slug`/`path`/`run_context`, so no schema change is
needed beyond accepting the new status value; the write path is unchanged.

`:in_progress` is a **checkpoint-level marker**, not a `Feature` lifecycle status
— `Feature.status()` keeps its existing atoms. `resume/2` never gates on the
checkpoint `status` field (it validates `last_phase` against `Pipeline.phase?/1`
and starts at the *next* phase), so an in-progress record resumes exactly like a
divert record: the interrupted phase is re-run from a clean tree.

**Rationale**: One resume engine (feature 007's `resume/2`) already reads the
checkpoint, recovers identity from `slug`/`path`, reapplies `RunContext`, and
reuses the branch. Writing the same record shape after every phase makes a
cleanly-running feature resumable with zero new resume code.

**Alternatives rejected**:
- *A second "progress" file distinct from `checkpoint.json`* — duplicates the
  identity/context fields and forces `resume/2` to merge two sources. Rejected:
  one pointer file is simpler and already sufficient.
- *Write only `last_phase` (drop context on the in-progress write)* — a crash
  during phase 2 would then resume without the run shape. Rejected: the context
  is already in hand in the loop; always writing it is free and correct.

## D2 — Phase-boundary commit + squash-on-completion (FR-003 / FR-004)

**Decision**: In the phase loop, after each successful phase call
`Worktree.commit/2` with a per-phase message (e.g. `speckit: <id> checkpoint
after <phase>`). At `:done`, before the worktree is torn down, **squash** all
per-phase commits into a single feature commit via a new `Worktree.squash/3`:
`git reset --soft <base>` (where `<base>` = the branch's fork point, computed with
`git merge-base HEAD <pr_base-or-create-base>`) then one commit using the existing
authored/template message. On a kept terminal (`:escalated`/`:halted`/`:failed`)
the per-phase commits are **left in place** — they are the post-mortem trail and
a later `resolve/1` continues on the branch.

`git reset --soft` preserves the working tree and index, so the squash only
rewrites commit history on the (unpublished, cap-respecting) feature branch — the
final tree is byte-identical to the sum of the per-phase commits.

**Rationale**: The spec's clarification chose *squash*: the final branch/PR shows
one clean reviewable commit and no intermediate checkpoint commits (FR-004,
commit-noise edge case). Per-phase commits give the restore points during the
run; squash removes them exactly once, at the end, when they are no longer needed.

**Alternatives rejected**:
- *`git commit --amend` each phase onto one commit* — the amended commit's parent
  is fixed, but a crash mid-amend can leave a detached/duplicated state, and there
  is no per-phase restore point (each amend discards the prior boundary).
  Rejected: loses the clean per-phase history the restore depends on.
- *Interactive rebase to squash* — `-i` is unavailable in this environment and
  needs an editor. Rejected: `reset --soft` is deterministic and scriptable.
- *Keep per-phase commits on `:done` too* — violates FR-004 (noisy PR). Rejected.

## D3 — Restore the worktree before re-running the interrupted phase (FR-003)

**Decision**: A crash mid-phase can leave **uncommitted** partial files in the
worktree (the phase-boundary commit only happens *after* the phase succeeds). On
resume, before re-running the interrupted phase, `Worktree.restore/1` runs
`git reset --hard HEAD` + `git clean -fd` inside the worktree, returning the tree
to the last phase-boundary commit. The resume then re-runs the interrupted phase
from that consistent state (US1 scenario 2, idempotent-phase-re-run edge case).

**Rationale**: Speckit phases regenerate their own artifact, so a clean re-run is
safe; the only hazard is leftover partial output confusing the re-run. `reset
--hard` + `clean -fd` is the precise "discard everything since the last commit"
operation. The last phase-boundary commit *is* `HEAD` because per-phase commits
are clean and the crash happened before the next one.

**Alternatives rejected**:
- *`git stash`* — leaves a stash entry to leak; ambiguous on a later run.
  Rejected: `reset --hard` is the intent exactly.
- *Trust the phase to overwrite its own partial output* — some phases append or
  read prior partial files; not universally safe. Rejected per the spec's
  idempotency edge case.

## D4 — Run manifest: new `RunManifest` module, single slot (FR-005 / FR-008)

**Decision**: New pure module `SpeckitOrchestrator.RunManifest` writing one JSON
file at `<Config.transcript_root()>/run.json`:

- `write/1` — persist `%{features: [...], statuses: %{id => status}, context:
  RunContext map, spend: number, updated_at: <caller-supplied>}` (best-effort,
  mirrors `Checkpoint.write/1`).
- `read/0` — three-way `{:ok, map}` / `{:error, :no_manifest}` / `{:error,
  :corrupt}` (mirrors `Checkpoint.read/1`; never fabricates).
- `clear/0` — delete the slot (no-op if absent).
- `resumable?/0` (or `read/0` + a pure classifier) — true when the manifest holds
  at least one non-terminal-and-final feature (a `:running`/`:pending` status, or
  an `:escalated`/`:halted` awaiting resolution counts as *reported, not
  auto-resumed*). Detection starts no work (FR-008, SC-006).

The `Coordinator` owns manifest writes (single serialization point) through an
injected `:manifest` seam (default `RunManifest`, tests pass a fake): it writes on
`init` (features + all `:pending` + context + spend 0), on `spawn_feature`
(`:running`), and on `{:finished}` (terminal status + current `Ledger.spent`).
`run/1` supersedes the prior manifest by clearing then writing at run start
(single-slot, FR-005).

**Rationale**: Single-slot was the spec's clarification — "is there a resumable
run?" is an unambiguous one-file check. The `Coordinator` already holds
`features`/`statuses`/`ledger` and is the only writer of run-level state, so
routing manifest writes through it is race-free without new locking.

**Alternatives rejected**:
- *Per-run manifest files keyed by a run id (multi-slot)* — the spec explicitly
  chose single-slot; multi-slot reintroduces the "which run?" ambiguity and a GC
  problem. Rejected.
- *Each `FeatureRunner` writes the shared manifest* — concurrent writers race on
  one file. Rejected: the `Coordinator` is the natural single writer.

## D5 — Cost continuity: restore committed spend on the `Ledger` (FR-012 / FR-013)

**Decision**: Record run-global committed spend into the manifest at each
manifest update (read from `Ledger.spent/1`, which is current after each phase
because `RunPhase` calls `Ledger.record/3` per phase). On `resume_run/1`, restore
the app-supervised `Ledger` to the recorded value before releasing any wave, via a
new `Ledger.restore/2` that sets `committed = max(committed, recorded)`
(idempotent; never lowers an already-higher live value). A resumed run whose
restored committed is at/above budget is then already tripped, so `Release`/the
`Coordinator` release nothing (drain, not kill), and the invariant `committed <
budget + max single reservation` continues to hold (FR-013, SC-003).

**Rationale**: `Ledger.record(server, nil, amount)` already commits an unreserved
amount, so a restore is expressible today; a dedicated `restore/2` makes the
intent explicit and idempotent (safe if the Ledger already advanced). Recording
spend at phase boundaries makes the restored figure accurate to within at most one
interrupted phase's spend — the spec's accepted "best-effort granular" bound.

**Alternatives rejected**:
- *Restart the budget tally from zero on resume* — a crash would then silently
  double the budget (the exact gap US3 closes). Rejected outright.
- *Persist committed spend per feature in each checkpoint and sum on resume* —
  spend is run-global (one `Ledger`), not per-feature; summing per-feature figures
  double-counts nothing but adds bookkeeping the single manifest slot already
  covers. Rejected: keep the run-global figure in the run-global file.
- *Reuse `record/3` directly instead of adding `restore/2`* — works only while the
  app Ledger starts at 0; a resume when committed is already non-zero would double.
  Rejected in favor of an idempotent `restore/2`.

## D6 — `resume_run/1`: reconstruct `Coordinator` state, reuse per-feature resume (FR-006 / FR-007)

**Decision**: New facade `resume_run/1`:
1. `RunManifest.read/0`; on `:no_manifest`/`:corrupt` return a loud error and start
   nothing (FR-016). If a `Coordinator` is already alive with an unfinished run,
   refuse unless an explicit `force:`/confirmation opt is passed (FR-017, US2 s4).
2. Reconstruct the feature list and a `statuses` map from the manifest: terminal
   features keep their terminal status (not re-run); `:running`/`:pending` features
   are reset to `:pending` so `Release` will release them.
3. `Ledger.restore/2` from the manifest's recorded spend (D5).
4. Start the `Coordinator` with a new `:statuses` init option (reconstructed map)
   and a **resume-aware runner**: for a feature with an in-progress/divert
   checkpoint it runs the existing `resume/2` per-feature path (locate/recreate the
   worktree, `Worktree.restore/1`, `start_phase:` = next phase after
   `last_phase`); for a fresh `:pending` feature with no checkpoint it runs the
   normal fresh runner. Run-shaping context comes from the manifest (FR-007),
   reapplied through the existing `RunContext.merge/2` precedence.

`resumable_run/0` is step 1 without steps 2–4 — it reads/classifies the manifest
and reports, starting nothing (FR-008, SC-006).

**Rationale**: The `Coordinator` already drives dependency-and-cap waves from a
`statuses` map via `Release`; seeding that map with the reconstructed statuses is
the minimal change to get "done features not re-run, pending features release in
order." The per-feature resume is feature 007's `resume/2`, unchanged.

**Alternatives rejected**:
- *A parallel run-resume engine that re-implements wave scheduling* — duplicates
  `Release`/`Coordinator`. Rejected: seed the existing scheduler with reconstructed
  state instead.
- *Auto-resume on boot* — violates FR-014/SC-006 (a resume spends money). Rejected;
  boot only *detects and reports* via `resumable_run/0`.

## D7 — Failure & safety surfaces (FR-014/015/016/017)

**Decision**: Enumerated, each returning a distinct loud error and starting no
work: `:no_manifest`, `:corrupt_manifest`, per-feature `:no_checkpoint` /
`:corrupt_checkpoint` (from `resume/2`), `{:worktree, :branch_missing}` for a
checkpointed feature whose branch/worktree is gone (steer to full restart, US1
s4), and `{:active_run, pid}` when a different run is live (FR-017). An
`:escalated`/`:halted` feature is surfaced but never auto-passed — it keeps its
`resolve/1` path (FR-015, SC-004). Nothing runs on boot (FR-014).

**Rationale**: Fail-loud-at-boundaries (Principle II) plus human-in-the-loop
(Principle V) demand that every untrustworthy or gated state stops rather than
guesses. These reuse the error vocabulary `resume/2`/`Checkpoint` already return.

**Alternatives rejected**:
- *Silent best-effort resume that skips unrecoverable features* — hides data loss
  and can auto-pass a gate. Rejected: fail loud, steer to restart.
