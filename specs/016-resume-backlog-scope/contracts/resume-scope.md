# Contract: `SpeckitOrchestrator.resume/2` — whole-run continuation

**Feature**: `016-resume-backlog-scope`

Supersedes the dispatch section of `specs/005-resume-facade/contracts/resume.md`
and `specs/007-resume-self-sufficient/contracts/resume.md`. Everything those
contracts say about identity recovery, phase resolution, run-context precedence,
remediation, and task-phase overrides **still holds unchanged** — this contract
changes only *which features the resumed run contains*.

## Signature

```elixir
@spec resume(String.t(), keyword()) ::
        GenServer.on_start()
        | {:error, {:unknown_feature, String.t()}}
        | {:error, :no_checkpoint}
        | {:error, :corrupt_checkpoint}
        | {:error, {:unknown_phase, term()}}
        | {:error, {:unknown_model, String.t()}}
        | {:error, {:active_run, pid()}}     # NEW (FR-010a)
```

New option:

| Option | Type | Default | Meaning |
|--------|------|---------|---------|
| `:force` | `boolean()` | `false` | proceed despite a live unfinished run, matching `resume_run/1`'s option of the same name |

All existing options (`:from`, `:prompt`, `:remediation_prompt`,
`:remediation_model`, `:from_task_phase`, plus every `run/1` option) are
unchanged.

## Order of operations

1. **Live-run guard** — `{:error, {:active_run, pid}}` unless `force: true`.
   Starts no work, reads nothing else.
2. **Layout** — `:layout` opt, else rebuilt from the manifest's recorded
   `segment`/`scope`, else `nil` (unchanged).
3. **Checkpoint** — read for `feature_id`; `:no_checkpoint` / `:corrupt_checkpoint`
   abort before any run starts (unchanged).
4. **Identity** — explicit/backlog feature > checkpoint identity (unchanged).
5. **Start phase** — `:from` > checkpoint `last_phase` (with the `in_progress` →
   next-phase rule) (unchanged).
6. **Model validation** — `Config.remediation_model/2` (unchanged).
7. **Run context** — `RunContext.merge/2`; explicit opt > recorded > live Config
   (unchanged, FR-010).
8. **Scope restore** *(new)* — read the run manifest:
   - `{:ok, record}` → `Recovery.reconcile_run/2` for statuses + resume phases
     (FR-002a); `RunManifest.reconstruct/1` for the feature list;
     `Ledger.restore/2` from the recorded spend (SC-007).
   - `{:error, :no_manifest | :corrupt}` → single-feature set, exactly today
     (FR-009).
9. **Target merge** *(new)* — append the target feature if the record omits it
   (FR-008); force its seed status to `:pending`; drop it from `resume_phases`
   so step 5's phase governs (D2).
10. **Start** — `run(supersede: false, …)`.

## Dispatch matrix

For every feature in the restored set:

| Seeded status | `resume_phases` entry | Target? | Dispatched | Start phase |
|---------------|----------------------|---------|------------|-------------|
| `:pending` | present | no | when prereqs `:done` | the recorded resume phase |
| `:pending` | absent | no | when prereqs `:done` | checkpoint phase if a checkpoint exists, else `Pipeline.first()` |
| `:pending` | — | **yes** | immediately (prereqs are not re-checked for the target) | step 5's phase, with `:prompt` / remediation / `:from_task_phase` / `reset_implement_sessions: true` |
| `:done` | — | no | never (FR-005) | — |
| `:escalated` / `:halted` / `:failed` | — | no | never (FR-006) | — |
| `:blocked` (conflict) | — | no | never | — |

Only the target row carries operator guidance; no other feature receives
`:prompt`, `:remediation_prompt`, `:remediation_model`, or `:from_task_phase`.

## Guarantees

| ID | Guarantee |
|----|-----------|
| G1 | The Coordinator's feature set equals the recorded set ∪ `{target}` (FR-001, FR-008). |
| G2 | No non-target feature is dispatched at a phase earlier than its reconciled state implies (FR-002, FR-003). |
| G3 | Dependents of the target release automatically as prereqs reach `:done` — no further operator action (FR-004, SC-002). |
| G4 | The final report counts every restored feature (FR-007). |
| G5 | Target dispatch is byte-identical to pre-016 `resume/2` for the same inputs (SC-005). |
| G6 | With no readable manifest, the whole call is byte-identical to pre-016 (FR-009, SC-005). |
| G7 | Spend and breaker behaviour are those of the original run (SC-007). |
| G8 | Every failure mode starts no work and leaves the record untouched (Principle II). |

## Non-goals

- Resuming two features in one call. One target per resume; a second diverted
  feature keeps its state (FR-006) and needs its own resume.
- Changing `resume_run/1`'s public contract. It gains nothing and loses nothing;
  it shares the private continuation path.
- Re-running a `:done` feature. `resolve/1` remains the tool for a full restart.
