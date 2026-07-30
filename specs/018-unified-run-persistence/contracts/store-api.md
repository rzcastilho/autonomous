# Contract: Programmatic Operator Surface

**Feature**: `018-unified-run-persistence`

FR-030a makes this the contract the requirements are verified against: every
capability works with **no user interface running** (SC-007a). The console
renders these functions and holds no query logic of its own (FR-030c).

Two layers:

- **`SpeckitOrchestrator.*`** — the operator-facing facade (iex, scripts, the
  console). Stable names, tagged-tuple returns.
- **`SpeckitOrchestrator.Store.{Writer,Query}`** — the internal persistence API
  the orchestrator writes through. Not an operator surface.

---

## 1. Facade — operator functions

### `run_history(opts \\ []) :: {:ok, [run_summary]} | {:error, term}`

A repository's runs, **most recent first** (FR-021), successful and unsuccessful
alike. Never loads transcript content (FR-036, SC-009).

Options: `:repo` (default `Config.repo/0`), `:outcome` (atom or list — FR-024),
`:feature` (feature id — "every run in which feature X escalated", FR-024),
`:limit`, `:before` (run_id, for paging).

`run_summary`:

```elixir
%{run_id:, state:, outcome:, started_at:, ended_at:, duration_ms:,
  spend_usd:, record_complete?:, superseded_by:, scope:,
  feature_statuses: %{feature_id => status}}
```

An unknown repository returns `{:ok, []}` — an empty history, not an error
(US2 acceptance 4).

### `run_detail(run_id, opts \\ []) :: {:ok, run_detail} | {:error, :absent} | {:error, {:damaged, …}}`

Everything about one run except transcript bodies (FR-022):

```elixir
%{run: run_summary,
  settings: map, amendments: [amendment],
  features: [%{feature_id:, slug:, status:, terminal_reason:, branch:,
               phase_attempts: [attempt],   # execution order
               escalations: [escalation],
               remediation_attempts: [remediation_attempt],
               checkpoint: checkpoint | nil}]}
```

Each `attempt` carries `phase, ordinal, label, outcome, model, cost_usd,
cost_kind, duration_ms, started_at, substep` and a `transcript_ref` (its
`attempt_id`) — **not** the body.

### `transcript(attempt_ref) :: {:ok, %{body:, bytes:, written_at:}} | {:error, :absent} | {:error, {:damaged, …}}`

On-demand retrieval of one phase attempt's transcript (FR-029). Works after the
feature's worktree has been removed (SC-006). Body is returned **verbatim**
(FR-029a).

### `resumable(opts \\ []) :: {:ok, resumable} | :none | {:error, term}`

What is resumable for a repository, **starting no work** (FR-016, SC-003):

```elixir
%{run_id:, state:, record_complete?:, halt_reason:,
  report: Recovery.Report.t(),          # reconciled against repo evidence (FR-018)
  statuses: %{feature_id => status},
  resume_phases: %{feature_id => phase},
  gap_possible?: boolean}               # true when the run was halted by a persistence failure (FR-010a)
```

Replaces today's `resumable_run/0`, whose name and shape are kept as a
delegating alias so existing operator muscle memory and docs keep working.

### `prune_preview(opts) :: {:ok, prune_plan}` / `prune(opts) :: {:ok, prune_result} | {:error, term}`

`prune_preview/1` reports what a boundary would remove and how much it would
reclaim **without performing it** (FR-031e). `prune/1` performs it — the only
mechanism in the system that removes recorded state (FR-031a).

Options: `:repo`, `:before` (a `DateTime` or a `run_id` boundary), `:dry_run`
(equivalent to preview), `:confirm` (required by `prune/1`; absent ⇒
`{:error, :confirmation_required}`).

```elixir
prune_plan  :: %{removable: [%{run_id:, ended_at:, bytes:}],
                 retained:  [%{run_id:, reason: :resumable | :in_flight}],
                 bytes_reclaimable: integer}
prune_result:: %{removed: [run_id], bytes_reclaimed: integer}
```

A resumable or in-flight run is **never** removed, regardless of boundary
(FR-031); it is reported as retained with a reason, not silently skipped.

### `export_run(run_id, path, opts \\ []) :: {:ok, path} | {:error, term}`

Writes exactly **one** self-describing JSON file (FR-032, FR-032a) — see
`contracts/export-format.md`. Read-only: modifies, locks, and prunes nothing,
and is available mid-run and under a capacity refusal (FR-032c).

