# Phase 1 Data Model: Resume Preserves Backlog Scope

**Feature**: `016-resume-backlog-scope` | **Date**: 2026-07-26

No datastore. Every entity below is either an existing file-backed record, an
in-memory value threaded through one call, or a telemetry payload. Entities are
listed as **existing (changed)** or **new**.

---

## Entity 1 — Run record *(existing, invariant strengthened)*

`RunManifest`, one slot per repository segment at
`<autonomous_root>/transcripts/<segment>/run.json`.

| Field | Type | Change |
|-------|------|--------|
| `features` | `[%{id, slug, path, prereqs}]` | unchanged shape; **now guarded** |
| `statuses` | `%{id => status_string}` | unchanged |
| `context` | run-shaping map (`RunContext`) | unchanged |
| `spend` | number | unchanged |
| `segment` | string \| absent | unchanged |
| `scope` | `"ad-hoc"` \| `%{"breakdown" => slug}` | unchanged |
| `updated_at` | integer | unchanged |

**New invariant (FR-011, FR-015, SC-004)** — *scope monotonicity*:

> For a given segment, across any two successive writes `W₁ → W₂` with no
> intervening `clear/0`, `ids(W₁.features) ⊆ ids(W₂.features)`.

A `clear/0` (only `run/1` with `supersede: true`) resets the chain — that is what
makes a deliberately fresh run a supersede rather than a narrowing (FR-013).

Because `scope` is only ever written from the run's `%Layout{}` and the feature
set can now only grow within a chain, the previously producible inconsistency
(a `scope` naming a breakdown package beside a one-entry `features` list) is
unreachable (FR-015).

**Validation** (in `RunManifest.write/1`, before any file write):

| Condition | Result |
|-----------|--------|
| No existing record at the segment path | write proceeds |
| Existing record unreadable/corrupt | write proceeds (nothing provable to lose) |
| `recorded_ids -- proposed_ids == []` | write proceeds |
| `recorded_ids -- proposed_ids != []` | **refused**: file untouched, refusal event emitted, `:ok` returned |

Comparison is by feature **id**, as a set — count is irrelevant (FR-011).

---

## Entity 2 — Restored run set *(new, in-memory)*

What a resume hands the `Coordinator`. Produced once per resume, never persisted
in this shape.

| Field | Type | Meaning |
|-------|------|---------|
| `features` | `[%Feature{}]` | full recorded set, **plus** the target if the record omits it (FR-008) |
| `statuses` | `%{id => Feature.status()}` | reconciled seed; target forced `:pending` |
| `resume_phases` | `%{id => Pipeline.phase()}` | reconciled mid-run restart points, target excluded |
| `layout` | `%Layout{} \| nil` | rebuilt from the record's `segment`/`scope` |
| `context` | `%RunContext{}` | merged: explicit opt > recorded > live Config |
| `target` | `%ResumeTarget{} \| nil` | `nil` for a whole-run resume |

Derivation:

```text
record ──RunManifest.reconstruct/1──▶ features
record ──Recovery.reconcile_run/2 ──▶ statuses, resume_phases, report
target ──(append if absent)────────▶ features
target ──(force :pending)──────────▶ statuses
target ──(delete key)──────────────▶ resume_phases     # D2: operator phase wins
```

**State seeding rules** (unchanged from 009/014 except the target row):

| Reconciled verdict | Seed status | Dispatched? | Start phase |
|--------------------|-------------|-------------|-------------|
| `:done` | `:done` | no (FR-005) | — |
| `:escalated` / `:halted` / `:failed` | as-is | no (FR-006) | — |
| `{:conflict, r}` | `:blocked` | no | — |
| `{:resume, phase}` | `:pending` | yes | `phase` |
| `:pending` | `:pending` | yes, when prereqs `:done` (FR-004) | `Pipeline.first()` |
| *target feature* | `:pending` | yes | `:from` \| checkpoint phase (D2) |

---

## Entity 3 — Resume target *(new, in-memory)*

The per-feature override that distinguishes `resume/2` from `resume_run/1`.

| Field | Type | Source |
|-------|------|--------|
| `feature_id` | `String.t()` | positional arg |
| `start_phase` | `Pipeline.phase()` | `:from` opt > checkpoint `last_phase` |
| `prompt` | `String.t() \| nil` | `:prompt` |
| `remediation_prompt` | `String.t() \| nil` | `:remediation_prompt` |
| `remediation_model` | `String.t() \| nil` | `:remediation_model` |
| `start_task_phase` | `pos_integer() \| TaskPhaseRef.t() \| nil` | `:from_task_phase`, only when `start_phase == :implement` |

