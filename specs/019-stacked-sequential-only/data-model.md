# Data Model: Stacked Sequential Runs as the Only Behaviour

**Feature**: `019-stacked-sequential-only` | **Date**: 2026-07-28

This feature is mostly subtraction. Three fields and one status are deleted;
four fields and two statuses are added. Nothing new is introduced that did not
already have a home — the parked run is a state of an existing record, the group
is a field on an existing struct.

Entities below are grouped by where they live: the pure core (no Mnesia, no
harness — Principle I) and the store schema.

---

## Pure core

### `SpeckitOrchestrator.Feature`

The work unit. Loses its dependency edges, gains its group and its ordering key.

| Field | Type | Change | Notes |
|---|---|---|---|
| `id` | `String.t()` | unchanged | Zero-padded identity, e.g. `"001"`. Branch name, store key, operator label. |
| `number` | `pos_integer()` | **added** | Ordering key, parsed from the `NNN` filename prefix at load. Compared numerically (R2). |
| `slug` | `String.t()` | unchanged | Kebab-case name from the filename. |
| `path` | `String.t()` | unchanged | Source file path. |
| `group` | `:backlog \| :ad_hoc` | **added** | Default `:backlog`. Decides ordering rule and base-branch policy (FR-024, FR-028). |
| `created_at` | `DateTime.t() \| nil` | **added** | Set for `:ad_hoc` only; `nil` for `:backlog`, which orders by `number` (FR-025). |
| `prereqs` | `[String.t()]` | **deleted** | FR-010 — ordering has exactly one input, the numbering. |
| `status` | `status()` | changed union | See below. |

**Status union**: `:pending | :running | :done | :escalated | :halted | :failed`

- `:blocked` — **deleted**. It expressed "a prerequisite did not complete"; with
  prerequisites gone, a feature is either attempted or never started.
- Terminal statuses are unchanged: `:done | :escalated | :halted | :failed`.

**Validation rules**

- `number` must parse from the filename prefix; a file whose name does not match
  `^(\d{3,})-(.+)\.md$` is ignored by the loader (unchanged behaviour).
- `group: :ad_hoc` implies `created_at != nil`. Enforced at construction in
  `SingleSpec.build/3`, not by a runtime guard on the struct.

**State transitions** (unchanged from today except for the removed `:blocked`):

```
:pending ──release──> :running ──┬──> :done
                                 ├──> :escalated   (clarify gate)
                                 ├──> :halted      (analyze gate / breaker)
                                 └──> :failed
```

A feature that is never released stays `:pending` in the live run and is written
as `:never_started` when the run closes out (see the store section).

---

### `SpeckitOrchestrator.Backlog`

Parses a directory of `NNN-slug.md` files. Loses the whole dependency layer.

| Element | Change |
|---|---|
| `load!/1` | Returns features sorted by `number` ascending, all `group: :backlog`. |
| `extract_prereqs/1` | **deleted** |
| `dependents/1` | **deleted** |
| `validate_prereqs!/1`, `detect_cycles!/1`, `topo_resolve/3` | **deleted** |
| `MissingPrereqError`, `CycleError` | **deleted** |
| `DuplicateNumberError` | **added** — raised when two files' numbers are numerically equal, naming every conflicting file (FR-012). |
| `ParseError` | unchanged |

A `## Prerequisites` section in a breakdown file is now inert prose: not read,
not validated, not an error (spec Assumptions — operators need not delete them).

---

### `SpeckitOrchestrator.Release`

The pure release policy. Collapses from a wave function to a single-step
decision (R4).

**Removed**: `next_wave/4`, `releasable?/2`, `blocked?/2`, `sequential_order/1`.

**Added**:

```elixir
@spec next([Feature.t()], %{String.t() => Feature.status()}, boolean()) ::
        {:release, Feature.t()} | :none | {:stopped, String.t(), Feature.status()}

@spec order([Feature.t()]) :: [Feature.t()]
```

`order/1` is the total order: `:backlog` features by `number` ascending, then
`:ad_hoc` features by `{created_at, number}` ascending. It is the ordering every
listing view uses (FR-027) and the order `next/3` releases in.

`next/3`'s rules, in evaluation order (R4): breaker ⇒ `:none`; any non-done
terminal ⇒ `{:stopped, id, status}`; any `:running` ⇒ `:none`; lowest-ordered
`:pending` ⇒ `{:release, feature}`; nothing pending ⇒ `:none`.

There is **no cap parameter** — one-at-a-time is rule 3, structural (FR-006,
R10).

---

### `SpeckitOrchestrator.RunContext`

The settings recorded with a run so it can be resumed faithfully. Drops from ten
fields to eight.

| Field | Change |
|---|---|
| `pr_workflow` | **deleted** (FR-021) |
| `max_concurrency` | **deleted** (FR-007, FR-021) |
| `budget_usd`, `plan_stack`, `pr_base`, `pr_remote` | unchanged |
| `auto_remediation`, `auto_remediation_threshold`, `auto_remediation_attempt_limit`, `auto_remediation_model` | unchanged |

**Removed functions**: `stacked?/1` (every run is stacked — nothing to ask) and
`effective_max_concurrency/2` (no requested cap to reconcile against).

`capture/1`, `to_map/1`, `from_map/1`, and `merge/2` keep their shapes and their
documented precedence (explicit opt > recorded > live Config), minus the two
fields.

