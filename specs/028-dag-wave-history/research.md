# Research: Pipeline Chain Shows Each Wave's Own History

All Technical Context items were resolved from the code itself. No
`NEEDS CLARIFICATION` remained after the spec's clarification session.

## R1 — Root cause of the leak

**Finding.** `PipelineDagLive` (`lib/speckit_orchestrator/web/live/pipeline_dag_live.ex`)
has two faults that combine.

1. **The gate fails open.** `run_package/1` reads the scope from
   `current_run_detail/0`, which resolves through
   `SpeckitOrchestrator.current_run_id/0` → `Store.current_run_key/1` →
   `Query.in_flight_run/1`. That call only ever finds an `:in_flight` run.
   Once a run is `:completed`, `:parked` or `:superseded`, `run_package` is
   `nil`, and `drawing_run_package?(%{run_package: nil})` returns `true`. So
   **every** wave draws `view.per_feature`.
2. **`per_feature` is unscoped last-run memory.** With the gate open, the
   rows come from three places, each keyed by feature id alone:
   - `Coordinator.status/0`: a finished or parked Coordinator stays alive and
     keeps reporting its `per_feature`;
   - `ConsoleReadModel.overlay_observed/2`: the projection's observed slices;
   - `hydrate/3` on whatever `run_detail` was passed.

   None of them carries a wave, so nothing downstream can separate `008`'s
   `001` from `007`'s `001`.

**Decision.** Fix both faults:
- the gate fails **closed** (FR-002);
- a wave's drawn rows come only from a run whose recorded `scope` is
  `{:breakdown, slug}` for that wave.

**Alternatives rejected.**
- *Blank every wave that is not the in-flight run's.* This fixes US1 but
  throws away recorded history (US2) and makes a finished wave look like it
  never ran.
- *Tag `per_feature` rows with a wave in `ConsoleReadModel`/telemetry.* This
  is wide-reaching: telemetry metadata, the projection, and Mission Control
  would all change. The spec keeps other views out of scope, and the store
  already records scope per run.

## R2 — Which run supplies a wave's state

**Decision.** Add a pure `WaveHistory.source_for(slug, summaries)` over
`SpeckitOrchestrator.run_history/1`. The summaries come from `Store.runs/2`
and carry `run_id`, `state`, `scope` and `started_at`, sorted by `run_id`
descending. `run_id` is allocated from a monotonic per-repo sequence
(`Ids.run_id/1`), so descending `run_id` means most recently started first.
The first matching rule wins:

1. `{:live, s}`: a summary with `state: :in_flight` and
   `scope: {:breakdown, slug}`.
2. `{:recorded, s}`: the first (newest) summary with
   `scope: {:breakdown, slug}`, in any state (clarification Q1).
3. `:none`.

Two inputs are excluded:
- **Damaged summaries** (`%{damaged: true}`) are **skipped**. Their scope is
  unreadable, and FR-002 forbids drawing unknown-scope state anywhere.
- **Ad-hoc runs** (`scope: :ad_hoc`) never match any slug (edge case).

**Rationale.**
- Exactly one run is chosen per wave (FR-006).
- The in-flight run wins for its own wave, so live behaviour is preserved.
- The rest are chosen by recency, not by outcome (clarification Q1).

**Alternative rejected.** Adding a new `Store.Query.latest_run_for_scope/2`.
It is not needed: `runs/2` already has everything required, and SC-003's
budget (20 waves, under 1 s) is met by one index read.

## R3 — How a past run's state is drawn

**Decision.** For `{:recorded, s}`:
1. Call `SpeckitOrchestrator.run_detail(s.run_id)`.
2. Pass the result to `ConsoleReadModel.hydrate/3` over a fresh inactive view
   (`%{active?: false, per_feature: %{}, observed: %{}}`).
3. Pass that through `WaveHistory.interrupt/2` (R4).

The Coordinator status and `ConsoleProjection.read/0` are **not** consulted
for a recorded wave. Both hold the latest run's memory without a wave, so
merging either one back in would recreate the leak.

**Rationale.**
- `hydrate/3` with `active?: false` and an empty `observed` builds rows purely
  from the record, using the same `ConsoleHydration.from_record/3` path that
  Mission Control and restart hydration already use.
- So a recorded wave's per-feature status and spend match its run record,
  which is SC-002's 100% agreement.
- Recorded windows come only from ended attempts
  (`ExecutionTime.from_attempts/1`), so the drawer's ELAPSED never ticks.
- The read is read-only, as the Assumptions require.

**`run_detail/1` failure** (`{:error, :absent}` or
`{:error, {:damaged, _, _}}`) resolves to `{:unavailable, reason}`. The wave
renders cold with a note (FR-010).

## R4 — Drawing a past run's `:running` feature as interrupted

**Decision.** `WaveHistory.interrupt(row, run_state)`. When `run_state` is
anything other than `:in_flight` and `row.status == :running`:

- `status` becomes the display-only atom `:interrupted`;
- the open phase gets the cell `%{state: :interrupted}`. The open phase is the
  phase after the checkpoint's `last_completed_phase` in `Pipeline.phases/0`
  (the first phase if there is none). It is taken from `row.current_phase`,
  which `from_record/3` sets from the checkpoint.
- The phases before it keep their recorded `:completed` cells, and later
  phases stay absent, which renders as pending.

Rows in any other status are returned unchanged.

