# Phase 1 Data Model: Control Plane

The console holds **no persistent data** (FR-036). Every entity below is a
read-model derived at request/broadcast time from an authoritative backend source.
This document maps each spec entity to its source and the console's in-memory
shape. "Source" = where the truth lives; the console never becomes a second source
of truth (FR-033).

## Entity → source map

| Entity (spec) | Authoritative source | Console shape |
|---------------|----------------------|---------------|
| Run | per-run `Coordinator` (named, may be absent) + `Config` | `RunView` |
| Feature | `Coordinator.status/0` `per_feature` + `Backlog`/`Feature` + projection | `FeatureView` |
| Phase | `Pipeline.phases/0` + phase telemetry | `PhaseCell` |
| Checkpoint | `Checkpoint.read/1` JSON | `CheckpointView` |
| Escalation / Halt | `Coordinator` status + `Checkpoint` + spec (clarify Qs) | `EscalationView` |
| Telemetry event | `[:speckit, :phase/feature, …]` events | `EventEntry` (bounded feed) |
| Transcript | filesystem glob `<transcript_root>/<id>/*.md` | `TranscriptDoc` |
| Cost breaker | `Ledger.snapshot/1` | `BreakerView` |
| Configuration | `Config.*` + live setters | `ConfigView` |

## RunView (FR-004, FR-036)

Derived from the presence/state of the named `Coordinator` plus `Config`.

| Field | Source | Notes |
|-------|--------|-------|
| `active?` | `Process.whereis(Coordinator) != nil` | false → render no-active-run state |
| `title` | run start opts / derived | e.g. "Backlog run" / "Single-spec: <slug>" |
| `mode` | `Config.pr_workflow?/0` at start | `:parallel_waves` \| `:stacked_pr` |
| `max_concurrency` | `Config.max_concurrency/0` / live cap | PR mode forces effective 1 |
| `budget_usd` | `Ledger.snapshot.budget` | live |
| `finished?` | `Coordinator.status.finished?` | drained/completed screen |
| `report` | `Coordinator.status.report` | nil until finished; final counts+spend |

Run lifecycle (for display): `no_run → active → drained`. `active` sub-states come
from per-feature aggregation, not a Run-level status field (none exists).

## FeatureView (FR-007, FR-008, FR-011)

One per feature. Merges three sources; the **current phase** is projected from
telemetry (see PhaseCell / research R3), not read from the snapshot.

| Field | Source |
|-------|--------|
| `id`, `slug`, `prereqs` | `Feature` struct (backlog / run) |
| `status` | `Coordinator.status.per_feature[id].status` — one of `:pending, :blocked, :running, :escalated, :halted, :failed, :done` |
| `elapsed_ms` | `Coordinator.status.per_feature[id].elapsed_ms` (nil until started) |
| `spend` | projection sum of per-phase `cost` / `[:feature, :terminal]` `cost_total` |
| `current_phase` | projection: last `[:phase, :start]` `meta.phase` |
| `phases` | `[PhaseCell]` — one per `Pipeline.phases/0` |

**Status → color** (single shared palette, used identically in strip, table, DAG,
drawer, escalations — FR-034): `pending` neutral, `blocked` muted, `running`
active/blue, `escalated` amber, `halted` red, `failed` red-dark, `done` green.

## PhaseCell (FR-008)

Seven per feature, fixed order `Pipeline.phases/0`:
`specify → clarify → plan → tasks → analyze → implement → converge`.

| Field | Source | Values |
|-------|--------|--------|
| `phase` | `Pipeline.phases/0` | atom |
| `state` | projection | `:completed \| :active \| :pending` |
| `outcome` | `[:phase, :stop]` `meta.outcome` | phase result summary (active/completed) |
| `cost` | `[:phase, :stop]` `meta.cost` | float |
| `model` | `[:phase, :start]` `meta.model` | resolved model string |

The **active** cell is further distinguished by the feature's `status`
(running vs escalated vs halted vs failed) so a diverted phase reads correctly
(FR-008).

## CheckpointView (FR-020, FR-021)

From `Checkpoint.read/1` → `{:ok, map}` (string keys) \| `{:error, :no_checkpoint}`
\| `{:error, :corrupt}`.

