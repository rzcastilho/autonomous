# Quickstart: Elapsed Is Execution Time

**Feature**: `024-elapsed-execution-time` | **Date**: 2026-09-16

Runnable checks that prove the feature end-to-end. Shapes and rules are in
[data-model.md](./data-model.md) and [contracts/](./contracts/); this is a
validation guide, not an implementation.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors ON
```

Everything below is hermetic (own temp Mnesia schema via `StoreCase`); no
target repo, no `claude` CLI, no wall-clock sleeps — every pure test injects
`now`.

## 1. Window algebra (FR-001, FR-002, FR-012, SC-006)

```bash
mise exec -- mix test test/speckit_orchestrator/execution_time_test.exs
```

Expected: green. Synthetic `%{key, from, to}` windows and synthetic
`phase_attempts` maps, fixed `now`:

- disjoint windows sum; a window nested in another adds nothing; a partial
  overlap is counted once; touching windows form one span (§2.4);
- an open window grows with `now` and never shrinks; closing it at the
  duration a span reported equals the value shown live at that instant;
- `from_attempts/1` takes every phase atom (`:specify` … `:converge`,
  `:remediation`, `:implement_chunk`, `:auto_remediation`), skips attempts
  with a `nil`, non-`DateTime`, or reversed timestamp, never raises (FR-013);
- `normalize/1` is idempotent; a closed window beats an open one on the
  same `{key, from}`;
- the implement roll-up + three chunks, and the final analyze + two
  superseded runs + two corrections, each measure the same with and without
  the inner attempts (SC-006).

## 2. Hydration (FR-004, FR-007, FR-009, FR-010, FR-011)

```bash
mise exec -- mix test test/speckit_orchestrator/console_hydration_test.exs
```

Expected: green. Amended from 023:

- US1-1: seven attempts covering 40 min across a 20 h span ⇒
  `elapsed_ms == 2_400_000`, not `72_000_000`; the feature's
  `started_at`/`ended_at` no longer matter;
- `layer/3`: recorded ∪ live windows; a live open window advances the
  value between two `now`s; a live slice carrying only a Coordinator
  `elapsed_ms` and no windows layers to `nil` over an empty record (FR-009);
- `apply_update/3`: idempotent for a fixed `now`; never lowers
  `elapsed_ms`; an update whose closed live window is contained in the
  row's recorded window leaves the value unchanged (FR-004);
- 023's properties (live wins per phase, spend `max`, `pr_url` kept, no
  blanking, trim after active) still hold.

## 3. Fold + read-model modes (FR-003, FR-008, FR-009)

```bash
mise exec -- mix test test/speckit_orchestrator/console_read_model_test.exs
```

Expected: green. Measurements are crafted with
`System.convert_time_unit(ms, :millisecond, :native)`:

- `[:speckit, :phase, :start]` opens a window; `:stop` / `:exception`
  closes it at `from + duration`; a `:stop` with no prior `:start` leaves
  `windows` unchanged; `[:speckit, :remediation, *]` and
  `[:speckit, :chunk, *]` fold the same way under their own keys;
- `[:speckit, :feature, :terminal]` with `system_time` closes every open
  window; without it, leaves them;
- `merge/3` drops the Coordinator's `elapsed_ms` from every per-feature
  row (the 023 test asserting `elapsed_ms == 1000` flips to `refute
  Map.has_key?(row, :elapsed_ms)`);
- `hydrate/3` cold and live agree for a feature with no open window
  (FR-007); `overlay_observed/2` promotes a live-active feature to
  `:running` with its open window counting (FR-008).

## 4. Console pages (cold boot, live, resume, diverted)

```bash
mise exec -- mix test test/speckit_orchestrator/web/mission_control_live_test.exs
mise exec -- mix test test/speckit_orchestrator/web/pipeline_dag_live_test.exs
```

Expected: green. Each scenario in
[contracts/console-views.md §2](./contracts/console-views.md) is one test.
Attempts are recorded with explicit `started_at`/`ended_at` (helper gains
timestamp arguments) so the expected `Mm Ss` is known; live phases are
started with `:telemetry.execute([:speckit, :phase, :start],
%{system_time: System.system_time()}, …)` as the existing resume tests
already do. The `1348m`-class check is US1-1: a record whose attempts sum to
40 min across a 20 h calendar span renders `40m 0s` cold and live.

## 5. Whole suite + design guard (SC-008)

```bash
mise exec -- mix test
mise exec -- mix test test/speckit_orchestrator/design_contract_test.exs
mise exec -- mix test --cover
```

Expected: all green, no warnings, guard clean (no new literal, status value,
keyframe, or inline style), coverage on `ExecutionTime` 100% and on
`ConsoleHydration` / `ConsoleReadModel` not below their 023 level.

## 6. Manual check against a real record (optional)

With the orchestrator running over a store that holds a multi-day run
(e.g. the mod-player run from the spec):

```bash
mise exec -- iex -S mix
```

Open `http://localhost:4000/`. For a feature that crossed a restart, ELAPSED
now reads well below the calendar span since its first start — and equals,
to the second, the sum an operator gets by adding that feature's
non-overlapping rows in Run Detail's Duration column (SC-001, SC-002).
`SpeckitOrchestrator.print_status/0` in iex still shows the Coordinator's
since-release counter — unchanged by design (FR-009, spec Assumptions).