**Rendering.**
- `CoreComponents.status_class(:interrupted)` folds to `"blocked"`.
  `:never_started` is the precedent: a started-but-not-finished state shares
  the slate "inactive" meaning, and no eighth color exists.
- `label(:interrupted)` is `"Interrupted"`.
- `phase_cell_state(%{state: :interrupted}, _)` returns `"interrupted"`, and a
  new CSS rule `.phase-cell-interrupted { background: var(--blocked); }` has
  no animation.
- Because the node's `data-status` is `"blocked"`, not `"running"`, the chip's
  `scPulse` selector never matches.

**Why not keep `:running`.** A resting node would claim live work and pulse,
which violates Principle VII's "Motion means live" rule and FR-007a.

**Why not `:never_started`.** The feature did start, and its phases are on
record. Calling it never started would be a false assertion.

**Why not `:failed`.** Nothing recorded a failure. Inventing one would violate
Principle II ("MUST NOT invent data").

**Vocabulary.** `:interrupted` is the word the codebase already uses for this
condition (`Recovery`/`resume_run` docs: "interrupted mid-run"). It is a
derived display state, never persisted, and its receipt is the run's own
`:state` (such as `:superseded`) shown in the source strip (R6).

## R5 — Live updates and the reconcile tick

**Decision.**
- `view` stays the live read model. It feeds the ad-hoc lane (unchanged,
  FR-009) and the live wave.
- A separate `wave_view` assign holds a recorded wave's hydrated rows.
- `chain_view/1` picks per source:
  - `{:live, _}` → `view`;
  - `{:recorded, _}` → `wave_view`;
  - `:none` / `{:unavailable, _}` → an empty `per_feature`.
- `{:console, :feature_updated, …}` changes only `view`. A recorded or cold
  wave cannot change from a live event (FR-004, US1-5).
- History is re-resolved on:
  1. mount;
  2. `select_package`;
  3. `{:console, :run_finished, _}`;
  4. a `:reconciled` tick whose `current_run_id/0` differs from the cached
     `live_run_id`.

  Case 4 covers a run that started or ended while the page is open. Steady
  reconcile ticks do no history read.

**Alternative rejected.** Re-reading history on every reconcile tick. It is
correct but wasteful. `Store.runs/2` also rolls up `feature_statuses` per run.

## R6 — Source receipt (FR-007)

**Decision.** Add a strip under the canvas header,
`<div data-wave-source={kind}>`:

| Source | Strip content |
|---|---|
| `recorded` | `run_id` in mono, linked to `/runs/:run_id` (`RunDetailLive`), then the run state as a mono atom (`:completed`, `:parked`, `:superseded`) |
| `live` | `run_id` in mono and `:in_flight`, which keeps one consistent receipt |
| `none` | Sans prose: "No recorded run for `<slug>`" (a status report, not a call to action) |
| `unavailable` | Sans prose: "History for `<slug>` could not be read" plus the `run_id` in mono. Neutral text tokens only, never a status color (FR-010, "non-alarming") |

The strip is omitted in the legacy no-packages layout (FR-009).

## R7 — Default selected wave (US3, FR-008)

**Decision.** `WaveHistory.default_package(packages, summaries)`. The first
matching rule wins:

1. the slug of the `:in_flight` run, if it is in `packages`;
2. otherwise the slug of the newest `{:breakdown, slug}` summary whose slug is
   in `packages` (ad-hoc and damaged summaries are skipped);
3. otherwise `List.first(packages)`, which is alphabetical because
   `package_slugs/1` sorts.

It replaces `default_package/2` in the LiveView.

## R8 — Legacy no-packages layout

**Decision.** When `selected_package == nil` (the repo has no
`breakdown/<slug>/` packages), keep today's behaviour exactly: draw `view`
ungated, with no source strip (FR-009, SC-005). There is no wave to scope to,
so wave history does not apply.

## R9 — Test strategy

**Pure tests** (`wave_history_test.exs`) are table-driven:
- `source_for/2`: live, recorded in each state, ad-hoc skipped, damaged
  skipped, several runs where the newest wins, and empty input;
- `default_package/2`: in-flight, recent, ad-hoc only, slug not in packages,
  and no runs;
- `interrupt/2`: `:running` with and without a checkpoint, terminal rows
  unchanged, and `:in_flight` unchanged.

**LiveView tests**
(`pipeline_dag_live_test.exs`, "wave history" describe) reuse
`repo_with_colliding_packages/0`. They seed completed and superseded runs
through `Store.Writer` in the hermetic temp store, the same way the existing
restart tests do, and assert:

- **FR-011 / US1-1 and US1-4**: a finished `beta` run, then selecting `alpha`,
  shows no leaked status, phases or spend on nodes or in the drawer;
- **US1-5**: a live `feature_updated` for `001` while `alpha` is selected does
  not change `alpha`'s node;
- **US2-1 and US2-2**: each wave draws its own newest run, with no merge;
- **US2-4**: a superseded run with `:running` `003` renders
  `data-status="blocked"`, the interrupted cell, and no `phase-cell-active`;
- **US2-5**: the receipt strip shows the `run_id` and state;
- **US3**: a reload lands on the most recent wave;
- **FR-010**: a damaged run record renders the unavailable note and a cold
  wave.

**Regression**: the existing live-wave, ad-hoc, legacy, and invalid-backlog
tests must pass unchanged (SC-005). The existing test "after a restart with no
live Coordinator… in-flight run" still holds, because an in-flight source
still hydrates as before.
