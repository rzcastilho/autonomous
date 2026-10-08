# Quickstart: validating atomic continue (035)

Prereqs: `mise exec -- mix deps.get && mise exec -- mix compile` clean
(`warnings_as_errors`).

## 1. Automated (default suite, hermetic)

```bash
mise exec -- mix test test/autonomous/parked_run_test.exs
mise exec -- mix test test/autonomous/continue_run_atomic_test.exs   # new
mise exec -- mix test test/autonomous/store test/autonomous/recovery_test.exs  # writer, migration v7, apply_corrections
mise exec -- mix test test/autonomous/web                             # Run Detail block, MC panel
mise exec -- mix test                                                 # SC-005: whole suite green
```

What the new tests must show (one per row of `contracts/continue-run.md`
step table):

| Scenario | Setup | Expect |
|---|---|---|
| Incident (US1-AS1) | temp git target, committed pack below contract 3, run recorded `permissive`, parked; no `:runner` seam | `{:error, {:preflight, [{:pack_outdated, ".claude/hooks/scope_guard.py", _} \| _]}}`; `Store.parked_run/1` returns same `stopped_by`/`stopped_reason`; no Coordinator; `Workers.in_flight/1 == []`; no worktree created |
| Retry after fix (US1-AS3) | same, then commit contract-3 pack, seam runner | `{:ok, pid}`; run `:in_flight`; stopping feature released first |
| Each FR-002 cause | capacity refusing; `:containment_profile` mismatch; corrupt/missing checkpoint; bad `:from`; unknown `:remediation_model`; publish-only + `:prompt`; retired opt; invalid remediation setting; `:coordinator_start` seam → `{:error, :boom}` | reason equals the literal term in tasks.md T014; record field-for-field equal to pre-attempt snapshot (incl. feature rows, checkpoints, no new phase_attempt/cost/escalation rows — even when a reconcile `:done` correction would fire) |
| Restore failure (SC-006) | `:coordinator_start` → error, `:repark` → `{:error, :disk}` | `{:error, {:continue_restore_failed, :boom, :disk}}`; error logged; run `continue_restore_failure` set; Run Detail shows `data-marker="continue-restore-failure"`; cleared by `resume/2` success / `end_run/1`; with `:annotate` also failing, result and log still carry both reasons |
| Race (FR-010) | two concurrent `continue_run/1` with seam runner | exactly one `{:ok, pid}`; other `{:error, :not_parked}`; winner's Coordinator **and stack tracker** alive |
| Success unchanged (FR-008) | existing `parked_run_test.exs` | passes unmodified |
| Escalations (US3) | parked run, refusal cause, submit resume form for `stopped_by` | flash names cause; run still `:parked` |

## 2. Manual (container, against a real target)

Reproduces r000003. Use a scratch target, not a real backlog.

1. In the target, commit a pack one contract behind (e.g. check out an older
   `.claude/hooks/scope_guard.py`).
2. Start a `permissive` run with a backlog whose first feature is forced to
   fail (or park it via a seeded failing feature) — run parks, Mission
   Control shows `continue_run/1` / `end_run/1`.
3. Click **continue_run/1**. Expect flash
   `Continue failed: {:preflight, [{:pack_outdated, ".claude/hooks/scope_guard.py", …}]}`.
4. Reload Mission Control: parked panel still offered; Run Detail still
   shows `stopped at <id> (<reason>)`; nothing running.
5. Reinstall the pack (`TargetPack.install/2`), commit, click
   **continue_run/1** again → run continues from the stopping feature.

## Walkthrough record (2026-10-08)

Manual container walkthrough (§2) **not yet performed**. Steps 1–5 are covered
hermetically by: `continue_run_atomic_test.exs` (incident + retry-after-fix, T012/T013),
`mission_control_live_test.exs` ("a refused continue flashes the pack-outdated
cause verbatim" — flash text, parked panel retained, nothing running). Run the
manual scenario against a scratch target before release to close T032.
