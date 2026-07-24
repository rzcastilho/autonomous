# Contract: Recovery orchestration + reconciled report

`Recovery` is the thin orchestrator wiring the collector to the pure table, the
manifest rewrite, and the operator-facing report. It runs on operator-initiated
recovery (`resume_run/2`, `resumable_run/0`) — never automatically on boot
(FR-010, 009 FR-014).

## `reconcile_run/2`

```elixir
@spec reconcile_run(record :: map(), opts :: keyword()) ::
        {:ok, %{
           statuses: %{Feature.id() => Feature.status()},
           report: Recovery.Report.t(),
           resume_phases: %{Feature.id() => Pipeline.phase()}
         }}
        | {:error, term()}
```

Steps (all read-only w.r.t. work):

1. Rebuild `Layout` from the record (`RunManifest.rebuild_layout/2`) and derive
   `run_shape` from its scope.
2. For each feature: `Recovery.Evidence.collect/3` → `Recovery.Reconcile.status/3`.
3. Fold reconciled values into a persisted `statuses` map (see mapping table in
   data-model.md) and a `resume_phases` map for `{:resume, phase}` results.
4. **Immediately** rewrite the manifest with corrected `statuses`, preserving
   `features`/`context`/`spend`/`segment`/`scope` verbatim (FR-009). `updated_at`
   refreshed. This rewrite runs no phase and spends no budget (FR-010).
5. Build the reconciled report (below) including `next_runnable` computed via the
   existing `Release`/DAG rules over the corrected statuses.

Errors: a missing/corrupt **manifest** propagates as `{:error, :no_manifest |
:corrupt}` (fail loud, Principle II) — recovery does not fabricate a run. A
single corrupt per-feature artifact does NOT error; it is absorbed by the
collector's fallback.

## Reconciled report (FR-015)

Consumed by `Report`/`SpeckitOrchestrator.print_status`-style rendering; read-only
whole-run picture the operator reviews before continuing.

```
Feature   Recorded   Reconciled          Note
001       running    done                corrected (PR pushed)
002       pending    pending             next runnable
003       pending    pending             blocked on 002
007       escalated  escalated           held (human gate)
00X       done       conflict:blocked    CONFLICT — no branch/PR; human resolve
...
Spend: $X.XX (preserved)   Next runnable: [002]
```

Fields per [data-model.md](../data-model.md) "Reconciled run report". `corrected?`
is `recorded != reconciled`. Conflicts are listed separately with their reason so
the operator can resolve them (Principle V).

## Integration with `resume_run/2`

- `resume_run/2` calls `Recovery.reconcile_run/2` in place of the raw
  `RunManifest.reconstruct/1`, then:
  - seeds the Coordinator via its existing `:statuses` seam with the reconciled
    statuses (done/held/conflict features are thereby never re-released);
  - `Ledger.restore` restores the preserved `spend` (FR-013) — unchanged;
  - `dispatch_resume` uses `resume_phases` for `{:resume, phase}` features
    (resume at that phase via the existing checkpoint path) and leaves `:done`/
    held/conflict features untouched (FR-006: no re-run).
- `resumable_run/0` returns the reconciled report for a read-only preview without
  seeding any Coordinator or starting work (FR-015, SC-008).

## Conflict release semantics (FR-014)

A `{:conflict, _}` feature is persisted as `blocked`. `Release.next_wave` already
releases only `:pending` features with all prereqs `:done`, so:
- the conflict feature (not `:pending`) is never released;
- its dependents (prereq not `:done`) stay blocked;
- independent features elsewhere release and run normally — one conflict never
  freezes the whole run.

No change to `Release` is required — the conflict enters through `:blocked`, and
existing DAG semantics produce the required behavior.
