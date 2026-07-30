# Contract: `SpeckitOrchestrator.Release` — the pure release policy

**Feature**: `019-stacked-sequential-only`

Pure module. No process state, no IO, no Mnesia, no harness (Principle I). This
is the whole decision surface for "what runs next", the direct analogue of
`Pipeline.next/3` for the run level.

---

## `order/1`

```elixir
@spec order([Feature.t()]) :: [Feature.t()]
```

The total order. Backlog features first, ascending by `number`; then ad-hoc
features, ascending by `{created_at, number}`.

**Guarantees**

- **Total** — every pair of distinct features has a defined order.
- **Stable** — two ad-hoc features with identical `created_at` order by `number`,
  which is unique by construction (spec Edge Cases: "two ad-hoc features created
  in the same instant").
- **Deterministic** — the same input list always yields the same output,
  independent of input order. Every listing view and the release loop use this
  one function, so no view can show an order the run will not follow (FR-027).

---

## `next/3`

```elixir
@spec next([Feature.t()], %{String.t() => Feature.status()}, boolean()) ::
        {:release, Feature.t()}
      | :none
      | {:stopped, String.t(), Feature.status()}
```

Arguments: the run's features, `feature_id => status` (a feature absent from the
map uses its struct `status`), and whether the cost breaker is tripped.

### Rules, in evaluation order

| # | Condition | Result | Requirement |
|---|---|---|---|
| 1 | `breaker_tripped?` | `:none` | Principle IV — drain, don't kill |
| 2 | any feature is `:escalated`, `:halted`, or `:failed` | `{:stopped, id, status}` | FR-014, FR-015 |
| 3 | any feature is `:running` | `:none` | FR-006 — one at a time, structural |
| 4 | some feature is `:pending` | `{:release, lowest_ordered_pending}` | FR-009 |
| 5 | otherwise | `:none` | run complete |

When rule 2 matches more than one feature (possible only on a resumed run whose
record already held several), the **lowest-ordered** one is reported — it is the
one that broke the chain first.

### Why the ordering of rules matters

- **2 before 3** — a feature halted by the cost breaker mid-phase is a non-done
  terminal, so the chain stops for the right reason with no special case (spec
  Edge Cases: "cost breaker trips mid-chain").
- **1 before 2** — a tripped breaker drains silently rather than reporting a
  stop; the halted feature it produces triggers rule 2 on the next call.
- **3 before 4** — this rule, and only this rule, is what makes concurrency 1.
  There is no parameter that can change it (FR-006, R10).

### What is not here

No `cap` argument. No `releasable?/2`. No `blocked?/2`. No prerequisite lookup.
`next/3` never reads a feature's `prereqs` because the field no longer exists.

---

## Caller obligations (`Coordinator`)

| `next/3` result | Coordinator action |
|---|---|
| `{:release, feature}` | mark `:running`, add to `inflight`, invoke the runner |
| `{:stopped, id, status}` | when `inflight` is empty: build the report with `stopped_by`, **park** the run (`Store.Writer.park_run/2`), notify the owner |
| `:none` with `inflight` non-empty | wait for the next `{:finished, …}` |
| `:none` with `inflight` empty | build the report, close the run out, notify the owner |

The Coordinator reacts; it never decides. Every branch above is determined by
`next/3`'s return value alone.

---

## Test obligations

Coverage above 90% on this module (Quality & Test Discipline), driven entirely
through the pure function — no CLI, no worktree, no store:

1. Ascending release order over a gapped backlog (001, 005, 020).
2. Never two in flight: with any feature `:running`, every call returns `:none`.
3. Stop on each of `:escalated`, `:halted`, `:failed` — later features stay
   `:pending` and are never returned.
4. Breaker tripped ⇒ `:none` even with releasable features.
5. Ad-hoc ordering by `created_at`, tie-broken by `number`.
6. `order/1` is independent of input list order.
7. Prose `## Prerequisites` in a fixture has no effect on order (FR-010).
