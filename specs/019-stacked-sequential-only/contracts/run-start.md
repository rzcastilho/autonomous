# Contract: Run start after the collapse

**Feature**: `019-stacked-sequential-only`

Covers `SpeckitOrchestrator.run/1` and `run_spec/2` — the only two ways new work
begins. Both are now *one shape*: stacked, sequential, ordered by number.

---

## 1. `run/1`

```elixir
@spec run(keyword()) :: GenServer.on_start() | {:error, term()}
```

### Accepted options

| Option | Meaning | Change |
|---|---|---|
| `:features` | explicit feature list (tests, ad-hoc) | unchanged |
| `:owner` | pid receiving `{:run_complete, report}` | unchanged |
| `:runner` | override the feature runner (test seam) | unchanged |
| `:executor` | `(feature, base, notify)` seam | unchanged — now the only real path |
| `:publisher` | `(feature, base) -> {:ok, url} \| {:error, term}` | unchanged |
| `:run_key` | continue an existing store run | unchanged |
| `:layout`, `:scope`, `:slug`, `:package` | run-directory resolution | unchanged |
| `:budget_usd`, `:plan_stack`, `:pr_base`, `:pr_remote` | recorded run shape | unchanged |
| `:auto_remediation*` (4 keys) | remediation loop | unchanged |
| `:statuses` | seed statuses (resume paths) | unchanged |

### Refused options (FR-004, SC-005)

| Option | Result |
|---|---|
| `:pr_workflow` | `{:error, {:preflight, [{:retired_option, :pr_workflow}]}}` |
| `:max_concurrency` | `{:error, {:preflight, [{:retired_option, :max_concurrency}]}}` |
| any other unknown key | `{:error, {:preflight, [{:unknown_option, key}]}}` |

Refusal happens **before every side effect**: before the remediation preflight,
before the layout is ensured, before the store run opens. A refused start
supersedes nothing and creates nothing.

### Preflight order

Each step refuses with `{:error, {:preflight, problems}}` and starts no work.

1. **Option validation** — retired/unknown keys (above).
2. **Remediation settings** — unchanged (017 FR-011).
3. **Parked-run guard** — a `:parked` run for this repository refuses with
   `{:error, {:parked_run, run_id, [:continue, :end]}}` (FR-020a). Applies to
   `run/1` and `run_spec/2` alike (FR-020b).
4. **Layout** — repository identity + run directory; unchanged.
5. **Store writability and capacity** — unchanged.
6. **Target pack + PR remote** — `TargetPack.verify(repo, check_remote: pr_remote)`.
   Now **unconditional** (FR-003) rather than gated on `pr_workflow?`. Skipped
   only when a `:runner`/`:executor` seam is injected (test mode), unchanged.
7. **Backlog load** — raises `Backlog.DuplicateNumberError` on numerically equal
   numbers (FR-012); gaps are legal (FR-011).

### Behaviour on success

- Exactly one `Coordinator` starts, holding the ordered feature list, with **no
  cap**.
- `StackTracker` is seeded with `Config.pr_base()`.
- The first release is the lowest-ordered `:pending` feature; nothing else is
  released while it runs (FR-006).
- `RunContext.capture/1` records eight settings — no run mode, no concurrency
  (FR-021).

### Empty backlog

`{:ok, pid}` with an immediately-drained run and an empty report — not an error
(spec Edge Cases).

---

## 2. `run_spec/2` (ad-hoc single-spec)

```elixir
@spec run_spec(String.t() | nil, keyword()) ::
        GenServer.on_start() | {:error, :empty_description} | {:error, term()}
```

Unchanged except:

- The built feature carries `group: :ad_hoc` and `created_at: DateTime.utc_now()`
  (FR-024, FR-025).
- It branches from, and opens its PR against, `Config.pr_base()` — never the
  chain top, and it never advances the chain (FR-028).
- The PR preflight is unconditional (as in `run/1` step 6), no longer gated on
  the retired toggle.
- The parked-run guard applies (FR-020b).
- Retired options are refused identically.

An ad-hoc feature started while a run is in flight does not run alongside it —
the one-at-a-time rule holds across both groups because `run/1` refuses to start
a second run while one is live (`{:error, {:active_run, pid}}`, unchanged).

---

## 3. Environment and stored configuration

| Surface | Retired key | Behaviour |
|---|---|---|
| `config/runtime.exs` | `SPECKIT_PR_WORKFLOW` | set at all ⇒ `raise` at config load, naming the retired setting |
| `config/runtime.exs` | `SPECKIT_MAX_CONCURRENCY` | set at all ⇒ `raise` at config load |
| `Application.get_env` | `:pr_workflow` | present at boot ⇒ startup aborts, naming the retired setting |
| `Application.get_env` | `:max_concurrency` | present at boot ⇒ startup aborts |

Startup abort means the supervision tree does not start — no run can be started
against a configuration that names a setting the system will not honour.

---

## 4. Report

```elixir
%{
  done:          [feature_id],
  escalated:     [feature_id],
  halted:        [feature_id],
  failed:        [feature_id],
  not_started:   [feature_id],          # never attempted (FR-016)
  stopped_by:    %{feature_id: id, status: status, reason: term} | nil,  # FR-017
  spend:         float,
  breaker_tripped: boolean
}
```

`blocked` is **gone** from the report (no prerequisites ⇒ no blocked features).

`stopped_by` is `nil` for a run that completed every feature or that drained on a
tripped breaker with nothing terminal-non-done.
