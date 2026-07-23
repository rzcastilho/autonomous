# Phase 1 Data Model: Crash Recovery

Recovery introduces **no datastore** (FR-018, SC-007). Every entity below is
either a git commit or a small JSON file under `Config.transcript_root()`
(default `<repo>/.speckit-transcripts`). All JSON files are string-keyed, written
best-effort, and read three-way (record / absent / corrupt) — never fabricated.

## Entity 1 — Progress checkpoint (extended)

Per-feature resume pointer, one file at
`<transcript_root>/<feature_id>/checkpoint.json`. **Extended** from divert-only to
after-every-phase.

| Field | Type | Notes |
|-------|------|-------|
| `feature_id` | string | required |
| `last_phase` | string | phase that **completed** (resume starts at the next one) |
| `status` | string | `"in_progress"` after a clean phase; `"escalated"`/`"halted"`/`"failed"` on a divert. Checkpoint-level marker — **not** a `Feature` lifecycle status |
| `reason` | string | `inspect/1` of the divert reason; `"nil"`-ish for in-progress |
| `session_id` | string \| null | Claude session id (best-effort continuity) |
| `slug` | string | feature identity — lets `resume/2` rebuild the `%Feature{}` |
| `path` | string | feature identity (breakdown/spec path) |
| `context` | object \| absent | `RunContext.to_map/1` — the six run-shaping settings |

**Write timing (changed)**: after every successful phase (`:in_progress`,
`last_phase` = just-completed phase) **and** on a non-`:done` terminal (existing
divert behavior). Deleted on `:done` (existing). Best-effort: a write failure
never breaks the run.

**Validation**: `resume/2` validates `last_phase`/`:from` against
`Pipeline.phase?/1` via `String.to_existing_atom/1` (atom-table safe); an
unparseable phase → `{:error, {:unknown_phase, _}}`. A missing/corrupt file →
`{:error, :no_checkpoint}` / `{:error, :corrupt}`.

**State meaning**: `last_phase` + on-disk worktree is sufficient to resume with no
in-memory state (FR-002, SC-005).

## Entity 2 — Phase-boundary commit

A git commit of the feature worktree made after each phase completes, on branch
`feature/<id>-<slug>`. Serves as the clean restore point for that boundary.

- **Created by**: `Worktree.commit/2` in `FeatureRunner.loop/7`, once per phase.
- **Message**: `speckit: <feature_id> checkpoint after <phase>` (distinct from the
  final authored/template message).
- **Author**: the existing orchestrator author (`speckit-orchestrator
  <orchestrator@speckit.local>`), so pipeline commits stay distinguishable from
  human resolution commits.
- **Lifecycle**:
  - On `:done` → **squashed** into one feature commit (`Worktree.squash/3`); no
    intermediate checkpoint commits remain (FR-004).
  - On a kept terminal (`:escalated`/`:halted`/`:failed`) → **left in place** as
    the post-mortem trail; a later `resolve/1` continues on the branch.
  - On resume, the interrupted phase's **uncommitted** partial output is discarded
    by `Worktree.restore/1` (`reset --hard HEAD` + `clean -fd`) back to the last
    boundary commit before the phase is re-run (FR-003).

**Invariant**: `git reset --soft <base>` (squash) and `reset --hard HEAD`
(restore) never touch any branch other than the feature branch, which is
unpublished until the PR workflow pushes it.

## Entity 3 — Run manifest (new)

Single-slot durable record of the run, one file at `<transcript_root>/run.json`.
Owned/written by the `Coordinator`; superseded (cleared then rewritten) at each
new `run/1`.

| Field | Type | Notes |
|-------|------|-------|
| `features` | array of object | each `{id, slug, path, prereqs: [id]}` — enough to reconstruct the DAG without loading the backlog |
| `statuses` | object | `{feature_id => status_string}` — last-known lifecycle status per feature |
| `context` | object | `RunContext.to_map/1` — run-shaping settings the run started under (FR-007) |
| `spend` | number | recorded run-global committed spend (`Ledger.spent/1`) at the last update (FR-012) |
| `updated_at` | string \| number | caller-supplied stamp (scripts have no `Date.now`; the app supplies `System.system_time`) |

