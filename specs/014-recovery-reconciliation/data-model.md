# Phase 1 Data Model: Recovery State Reconciliation

**Feature**: 014-recovery-reconciliation | **Date**: 2026-07-24

No persistent schema is added. These entities are in-memory values passed through
the pure reconciliation and the existing file-backed manifest. Fields reuse
existing structs (`Feature`, `RunContext`, `Layout`, `Checkpoint`, `pr.json`)
wherever possible.

## Entity: `Recovery.Evidence`

The per-feature durable ground truth collected from disk/git. One struct per
feature; every field independently sourced so any one absent/corrupt degrades to
its "unknown" value without failing collection.

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| `feature_id` | `String.t` | manifest | key |
| `branch_committed?` | `boolean` | `git` on `feature/NNN-slug` | branch exists with committed work |
| `last_boundary_phase` | `phase \| nil` | `git log` newest `"speckit: <id> checkpoint after <phase>"` | **authoritative** last completed phase (FR-005) |
| `pr_record?` | `boolean` | `Describe.read_pr/2` (`pr.json`) | local durable PR record present & parseable |
| `pr_remote?` | `boolean \| :unknown` | `gh` seam (fallback only) | `:unknown` when local record present, remote unreachable, or query skipped |
| `checkpoint` | `map \| nil` | `Checkpoint.read/2` | corroborating; `nil` if absent/corrupt |
| `final_marker?` | `boolean` | `07-converge.md` transcript | `## CONVERGE: READY` present (non-PR done-signal) |

**Validation / tolerance**: each source read is `{:ok,_}` → populate; `{:error,
:corrupt}`/`{:error, :absent}` → the field's unknown value (`false`/`nil`/
`:unknown`). Collection never raises on a single bad source (FR-011).

**Corrupt-tolerance rule**: `pr_record?` is `true` only when `pr.json` parses;
a truncated `pr.json` → `false` and the decision falls back to the git/transcript
evidence for that feature.

## Entity: Reconciled status (`Recovery.Reconcile` output)

The corrected status the system reports and persists per feature, one of:

| Reconciled value | Manifest status persisted | Meaning | Origin FR |
|------------------|---------------------------|---------|-----------|
| `:done` | `done` | Repository shows finished; dependents releasable | FR-003 |
| `{:resume, phase}` | `running` (checkpoint drives resume phase) | Resume at `phase` = after latest committed boundary | FR-004/FR-005 |
| `:pending` | `pending` | Never started; releasable when prereqs `done` | FR-008 |
| `:escalated` | `escalated` | Held at human gate, unchanged | FR-007 |
| `:halted` | `halted` | Held at human gate, unchanged | FR-007 |
| `:failed` | `failed` | Stays failed | US3 |
| `{:conflict, reason}` | `blocked` | Self-contradictory evidence; held gate-like, dependents blocked, rest of run continues | FR-014 |

`{:resume, phase}` and `{:conflict, reason}` are the two carriers of extra data;
all others are bare atoms. The manifest persists the plain status string (the
resume `phase` is recovered from the checkpoint at continuation, the conflict
`reason` is carried in the report).

## Entity: Run manifest (existing — role change)

Unchanged shape (`run_manifest.ex`: `features`/`statuses`/`context`/`spend`/
`updated_at`/`segment`/`scope`). Role change only: after this feature the
`statuses` map is explicitly an **optimistic cache** that reconciliation reads,
corrects, and rewrites (FR-002, FR-009). `features`, `context`, `spend`,
`segment`, and `scope` are preserved verbatim across a reconcile rewrite — only
`statuses` (and `updated_at`) change.

## Entity: Reconciled run report (`Recovery` output → `Report`)

The read-only whole-run picture the operator sees before continuing (FR-015).

| Field | Type | Notes |
|-------|------|-------|
| `features` | `[%{id, slug, recorded, reconciled, resume_phase, corrected?}]` | per-feature before/after |
| `conflicts` | `[%{id, reason}]` | features held gate-like for human resolution |
| `next_runnable` | `[feature_id]` | features releasable after reconciliation (via `Release`) |
| `spend` | `number` | preserved committed spend (FR-013) |
| `run_shape` | `{:breakdown, slug} \| :ad_hoc` | from manifest scope (FR-012) |

## State transitions (recorded → reconciled)

Pure function `Recovery.Reconcile.status/3(recorded, evidence, run_shape)`:

```
recorded=running, evidence=done-signal(shape)             → :done                 (FR-003)
recorded=running, branch has boundary commits, no done    → {:resume, after(last_boundary_phase)}  (FR-004/005)
recorded=pending, no branch & no artifacts                → :pending              (FR-008)
recorded ∈ {escalated, halted}                            → same (held)           (FR-007)
recorded=failed                                           → :failed               (US3)
recorded=done, evidence confirms (branch/PR)              → :done                 (US3 #3)
recorded=done, NO branch/PR (contradiction)               → {:conflict, :done_without_artifacts}   (FR-014)
pr_record? but branch missing (contradiction)             → {:conflict, :pr_without_branch}         (FR-014)
insufficient/ambiguous                                    → {:conflict, reason}   (FR-014)
```

`done-signal(shape)`:
- `{:breakdown, _}` / PR-workflow → `pr_record? and branch_committed?`
- non-PR-workflow → `final_marker? and branch_committed?`

`after(phase)` = `Pipeline` phase following `phase`; if `phase` is the terminal
`converge`, the feature is `:done`, not `{:resume, _}` (terminal boundary is a
done-signal only in combination with the shape's done rule above).
