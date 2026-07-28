# Phase 0 Research: Unified Run-State Persistence

**Feature**: `018-unified-run-persistence` | **Date**: 2026-07-27

All Technical Context unknowns are resolved below. Each entry is a decision, the
rationale, and the alternatives rejected. Findings marked **(probed)** were
verified empirically against the pinned toolchain (Elixir 1.20.2 / OTP 28) with
throwaway scripts, not recalled from documentation.

---

## R1 — Store engine: Mnesia, single-node, machine-local

**Decision**: Mnesia, exactly as the constitution's `Technology Stack →
Persistence (run state)` subsection (v1.3.0) mandates. No external database
service, no Hex persistence dependency, no ORM. `:mnesia` is added to
`extra_applications` in `mix.exs`; nothing else is added to `deps`.

**Probed facts** that shape every later decision:

| Probe | Result |
|-------|--------|
| `:mnesia.create_schema([node()])` on `:nonode@nohost` | `:ok` — a disc schema works on a non-distributed node |
| `disc_copies` table create | `{:atomic, :ok}`, writes `<name>.DCD` |
| `disc_only_copies` table create | `{:atomic, :ok}`, writes `<name>.DAT` (DETS) |
| `ordered_set` + `disc_only_copies` | `{:aborted, {:bad_type, _, {:not_supported, :ordered_set, :disc_only_copies}}}` |
| `ordered_set` + `disc_copies` | `{:atomic, :ok}` |
| secondary `index:` on `disc_copies` | works; `:mnesia.index_read/3` returns matching rows |
| `:mnesia.transform_table/3` | `{:atomic, :ok}`; attribute list updated in place |
| 50 concurrent transactional writers | 50 rows, zero lost updates |
| `:mnesia.table_info(tab, :memory)` on `disc_only_copies` | **bytes** (DETS file size), not words |
| `:mnesia.table_info(:schema, :disc_copies)` | `[:nonode@nohost]` — the node the schema belongs to is readable |
| `:mnesia_frag` | loaded and available in OTP 28 |

**Rationale**: already in the runtime; no new operational surface; transactions
give FR-006 (all-or-nothing) and FR-007 (concurrent writers) with no
hand-rolled locking.

**Alternatives rejected**: SQLite/Ecto (new dep + ORM, both barred);
append-only JSON log with fsync (re-implements transactions badly, and FR-007
concurrency becomes hand-rolled locking); DETS directly (no transactions).

---

## R2 — Node name and schema ownership

**Decision**: do **not** force distribution. The orchestrator runs as
`:nonode@nohost` under `mix run` / `iex -S mix`, which the probe confirms
supports a disc schema. Schema ownership is verified, not assumed:

1. `Store.Boot` reads `:mnesia.table_info(:schema, :disc_copies)` after start.
2. If `node()` is not in that list → **abort startup loud** with
   `{:error, {:schema_node_mismatch, expected: node(), schema: nodes}}`.
   Never create a fresh empty schema over the top of a foreign one.
3. The node name is also recorded in the `speckit_meta` table at schema
   creation, so a mismatch is detectable even if Mnesia would have tolerated it.

**Rationale**: Constitution requires the node name to be explicit and stable and
requires a loud failure on a foreign schema — presenting a repository as having
no history because the operator started with `--sname` is exactly the silent
data loss Principle II forbids. Recording it twice (schema + meta row) makes
the check independent of Mnesia internals.

**Operator consequence (documented in the runbook)**: starting the orchestrator
with a different node name than the one that created the schema is a hard
failure with a message naming both names, not a silent new store.

**Alternatives rejected**: forcing `--sname speckit` (adds epmd to the runtime
surface for zero benefit on a single-node, machine-local store); auto-creating a
new schema on mismatch (silently hides history — barred).

---

## R3 — Store location

**Decision**: `<Config.autonomous_root()>/mnesia` (default
`~/.autonomous/mnesia`), set via `:application.put_env(:mnesia, :dir, …)`
**before** `:mnesia.start()`. Never inside a target repository's working tree.
A new `Config.store_dir/0` reads `:store_dir`, defaulting to that path, so tests
and operators can relocate it.

**Rationale**: FR-005 and the constitution both require the store to sit outside
the target tree so worktree removal or branch switching cannot destroy it.
`autonomous_root` is already the machine-global root for worktrees and
transcripts, so this adds no new root concept.

**Alternatives rejected**: per-repository store directories (defeats
cross-repository history queries and multiplies schema-boot cost for no gain —
partitioning is a key concern, not a directory concern, see R10).

---

## R4 — Startup ordering and failure

**Decision**: a `Store.Boot.start!/0` runs **first** in
`SpeckitOrchestrator.Application.start/2`, before any child spec, and returns
`{:error, reason}` from `start/2` on failure so the OTP application aborts.
Sequence:

1. resolve and `mkdir -p` the store dir;
2. `:application.put_env(:mnesia, :dir, …)`;
3. `:mnesia.create_schema([node()])` if absent (an `{:error, {_, {:already_exists, _}}}` is not an error);
4. `:mnesia.start()`;
5. verify schema ownership (R2);
6. read `speckit_meta`'s `:schema_version`, run pending migrations (R13), or create tables at the current version on a fresh schema;
7. `:mnesia.wait_for_tables(all_tables, timeout)`;
8. a write-probe transaction into `speckit_meta` proving the store is writable (FR-009).

**Rationale**: the constitution requires Mnesia started and its schema verified
before any state consumer starts, and FR-009 requires a loud failure at run
start rather than spending money that cannot be recorded. Doing it in
`Application.start/2` means the failure surfaces before the supervision tree
even exists, so no consumer can observe a half-ready store.

**Alternatives rejected**: a supervised `Store` GenServer that starts Mnesia in
`init/1` (racy — sibling children could start first under `:one_for_one`);
lazy start-on-first-write (a run would already be in flight when it failed).

---

## R5 — Table set, keys, storage types, ordering

**Decision**: twelve tables (full schema in `contracts/schema.md`,
entity mapping in `data-model.md`). Shape rules:

- Everything except transcripts is `disc_copies` — small, hot, run-control data
  that must be RAM-resident for a responsive history listing.
- `speckit_transcript` is **`disc_only_copies`** — it is the bulk of stored
  volume and must never grow the BEAM heap (constitution, FR-030, FR-036).
- `speckit_run` is `ordered_set` keyed `{repo_id, run_seq_key}` where
  `run_seq_key` is the run's sequence number **zero-padded to 6 digits as a
  binary**. Ordered-set key order then *is* chronological order, with no sort
  and no clock dependency (FR-033). Cap: 999 999 runs per repository, recorded
  as a documented limit.
- Child tables (`feature_run`, `phase_attempt`, `checkpoint`, `escalation`,
  `remediation_attempt`, `cost_entry`, `settings_amendment`) carry a `run_key`
  attribute (`{repo_id, run_key}`) with a secondary `index:` on it, so a run's
  full detail loads with `index_read/3` per table rather than a table scan.
- `speckit_run` also carries indexed `repo_id` and `outcome` attributes,
  backing FR-024's filter-by-outcome; filter-by-feature resolves through
  `speckit_feature_run`'s indexed `feature_id`.
- Transcripts are `set` (not `ordered_set`) because the probe shows
  `ordered_set` is unsupported on `disc_only_copies`; they are retrieved by
  exact attempt key only, never scanned in order.

**Rationale**: FR-036 requires history and summaries never to load transcript
content — a separate table with a separate storage type makes that structural
rather than a discipline the code must remember.

**Alternatives rejected**: one wide `run` row holding features/attempts as
embedded maps (a phase-attempt write would rewrite the whole run row —
FR-007's parallel writers would then contend and lose updates); transcripts as
an attribute on `phase_attempt` (would drag transcript bytes into every
`disc_copies` read, violating FR-036 and the constitution's heap rule).

---

## R6 — Transaction discipline

**Decision**: every mutation runs inside `:mnesia.transaction/1`. Every read
that feeds a resume, a gate, a cost decision, an export, or a prune is
transactional. `:mnesia.dirty_*` is used **only** in the console's
non-authoritative liveness reads, and never for a write.

The per-repository run sequence (FR-020/FR-033) uses a transactional
read-modify-write with a write lock —
`:mnesia.read(:speckit_seq, repo_id, :write)` then `:mnesia.write/1` — **not**
`:mnesia.dirty_update_counter/3`, which the constitution's no-dirty-writes rule
bars even when called from inside a transaction.

**Rationale**: this is what makes FR-006 (all-or-nothing under interruption) and
FR-007 (no lost update from parallel features) true by construction instead of
by convention.

**Alternatives rejected**: `:mnesia.async_dirty` for phase-attempt writes
(faster, but a crash mid-write can leave a half-applied update — the exact
failure this feature exists to remove).

---

## R7 — Write granularity: one transaction per durable boundary

**Decision**: each durable boundary is exactly one transaction spanning every
row it touches. Concretely:

| Boundary | Rows written in one transaction |
|----------|--------------------------------|
| run start | `seq` bump, prior in-flight run → `superseded` + its non-terminal features → `ended_by_supersession`, new `run`, `run_settings`, all `feature_run` rows |
| phase attempt finished | `phase_attempt`, `cost_entry`, `checkpoint` (superseding the feature's prior one), `transcript` |
| remediation attempt | `remediation_attempt`, `cost_entry`, `transcript` |
| feature terminal | `feature_run` status/reason, `checkpoint` (deleted on `:done`), `escalation` when diverted |
| run drained | `run` state/outcome/end time/spend |

**Rationale**: FR-006 says a reader must never see a half-applied update. A
checkpoint that exists without the phase attempt it points at, or a phase
attempt whose transcript is missing (FR-035: "cannot be separated"), *is* a
half-applied update — so they must share a transaction, not merely each be
atomic.

**Alternatives rejected**: transcript written in a follow-up transaction to keep
the hot transaction small (breaks FR-035 and lets a crash orphan an attempt).

---

## R8 — Transcript recording must not delay the run (FR-030)

**Decision**: transcripts are written synchronously inside the boundary
transaction (R7), and the size is bounded at the source rather than by
deferring the write. Measurements to confirm SC-010 are part of the quickstart;
if a phase's transcript proves large enough to matter, the mitigation is
`disc_only_copies`' streaming write path already in use, not an async queue.

**Rationale**: a phase takes tens of seconds to minutes of CLI time; a DETS
append of even a multi-megabyte binary is orders of magnitude below that, so
the "negligible fraction of a phase's own duration" bar (SC-010) is met
synchronously. An async writer would reintroduce exactly the window FR-006
closes — a phase reported complete whose transcript is not yet durable.

**Alternatives rejected**: async transcript writer process (breaks R7's
one-transaction rule and FR-035); truncating large transcripts (FR-029a bars
any transformation of transcript content).

---

## R9 — Persistence failure ⇒ drain and halt (FR-010)

**Decision**: a new `Store.Health` GenServer mirrors `Ledger`'s breaker exactly.

- Every write goes through `Store.Writer`, which reports an `{:aborted, reason}`
  transaction to `Store.Health.record_failure/2`.
- `Store.Health.failed?/1` is checked by `Coordinator.advance/1` (releases
  nothing new — the identical position where `breaker_tripped?/1` is checked)
  and by `FeatureRunner`'s inter-phase drain point (the `{:cont, next}` branch
  where the breaker is already checked), which halts with
  `{:persistence_failed, reason}` **between** phases.
- The in-flight phase is never aborted; no further phase and no further feature
  starts.
- The run row is flagged `record_complete?: false` on a best-effort halt write.
  If that write also fails, the run stays `state: :in_flight` with its last
  successful `updated_at` — which is itself the incompleteness signal a later
  `resumable/1` reports (FR-010a, FR-018).

**Rationale**: FR-010 explicitly says "this mirrors the cost breaker's
drain-don't-kill behaviour". Reusing the two existing check points means the
drain semantics are literally the same code path, not a parallel
implementation that can drift.

**Alternatives rejected**: raising from the write site and letting the runner
Task crash (kills mid-phase — barred by FR-010); a degraded in-memory mode
(barred explicitly by FR-010).

---

## R10 — Repository partition, including a repo with no origin

**Decision**: partition key `repo_id` is a new
`RepoIdentity.partition/1`:

- origin resolvable → `{:origin, segment}` where `segment` is today's
  `"<name>-<sha6(canonical)>"`;
- no usable origin → `{:local, "<basename>-local-<sha6(expanded abs path)>"}`.

`repo_id` is stored as the resulting binary, prefixed (`"o:"` / `"l:"`) so an
origin-derived and a path-derived identity can never collide.

`RepoIdentity.resolve/1` and `run/1`'s existing no-origin preflight refusal are
**unchanged** — relaxing that refusal is out of scope. The `{:local, …}`
fallback exists so the store honours the spec's "repository with no identifiable
origin" edge case (state still recorded, never sharing a bucket) the moment
that preflight is ever relaxed, and so `run_spec/2`-style flows on a
not-yet-remoted repo have a defined key rather than an undefined one.

**Rationale**: FR-004 requires that two checkouts with the same directory name
from different origins never share state — the existing origin hash already
guarantees that, and the path hash extends the same guarantee to origin-less
repos.

**Alternatives rejected**: keying by absolute path always (two clones of the
same repo would show unrelated histories); keying by directory basename (the
exact collision FR-004 names).

---

## R11 — Run identity, lifecycle, and supersession (FR-020, FR-023, FR-034)

**Decision**: `run_id` = `"r" <> zero-padded 6-digit per-repository sequence`
(e.g. `"r000004"`). Stable across resumes of that run — a resume continues the
existing run row rather than creating one. Lifecycle:

```
in_flight ──drained──▶ completed(outcome)
    │
    └──new run started for same repo──▶ superseded
