# Quickstart: Validating stacked-sequential-only

**Feature**: `019-stacked-sequential-only` | **Date**: 2026-07-28

Runnable validation scenarios proving the feature end to end. Scenarios 1–6 are
hermetic (default suite, no CLI, no worktrees, no spend). Scenario 7 is the
opt-in live run against a target repository.

Details live in the contracts — [run-start](./contracts/run-start.md),
[release-policy](./contracts/release-policy.md),
[parked-run](./contracts/parked-run.md),
[backlog-order](./contracts/backlog-order.md),
[store-schema-v2](./contracts/store-schema-v2.md) — and in
[data-model.md](./data-model.md). This file says how to *run* the checks.

---

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

The store directory is reset before first use of a v2 build:

```bash
rm -rf ~/.autonomous/mnesia
```

Tests never touch that directory — they create and tear down their own schema in
a temp dir (Quality & Test Discipline).

---

## Scenario 1 — Ordering by number, one at a time (US2, SC-002)

**Proves**: ascending numeric order, gaps legal, never two in flight, prose
prerequisites inert.

```bash
mise exec -- mix test test/speckit_orchestrator/release_test.exs
mise exec -- mix test test/speckit_orchestrator/backlog_test.exs
```

Expected:

- A gapped backlog (`001`, `005`, `020`) releases in exactly that order.
- With any feature `:running`, `Release.next/3` returns `:none` — no input makes
  it return a second feature.
- A fixture whose `## Prerequisites` section names `020` from `001` orders
  identically to one with no such section.
- `001` and `0001` in the same directory raise `Backlog.DuplicateNumberError`
  naming both files.

---

## Scenario 2 — A broken link stops the chain (US3, SC-003)

**Proves**: stop on the first non-done terminal; later features never started;
the report names the stopper.

```bash
mise exec -- mix test test/speckit_orchestrator/coordinator_test.exs
```

Expected, with a seven-feature backlog whose `002` is forced to escalate through
the injected `:runner` seam:

```elixir
%{
  done: ["001"],
  escalated: ["002"],
  not_started: ["003", "004", "005", "006", "007"],
  stopped_by: %{feature_id: "002", status: :escalated, reason: _}
}
```

Repeat with `:halted` and `:failed` — identical shape, different status. No
`blocked` key exists in the report.

---

## Scenario 3 — No surface accepts a retired setting (US1, SC-005)

**Proves**: refusal, not silent acceptance, on all three surfaces.

```bash
mise exec -- mix test test/speckit_orchestrator/retired_settings_test.exs
```

Expected:

```elixir
SpeckitOrchestrator.run(pr_workflow: true)
#=> {:error, {:preflight, [{:retired_option, :pr_workflow}]}}

SpeckitOrchestrator.run(max_concurrency: 4)
#=> {:error, {:preflight, [{:retired_option, :max_concurrency}]}}

SpeckitOrchestrator.run_spec("anything", pr_workflow: false)
#=> {:error, {:preflight, [{:retired_option, :pr_workflow}]}}
```

Environment surface, checked manually once:

```bash
SPECKIT_PR_WORKFLOW=true mise exec -- mix run -e ':ok'
# expect: raise naming the retired setting, non-zero exit
SPECKIT_MAX_CONCURRENCY=4 mise exec -- mix run -e ':ok'
# expect: raise naming the retired setting, non-zero exit
```

Grep check — nothing outside the refusal paths and this spec folder mentions the
retired keys:

```bash
grep -rn "pr_workflow\|max_concurrency" lib config | grep -v retired
# expect: no results
```

---

## Scenario 4 — Park, continue, end (US4, SC-007, SC-008, SC-009)

**Proves**: the parked lifecycle and the refusal of new work.

```bash
mise exec -- mix test test/speckit_orchestrator/parked_run_test.exs
```

Expected sequence:

