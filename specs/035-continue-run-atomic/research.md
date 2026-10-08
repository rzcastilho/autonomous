# Research: Atomic Continue of a Parked Run (035)

All Technical Context items were resolvable from the codebase; no
`NEEDS CLARIFICATION` remained after reading the continue path. Each decision
below names the code it rests on.

## Today's continue path (as read, 2026-10-08)

```text
continue_run/1                                   lib/autonomous.ex:693
  guard_active_run(opts)                         refusal: {:active_run, pid} | {:awaiting_answers, id}
  find_parked_run(opts)                          refusal: :no_parked_run
  preflight_store_capacity()                     refusal: {:preflight, [{:store_capacity, _}]}
  Writer.continue_run(run_key)   <-- FLIP        :parked -> :in_flight, stopped_by/stopped_reason := nil
  resume(stopped_by, opts)                       lib/autonomous.ex:837
    reject_retired_opts / guard_active_run
    read_current_run()                           finds the run only because it was flipped
    guard_containment_profile                    {:preflight, [{:containment_profile_locked, _}]}
    find_feature_record / resolve_identity
    resolve_resume_route                         {:unknown_phase,_} | :no_checkpoint | :corrupt_checkpoint
                                                 | {:unknown_model,_} | {:publish_only, id}
    dispatch_resume_route
      restore_run_scope                          capacity again; Recovery.reconcile_run errors;
                                                 restore_ledger (in-memory only)
      run(opts ++ [run_key: run_key])
        reject_retired_opts, preflight_remediation, preflight_interactive_clarify,
        preflight_containment, preflight_parked_run (passes only because flipped),
        preflight_layout, open_or_continue_run (no-op with :run_key)
        run_stacked
          preflight_stacked                      {:preflight, [{:pack_outdated, ...}]}  <-- INCIDENT
          start_stack_tracker
          start_run -> start_coordinator         {:error, reason} from DynamicSupervisor
```

Every refusal after the FLIP returns `{:error, _}` with the run left
`:in_flight`, `stopped_by: nil`, nothing running — the r000003 state.

## R1 — Mechanism: move the flip to the last durable step, compensate only the tail

**Decision**: Hybrid "check everything first, flip last, undo only a failed
start". `continue_run/1` no longer flips before `resume/2`. Instead it hands
`resume/2` → `run/1` → `run_stacked/4` an internal `:continue_parked`
marker carrying the parked `run_key` and its snapshot
(`stopped_by`, `stopped_reason`). Every existing check then runs against the
still-`:parked` record. The flip (`Writer.continue_run/1`) happens inside
`run_stacked/4` **after** `preflight_stacked/2` and **before** the stack
tracker start, so that no process-level side effect happens before the
attempt has won the flip (see R3: `start_stack_tracker/2` retires any
existing tracker via `stop_named(@stack_tracker)`). After the flip come, in
order: the deferred reconciliation corrections (R8), `start_stack_tracker/2`,
and `start_run/2`. If any of those three fails, a new transactional
`Writer.repark_run/2` restores `:parked` with the snapshot's
`stopped_by`/`stopped_reason`, and the original `{:error, reason}` is
returned. The current `{:ok, tracker} = start_stack_tracker(...)` match
becomes a `with` branch so a tracker start failure is a refusal, not a crash.

**Rationale**:
- Every refusal in FR-002 except "control process failed to start" now
  happens *before* any store write (reconciliation corrections included —
  R8), so FR-001/FR-003 hold by construction for them — there is nothing to
  undo, and nothing to fail while undoing.
- The flip must still precede the Coordinator start: `Coordinator`'s
  `handle_continue(:release, _)` and every edge module record against
  `Store.current_run_key/1`, which only finds an `:in_flight` run
  (`lib/autonomous/store.ex:157`). `Coordinator.init/1` itself writes nothing
  (`lib/autonomous/coordinator.ex:120`), so a failed `start_coordinator/1`
  has written nothing either — the compensation restores exactly the one
  write that happened.
- The undo window shrinks from "all of resume + run preflights" (where the
  incident lived, incl. git and filesystem I/O) to one `DynamicSupervisor`
  start.

**Alternatives considered**:
- *Record-then-undo around the whole of `resume/2`* (smallest diff: wrap the
  current `resume(stopped_by, opts)` and repark on any `{:error, _}`).
  Rejected: every ordinary refusal — the common case, incl. the incident —
  would depend on a second write succeeding, making FR-009's restore-failure
  path reachable from a pack-outdated refusal; and it leaves a wide window in
  which a crash or a racing `end_run/1` sees an `:in_flight` run with nothing
  running.
