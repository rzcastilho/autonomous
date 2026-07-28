# Contract: Console Run History and Run Detail

**Feature**: `018-unified-run-persistence` | **Requirements**: FR-030b, FR-030c,
SC-007

The console renders the programmatic surface and holds no query logic of its
own. It is an observability surface over one source of truth — never a second
one.

## Hard rule (FR-030c)

No module under `lib/speckit_orchestrator/web/` may reference `:mnesia`,
`SpeckitOrchestrator.Store.Query`, or `SpeckitOrchestrator.Store.Writer`, or read
a state file from disk. Every query goes through a `SpeckitOrchestrator.*`
facade function. Enforced by a test that greps the web tree (the same red-team
style used for the scope-guard hook).

## New views

### `/runs` — run history (FR-030b)

Calls `SpeckitOrchestrator.run_history/1` only.

- Rows: run id, state badge (in flight / completed / superseded), outcome,
  started, duration, spend, per-feature terminal status chips,
  an "incomplete record" marker when `record_complete? == false`.
- Most recent first; the ordering comes from the facade, not from a client-side
  sort (FR-021).
- Filters: outcome and feature (FR-024), submitted as facade options.
- A capacity banner from `store_capacity/0` when `status == :refusing`, naming
  the shortfall and the reclaimable amount, with a link to the prune preview.
- Empty repository renders an empty state, not an error.
- Never renders transcript content, so the list stays responsive at 500 runs
  regardless of stored transcript volume (FR-036, SC-009).

### `/runs/:run_id` — run detail (FR-030b)

Calls `SpeckitOrchestrator.run_detail/1`, and `transcript/1` **only** when the
operator opens a specific attempt.

- Run header: settings in force, amendments with their effective point (FR-027),
  spend, outcome, halt reason.
- Per feature: phase attempts in execution order with outcome, model, cost,
  duration; escalations with reason, originating phase, and triggering evidence
  (FR-025); remediation attempts listed individually with the attempt limit and
  severity threshold in force (US3 acceptance 4); the checkpoint.
- Each attempt has an "open transcript" affordance — retrieved on demand
  (FR-036), rendered verbatim.
- Actions: export this run (`export_run/3`), resolve an escalation
  (`resolve_escalation/2`).

## Existing views, re-pointed

| View | Today | After |
|------|-------|-------|
| `MissionControlLive` | `RunManifest.read/0` + `Checkpoint.read/2` | `run_detail/1` for the current run; live `Coordinator` still wins when active |
| `PipelineDagLive` | `RunManifest.read/0` + `rebuild_layout` + `Checkpoint.read/2` | `run_detail/1` |
| `EscalationsLive` | `Checkpoint.read/2` per feature | `run_detail/1`'s `escalations` — now the authoritative record, including resolved ones (FR-026) |
| `TranscriptsLive` | directory walk under `<autonomous_root>/transcripts/<segment>/…` | `run_detail/1` to populate the picker, `transcript/1` to render |
| `ConsoleProjection` | in-memory telemetry fold; manifest overlay on a cold boot | unchanged fold; the cold-boot overlay comes from `run_detail/1` instead of the manifest file |

`ConsoleProjection` remains non-persisting and is not a source of truth: it
holds live-run display state derived from telemetry, and every durable fact it
shows on a cold boot comes from the facade.

## Navigation

`/runs` is added to the console nav. The feature drawer's existing transcript
link changes from `?feature=<scope>/<id>&phase=<phase>` to a run-scoped
attempt reference, since a transcript now belongs to a specific attempt of a
specific run rather than to a path on disk.