---

### `SpeckitOrchestrator.Coordinator` (state)

| Field | Change |
|---|---|
| `cap` | **deleted** (FR-007 — not in the recorded per-run settings, and `status/0` surfaced it) |
| `stopped_by` | **added** — `{feature_id, status, reason}` or `nil`; what parked the run (FR-017) |
| `features`, `statuses`, `inflight`, `started_at`, `ledger`, `runner`, `owner`, `self_pid`, `finished?`, `report`, `run_key`, `context`, `layout` | unchanged |

`inflight` remains, used only for the drain check, never for a capacity
comparison.

**Removed API**: `set_cap/2` (FR-008 — no live operation changes how many
features run at once).

**Report shape** (`build_report/1`):

| Key | Change |
|---|---|
| `done`, `escalated`, `halted`, `failed`, `spend`, `breaker_tripped` | unchanged |
| `blocked` | **deleted** — no prerequisites, no blocked features |
| `not_started` | unchanged in name; now means every `:pending` feature at drain (FR-016) |
| `stopped_by` | **added** — `%{feature_id:, status:, reason:}` or `nil` (FR-017) |

---

## Store schema (v2)

Schema version bumps `1 → 2` with a **refusal migration** (R9): a v1 directory
aborts startup naming the incompatibility (FR-023) rather than being
transformed (FR-022).

### `speckit_run`

| Attribute | Change |
|---|---|
| `state` | union gains `:parked` — `:in_flight \| :parked \| :completed \| :superseded` (FR-019) |
| `stopped_by` | **added** — feature id that broke the chain, or `nil` |
| `stopped_reason` | **added** — the divert/failure reason, or `nil` (FR-017) |
| `outcome` | union gains `:ended_by_operator` for a deliberately-ended parked run (FR-019b) |
| all other attributes | unchanged |

**Run state transitions**:

```
                       ┌──────────────── continue_run ─────────────┐
                       v                                           │
  (open_run) ──> :in_flight ──── park_run ────> :parked ───────────┘
                     │                              │
                     │ close_run                    │ end_run
                     v                              v
                 :completed                     :completed
                     ^
                     │
  (another run opens) ──> :superseded   [refused while a :parked run exists]
```

`open_run/2` aborts with `{:parked_run, run_id}` when the repository has a
`:parked` run — a parked run is never superseded automatically (FR-020a,
FR-020b, SC-009).

### `speckit_feature`

| Attribute | Change |
|---|---|
| `prereqs` | **deleted** (FR-010) |
| `group` | **added** — `:backlog \| :ad_hoc` (FR-024) |
| `created_at` | **added** — `DateTime.t() \| nil` (FR-025) |
| `number` | **added** — integer ordering key (R2) |
| `status` | union loses `:blocked`, gains `:never_started` (FR-016, FR-019b) |
| all other attributes | unchanged |

`:never_started` is written by `end_run/2` for every still-`:pending` feature, in
the same transaction that closes the run — so a closed-out record distinguishes
"ran and did not complete" from "never attempted" without re-derivation.

### Everything else

`speckit_run_settings` stores `RunContext.to_map/1`, which now has eight keys
instead of ten — no schema change, the value is an opaque map. `speckit_phase_attempt`,
`speckit_checkpoint`, `speckit_escalation`, `speckit_remediation_attempt`,
`speckit_cost_entry`, `speckit_transcript`, `speckit_settings_amendment`,
`speckit_repo`, and `speckit_meta` are **unchanged**.

---

## Deleted configuration

| Key | Surface | Replacement |
|---|---|---|
| `:pr_workflow` | `config.exs`, `runtime.exs` (`SPECKIT_PR_WORKFLOW`), `Config.pr_workflow?/0`, `LiveConfig`, `ConfigLive`, `TriggerLive` | none — behaviour is unconditional |
| `:max_concurrency` | `config.exs`, `runtime.exs` (`SPECKIT_MAX_CONCURRENCY`), `Config.max_concurrency/0`, `LiveConfig`, `ConfigLive`, `Coordinator.set_cap/2` | none — one at a time is structural |

Both keys are refused rather than ignored on all three surfaces (R1).

`:pr_base`, `:pr_remote`, `:budget_usd`, `:plan_stack`, and every
auto-remediation key remain configurable and live-editable (spec Assumptions:
"Only the run-mode flag and the concurrency limit are retired").

---

## Entity relationships after the change

```
Repository (repo_id)
   │
   ├─ 0..1 :in_flight or :parked Run      ← at most one; a parked one blocks new runs
   └─ 0..n :completed / :superseded Runs

Run
   ├─ 1 RunSettings          (8 keys — no run mode, no concurrency)
   ├─ 0..1 stopped_by        → Feature that broke the chain
   └─ 1..n Features
            ├─ group: :backlog  → ordered by number; links in the Chain
            └─ group: :ad_hoc   → ordered by created_at; NOT links in the Chain

Chain (derived, not stored)
   pr_base ──> feature/001-… ──> feature/002-… ──> …
   advanced only by a :done :backlog feature; stops at the first non-done one
```

The Chain is deliberately **not** a stored entity: it is `Config.pr_base()` plus
the branches of the `:done` backlog features, in order. R6 re-derives it on
continue rather than persisting a stack top that could disagree with the
branches that actually exist.