### `store_capacity() :: {:ok, capacity}`

```elixir
%{used_bytes:, transcript_bytes:, capacity_bytes:, headroom_bytes:,
  status: :ok | :refusing, shortfall_bytes: integer | nil,
  reclaimable_bytes: integer}
```

Backs FR-031b's refusal message and the console's capacity banner.

### `resolve_escalation(escalation_id, opts) :: :ok | {:error, term}`

Records a resolution against the original entry (FR-026). Never deletes it.

---

## 2. Changed behaviour of existing facade functions

| Function | Change |
|----------|--------|
| `run/1` | Adds a capacity preflight (FR-031b) and a store-writability preflight (FR-009), both refusing before any spend, in the same `{:error, {:preflight, problems}}` shape as today's refusals. Opens the run record in one transaction (FR-034 supersession). Drops `RunManifest.clear/0` and the whole `:supersede` option — supersession is now a store transaction, not a file delete. |
| `run_spec/2` | Unchanged surface; inherits the above through `run/1`. |
| `resume/2` | Reads the checkpoint and run record from the store instead of `checkpoint.json` + `run.json`. Continues the **same** `run_id` (FR-020), so cost stays attributable across the resume. Error vocabulary keeps `{:error, :no_checkpoint}` / `{:error, :corrupt_checkpoint}`, now sourced from the store's absent/damaged distinction. |
| `resume_run/1` | Same, at run scope. |
| `resumable_run/0` | Delegates to `resumable/1`. |
| `recover_record/1` | Rebuild proposal is computed against the store record; `:confirm` writes through `Store.Writer` in one transaction. |
| `status/0`, `print_status/0` | Unchanged — live `Coordinator` snapshot. |
| `resolve/1` | Unchanged, except the freed feature's state transition is recorded (FR-026 resolution when it was escalated). |

---

## 3. Internal API — `Store.Writer`

Every function runs one transaction (`contracts/schema.md` § Transaction
boundaries) and returns `:ok | {:error, reason}`. A failure is reported to
`Store.Health` (see `contracts/persistence-failure.md`) — never raised into the
run.

```elixir
open_run(repo_id, %{features:, settings:, scope:, layout:})   :: {:ok, run_id} | {:error, term}
record_phase_attempt(run_id, %{attempt:, cost:, checkpoint:, transcript:}) :: :ok | {:error, term}
record_remediation_attempt(run_id, attempt)                    :: :ok | {:error, term}
record_feature_started(run_id, feature_id)                     :: :ok | {:error, term}
record_feature_terminal(run_id, feature_id, status, reason)    :: :ok | {:error, term}
record_escalation(run_id, escalation)                          :: :ok | {:error, term}
resolve_escalation(escalation_id, resolution)                  :: :ok | {:error, term}
record_settings_amendment(run_id, changes, effective_after)    :: :ok | {:error, term}
close_run(run_id, outcome, opts)                               :: :ok | {:error, term}
flag_record_incomplete(run_id, halt_reason)                    :: :ok | {:error, term}
```

## 4. Internal API — `Store.Query`

```elixir
runs(repo_id, filters)          :: {:ok, [run_summary]}
run(run_key)                    :: {:ok, run_detail} | {:error, :absent | {:damaged, …}}
checkpoint(run_key, feature_id) :: {:ok, checkpoint} | {:error, :absent | {:damaged, …}}
transcript(attempt_id)          :: {:ok, transcript} | {:error, :absent | {:damaged, …}}
in_flight_run(repo_id)          :: {:ok, run_summary} | :none
capacity()                      :: capacity
```

## 5. Boundary rules

1. The pure core (`Feature`, `Config`, `Pipeline`, `Ledger`, `Release`,
   `Backlog`, `Severity`, `Remediation`, `Store.Records`, `Store.Prune`,
   `Store.Capacity`, `Store.Export`, `Store.Ids`) **never** references
   `:mnesia` — enforced by a test that greps those modules.
2. No LiveView references `:mnesia`, `Store.Query`, or `Store.Writer` — the
   console calls facade functions only (FR-030c) — enforced by a test that greps
   `lib/speckit_orchestrator/web/`.
3. `Store.Mnesia` is the only module that calls `:mnesia`.
4. Every capability above is exercised by a test that runs with no endpoint and
   no LiveView mounted (SC-007a).