`reset_implement_sessions: true` is implied for the target and only the target
(FR-013b of feature 015 — resuming is an explicit grant of session budget).
Non-target features carry none of these fields.

---

## Entity 4 — Scope-narrowing refusal *(new, telemetry payload)*

Event `[:speckit, :run, :scope_narrowing_refused]`.

| Part | Field | Type |
|------|-------|------|
| measurements | `dropped_count` | `pos_integer()` |
| metadata | `segment` | `String.t() \| nil` |
| metadata | `recorded` | `[String.t()]` — ids in the surviving record |
| metadata | `attempted` | `[String.t()]` — ids in the refused write |
| metadata | `dropped` | `[String.t()]` — `recorded -- attempted`, sorted |

Consumers: default logger (`Telemetry.handle_event/4`), console feed
(`ConsoleReadModel.apply_event/4` → `%{feature_id: nil, phase: nil, severity:
:warn, text: …}`), broadcast by `ConsoleProjection` on `"console:run"`.

---

## Entity 5 — Rebuild proposal *(new, in-memory; US3)*

`Recovery.Rebuild.propose/3` output; the preview payload of
`SpeckitOrchestrator.recover_record/1`.

| Field | Type | Meaning |
|-------|------|---------|
| `features` | `[%Feature{}]` | union of record features and backlog features, in backlog order |
| `statuses` | `%{id => Feature.status()}` | reconciled per feature (Entity 2 rules) |
| `resume_phases` | `%{id => Pipeline.phase()}` | mid-run restart points |
| `discrepancies` | `[discrepancy()]` | everything not reconcilable, never silently merged |
| `report` | `Recovery.Report.t()` | operator-facing rendering |
| `source` | `%{record_ids: [id], backlog_ids: [id], backlog_root: path}` | provenance |

Sources of each field:

```text
run.json ─────────┐
                  ├─▶ union ─▶ per-feature Evidence ─▶ Reconcile ─▶ statuses
breakdown/*.md ───┘                                  └─▶ discrepancies
```

---

## Entity 6 — Discrepancy *(new, in-memory; US3)*

| `kind` | Raised when | Effect on the proposal |
|--------|-------------|------------------------|
| `:absent_from_backlog` | recorded feature has no file in the backlog on disk | kept in `features` with its recorded status; reported |
| `:absent_from_record` | backlog feature never named by the record | added, status from evidence (usually `:pending`); reported |
| `:unreconcilable` | `Reconcile` returned `{:conflict, reason}` | status `:blocked`; reported with `reason` |
| `:prereq_missing` | a restored feature names a prereq absent from the union | reported; the proposal is refused (FR-020) |

Each row: `%{kind: atom(), id: String.t(), detail: term()}`.

---

## Entity 7 — Recovery outcome *(new, return value; US3)*

| Call | Return | Durable effect |
|------|--------|----------------|
| `recover_record()` | `{:ok, proposal}` | **none** (FR-019a) |
| `recover_record(confirm: true)` | `{:ok, :written, proposal}` | one `RunManifest.write/1` |
| backlog unloadable | `{:error, {:backlog, reason}}` | none |
| `:prereq_missing` present | `{:error, {:inconsistent, discrepancies}}` | none (FR-020) |
| no record at all | `{:error, :no_manifest}` | none |

---

## Lifecycle: one resume, end to end

```text
resume(id, opts)
  │
  ├─ guard_active_run          ── {:error, {:active_run, pid}} unless force:  (FR-010a)
  ├─ read manifest ── none/corrupt ─▶ single-feature path, unchanged          (FR-009, D8)
  │      │ ok
  ├─ Recovery.reconcile_run    ── statuses, resume_phases, report             (FR-002a)
  ├─ reconstruct features      ── + append target if absent                   (FR-008)
  ├─ resolve target override   ── :from > checkpoint last_phase               (FR-003, D2)
  ├─ Ledger.restore(spend)                                                     (SC-007)
  └─ run(supersede: false, features: all, statuses: seed, runner: split)      (FR-001)
         │
         └─ Coordinator ─ writes full set each phase ─ guard is a no-op       (FR-011)
                        └─ releases dependents as prereqs go :done            (FR-004)
```