```elixir
# run stops at 002
{:ok, detail} = SpeckitOrchestrator.run_detail(run_id)
detail.run.state       #=> :parked
detail.run.stopped_by  #=> "002"

# new work is refused while parked
SpeckitOrchestrator.run([])
#=> {:error, {:parked_run, "r000001", [:continue, :end]}}
SpeckitOrchestrator.run_spec("a one-off")
#=> {:error, {:parked_run, "r000001", [:continue, :end]}}

# resolving without a decision changes nothing
SpeckitOrchestrator.resolve("002")
#=> {:error, :decision_required}

# continue: same run_id, 002 re-runs, 003.. follow in order
SpeckitOrchestrator.resolve("002", decision: :continue)
SpeckitOrchestrator.current_run_id()   #=> "r000001"   (unchanged)

# or end: closes out, never-started recorded as such
SpeckitOrchestrator.resolve("002", decision: :end)
detail.run.state    #=> :completed
detail.run.outcome  #=> :ended_by_operator
# every unattempted feature: status :never_started
```

Also covered: continuing a run whose stopping feature breaks again parks it a
second time with the new reason recorded distinctly; a parked run whose stopper
was the last feature reaches the same closed-out result via either decision.

---

## Scenario 5 — Ad-hoc features are their own group (US1, FR-024..028)

**Proves**: separate group, creation-time order, base-branch neutrality.

```bash
mise exec -- mix test test/speckit_orchestrator/single_spec_test.exs
mise exec -- mix test test/speckit_orchestrator/release_test.exs
```

Expected:

- `SingleSpec.build/3` yields `group: :ad_hoc` with a non-nil `created_at`.
- `Release.order/1` puts backlog features first (by number), ad-hoc after (by
  `created_at`, tie-broken by `number`).
- The ad-hoc executor branches from `Config.pr_base()` and never calls
  `StackTracker.set_top/2` — asserted through the injected `:publisher` seam by
  observing the stack top unchanged after an ad-hoc `:done`.

---

## Scenario 6 — Console shows one shape (US1, SC-001)

**Proves**: zero run-shape decisions at start; no mode label anywhere.

```bash
mise exec -- mix test test/speckit_orchestrator/web/
```

Expected:

- `TriggerLive` renders no PR-workflow toggle and no effective-concurrency line;
  the count of run-shape inputs on the trigger screen is **0** (SC-001).
- `ConfigLive` renders no concurrency slider and no PR-workflow toggle;
  `pr_base`, `pr_remote`, budget, and models remain editable.
- The status bar renders no mode label and no cap.
- The pipeline view renders two ordered groups (numbered backlog, Ad-hoc), not a
  dependency graph.
- `MissionControlLive` renders the parked banner with the stopping feature, its
  reason, and both actions when the run is parked.

---

## Scenario 7 — Live end-to-end (opt-in)

**Proves**: the whole thing against a real target repository. Costs money.

```bash
mise exec -- mix test --include integration
```

Then a real run, following `docs/phase7-ledgerlite-runbook.md`:

```bash
rm -rf ~/.autonomous/mnesia          # SC-006: first run is run number one
mise exec -- iex -S mix
```

```elixir
# no run-shape options exist to pass
{:ok, _pid} = SpeckitOrchestrator.run()
SpeckitOrchestrator.print_status()
```

Observe:

1. The PR remote and target pack are preflighted before any feature work (FR-003).
2. Exactly one feature is in flight at every point (SC-002).
3. Each completed feature's branch is pushed and a PR opened against the previous
   completed feature's branch (FR-001).
4. On the first non-done terminal, the run parks and releases nothing further
   (FR-014, SC-003).
5. `run_detail/1` names the stopper and lists the never-started features without
   inspecting the target repo (SC-004).
6. `resolve(id, decision: :continue)` carries the chain to completion with no
   manual re-basing and no re-declared run shape (SC-007).

---

## Success-criteria coverage

| Criterion | Scenario |
|---|---|
| SC-001 zero run-shape choices | 6 |
| SC-002 ascending order, max one in flight | 1, 7 |
| SC-003 no later feature after a non-done | 2, 7 |
| SC-004 report names stopper + never-started | 2, 7 |
| SC-005 no surface accepts retired settings | 3 |
| SC-006 zero compatibility code, empty store | 3 (grep), 7 |
| SC-007 stopped chain continued to completion | 4, 7 |
| SC-008 parked decision visible and one-step | 4, 6 |
| SC-009 no parked run lost to supersede | 4 |