**Write timing**: `Coordinator.init` (all features `:pending`, `spend` 0), each
`spawn_feature` (`:running`), each `{:finished}` (terminal status + current
`Ledger.spent`). Best-effort; a write failure never breaks the run.

**Read/classify**: `RunManifest.read/0` → `{:ok, map}` / `{:error, :no_manifest}` /
`{:error, :corrupt}`. **Resumable** when at least one feature's status is
non-terminal-and-final — a `:running`/`:pending` feature (was interrupted or never
released), reported for operator-initiated resume. Terminal features (`:done`, and
gate diverts awaiting `resolve/1`) are reported but not auto-resumed.

**Single-slot rule**: starting a new run clears the prior manifest (FR-005); "is
there a resumable run?" is therefore an unambiguous one-file check (FR-008).

## Entity 4 — Recorded spend

Not a separate file — the `spend` field of the run manifest (Entity 3). The
durable committed-spend figure used to restore the cost breaker on resume.

- **Source**: `Ledger.spent/1`, current after each phase (`RunPhase` records cost
  to the `Ledger` per phase).
- **Restore**: `Ledger.restore/2` sets `committed = max(committed, recorded)` at
  `resume_run/1` before any wave releases (idempotent; never lowers a higher live
  value).
- **Guarantee**: the resumed run's total spend across the crash stays within the
  original budget plus at most one outstanding reservation (SC-003), because the
  restored `committed` seeds the same breaker invariant (`committed < budget + max
  single reservation`) the live run enforced.

## Entity 5 — Resume operation

Operator-initiated action reconstructing a feature (or a whole run) from the
entities above and continuing it to completion. Not persisted state — a facade
call.

- **Per-feature**: `resume/2` (feature 007, unchanged) — checkpoint read → identity
  recovery → `RunContext` reapply → worktree reuse/recreate → `Worktree.restore/1`
  → re-run interrupted phase → continue to terminal.
- **Whole-run**: `resume_run/1` (new) — manifest read → reconstruct
  features/statuses → `Ledger.restore/2` → start `Coordinator` with reconstructed
  `:statuses` and a resume-aware runner → release remaining waves in dependency
  order under the recorded cap.
- **Detect-only**: `resumable_run/0` (new) — read/classify the manifest and report;
  starts nothing (FR-008, SC-006).

## State transitions

Per-feature lifecycle is unchanged (`Feature.status()`:
`:pending → :running → {:done | :escalated | :halted | :failed}`, plus
`:blocked`). Crash recovery adds only the **checkpoint status** dimension
(`"in_progress"` between phases) and the reconstruction mapping used on resume:

```text
manifest status at crash   →  reconstructed status on resume
──────────────────────────    ──────────────────────────────
:done                      →  :done       (kept — not re-run)          SC-002
:escalated / :halted       →  :escalated / :halted (kept — no auto-pass) FR-015/SC-004
:failed                    →  :failed     (kept — operator decides)
:running (interrupted)     →  :pending    → released → resume/2 at next phase
:pending (never released)  →  :pending    → released fresh in DAG order
```

## Validation & failure rules (summary)

| Condition | Behavior | Ref |
|-----------|----------|-----|
| Missing/corrupt manifest | loud error, start nothing, steer to restart | FR-016 |
| Missing/corrupt checkpoint for a feature | `resume/2` returns `:no_checkpoint`/`:corrupt`; start nothing | FR-016 |
| Checkpointed feature's branch/worktree gone | `{:worktree, :branch_missing}` → steer to full restart | US1 s4 |
| Crash before first commit (`specify`) | no boundary commit → treat as feature restart, not resume | edge case |
| Stale manifest + a different run already active | refuse without explicit operator force | FR-017/US2 s4 |
| Restored spend ≥ budget | breaker treated as tripped; release nothing (drain) | FR-013/US3 s2 |
