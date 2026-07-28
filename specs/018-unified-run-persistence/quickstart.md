# Quickstart: Validating Unified Run-State Persistence

**Feature**: `018-unified-run-persistence`

Runnable scenarios that prove the feature end-to-end. Details live in
[data-model.md](./data-model.md) and [contracts/](./contracts/) — this file is
the run guide.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

The default suite is hermetic: `test/test_helper.exs` creates one temporary
Mnesia store under the system temp dir and removes it on exit. It never touches
`~/.autonomous` (research R14).

## 1. Suite

```bash
mise exec -- mix test                       # full suite
mise exec -- mix test --cover               # pure core must stay >90%
mise exec -- mix test --include integration # real-harness, costs money
```

Targeted:

```bash
mise exec -- mix test test/speckit_orchestrator/store/records_test.exs      # pure, async
mise exec -- mix test test/speckit_orchestrator/store/prune_test.exs        # pure, async
mise exec -- mix test test/speckit_orchestrator/store/capacity_test.exs     # pure, async
mise exec -- mix test test/speckit_orchestrator/store/export_test.exs       # pure, async
mise exec -- mix test test/speckit_orchestrator/store/mnesia_test.exs       # schema, async: false
mise exec -- mix test test/speckit_orchestrator/store/boot_test.exs         # schema ownership + migrations
mise exec -- mix test test/speckit_orchestrator/persistence_failure_test.exs
```

## 2. Store boots and refuses a foreign schema (FR-009, R2, R13)

```bash
mise exec -- iex -S mix
```

```elixir
SpeckitOrchestrator.Store.Query.capacity()
# %{used_bytes: _, transcript_bytes: _, capacity_bytes: 1_500_000_000, status: :ok, ...}
```

Expected failures, each aborting startup with a named reason and no empty
schema created in its place:

- store dir unwritable → app does not boot, `{:error, {:store_unwritable, _}}`
- schema owned by another node → `{:error, {:schema_node_mismatch, expected, found}}`
- recorded schema version newer than known → `{:error, {:schema_version_ahead, found, known}}`

## 3. US1 — Resume from one authoritative record (P1)

```elixir
# start a run against the target repo
{:ok, _pid} = SpeckitOrchestrator.run()

# interrupt it: Ctrl-C twice, or kill the OS process mid-phase
```

Restart and ask what is resumable — **no work starts**:

```elixir
{:ok, r} = SpeckitOrchestrator.resumable()
r.run_id            # same id as before the crash (FR-020)
r.statuses          # terminal features kept, interrupted ones :pending
r.resume_phases     # each incomplete feature's checkpointed phase
r.gap_possible?     # false for a plain crash; true after a persistence-failure halt

SpeckitOrchestrator.resume_run()
```

Verify: completed features are not re-run (FR-017); the resumed run uses the
settings captured at first start (FR-014); the run id is unchanged, so spend
stays attributable across the resume.

Interrupted-write check (SC-002): the store-level test suite injects an
interruption at every phase boundary and asserts a reader observes either the
complete pre-update or the complete post-update state — never a mixture.

Two-repository isolation (US1 acceptance 5): run against repo A and repo B, then
`SpeckitOrchestrator.resumable(repo: path_a)` — only A's rows are read or
written.

## 4. US2 — Run history (P2)

```elixir
{:ok, runs} = SpeckitOrchestrator.run_history()
Enum.map(runs, &{&1.run_id, &1.state, &1.outcome, &1.spend_usd})
# most recent first; every prior run still present

SpeckitOrchestrator.run_history(outcome: [:halted, :escalated])
SpeckitOrchestrator.run_history(feature: "003")
```

Verify: starting a new run destroys nothing (SC-004); the prior in-flight run is
retained as `superseded` and is distinguishable from one that reached its own
terminal state (FR-023); an unknown repository returns `{:ok, []}`, not an
error.

Responsiveness (SC-009): the store test seeds 500 runs with large transcripts
and asserts listing time is both interactive and unaffected by transcript
volume.

## 5. US3 — Full detail of one run (P3)

