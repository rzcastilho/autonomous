# Contract: Live configuration apply (forward-only)

Satisfies FR-029..FR-032 and FR-037. Every edit retunes the **current live run**
for work **not yet started** — never retroactively, never persisted as a cross-run
default. This is the only part of the console that writes back into the runtime;
it does so through two small additive setters plus app-env writes, and preserves
the drain-don't-kill invariants (Constitution IV).

## The apply table

| Setting | Mechanism | Forward-only because | Reflected in |
|---------|-----------|----------------------|--------------|
| Per-phase model (`opus`/`sonnet`) | `Application.put_env(:speckit_orchestrator, :models, updated)` | `Config.model_for/1` is read per phase inside `FeatureRunner` at phase start | Config view; next phase's `[:phase, :start]` `meta.model` |
| Budget (USD) | **`Ledger.set_budget(server, amount)`** (new) — `GenServer.call` updating `state.budget` | breaker decisions (`reserve`, `breaker_tripped?`) read `state.budget` on the next call | status-bar gauge, `Ledger.snapshot/1` |
| Max concurrency | **`Coordinator.set_cap(server, n)`** (new) — `GenServer.call` updating `state.cap`; also mirror to app env | `Release.next_wave` reads `state.cap` at the next wave computation | status bar, next wave size |
| PR workflow on/off | `Application.put_env(:pr_workflow, bool)` | consulted at run start / release strategy | forces **effective cap 1** (surfaced) |
| PR base / remote | `Application.put_env(:pr_base / :pr_remote, …)` | consulted when a PR is opened on `:done` | Config view display |

## New backend setters (the only non-web additions)

```elixir
# Coordinator
@spec set_cap(GenServer.server(), pos_integer()) :: :ok
def set_cap(server \\ __MODULE__, n) when is_integer(n) and n >= 1

# Ledger
@spec set_budget(GenServer.server(), number()) :: :ok
def set_budget(server \\ __MODULE__, amount) when is_number(amount) and amount >= 0
```

Both are additive `GenServer.call` handlers that mutate one field of existing
state. Neither touches in-flight work.

## Invariants (MUST hold)

1. **Never retroactive** (FR-032/FR-037): an already-completed phase's model, cost,
   or outcome is never altered by a config change. The console must not depict such
   a change.
2. **Never persisted** (FR-037): edits live in runtime state / app env for this
   node's current run only. They are not written to `config/*.exs` and do not
   survive a node restart as new defaults.
3. **Drain-don't-kill preserved** (Constitution IV / SC-007): lowering the budget
   may trip the breaker on the **next** reservation/decision, halting new releases
   and letting in-flight phases finish, but MUST NOT kill an in-flight phase. The
   Ledger invariant `committed < budget + max single reservation` continues to hold
   under the new budget for future reservations.
4. **PR mode forces cap 1** (FR-031): when PR workflow is enabled, effective
   concurrency displayed and applied is 1 regardless of the max-concurrency field.
5. **Bounds**: budget ≥ 0; max concurrency ≥ 1; model ∈ `{opus, sonnet}` per phase.
   Out-of-bounds input is rejected at the form (Fail Loud, Constitution II) — no
   setter is called.

## Apply flow

1. Operator edits a field in `ConfigLive` and submits.
2. `LiveConfig.apply(change)` validates bounds (reject → field error, no setter).
3. On valid input, dispatch the mechanism from the apply table.
4. Broadcast a reconcile so the status bar/gauge and other LiveViews reflect the
   new value (FR-030); toast the change (FR-005).
