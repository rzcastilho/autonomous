# Data Model: Unified Run-State Persistence

**Feature**: `018-unified-run-persistence` | **Date**: 2026-07-27

Every entity in the spec's *Key Entities* section maps to exactly one Mnesia
table. Table mechanics (attribute order, storage type, indexes, migrations) are
in `contracts/schema.md`; this document is the entity model, its invariants, and
its state transitions.

Pure structs live in `SpeckitOrchestrator.Store.Records` and know nothing about
Mnesia — they are plain data with `encode/1` / `decode/1` to and from the record
tuple, unit-testable with no schema and no running node (Principle I,
constitution's "pure core MUST NOT depend on Mnesia").

---

## Identity and partitioning

**`repo_id`** — the partition key on every table (FR-004). Derived by
`RepoIdentity.partition/1` (research R10):

| Case | `repo_id` |
|------|-----------|
| origin resolvable | `"o:" <> "<name>-<sha6(canonical origin)>"` |
| no usable origin | `"l:" <> "<basename>-local-<sha6(expanded abs path)>"` |

The `o:` / `l:` prefix makes the two derivations non-colliding by construction.
Two checkouts of different repositories that share a directory name get
different `repo_id`s; two checkouts of the *same* origin share one.

**`run_key`** — `{repo_id, run_id}`, the parent reference carried by every
child row and the value its secondary index is built on.

**`run_id`** — `"r" <> zero-padded 6-digit per-repository sequence`
(`"r000001"`, `"r000002"`, …). Stable across resumes of that run (FR-020).
Because `speckit_run` is an `ordered_set` keyed `{repo_id, run_id}`, key order
*is* chronological order — independent of any clock (FR-033). Documented
ceiling: 999 999 runs per repository.

**`attempt_id`** — `{repo_id, run_id, feature_id, phase, ordinal}`. Used as the
primary key of `speckit_phase_attempt` and, unchanged, as the primary key of
`speckit_transcript`, so a transcript and the attempt it describes are keyed
identically and cannot be separated or pruned out of step (FR-035).

---

## Entities

### 1. Repository

Not a table of its own — `repo_id` *is* the repository, and `speckit_seq` holds
its one mutable fact (the next run sequence). A repository with no recorded runs
returns an empty history rather than an error (US2 acceptance 4).

| Field | Type | Notes |
|-------|------|-------|
| `repo_id` | `binary` | key |
| `next_seq` | `pos_integer` | bumped transactionally under a write lock (research R6) |
| `origin` | `binary \| nil` | recorded for display; never used as a key |
| `local_path` | `binary` | last-seen path, display only — may legitimately change |

### 2. Run

One orchestration attempt over a set of features (`speckit_run`).

| Field | Type | Notes |
|-------|------|-------|
| `key` | `{repo_id, run_id}` | primary key, ordered |
| `repo_id` | `binary` | **indexed** — history listing (FR-021) |
| `run_id` | `binary` | |
| `state` | `:in_flight \| :completed \| :superseded` | FR-023 |
| `outcome` | `:all_done \| :escalated \| :halted \| :failed \| :mixed \| nil` | `nil` while in flight |
| `outcome_index` | `atom` | **indexed** — filter by outcome (FR-024); equals `outcome`, or `:in_flight` |
| `started_at` / `ended_at` | `DateTime` | display and duration; never an ordering key |
| `duration_ms` | `integer \| nil` | computed once at end |
| `spend_usd` | `float` | run total, from `cost_entry` roll-up |
| `record_complete?` | `boolean` | `false` when a persistence failure drained the run (FR-010) |
| `halt_reason` | `term \| nil` | e.g. `{:persistence_failed, reason}`, `:breaker` |
| `scope` | `{:breakdown, slug} \| :ad_hoc` | the run's `Layout` scope |
| `layout` | `map` | recorded `%Layout{}` fields, so a resume rebuilds roots without re-resolving identity |
| `superseded_by` | `run_id \| nil` | set when a later run supersedes this one |
| `schema_version` | `integer` | the version this row was written under |

**Invariant (FR-034 / SC-012)**: at most one row per `repo_id` with
`state: :in_flight`. Enforced inside the run-start transaction, not by a check
after the fact.

### 3. Run Settings

The run-shaping values captured at start and reapplied on resume
(`speckit_run_settings`, one row per run — separated from `run` so a live
amendment never rewrites the run row).

| Field | Type | Notes |
|-------|------|-------|
| `run_key` | `{repo_id, run_id}` | primary key |
| `settings` | `map` | the ten `RunContext` fields, verbatim |
| `captured_at` | `DateTime` | |

**Invariant (FR-028)**: contains no credentials or secrets by construction — it
is `RunContext.to_map/1`'s output, whose struct admits only bool / number /
string / list-of-string fields. No new field may be added to `RunContext`
without preserving that.

### 3a. Settings Amendment

An amendment applied to a live run (`speckit_settings_amendment`), so the record
explains why later work behaved differently from earlier work (FR-027).

| Field | Type | Notes |
|-------|------|-------|
| `id` | `{repo_id, run_id, ordinal}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `ordinal` | `pos_integer` | |
| `changes` | `map` | changed keys only, old → new |
| `effective_at` | `DateTime` | |
| `effective_after` | `attempt_id \| nil` | the boundary it took effect at |

### 4. Feature Run

One feature's participation in a run (`speckit_feature_run`).

| Field | Type | Notes |
|-------|------|-------|
| `key` | `{repo_id, run_id, feature_id}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** — load a run's features |
| `feature_id` | `binary` | **indexed** — FR-024 filter by feature |
| `slug` / `path` | `binary` | identity, so a resume rebuilds the work unit |
| `prereqs` | `[binary]` | the DAG edge set as recorded |
| `status` | see below | |
| `terminal_reason` | `term \| nil` | |
| `worktree_path` / `branch` | `binary \| nil` | `worktree_path` cleared when removed on `:done` |
| `pr_description` | `map \| nil` | `%{pr_title:, pr_body:}` — replaces `pr.json` (research R15) |
| `started_at` / `ended_at` | `DateTime \| nil` | |

`status ∈ :pending | :running | :done | :escalated | :halted | :failed |
:blocked | :ended_by_supersession`.

`:ended_by_supersession` is new: a feature of a run that was superseded while in
flight, distinguishable from one that genuinely completed or failed (FR-023,
spec edge case).

### 5. Phase Attempt

One execution of one pipeline phase for a feature (`speckit_phase_attempt`).

| Field | Type | Notes |
|-------|------|-------|
| `attempt_id` | `{repo_id, run_id, feature_id, phase, ordinal}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `feature_key` | `{repo_id, run_id, feature_id}` | **indexed** |
| `phase` | `atom` | a `Pipeline.phase()`, or `:remediation` |
| `ordinal` | `pos_integer` | 1-based per `{feature, phase}`; a transient retry increments it |
| `step` | `non_neg_integer` | the run-wide step number used in transcript labels today |
| `label` | `binary` | `"analyze"`, `"implement-p03-a2"`, `"implement-sweep-a1"`, … |
| `started_at` / `ended_at` | `DateTime` | |
| `duration_ms` | `integer` | |
| `outcome` | `atom` | the agent outcome (`:ok`, `:error`, …) |
| `model` | `binary` | the alias actually routed |
| `cost_usd` | `float` | |
| `cost_kind` | `:actual \| :estimate` | preserves today's prefer-actual rule |
| `substep` | `map \| nil` | within-phase position (chunk ordinal/number/title/sessions) — FR-012 |
| `session_id` | `binary \| nil` | |
| `error` | `term \| nil` | |

**Invariant (SC-008)**: recorded phase attempts equal executed phase attempts,
exactly. Guaranteed by R7's one-transaction-per-boundary rule plus Mnesia's
per-row write locks; parallel features write disjoint keys and cannot lose each
other's updates.

### 6. Checkpoint

The durable resume pointer for a feature (`speckit_checkpoint`) — one row per
`{run, feature}`, superseded in place by each newer checkpoint.

| Field | Type | Notes |
|-------|------|-------|
| `key` | `{repo_id, run_id, feature_id}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `phase` | `atom` | the phase to restart at |
| `last_completed_phase` | `atom` | the phase that just finished |
| `status` | `:in_progress \| :escalated \| :halted \| :failed` | |
| `reason` | `term \| nil` | |
| `session_id` | `binary \| nil` | |
| `implement_chunk` | `map \| nil` | unchanged shape from 015 |
| `analyze_remediation` | `map \| nil` | unchanged shape from 017 |
| `updated_at` | `DateTime` | |

**Rules (unchanged from today, only relocated)**: written after **every**
successfully completed phase, not only on a terminal (FR-013); deleted when the
feature reaches `:done` (so a `:done` feature is never resumed); written in the
same transaction as the phase attempt it points at (R7), so a reader can never
see a checkpoint whose attempt is missing (FR-006).

### 7. Escalation

An explicit human-handoff or halt record (`speckit_escalation`) — FR-025.

| Field | Type | Notes |
|-------|------|-------|
| `id` | `{repo_id, run_id, feature_id, ordinal}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `feature_id` | `binary` | **indexed** — "every run in which feature X escalated" (FR-024) |
| `kind` | `:escalated \| :halted` | |
| `phase` | `atom` | the phase that raised it |
| `severity` | `:low \| :medium \| :high \| :critical \| nil` | analyze findings carry one; a clarify escalation does not |
| `reason` | `term` | |
| `evidence` | `map` | the marker line, the finding list, the breaker figures — whatever triggered it |
| `raised_at` | `DateTime` | |
| `resolution` | `map \| nil` | `%{resolved_at:, note:, by:}` |

**Rule (FR-026)**: resolving sets `resolution`; it never deletes the row. The
history shows both that it happened and that it was resolved.

### 8. Remediation Attempt

One iteration of the bounded pre-gate auto-remediation loop
(`speckit_remediation_attempt`) — FR-022, US3 acceptance 4.

| Field | Type | Notes |
|-------|------|-------|
| `id` | `{repo_id, run_id, feature_id, ordinal}` | primary key |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `feature_key` | `{repo_id, run_id, feature_id}` | **indexed** |
| `ordinal` | `pos_integer` | 1-based within the feature run |
| `findings` | `list` | the findings it acted on, verbatim |
| `max_severity` | `atom` | |
| `outcome` | `atom` | |
| `cost_usd` | `float` | |
| `attempt_limit` | `pos_integer` | the limit in force |
| `threshold` | `atom` | the threshold in force |
| `model` | `binary` | |
| `attempt_id` | `attempt_id \| nil` | the corrective step's own phase attempt |

### 9. Transcript

The recorded output of one phase attempt (`speckit_transcript`,
**`disc_only_copies`**) — FR-029, FR-035, FR-036.

| Field | Type | Notes |
|-------|------|-------|
| `attempt_id` | same tuple as the phase attempt | primary key — inseparable by construction |
| `body` | `binary` | **verbatim**; never redacted, scrubbed, filtered or truncated (FR-029a) |
| `bytes` | `pos_integer` | recorded so capacity and prune previews need no body read |
| `written_at` | `DateTime` | |

**Rules**: retrieved on demand only, never as part of a history listing or a run
summary (FR-036, SC-009); survives worktree removal because it never lived in
the worktree (FR-029, SC-006).

### 10. Cost Entry

A recorded charge attributable to a run, feature, and phase attempt
(`speckit_cost_entry`).

| Field | Type | Notes |
|-------|------|-------|
| `id` | `{repo_id, run_id, feature_id, phase, ordinal}` | primary key (= `attempt_id`) |
| `run_key` | `{repo_id, run_id}` | **indexed** |
| `amount_usd` | `float` | |
| `kind` | `:actual \| :estimate` | preserves the prefer-actual/fallback-to-estimate rule |
| `recorded_at` | `DateTime` | |

**Rule (spec edge case "cost accounting across a resume")**: a resume continues
the same `run_id`, so its entries land under the same run and are neither
double-counted nor lost. `Ledger.restore/2` is seeded from the run's entry
roll-up rather than from a single recorded scalar.

### 11. Meta

`speckit_meta` — `{:schema_version, integer}`, `{:node, node()}`,
`{:created_at, DateTime}`, plus the write-probe row `Store.Boot` uses to prove
the store is writable (FR-009).

---

## State transitions

### Run

```
                    ┌──────────────── new run for same repo ───────────────┐
                    │                                                      ▼
(none) ── start ──▶ in_flight ── drain ──▶ completed(outcome)          superseded
                        │
                        └── persistence failure ──▶ halt between phases,
                            record_complete? = false, state stays in_flight
                            until the halt write succeeds (FR-010, FR-010a)
```

`outcome` is derived from the terminal feature statuses when the run drains:
all `:done` → `:all_done`; any `:halted` → `:halted`; else any `:failed` →
`:failed`; else any `:escalated` → `:escalated`; else `:mixed`.

### Feature run

```
pending ──▶ running ──▶ done | escalated | halted | failed
   │           │
   │           └── owning run superseded ──▶ ended_by_supersession
   └── prereq ended non-done ──▶ blocked
```

Resume mapping (unchanged in meaning from today's manifest reconstruction, now
reading the store): terminal statuses are kept and never re-run;
`:running` / `:pending` become `:pending` for release, with `resume_phases`
carrying the checkpointed phase so the feature restarts there rather than at
`Pipeline.first()` (FR-017).

### Checkpoint

```
(absent) ──▶ in_progress(phase N) ──▶ in_progress(phase N+1) ──▶ …
                       │                        │
                       │                        └── terminal divert ──▶ escalated | halted | failed
                       └── feature reaches :done ──▶ (deleted)
```

### Escalation

```
raised ──▶ resolved   (resolution set; the row is never removed — FR-026)
```

---

## Validation rules

| Rule | Source | Where enforced |
|------|--------|----------------|
| At most one `in_flight` run per `repo_id` | FR-034 | run-start transaction |
| A checkpoint's `phase` is a real `Pipeline.phase()` | FR-012 | `Records.decode/1`, loud on mismatch |
| Recorded settings contain no secrets | FR-028 | `RunContext` struct shape |
| Transcript body is stored byte-identical | FR-029a | no transform on the write path; property test |
| A prune never removes a resumable run's state | FR-031 | `Store.Prune.plan/3` (pure) |
| A new run is refused past the headroom threshold | FR-031b | `Store.Capacity.check/1` (pure) at run start only |
| Damaged rows are reported, never defaulted | FR-008, SC-011 | `Records.decode/1` returns `{:error, {:damaged, key, reason}}`; no fabricated field |
| Absent ≠ complete ≠ damaged | FR-008 | three-way return on every read, mirroring today's `{:ok, _} / {:error, :absent} / {:error, :damaged}` |
| Status vocabularies are mapped explicitly | existing repo rule | never `String.to_atom/1` on stored content |

---

## What is *not* in the store

Per the spec's Assumptions and Out of Scope: git worktrees and branches; the
target repository's `spec.md` / `plan.md` / `tasks.md` / constitution; source
code. The store records references (branch name, worktree path, feature path)
and the outcomes derived from them — never the artifacts themselves.
