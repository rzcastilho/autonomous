# Quickstart: validating wave-scoped history in the Pipeline Chain

## Prerequisites

- The toolchain comes from mise (`.tool-versions` pins `1.20.2-otp-28`).
- `mise exec -- mix deps.get && mise exec -- mix compile` must be clean,
  because `warnings_as_errors` is on.

## 1. Automated validation (hermetic)

```bash
mise exec -- mix test test/speckit_orchestrator/wave_history_test.exs
mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs
mise exec -- mix test test/speckit_orchestrator/web/phase_strip_test.exs
mise exec -- mix test test/speckit_orchestrator/web/design_contract_test.exs
mise exec -- mix test                      # full suite: SC-005, nothing else regresses
```

The expected outcome is that all of these pass. The scenarios the tests must
cover are:

| Scenario | Spec ref | Setup (via `Store.Writer`, temp store, `breakdown_packages` fixture: waves `alpha` and `beta`, both with `001`) | Assert |
|---|---|---|---|
| Reported bug | FR-011, US1-1, SC-001 | A completed `beta` run where `001` is `:done` with phases and spend. No run in flight. Select `alpha`. | `alpha`'s `001` node is `data-status="pending"`, has no `phase-cell-completed`, and shows `$0.00` |
| Drawer does not leak | US1-4, FR-003 | Same as above. Click `alpha`'s `001`. | The drawer shows none of `beta`'s run state |
| Live event does not leak | US1-5, FR-004 | An in-flight `beta` run. Select `alpha`. Broadcast `feature_updated` for `001`. | `alpha`'s `001` is unchanged |
| Own history | US2-1, SC-002 | Completed runs for both `alpha` and `beta`. Select each in turn. | Each wave's statuses and spend equal its own run record |
| Newest run only | US2-2, FR-006 | Two `alpha` runs: an older one where `001` is `:done`, and a newer one where `001` is `:halted`. | `001` shows `:halted`, with no merged phases |
| Never run | US2-3 | No run for `alpha` | Cold nodes; `data-wave-source="none"` |
| Interrupted | US2-4, FR-007a | A superseded `alpha` run where `003` is `:running` and its checkpoint's `last_completed_phase` is `:tasks`. | `003` has `data-status="blocked"`, reads `Interrupted`, and has `phase-cell-interrupted` on the next phase. There is no `phase-cell-active`. |
| Receipt | US2-5, FR-007 | A completed `beta` run | `data-wave-source="recorded"`, the `run_id` is linked to `/runs/<run_id>`, and the state reads `:completed` |
| Default wave | US3-2, SC-004 | The most recent run is scoped to `beta`, nothing is in flight, and the view is opened fresh | `beta` is `selected` |
| Unreadable record | FR-010 | The newest `alpha` summary is readable but its `run_detail` is damaged | Cold nodes and `data-wave-source="unavailable"`, with no status color and no `beta` state |

## 2. Manual validation against a real target (optional)

1. Start the console with `mise exec -- iex -S mix` (the endpoint serves the
   console) and point `config :speckit_orchestrator, :repo` at a target with
   two or more breakdown packages that share feature numbers.
2. Run one wave to completion, for example
   `SpeckitOrchestrator.run(package: "008-…")`, or reuse an existing recorded
   run.
3. Open `/dag`.
   - **Expected**: the picker lands on `008` (US3), and the receipt strip
     shows that run's `run_id` and `:completed`.
4. Switch to `007`.
   - **Expected**: no node shows `008`'s phases or spend. If `007` was run
     before, its own last run's receipt and state appear. Otherwise you see
     "No recorded run for `007-…`".
5. Click the `run_id` in the receipt.
   - **Expected**: `/runs/<run_id>` (Run Detail) opens and agrees with what
     the chain drew (SC-002).
6. Switch back and forth between waves.
   - **Expected**: each switch renders in under 1 s (SC-003).