```

Starting a run executes R7's run-start transaction, which marks any existing
`in_flight` run for that repo `superseded` in the *same* transaction that
inserts the new one — so FR-034's "at most one in flight" cannot be violated
even by two racing starts, and SC-012 holds.

Features of a superseded run that had not reached their own terminal state are
marked `:ended_by_supersession`, distinct from `:done`/`:failed` (FR-023,
spec edge case "a run superseded while in flight").

**Rationale**: a padded sequence gives a stable id, uniqueness within a
repository, and clock-independent ordering with one value instead of three.

**Alternatives rejected**: UUID run ids (no ordering, needs a separate sequence
anyway); timestamp ids (breaks under clock movement — an explicit edge case).

---

## R12 — Export format (FR-032, FR-032a/b/c)

**Decision**: one JSON file per run, no directory, no archive, no side files:

```json
{ "format": "speckit.run-export",
  "format_version": 1,
  "exported_at": "…",
  "run": { …, "features": [ { …, "phase_attempts": [ { …, "transcript": {…} } ] } ] } }
```

Transcripts are embedded as fields on their phase attempt, verbatim
(FR-029a). Because a transcript is raw tool output and need not be valid
UTF-8 while JSON strings must be, each transcript carries an explicit
`"encoding"`: `"utf8"` with the text inline, or `"base64"` with the exact
original bytes — lossless either way, and never a transformation of content
(base64 is a transport encoding, not redaction).

No path, store reference, node name, or worktree location is required to read
the file (FR-032b). Export runs in a read-only transaction and takes no locks
that block writers, so it works mid-run and under a capacity refusal
(FR-032c).

**Rationale**: FR-032a is explicit about "exactly one self-describing
machine-readable file". JSON + Jason is already in the tree and readable
without Mnesia, which the constitution requires ("Mnesia's own backup facility
is an operations tool, not the export contract").

**Alternatives rejected**: `:mnesia.backup/1` (unreadable without Mnesia —
barred by the constitution); a tarball of per-entity files (barred by FR-032a).

---

## R13 — Schema evolution

**Decision**: `speckit_meta` holds `{:schema_version, integer}`.
`Store.Migrations` is an ordered list of `{version, fun}` applied at boot inside
transactions, using `:mnesia.transform_table/3` (probed working) for attribute
changes. Rules:

- recorded version **older** than known → apply the intervening migrations, then
  rewrite the version;
- recorded version **equal** → proceed;
- recorded version **newer or unrecognized** → **abort startup loud**; never
  auto-coerce, never downgrade.

**Rationale**: constitution requires exactly this, and Principle II makes an
unrecognized version a boundary rejection rather than a best guess.

---

## R14 — Test hermeticity with a node-global Mnesia directory

**Decision**: the Mnesia directory is a node-global setting, so per-test
directories are impossible in one BEAM. Therefore:

- `test/test_helper.exs` creates **one** temporary store (a fresh dir under the
  system temp dir, unique per run), boots it via the same `Store.Boot` path
  production uses, and removes it on exit;
- a `SpeckitOrchestrator.StoreCase` helper clears every table between tests;
- tests that touch the store are `async: false`; pure-module tests
  (`Store.Records`, `Store.Prune`, `Store.Capacity`, `Store.Export`,
  `Store.Ids`) stay `async: true` and need no schema at all;
- the default suite therefore never touches `~/.autonomous`, satisfying the
  constitution's hermeticity clause.

**Rationale**: the constitution requires the default suite not to depend on a
developer's machine-global Mnesia directory. One shared temp schema is the only
shape that satisfies that without a node per test.

**Alternatives rejected**: `ram_copies`-only test schema (would not exercise the
DETS/`disc_only_copies` path where the transcript and capacity behaviour lives);
peer nodes per test (start-up cost per test file, and OTP peer nodes need
distribution — see R2).

---

## R15 — Clean break: what stops being written (FR-037)

**Decision**: the following file locations stop being written **and** stop being
read, in the same change:

| Location | Fate |
|----------|------|
| `<autonomous_root>/transcripts/<segment>/run.json` (`RunManifest`) | module deleted |
| `<transcript_root>/<feature_id>/checkpoint.json` (`Checkpoint`) | module deleted |
| `<transcript_root>/<feature_id>/NN-<phase>.md` (durable transcripts) | replaced by `speckit_transcript` |
| `<transcript_root>/<feature_id>/pr.json` (`Describe.write_pr/read_pr`) | replaced by a `feature_run` field |
| `<worktree>/.speckit_logs/NN-<phase>.md` (live worktree copy) | **also removed** — see below |

The worktree copy is removed too. It is the clearest instance of what FR-037
forbids: a second copy of the same fact that *survives*, because
`Worktree.commit/2` commits `.speckit_logs` onto the feature branch, so it
outlives the worktree in the target repository's git history. Removing it also
stops raw tool output — which the spec's accepted-risk clause acknowledges may
contain credentials — from being committed into the target repo.

Nothing reads `.speckit_logs` programmatically today (verified: the only reader
of transcript content is `Recovery.Evidence.final_marker?/2`, which reads the
*durable* root, and `TranscriptsLive`, which reads the durable root).

**Consequence, called out for the operator**: a live `tail -f` of
`<worktree>/.speckit_logs` is no longer available; the console's run-detail view
and `SpeckitOrchestrator.transcript/1` replace it.

**Alternatives rejected**: keeping `.speckit_logs` as a convenience copy
(FR-003/FR-037 forbid a surviving second copy, and it leaks transcripts into the
target repo's history).

---

## R16 — Recovery reconciliation after the cutover (FR-018)

**Decision**: `Recovery.Evidence` keeps its git-sourced signals unchanged
(`branch_committed?`, `last_boundary_phase` from boundary commit subjects) and
takes its three file-sourced signals from the store instead:

| Signal | Before | After |
|--------|--------|-------|
| `checkpoint` | `Checkpoint.read/2` | `Store.Query.checkpoint/2` |
| `pr_record?` | `Describe.read_pr/2` | `feature_run.pr_description != nil` |
| `final_marker?` | reads `07-converge.md` from disk | `Store.Query.transcript/1` for the converge attempt, same regex |

`Reconcile.status/3`, the pure decision table, is **unchanged** — this is a
change of where evidence comes from, not of how it is judged. Store-vs-git
disagreement continues to surface as a `Recovery.Report` conflict rather than
being resolved silently (FR-018), and now also covers FR-010a's "gap between the
last recorded position and the work that actually completed".

**Alternatives rejected**: trusting the store over git evidence (FR-018 requires
reporting the disagreement, not picking a winner).

---

## R17 — Capacity ceiling and headroom (FR-031b..e)

**Decision**: the binding limit is DETS's per-table file-size ceiling inherited
by `disc_only_copies`, which lands on `speckit_transcript`. Policy:

- `Config.store_capacity_bytes/0` — default `1_500_000_000` (1.4 GiB), safely
  under the DETS ceiling;
- `Config.store_headroom_bytes/0` — default `150_000_000` (10%);
- measurement: `:mnesia.table_info(:speckit_transcript, :memory)` returns
  **bytes** for a DETS table (probed), plus a sum of `File.stat/1` sizes across
  the store dir for the whole-store figure — no scan of table contents;
- `Store.Capacity.check/1` is a **pure** function
  `(used, capacity, headroom) → :ok | {:refuse, %{shortfall:, used:, capacity:}}`;
- a refusal blocks **run start only** (FR-031c): history, run detail, transcript
  retrieval, export and prune all stay available, and an in-flight run is
  untouched;
- hitting the ceiling mid-run is an ordinary write failure → R9's drain and halt
  (FR-031d); nothing is ever discarded to make room (FR-031a).

`Store.Prune.preview/2` reports what a boundary would remove and how much it
would reclaim without performing it (FR-031e), computed from stored byte counts
per run — never by deleting and measuring.

**Rationale**: the constitution requires the DETS ceiling be handled explicitly
by fragmentation or operator pruning and never by silently dropping state.
Operator pruning is the spec's chosen mechanism; fragmentation stays available
(`:mnesia_frag` is present — probed) as a later escape hatch if a single
repository's transcript volume ever justifies it.

**Alternatives rejected**: `:mnesia_frag` from day one (operational complexity
for volume no current run approaches); automatic rollover (barred by FR-031a).

---

## R18 — Prune safety (FR-031)

**Decision**: `Store.Prune.plan/3` is pure —
`(run_summaries, boundary, protected_run_ids) → %{removable:, retained:,
bytes_reclaimed:}`. `protected_run_ids` is every run the store reports as
resumable (`in_flight`, or halted/escalated with a live checkpoint). A prune
never removes a protected run regardless of boundary, and reports it as retained
with a reason rather than silently skipping it.

**Rationale**: FR-031's second clause ("pruning MUST NOT remove state that any
resumable run depends on") is a policy decision, and policy decisions belong in
a pure function that is unit-testable with no schema (Principle I).

---

## R19 — Console surface (FR-030a/b/c)

**Decision**: the programmatic facade is the contract; the console renders it.

- New facade functions (contract in `contracts/store-api.md`):
  `run_history/1`, `run_detail/1`, `transcript/1`, `resumable/1`,
  `prune_preview/1`, `prune/1`, `export_run/2`, `store_capacity/0`.
- New LiveViews `/runs` (history list, filterable) and `/runs/:id` (detail:
  per-feature phase attempts, escalations, remediation attempts, on-demand
  transcript).
- Existing views that read files today (`MissionControlLive`,
  `PipelineDagLive`, `EscalationsLive`, `TranscriptsLive`) are re-pointed at
  facade functions. No LiveView calls `:mnesia` or `Store.*` directly (FR-030c) —
  enforced by a test that greps the web tree for `:mnesia`/`Store.Query`.
- `ConsoleProjection` stays an in-memory telemetry fold. It is not a second
  source of truth: it holds only live-run derived display state and its
  last-known-status overlay now comes from `run_detail/1` instead of the
  manifest file.

**Rationale**: FR-030a makes the programmatic surface the thing the requirements
are verified against (SC-007a: every capability exercisable with no UI running),
and FR-030c keeps the console an observability surface.

---

## R20 — What deliberately does not change

Recorded so the implementation does not drift into them: `Pipeline.next/3` and
both gates; `Remediation.next/2` and the bounded pre-gate loop; `Ledger`'s
breaker arithmetic and drain-don't-kill; `Release.next_wave/4`; worktree
retention on non-`:done` terminals; `Backlog`'s load-time guards;
`RunContext`'s ten fields and its precedence rule; `Layout`'s worktree root and
the target repo's own spec artifacts. This feature changes **where state is
recorded**, and nothing else.
