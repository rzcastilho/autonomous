# Contract: `Autonomous.continue_run/1` — atomic (035)

Supersedes the step order in `specs/019-*/contracts/parked-run.md § 4` for the
position of the store flip only. Public signature, options, and success
result are unchanged (FR-008).

## Signature (unchanged)

```elixir
@spec continue_run(keyword()) ::
        GenServer.on_start()
        | {:error, :no_parked_run}
        | {:error, {:active_run, pid()}}
        | {:error, {:continue_restore_failed, reason :: term(), restore_error :: term()}}  # new, FR-009 only
        | {:error, term()}
```

## Step order (new)

| # | Step | Refusal (unchanged reason) | Store written? |
|---|---|---|---|
| 1 | `guard_active_run/1` | `{:active_run, pid}`, `{:awaiting_answers, id}` | no |
| 2 | `find_parked_run/1` → snapshot `{run_key, stopped_by, stopped_reason}` | `:no_parked_run` | no |
| 3 | `preflight_store_capacity/0` | `{:preflight, [{:store_capacity, _}]}` | no |
| 4 | `resume/2` checks on the **parked** run (`reject_retired_opts`, `guard_active_run`, `Store.run(run_key)`, `guard_containment_profile`, `find_feature_record`, `resolve_identity`, `resolve_resume_route`) | as today | no |
| 5 | `restore_run_scope/2` (capacity, **`Recovery.plan_run/2`** — read-only on the continue path, corrections deferred to step 9) | as today | no (Ledger restore is in-memory, spec Assumptions) |
| 6 | `run/1` preflights (retired, remediation, interactive clarify, containment, parked — **the continuing run is not counted**, layout) | as today | no |
| 7 | `run_stacked/4`: `preflight_stacked/2` (pack, constitution, remote) | as today — incl. `{:preflight, [{:pack_outdated, _, _}]}` | no |
| 8 | **`Writer.continue_run/1`** — `:parked -> :in_flight`, clears `stopped_by`, `stopped_reason`, `continue_restore_failure` | `:not_parked` (race loser / ended meanwhile) | yes (the flip) |
| 9 | `Recovery.apply_corrections/3` (the reconciliation writes deferred from step 5) | `{:error, reason}` → step 12 | yes |
| 10 | `start_stack_tracker/2` (retires any existing tracker — safe only after winning step 8) | `{:error, reason}` → step 12 | no |
| 11 | `start_run/2` → `start_coordinator/1` | `{:error, reason}` → step 12 | — |
| 12 | on step-9/10/11 error: `Writer.repark_run(run_key, snapshot)` | returns that step's reason; on repark error → step 13 | yes (undo) |
| 13 | restore failed: `Logger.error`, best-effort `annotate_continue_restore_failure/2` | `{:continue_restore_failed, reason, restore_error}` — returned and logged even if the annotation write fails | annotation, best effort |

Invariants:

- **I1 (FR-001/003)**: a refusal at steps 1–8 performs zero store writes
  (incl. no reconciliation correction, no escalation); a refusal at steps
  9–11 with a successful step 12 leaves the run record equal to its
  pre-attempt value field-for-field. Step-9 corrections that committed before
  a step-10/11 failure are evidence-backed reconciliations (a feature git
  proves `:done`), not attempt-attributable records; the test matrix
  exercises steps 10/11 with no correction pending so the snapshot is exact.
- **I2 (FR-004)**: no Coordinator, registered worker, worktree, or session
  exists after any refusal. Worktrees/sessions are created only by the
  executor the Coordinator releases (after step 11 succeeds). A stack tracker
  started at step 10 before a step-11 failure is stopped before returning.
- **I3 (FR-005)**: the `{:error, reason}` for a given cause equals today's.
  The flash in `MissionControlLive` (`"Continue failed: #{inspect(reason)}"`)
  and `EscalationsLive.dispatch_resume/2` are therefore unchanged.
- **I4 (FR-010)**: only an attempt whose own step 8 succeeded may run steps
  9–13; a step-8 loser returns before any process-level side effect — no
  `stop_named(@stack_tracker)`, no `stop_previous_run/0` — so it cannot
  disturb the winner's tracker or Coordinator. `:force` (step 1) is an
  explicit operator override outside this invariant (research R3).
- **I5 (FR-008)**: on success the result is `{:ok, coordinator_pid}` and the
  run ends `:in_flight` with `stopped_by`/`stopped_reason` `nil`, exactly as
  today.

## Internal option `:continue_parked`

`%{run_key, stopped_by, stopped_reason}` — set only by `continue_run/1`;
read by `resume/2` (step 4 run lookup), `restore_run_scope/2` (step 5
read-only reconcile), `run/1` (step 6 parked check), `run_stacked/4` (steps
8–13). Not a public option, and never added to the `extra` keyword
`start_run/2` hands the Coordinator. `resume/2`, `resume_run/1`, `run/1`,
`run_spec/2` called without it behave exactly as today (incl.
reconcile-time correction writes).

## Test seams (internal, with `:runner`/`:executor`)

- `:coordinator_start` — replaces `start_coordinator/1` at step 11.
- `:repark` — replaces `Writer.repark_run/2` at step 12.
- `:annotate` — replaces `Writer.annotate_continue_restore_failure/2` at step 13.

## Recovery addition (`Autonomous.Recovery`)

```elixir
@spec apply_corrections(run_key(), [map()], keyword()) :: :ok | {:error, term()}
```

Today's private `write_corrections/3`, promoted and made to report a writer
error instead of ignoring it; `reconcile_run/2` keeps calling it (its own
return shape unchanged).

## Store writer additions (`Autonomous.Store.Writer`)

```elixir
@spec repark_run(run_key(), %{stopped_by: binary(), stopped_reason: term()}) ::
        :ok | {:error, :not_in_flight} | {:error, term()}
@spec annotate_continue_restore_failure(run_key(), %{refusal: String.t(), restore_error: String.t(), at: DateTime.t()}) ::
        :ok | {:error, term()}
@spec clear_continue_restore_failure(run_key()) :: :ok | {:error, term()}
```

Each is one `run_transaction/1`. `continue_run/1` and `end_run/2` also set
`continue_restore_failure: nil` inside their existing transactions.
