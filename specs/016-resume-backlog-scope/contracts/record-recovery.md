# Contract: run-record recovery (`recover_record/1`, `Recovery.Rebuild`)

**Feature**: `016-resume-backlog-scope` — User Story 3

A repair tool for records already narrowed by this defect. Operator-invoked
only; never part of an ordinary resume (FR-019).

## `SpeckitOrchestrator.recover_record/1`

```elixir
@spec recover_record(keyword()) ::
        {:ok, Recovery.Rebuild.proposal()}
        | {:ok, :written, Recovery.Rebuild.proposal()}
        | {:error, :no_manifest}
        | {:error, :corrupt_manifest}
        | {:error, {:backlog, term()}}
        | {:error, {:inconsistent, [Recovery.Rebuild.discrepancy()]}}
```

| Option | Type | Default | Meaning |
|--------|------|---------|---------|
| `:confirm` | `boolean()` | `false` | write the rebuilt record; without it the call is a pure preview |
| `:backlog_root` | `Path.t()` | layout's `breakdown_root` | override the backlog source |
| `:layout` | `Layout.t()` | rebuilt from the record | test seam |
| `:git` / `:remote` | fun | `Recovery.Evidence` defaults | evidence seams |
| `:manifest` | module | `RunManifest` | writer seam |

### Preview (default)

Reads the record, loads the backlog, collects per-feature evidence, reconciles,
and returns `{:ok, proposal}`. **No file is written, no process is started, no
budget is spent** (FR-019a). Printable with `Recovery.Report.format/1`.

### Confirm

`confirm: true` performs everything the preview does and then writes the rebuilt
record through `RunManifest.write/1`. The proposal is a superset of the recorded
features, so the scope guard permits it (see `manifest-guard.md`). Returns
`{:ok, :written, proposal}`.

### Refusal (FR-020)

The record is left untouched and nothing is written when:

| Condition | Return |
|-----------|--------|
| no record for this repo | `{:error, :no_manifest}` |
| record unreadable | `{:error, :corrupt_manifest}` |
| backlog unloadable (missing dir, dangling prereq, cycle) | `{:error, {:backlog, reason}}` |
| any `:prereq_missing` discrepancy | `{:error, {:inconsistent, discrepancies}}` |

`Backlog.load!/1` raises by design (Principle II); `recover_record/1` catches
`MissingPrereqError` / `CycleError` at this boundary and returns them as
`{:error, {:backlog, reason}}` rather than propagating a raise into an operator
session.

## `Recovery.Rebuild.propose/3`

```elixir
@spec propose(record :: map(), backlog :: [Feature.t()], opts :: keyword()) ::
        {:ok, proposal()} | {:error, {:inconsistent, [discrepancy()]}}

@type proposal :: %{
        features: [Feature.t()],
        statuses: %{String.t() => Feature.status()},
        resume_phases: %{String.t() => Pipeline.phase()},
        discrepancies: [discrepancy()],
        report: Recovery.Report.t(),
        source: %{record_ids: [String.t()], backlog_ids: [String.t()], backlog_root: Path.t() | nil}
      }

@type discrepancy :: %{kind: atom(), id: String.t(), detail: term()}
```

### Union rule

`features` = backlog features in backlog order, then any recorded feature the
backlog does not name, appended in recorded order. Prereqs come from the backlog
when the backlog names the feature, else from the record.

### Per-feature status

Reconciled by the **existing** `Recovery.Evidence` + `Recovery.Reconcile` pair —
no second decision table (D4). The recorded status is the `recorded` input where
the record names the feature; `:pending` where it does not.

| Situation | Status | Discrepancy |
|-----------|--------|-------------|
| in both, reconciles cleanly | reconciled verdict | — |
| in both, `{:conflict, r}` | `:blocked` | `:unreconcilable` |
| record only (dropped from the backlog on disk) | recorded status, unreconciled | `:absent_from_backlog` |
| backlog only (the narrowed-away case) | reconciled from evidence — `:pending` when nothing was ever built | `:absent_from_record` |
| any restored feature names a prereq not in the union | — | `:prereq_missing` → refuse |

Recovery never invents a state (FR-017) and reports every case it could not
reconcile (FR-018).

## Worked example — the observed `../quickpoll` damage

Record after the bug: `features: [001]`, `statuses: {001 => done}`, scope
`{breakdown, first-wave}`. Backlog on disk: `001 → 002 → 003`.

```text
Feature  Recorded  Reconciled  Note
001      done      done        corroborated (branch + pr.json)
002      —         pending     restored from backlog (absent from record)
003      —         pending     restored from backlog (absent from record)

Discrepancies: 002 absent_from_record, 003 absent_from_record
Spend: $x.xx (preserved)   Next runnable: ["002"]
```

`recover_record(confirm: true)` writes that three-feature record; a subsequent
`resume_run/1` releases `002` then `003` and never rebuilds `001` (SC-006).

## Non-goals

- Running automatically on boot or inside `resume/2` / `resume_run/1` (FR-019).
- Repairing per-feature checkpoints, worktrees, or branches — this rebuilds the
  **run record** only.
- Guessing at a feature whose evidence is absent or contradictory. It is
  reported; the operator decides.
