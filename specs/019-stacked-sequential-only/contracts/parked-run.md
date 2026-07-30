# Contract: Parked runs — park, continue, end

**Feature**: `019-stacked-sequential-only`

A run that stopped at a broken link is **parked**: stopped, but not written off.
It holds its never-started remainder and waits for an operator decision. The
system never makes that decision on the operator's behalf (FR-019a).

---

## 1. Parking (automatic)

Triggered by the Coordinator when `Release.next/3` returns `{:stopped, id, status}`
and nothing is in flight.

```elixir
Store.Writer.park_run(run_key, %{
  stopped_by: feature_id,
  status: :escalated | :halted | :failed,
  reason: term()
})
```

One transaction: sets `state: :parked`, `stopped_by`, `stopped_reason`. Features
keep their statuses — never-started ones stay `:pending`, so a continue can
release them (FR-019b writes `:never_started` only on a deliberate end).

**Guarantees**

- A parked run is distinguishable from an `:in_flight` run and from a
  `:completed` one by its `state` alone (FR-019).
- Parking releases nothing further and starts no work.
- A parked run is never garbage-collected into a closed-out run, and stays
  parked indefinitely (spec Edge Cases: "a parked run is never resolved").
- A parked run is never removable by `prune/1` — it is resumable by definition
  (`resumable_summary?/1` already protects it via its non-completed state).

---

## 2. Refusing new work

```elixir
run(opts)       # => {:error, {:parked_run, run_id, [:continue, :end]}}
run_spec(d, o)  # => {:error, {:parked_run, run_id, [:continue, :end]}}
```

Enforced inside `Store.Writer.open_run/2`'s transaction — a `:parked` run for the
repository aborts with `{:parked_run, run_id}` instead of being superseded
(FR-020a). Because it is transactional, the guarantee is race-free: two
concurrent starts cannot both slip past a parked run (SC-009).

The refusal names the parked run and both ways out. It applies equally to
backlog runs and ad-hoc single-spec starts (FR-020b).

---

## 3. Resolving — the operator's choice

```elixir
@spec resolve(String.t(), keyword()) :: :ok | {:error, term()}
```

`resolve/2` gains a **required** `:decision` option when the repository has a
parked run:

| `:decision` | Effect |
|---|---|
| `:continue` | Frees the feature's worktree, records the escalation resolution, then `continue_run/1`. |
| `:end` | Frees the feature's worktree, records the escalation resolution, then `end_run/1`. |
| absent | `{:error, :decision_required}` — nothing changes, nothing is released (FR-019a). |

With no parked run, `resolve/1` behaves exactly as today (worktree freed,
escalation resolved, no run started) and `:decision` is not required.

---

## 4. `continue_run/1`

```elixir
@spec continue_run(keyword()) ::
        GenServer.on_start()
      | {:error, :no_parked_run}
      | {:error, {:active_run, pid()}}
      | {:error, term()}
```

Steps, in order:

1. Guard: a live unfinished `Coordinator` refuses with `{:error, {:active_run, pid}}`
   unless `:force`.
2. Locate the repository's `:parked` run; none ⇒ `{:error, :no_parked_run}`.
3. Store capacity preflight (a continue starts new phases, which record).
4. `Store.Writer.continue_run(run_key)` — `:parked → :in_flight`, clearing
   `stopped_by`/`stopped_reason`. **Same `run_id`** (FR-020).
5. Reset **only** the stopping feature to `:pending`, so it re-runs from its
   checkpoint (FR-019a: "continuing re-runs the feature that broke the chain").
   Every other feature keeps its reconciled status.
6. `Recovery.reconcile_run/2` against durable evidence — unchanged.
7. Re-seed `StackTracker` from the branch of the highest-ordered `:done` backlog
   feature, falling back to `Config.pr_base()`.
8. Start the Coordinator with the same `run_key` and the restored context.

**Guarantees**

- The operator restates no run-shape setting (FR-019c) — `RunContext.merge/2`
  reapplies the recorded eight.
- On the stopping feature completing, the next-ordered never-started feature
  starts from the newly published branch (FR-020).
- The continued run stops again at the next broken link under the same rules
  (FR-020), parking a second time with the new failure recorded distinctly from
  the first (spec Edge Cases).
- If the stopping feature was the last one, continuing reaches the same
  closed-out result as ending (spec Edge Cases).

**Accepted options** — the same per-feature options `resume/2` takes, applied to
the stopping feature (the only one being re-run): `:prompt`, `:from`,
`:remediation_prompt`, `:remediation_model`, `:from_task_phase`, `:force`. Plus
every `run/1` option except the retired two.

---

## 5. `end_run/1`

```elixir
@spec end_run(keyword()) :: {:ok, map()} | {:error, :no_parked_run} | {:error, term()}
```

One transaction:

- `state: :parked → :completed`, `outcome: :ended_by_operator`.
- Every still-`:pending` feature is written `:never_started` (FR-019b, FR-016).
- `stopped_by`/`stopped_reason` are **retained**, so the closed record still says
  which feature stopped the chain and why (FR-017).

Releases nothing. Returns the final report. After it, `run/1` for the repository
is accepted again — there is no parked run to block it.

---

## 6. Observability

| Surface | Requirement |
|---|---|
| `MissionControlLive` | Parked banner: stopping feature, its status, its reason, and both actions (FR-019, SC-008) |
| Run history (`/runs`) | `:parked` rendered distinctly from `:in_flight` and `:completed` |
| Run detail (`/runs/:id`) | `stopped_by` and `stopped_reason` shown; never-started features listed as such (SC-004) |
| Final report | `stopped_by` map + `not_started` list (FR-017, FR-016) |

SC-004's bar: an operator can tell which feature stopped the run, why, and
exactly which features were never attempted — **from the report alone**, without
inspecting the target repository.
