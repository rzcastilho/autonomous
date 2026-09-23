# Data Model: Drain the Superseded Runner

**Branch**: `026-drain-superseded-runner` | **Date**: 2026-09-23

No persisted schema changes. The store's `speckit_run` / `speckit_feature_run`
records, their states, and `:ended_by_supersession` are unchanged (FR-010). All
new state is **in-memory and process-scoped**: it dies with the process it
describes, so it can never go stale.

---

## Worker entry

One per live worker process, held in `SpeckitOrchestrator.WorkerRegistry`
(`Registry`, `keys: :duplicate`). Registered by the worker itself, as the first
act of its spawn helper; removed by `Registry` when the process exits for any
reason.

| Field | Type | Source | Notes |
|-------|------|--------|-------|
| *key* `repo_id` | `binary()` | `elem(run_key, 0)` | Repository partition — the drain and guard scope (FR-007) |
| `pid` | `pid()` | `Registry` | Implicit — the registering process |
| `feature_id` | `String.t()` | spawn site | What the operator is told is still working (FR-004, FR-013) |
| `run_id` | `binary()` | `elem(run_key, 1)` | Which run the worker belongs to |
| `deadline_at` | `DateTime.t() \| nil` | worker, per session | Wall-clock end of the session currently held; `nil` between sessions / before the first |

**Validation.** A spawn with `run_key == nil` registers nothing (test seam,
dry runs). `deadline_at` is only ever written by the owning process
(`Registry.update_value/3` is owner-only), immediately before each
`AgentServer.call` that drives a session: phase (`FeatureRunner`), chunk
(`ChunkRunner`, per-chunk `deadline_ms`), remediation (`AnalyzeRunner` and the
013 pre-phase step).

---

## Drain request

A latch in a public ETS table owned by `SpeckitOrchestrator.Workers`.

| Field | Type | Notes |
|-------|------|-------|
| *key* `pid` | `pid()` | The worker being drained |
| `requested_at` | `DateTime.t()` | For the drain log line / telemetry |

**Lifecycle.** Inserted by the drainer before it starts waiting; read (never
consumed) by the worker at each boundary via `drain_requested?/0`; deleted by
the drainer once the worker's `:DOWN` arrives *or* the bound expires. A
request for a pid that already exited is a no-op (spec edge case "finished but
not yet reaped").

---

## Drain bound (pure)

`Workers.Bound.wait_ms(deadline_at, now, opts) :: non_neg_integer()` — pure.

```
remaining = max(0, diff_ms(deadline_at, now))        # deadline_at nil ⇒ Config.phase_timeout()
wait_ms   = remaining + call_grace_ms + finalize_margin_ms
```

`call_grace_ms` is `PhaseSession`'s existing grace (the same one
`call_timeout/1` adds); `finalize_margin_ms` covers the drained exit's
worktree commit and agent stop. Several workers ⇒ overall bound = max.

---

## Signal extensions (pure decision tables)

| Table | New optional signal | New row | Position |
|-------|--------------------|---------|----------|
| `Chunking.next/2` | `drain?: boolean()` (absent ⇒ `false`) | `{:halted, :superseded, state}` | Immediately after row 7 (breaker), same `outcome == :ok` boundary condition |
| `Remediation.next/2` | `drain?: boolean()` (absent ⇒ `false`) | `{:halted, :superseded, state}` | Immediately after row 4 (breaker) |
| `FeatureRunner.loop/12` `{:cont, _}` `cond` | — (reads `Workers.drain_requested?/0`) | `{:halted, :superseded, agent}` | After `breaker_tripped?/1`, before `store_unwritable?/1` |

`Pipeline.next/3` is **not** touched: `:superseded` reaches `FeatureRunner` as
`terminal_reason: {:halted, :superseded}` through the existing
`terminal_override/1`, exactly as `{:halted, :breaker}` does.

---

## Worker exit paths

```
                ┌───────── session ends (own deadline or completion) ─────────┐
                │                                                              ▼
  running ──► boundary: attempt + checkpoint + transcript recorded ──► check predicates
                                                                              │
             breaker tripped ──► {:halted, :breaker}    ── normal terminal exit (today)
             drain requested ──► {:halted, :superseded} ── DRAINED exit (new)
             neither         ──► next session
```

**Drained exit** (see [research R5](./research.md#r5-what-the-drained-worker-writes-and-does-not)):
finalize agent → commit + keep worktree → emit `[:speckit, :feature, :drained]`
→ stop agent → process exits → registry entry removed → drainer's `:DOWN`.
Skips `record_feature_terminal`, `record_diversion_escalation`,
`[:speckit, :feature, :terminal]`, and `notify`.

---

## Errors (new)

| Term | Returned by | Meaning |
|------|-------------|---------|
| `{:error, {:drain_timeout, [%{feature_id: id, run_id: rid}]}}` | `run/1`, `run_spec/2`, and `resume/2` / `resume_run/1` / `continue_run/1` with `:force` | A worker did not exit within its bound; nothing was started, the prior run record was not superseded |

`{:error, {:active_run, pid}}` is unchanged in shape; `pid` may now be a
worker's pid rather than the Coordinator's (FR-005).
