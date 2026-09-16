# Quickstart: Console Restart Hydration

**Feature**: `023-console-restart-hydration` | **Date**: 2026-09-15

Runnable checks that prove the feature end-to-end. Shapes and rules are in
[data-model.md](./data-model.md) and [contracts/](./contracts/); this is a
validation guide, not an implementation.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors ON
```

Everything below is hermetic (own temp Mnesia schema via `StoreCase`); no
target repo, no `claude` CLI.

## 1. Pure hydration (FR-012, SC-007)

```bash
mise exec -- mix test test/speckit_orchestrator/console_hydration_test.exs
```

Expected: green. The file builds `run_detail`-shaped maps by hand and asserts,
with a fixed `now`:

- seven completed cells + spend + `elapsed = ended − started` for a `:done`
  feature (US1-1);
- last attempt per phase wins, own cost only, row spend sums every entry
  (clarification 2); `:remediation` / `:implement_chunk` / `:auto_remediation`
  attempts yield no cell (FR-003), chunks add no spend (FR-005);
- cells after the checkpoint phase absent; `:done` keeps all (FR-002a);
- halted-at-`analyze` cell is `active` with the attempt's cost/model and
  `outcome: :halted` (FR-004);
- `layer/2` / `apply_update/2`: live wins per phase, spend `max`, `pr_url`
  kept, later cells dropped after a live active phase, idempotence (§3
  properties);
- records lacking attempts / checkpoint / timestamps / cost entries produce
  empty cells, `nil` elapsed, `0.0` spend — no raise (FR-013).

## 2. Read-model modes

```bash
mise exec -- mix test test/speckit_orchestrator/console_read_model_test.exs
```

Expected: green. `hydrate/3` fills coordinator-listed rows in live mode and
ignores record-only features (FR-008); builds rows from the record in cold
mode; `overlay_observed/1` still promotes a live-active feature to `:running`
without blanking record cells.

## 3. Console pages (cold boot, live, resume)

```bash
mise exec -- mix test test/speckit_orchestrator/web/mission_control_live_test.exs
mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs
```

Expected: green. New cases record two `:done` features (seven attempts + cost
entries + `started_at`/`ended_at` each) and one in-flight feature, then:

- mount `/` with **no** Coordinator → both done rows show seven
  `phase-cell-completed`, `$<sum>`, and a non-`—` elapsed (US1-5);
- start a Coordinator over the same store and mount `/` → same cells and
  spend (US1-1), elapsed still from the record;
- `send(view.pid, {:console, :feature_updated, %{id: ..., feature: since_boot_slice}})`
  → the done rows are unchanged and the resumed row keeps its pre-restart
  cells (US1-2, US2-2, SC-004);
- click a row → drawer timeline meta shows `$<cost> · <model>` per completed
  phase (US2-4, FR-016);
- `/dag` node for a done feature carries the same cells and spend (US1-4).

## 4. Whole suite + design guard (SC-007)

```bash
mise exec -- mix test
```

Expected: all green, including `design_contract_test.exs` (no new literal,
status value, keyframe, or inline style was introduced).

## 5. Manual check against a real record (optional, after a live run)

With a run recorded in the machine-global store (e.g. after a Phase 7-style
run), from `iex`:

```elixir
mise exec -- iex -S mix
iex> {:ok, d} = SpeckitOrchestrator.run_detail(SpeckitOrchestrator.current_run_id())
iex> f = Enum.find(d.features, & &1.status == :done)
iex> SpeckitOrchestrator.ConsoleHydration.from_record(f, d.cost_entries, DateTime.utc_now())
```

Expected: `phases` has seven `:completed` cells with `cost`/`model` set,
`spend` equals the sum of that feature's rows on `/runs/<id>` excluding
`implement_chunk` rows (SC-002), `elapsed_ms == DateTime.diff(f.ended_at,
f.started_at, :millisecond)` (SC-003). Open `/` and `/dag` in the browser:
the row and node agree with the drawer and with `/runs/<id>`.