| Field | JSON key | Notes |
|-------|----------|-------|
| `last_phase` | `"last_phase"` | resume default start phase |
| `status` | `"status"` | `escalated`/`halted`/`failed` |
| `reason` | `"reason"` | inspect'd divert reason |
| `session_id` | `"session_id"` | nullable |
| `slug`, `path` | `"slug"`, `"path"` | identity |
| `run_context` | `"context"` | `%{pr_workflow, max_concurrency, budget_usd, plan_stack, pr_base, pr_remote}` — the recorded shape a resume re-executes under (FR-021) |

`:no_checkpoint` / `:corrupt` → the console steers to **full restart**
(`resolve/2`), never offers an impossible checkpoint resume (edge case / FR-023).

## EscalationView (FR-020–FR-024)

One per feature whose status ∈ `{:escalated, :halted, :failed}`.

| Field | Source |
|-------|--------|
| `feature` | FeatureView |
| `divert_reason` | Checkpoint `reason` / terminal event reason |
| `checkpoint` | CheckpointView (or absent/corrupt marker) |
| `clarify_questions` | parsed from the feature's `spec.md` `## NEEDS HUMAN` block (escalated only) |
| `run_context` | CheckpointView.run_context |
| actions | resume (`resume/2`) with optional `:prompt` + `:from`; full restart (`resolve/2` then `run/1`) |

The nav Escalations badge counts these (FR-002); empty set → all-clear state
(FR-024).

## EventEntry — bounded telemetry feed (FR-009, edge case)

| Field | Source |
|-------|--------|
| `feature_id` | event `meta.feature_id` |
| `text` | rendered from event (phase start/stop/outcome, terminal status) |
| `phase` | `meta.phase` (phase events) |
| `severity` | derived (info / warn on escalate/halt / error on exception/fail) |
| `at` | wall clock at receipt |

The feed is a fixed-length ring (newest first) held in `ConsoleProjection` state so
a long run never grows it unbounded.

## TranscriptDoc (FR-027, FR-028)

Filesystem-derived (no backend struct; `Transcripts` is write-only).

| Field | Source |
|-------|--------|
| `feature_id`, `phase` | picker selection |
| `path` | `<transcript_root>/<id>/NN-<phase>.md` (globbed) |
| `body` | file contents (markdown) |
| `exists?` | file present | false → explicit "not yet written" (FR-028) |

## BreakerView (FR-004, SC-007)

Direct from `Ledger.snapshot/1`.

| Field | JSON key |
|-------|----------|
| `budget` | `budget` |
| `committed` | `committed` |
| `reserved` | `reserved` |
| `tripped?` | `tripped?` |

Gauge fill = `(committed + reserved) / budget`; fill color signals proximity
(green → amber → red); `tripped?` shows the armed/tripped indicator. A tripped
breaker halts new releases on screen and never depicts a mid-phase kill (SC-007).

## ConfigView (FR-029–FR-032)

| Field | Source | Editable → apply |
|-------|--------|------------------|
| `models` | `Config.models/0` | per phase, `opus`/`sonnet` → app env (forward-only) |
| `budget_usd` | `Config.budget_usd/0` / Ledger | `Ledger.set_budget/2` (forward-only) |
| `max_concurrency` | `Config.max_concurrency/0` / Coordinator | `Coordinator.set_cap/2` (forward-only) |
| `pr_workflow` | `Config.pr_workflow?/0` | app env; forces effective cap 1 |
| `pr_base`, `pr_remote` | `Config.pr_base/0`, `Config.pr_remote/0` | app env; displayed |

All edits are forward-only and never persisted as cross-run defaults or applied to
an already-completed phase (FR-037) — see `contracts/live_config.md`.

## ConsoleProjection state (the console's read model)

Held in one boot-started GenServer; rebuilt by folding telemetry + reconcile ticks.

```
%{
  features: %{feature_id => %{current_phase, phases: %{phase => %{state, outcome, cost, model}}, spend}},
  feed:     [EventEntry]           # bounded ring, newest first
}
```

Merged at read time with `Coordinator.status/0` (status, elapsed, totals, inflight,
breaker_tripped, finished?, report) and `Ledger.snapshot/1` (breaker) to produce
the full view state. The fold is a **pure** function (`ConsoleReadModel`) —
unit-tested without LiveView or a CLI.