```elixir
{:ok, d} = SpeckitOrchestrator.run_detail("r000004")

f = Enum.find(d.features, & &1.feature_id == "003")
f.phase_attempts       # execution order, with outcome/model/cost/duration
f.escalations          # reason, originating phase, triggering evidence
f.remediation_attempts # each attempt, with the limit and threshold in force

# transcripts survive worktree removal (SC-006)
attempt = List.first(f.phase_attempts)
{:ok, t} = SpeckitOrchestrator.transcript(attempt.transcript_ref)
byte_size(t.body)
```

## 6. Persistence failure drains, never kills (FR-010, SC-013)

```elixir
# with a run in flight, make the store unwritable (chmod the store dir)
SpeckitOrchestrator.Store.Health.status()
# {:failed, reason, at}
```

Verify: the in-flight phase finished (0 mid-flight aborts); no further phase and
no further feature started; the run is halted with a persistence-failure reason;
`run_history/1` shows it with `record_complete?: false`. Restore writability,
clear health, `resume_run/1` → same run id, resumes from the last recorded
position, `gap_possible?: true`, and any disagreement with repository evidence
appears as a `Recovery.Report` conflict rather than being resolved silently.

## 7. Capacity and pruning (FR-031*, SC-014, SC-015)

```elixir
SpeckitOrchestrator.store_capacity()
# %{status: :refusing, shortfall_bytes: _, reclaimable_bytes: _} when headroom is gone

SpeckitOrchestrator.run()
# {:error, {:preflight, [{:store_capacity, %{shortfall_bytes: _, reclaimable_bytes: _}}]}}

{:ok, plan} = SpeckitOrchestrator.prune_preview(before: ~U[2026-06-01 00:00:00Z])
plan.removable          # what would go
plan.retained           # in-flight / resumable runs, each with a reason
plan.bytes_reclaimable

{:ok, res} = SpeckitOrchestrator.prune(before: ~U[2026-06-01 00:00:00Z], confirm: true)
```

Verify: under a refusal, history, detail, transcript retrieval, export and prune
all still work, and the in-flight run is untouched; the preview performs
nothing; a resumable run is never removed regardless of boundary; and with
headroom exhausted and no prune, row counts are unchanged (0 automatic
removals, SC-014).

## 8. Export (FR-032*, SC-016)

```elixir
{:ok, path} = SpeckitOrchestrator.export_run("r000004", "/tmp/r000004.json")
```

Verify: exactly one file; `format` / `format_version` present; every feature,
attempt, escalation, remediation attempt, setting, cost entry and transcript is
recoverable from that file alone with zero external references; transcript bytes
round-trip byte-identically (including a non-UTF-8 fixture, which exports with
`"encoding": "base64"`); exporting mid-run and under a capacity refusal both
work and change nothing in the store.

## 9. Console (FR-030b/c)

```bash
mise exec -- mix phx.server
```

- `/runs` — history list, filters, capacity banner when refusing.
- `/runs/:run_id` — per-feature attempts, escalations, remediation attempts,
  on-demand transcripts, export and resolve actions.
- Existing views (`/`, pipeline DAG, escalations, transcripts) render the same
  facts, now sourced from the facade.

Grep test (SC-007): no module under `lib/speckit_orchestrator/web/` references
`:mnesia`, `Store.Query`, or `Store.Writer`, and no state file is read from
disk.

## 10. Clean break (FR-037)

After the cutover, none of these are written or read:

```
<autonomous_root>/transcripts/<segment>/run.json
<transcript_root>/<feature_id>/checkpoint.json
<transcript_root>/<feature_id>/NN-<phase>.md
<transcript_root>/<feature_id>/pr.json
<worktree>/.speckit_logs/
```

Verify with a grep test asserting `RunManifest`, `Checkpoint`, `Transcripts`,
and `Describe.write_pr/read_pr` no longer exist, and a run test asserting no
file is created under those paths. Pre-existing files may be deleted manually;
they are never read.

## 11. Headline checks

| Check | Command / assertion |
|-------|---------------------|
| No compiler warnings | `mise exec -- mix compile` (warnings are errors) |
| Formatted | `mise exec -- mix format --check-formatted` |
| Pure core coverage >90% | `mise exec -- mix test --cover` |
| No UI needed | every capability test runs with no endpoint mounted (SC-007a) |
| Parallel writers lose nothing | recorded phase attempts == executed phase attempts, exactly (SC-008) |