- *Pure preflight-before-flip with no compensation*. Rejected: a Coordinator
  start failure can only be observed after the flip (see above), so some
  compensation is unavoidable.
- *One Mnesia transaction spanning the flip and the Coordinator start*.
  Rejected: a process spawn is not transactional; doing it inside
  `:mnesia.transaction/1` would also violate "no blocking/side effects in a
  transaction fun" (retried funs re-run side effects).

## R2 — How `resume/2` and `run/1` read a still-parked run

**Decision**: When `:continue_parked` is present, `resume/2` reads the run
with `Store.run(run_key)` for the parked key instead of
`read_current_run/0`, and `run/1`'s `preflight_parked_run/0` treats the
parked run whose key equals the marker's key as **not** blocking (any other
parked run still refuses — there is at most one per repository, so in
practice this never fires). Everything else (`guard_containment_profile`,
`resolve_resume_route`, `restore_run_scope`, all of `run/1`'s preflights,
`preflight_stacked`) is called unchanged, in the same order, so FR-005's
"same reason" holds by reusing the same functions.

**Rationale**: Minimal surface: two read sites learn about the marker; no
refusal is re-implemented. `read_current_run/0`'s `:no_manifest` cannot occur
on the continue path either today (flip made it findable) or after (explicit
key), so no new reason appears.

**Alternatives considered**: A separate `continue_preflight/1` duplicating
the checks — rejected, duplicated checks drift and FR-005 would then rest on
two copies agreeing.

The marker is an internal option: not documented as a public `run/1`/
`resume/2` option, ignored by `resume_run/1`/`run_spec/2`, and stripped
before options reach the Coordinator.

## R3 — Concurrent continues and `end_run/1` races (FR-010, edge cases)

**Decision**: Rely on `Writer.continue_run/1`'s existing transactional
`:parked` guard as the single arbiter. Two concurrent continues both pass the
read-only checks; exactly one flip succeeds; the loser's flip aborts
`:not_parked` and it returns `{:error, :not_parked}` *before* any
process-level side effect — before `start_stack_tracker/2` (which would
`stop_named(@stack_tracker)` the winner's tracker and crash the winner's
Coordinator on its next `set_top/2`) and before `start_run/2` (which would
`stop_previous_run/0` the winner's Coordinator). That is why the flip
precedes the tracker start (R1). Every step before the flip is a read, a
pure computation, or an in-memory idempotent `Ledger.restore/2`.
`repark_run/2` only transitions `:in_flight -> :parked` and is called only
by the attempt whose own flip succeeded, so a loser can never re-park a
running run.

**`:force` is outside FR-010.** `guard_active_run/1` with `force: true`
deliberately stops the live Coordinator and drains workers at step 1 — an
explicit operator override that predates this feature. A racing
`continue_run(force: true)` can therefore stop a winner that already
started; that is the documented meaning of `:force`, not an atomicity
defect, and it is unchanged.

`end_run/1` racing a refused continue: before the flip the run is `:parked`
and `end_run/1` may win (`:parked -> :completed`); the continue's later flip
then aborts `:not_parked` — consistent ("ended by the operator"). During the
start-only window `end_run/1` sees `:in_flight` and returns
`:no_parked_run`; after a repark it succeeds — consistent ("still parked").
Never `:in_flight` with nothing running except during a failed repark, which
is FR-009.

**Note on reason ordering**: today a race loser always got the flip's
`:not_parked` first; now it may first hit an ordinary preflight refusal that
applies to both. Same reason the same cause produces alone (FR-005 is about
a given cause), recorded here so it is not mistaken for a regression.

## R4 — Restore-failure handling (FR-009)

**Decision**: If `repark_run/2` returns `{:error, restore_error}`:
1. `Logger.error/1` naming run id, original refusal, restore error.
2. Best-effort `Writer.annotate_continue_restore_failure/2` writing
   `%{refusal: inspected, restore_error: inspected, at: DateTime}` onto the
   run record's new `continue_restore_failure` field (one transaction, no
   state change).
3. Return `{:error, {:continue_restore_failed, original_reason, restore_error}}`.

Cleared (set to `nil`) by `Writer.continue_run/1` (the flip of a later
successful continue), `Writer.end_run/2`, and a new
`Writer.clear_continue_restore_failure/1` called by `run_stacked/4` after a
successful `start_run/2` for any run started with a `:run_key` (covers
`resume/2` and `resume_run/1`, the documented recovery for an
`:in_flight` orphan). Clearing is a no-op write-skip when the field is
already `nil`, so successful continues stay observably unchanged (FR-008).

**Rationale**: Clarification 2026-10-08 fixed the observable contract;
values are stored as rendered strings so the annotation never holds a
term the record decoder cannot round-trip (pids, refs).

**Alternatives considered**: a new run state (`:continue_failed`) —
excluded by the clarification; a separate annotation table — rejected,
heavier than appending one nullable field and the annotation is 1:1 with the
run.

## R5 — Schema evolution

**Decision**: Schema v7 appends `speckit_run.continue_restore_failure`
(default `nil`) via `:mnesia.transform_table/3`, structurally identical to
v3/v4 (plain append). `Migrations.current_version/0` → 7; a
`@run_v7_attributes` constant pins the target shape (the module already
pins historical shapes, migrations.ex:43). Export includes the field.

**Rationale**: Constitution Persistence: explicit, versioned, transform not
refusal (a v6 record is readable as-is; the fact did not exist).

## R6 — Crash mid-continue

**Decision**: Accept the irreducible gap between the flip transaction and
the Coordinator spawn. A crash inside it leaves an `:in_flight` run whose
`stopped_by` was cleared — indistinguishable from a run that started and then
lost its node, which is exactly what the existing restart path
(`resume_run/1`, `resume/2`) already recovers. Before the flip (every
preflight) a crash leaves the run `:parked`, untouched.

**Rationale**: Matches the spec's edge-case wording ("either still `:parked`
or a genuinely started `:in_flight` run that the existing restart/recovery
path already handles"); the window is now microseconds, not the multi-second
preflight span of the incident.

## R7 — Test seams

**Decision**: Three internal seams, honoured only alongside the existing
`:runner`/`:executor` test seams:
- `:coordinator_start` — `(args -> {:ok, pid} | {:error, term})`, replaces
  `start_coordinator/1`, to force FR-002's "control process failed to start".
- `:repark` — `(run_key, snapshot -> :ok | {:error, term})`, replaces
  `Writer.repark_run/2`, to force FR-009 / SC-006.
- `:annotate` — `(run_key, annotation -> :ok | {:error, term})`, replaces
  `Writer.annotate_continue_restore_failure/2`, to prove FR-009's last
  bullet: when the annotation cannot be written, the returned result and the
  error log line still carry both reasons.

The incident case (outdated pack under `permissive`) is exercised **without**
seams against a temp git target whose committed pack lags contract 3, since a
refusal there never reaches the real executor (`preflight_stacked/2` runs
before anything spawns). `run/1`'s own `preflight_containment/2` only checks
the pack when `:containment_profile` is passed explicitly; the test must not
pass it, so the refusal comes from `preflight_stacked/2` exactly as in
r000003.

**Rationale**: Constitution Quality: breaker/sequencing logic tested through
injected seams, default suite hermetic.

## R8 — Reconciliation writes are deferred past the flip

**Finding**: `restore_run_scope/2` calls `Recovery.reconcile_run/1`, which is
`plan_run/2` **plus** `write_corrections/3` (`lib/autonomous/recovery.ex:109`).
Those corrections write the store: `record_feature_terminal(..., :done,
:reconciled_done_signal, [])` for a feature evidence proves done but the
store does not, and `reconcile_awaiting_answers/2` (closes a dead
`:awaiting_answers` round as an escalation). On today's path they run before
`preflight_stacked/2`, so a pack-outdated refusal would still leave changed
feature rows or a new escalation — an FR-003 violation even with the flip
moved.

**Decision**: On the continue path only, `restore_run_scope/2` computes the
reconciliation with the read-only `Recovery.plan_run/2` (already public, same
`statuses`/`resume_phases`/`report` as `reconcile_run/2` returns), and the
corrections are applied *after* the flip by a new public
`Recovery.apply_corrections(run_key, report_features, opts)` (today's private
`write_corrections/3`, promoted; `reconcile_run/2` calls it unchanged for every
other caller). A failure to apply corrections after the flip is handled like a
tracker/Coordinator start failure: re-park and return the error.

**Rationale**: Release decisions use the in-memory reconciled statuses either
way, so deferring the persistence changes no dispatch outcome; it only makes
the persistence conditional on the attempt actually proceeding. `resume/2`,
`resume_run/1`, and `resumable/1` called without `:continue_parked` keep
today's write-during-reconcile behaviour byte-for-byte.

**Alternatives considered**: pass a no-op `:writer` to `reconcile_run/2` and
re-run it after the flip — rejected, reconciles twice (git evidence collected
twice) and the second pass could disagree with the statuses already used.
