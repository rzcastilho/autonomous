# Implementation Plan: Unified Run-State Persistence

**Branch**: `018-unified-run-persistence` | **Date**: 2026-07-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/018-unified-run-persistence/spec.md`

## Summary

Replace the four independently-written state files — the run manifest, the
per-feature checkpoints, the durable transcripts, and the PR handoff — with one
transactional Mnesia store that holds everything a run is: its identity and
lifecycle, its features, every phase attempt, the checkpoints that make it
resumable, every escalation, every auto-remediation attempt, the settings it
started under, its cost entries, and its phase transcripts. Because those files
are written independently today, a crash between two of them leaves a record
that disagrees with itself; one transaction per durable boundary removes that
class of failure outright.

Technical approach — a new persistence boundary, a clean break, and no change to
any decision surface. `Store.Mnesia` is the only module that touches `:mnesia`;
`Store.Writer` and `Store.Query` are the internal API the orchestrator records
and reads through; `Store.Records`, `Store.Ids`, `Store.Prune`,
`Store.Capacity`, and `Store.Export` are pure and unit-testable with no schema
and no running node. `Store.Boot` starts and verifies the schema before any
child spec exists, so a run can never begin spending money it cannot record.
`Store.Health` mirrors `Ledger` exactly: a write failure is checked at the two
places the cost breaker is already checked, so a store that goes unwritable
mid-run drains and halts between phases instead of dying mid-phase or
continuing in a degraded mode.

Twelve tables, all `disc_copies` except `speckit_transcript`, which is
`disc_only_copies` so transcript volume never grows the BEAM heap and a history
listing structurally cannot load it. `speckit_run` is an `ordered_set` keyed by
a zero-padded per-repository sequence, so run ordering is correct across
restarts and clock changes without sorting on a timestamp. State is partitioned
by a repository identity derived from the origin remote, with a path-derived
fallback for a repo with none — prefixed so the two derivations cannot collide.

Everything the operator can do is a facade function first and a console view
second: `run_history/1`, `run_detail/1`, `transcript/1`, `resumable/1`,
`prune_preview/1`, `prune/1`, `export_run/3`, `store_capacity/0`. The console
gains `/runs` and `/runs/:run_id` and re-points four existing views at those
functions; no LiveView touches the store.

This is a clean break (FR-037): `RunManifest`, `Checkpoint`, `Transcripts`, and
`Describe`'s PR-file pair are **deleted**, not deprecated, in the same change
that adds their replacements. Two consequences are deliberate and called out
below: the in-worktree `.speckit_logs` copy stops being written (research R15),
and nothing reads pre-existing on-disk state.

No gate, breaker, or pipeline decision changes. `Pipeline.next/3`,
`Remediation.next/2`, `Release.next_wave/4`, `Ledger`'s arithmetic, worktree
retention, and `RunContext`'s precedence rule are untouched. Only where state is
recorded changes.

## Technical Context

**Language/Version**: Elixir `~> 1.20`, pinned `1.20.2-otp-28` via
`.tool-versions`; OTP 28 system-provided (never mise-managed). Every command
through `mise exec --`.

**Primary Dependencies**: no new Hex dependency. `:mnesia` is added to
`extra_applications` in `mix.exs` — it ships with Erlang/OTP. Existing: Jido
`~> 2.2`, `jido_harness` + `jido_claude` (GitHub SHA pins, `override: true` on
the harness), Phoenix `~> 1.7` / LiveView `~> 1.0` on Bandit, `phoenix_pubsub`,
Jason, `:telemetry`.

**Storage**: **Mnesia**, single-node and machine-local, per the constitution's
`Technology Stack → Persistence (run state)` subsection (v1.3.0). Directory
`<Config.autonomous_root()>/mnesia` (default `~/.autonomous/mnesia`), never
inside a target repository tree. Twelve tables; `disc_copies` for run-control
data, `disc_only_copies` for transcripts. Every mutation in a transaction;
`:mnesia.dirty_*` only for non-authoritative console reads. Schema version
recorded in-store with `:mnesia.transform_table` migrations applied at boot; an
unrecognized or newer version aborts startup. No external database service, no
ORM, no Ecto.

**Testing**: ExUnit. Pure modules (`Store.Records`, `Store.Ids`, `Store.Prune`,
`Store.Capacity`, `Store.Export`) are `async: true` and need no schema.
Store-touching tests are `async: false` against one temporary schema created in
`test_helper.exs` and torn down on exit, with a `StoreCase` helper clearing
tables between tests — the default suite never touches a developer's
`~/.autonomous`. Existing injected seams (`:runner`, `:manifest` → `:store`,
scripted fake agents) keep wave/DAG/breaker logic testable with no CLI or
worktree. Real-harness coverage stays behind `mix test --include integration`.
`warnings_as_errors` is on; `mix format` mandatory.

**Target Platform**: BEAM control plane on developer/CI machines (darwin +
linux), driving the `claude` CLI against a target git repo. Node name is
whatever `node()` is — `:nonode@nohost` under `mix run` / `iex -S mix`, which
supports a disc schema (verified). The node is recorded and verified at boot;
a mismatch fails loud.

**Project Type**: single Elixir/OTP application with an embedded Phoenix
LiveView console.

**Performance Goals**: history listing interactive at 500 recorded runs and
independent of stored transcript volume (SC-009); state recording adds no more
than a negligible fraction of a phase's own duration (SC-010) — a DETS append is
orders of magnitude below a phase's tens-of-seconds-to-minutes of CLI time;
recorded phase attempts equal executed phase attempts exactly under maximum
feature parallelism (SC-008).

**Constraints**: no partial state visible after any interruption (FR-006); no
lost update from parallel writers (FR-007); no automatic removal of any record
at any age or volume (FR-031a); transcripts stored and exported verbatim
(FR-029a); recorded settings free of secrets by construction (FR-028); the store
lives outside every target repository tree (FR-005); capacity is bounded by the
DETS per-table ceiling that `disc_only_copies` inherits, handled by operator
pruning plus a start-refusal, never by dropping state.

**Scale/Scope**: single machine, one run in flight per repository (FR-034),
target 500+ recorded runs per repository with a documented ceiling of 999 999;
default capacity 1.5 GB with 150 MB headroom. Cutover touches ~20 existing
modules and deletes 3.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution **v1.3.0**. Initial check: **PASS**. Post-design
re-check: **PASS with one recorded deviation** — the Erlang node name is
verified and recorded rather than explicitly configured (Persistence subsection).
The deviation, its need, and the rejected simpler alternative are recorded in
Complexity Tracking as the Governance section requires. No other clause deviates.

| Principle / section | Gate | Verdict |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | Pure logic must not depend on the CLI, harness, Jido — and, per the Persistence subsection, not on Mnesia | **PASS**. `Store.Records`, `Store.Ids`, `Store.Prune`, `Store.Capacity`, `Store.Export` are pure data and policy, tested with no schema. `Store.Mnesia` is the sole `:mnesia` caller. `Pipeline`, `Release`, `Ledger`, `Backlog`, `Severity`, `Remediation` gain no persistence dependency. Enforced by a grep test. |
| **II. Fail Loud at Boundaries** | Reject invalid input at the edge; never invent data | **PASS**. Store unreachable/unwritable at start → run refused before spend (FR-009). Foreign schema node, unrecognized/newer schema version → startup aborts. Damaged rows return `{:error, {:damaged, …}}`; absent, complete and damaged are three distinct returns, and no read path substitutes a default (FR-008, SC-011). Stored status vocabularies are mapped explicitly — never `String.to_atom/1` on stored content. |
| **III. Least-Privilege Containment** | Containment lives in the committed target-repo pack; layered; fails closed | **PASS**, and slightly strengthened: the store sits outside every target tree, and dropping the in-worktree `.speckit_logs` copy stops raw tool output being committed into the target repo. The scope-guard hook, `settings.json`, and per-phase `PhaseRequest` permissions are untouched. |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | Breaker arithmetic and drain-not-kill preserved | **PASS**. `Ledger` is unchanged; its restore is now seeded from the run's cost-entry roll-up instead of a recorded scalar, keeping spend attributable across a resume. The persistence-failure path *reuses* the breaker's two check points rather than adding a parallel mechanism, so drain-don't-kill is literally the same code path. Cost still prefers actual and falls back to the per-phase estimate, with `cost_kind` recording which. |
| **V. Human-in-the-Loop Escalation** | Gates, bounded pre-gate loop, worktree retention unchanged | **PASS**. `Pipeline.next/3` and `Remediation.next/2` are untouched. Escalations become first-class records that are *resolved*, never erased (FR-026) — strictly more auditable than today's checkpoint. Worktree retention on non-`:done` terminals is unchanged. |
| **VI. Idiomatic Elixir/OTP** | Pure transforms, pattern matching, `with`, tagged tuples, thin GenServers, supervision, no scheduler blocking, `@spec` + format | **PASS**. Policy lives in pure functions (`Capacity.check/1`, `Prune.plan/3`, `Records.decode/2`); `Store.Health` is a thin flag-holding shell exactly like `Ledger`; writers return tagged tuples and never raise into a run; boot failure aborts `Application.start/2` rather than being defensively rescued. Transactions are short and bounded, so no callback blocks a caller for long. |
| **Technology Stack → Persistence** | Mnesia only; single-node; outside the target tree; explicit stable node; transactions for every mutation, no dirty writes; deliberate per-table storage types with bulk in `disc_only_copies` and never loaded by a listing; DETS ceiling handled explicitly, never by dropping state; versioned schema with loud failure; started and verified before consumers; exportable without Mnesia; pure core independent; hermetic default suite | **PASS on every clause but one**, which is a recorded deviation: the node name is *verified and recorded* rather than *explicitly configured* — see Complexity Tracking. This feature is the subsection's first implementation; see `contracts/schema.md` for the clause-by-clause realization. |
| **Quality & Test Discipline** | mise, `warnings_as_errors`, >90% pure-core coverage, seams not CLI, integration opt-in, hermetic default suite | **PASS**. One temporary schema per suite run under the system temp dir (research R14). |
| **Development Workflow** | Spec Kit loop; gates mandatory; worktree parallelism; plan is source of truth | **PASS**. No workflow change. |

## Project Structure

### Documentation (this feature)

```text
specs/018-unified-run-persistence/
├── plan.md                        # This file
├── research.md                    # Phase 0 — R1..R20 decisions
├── data-model.md                  # Phase 1 — entities, invariants, transitions
├── quickstart.md                  # Phase 1 — validation guide
├── contracts/                     # Phase 1
│   ├── schema.md                  # Mnesia tables, boot, transactions, migrations
│   ├── store-api.md               # Programmatic operator surface (the contract)
│   ├── persistence-failure.md     # Drain-and-halt on write failure
│   ├── capacity-and-prune.md      # Ceiling, refusal, operator pruning
│   ├── export-format.md           # Single-file JSON export
│   └── console-runs.md            # /runs + /runs/:run_id, no direct store access
├── checklists/requirements.md
└── tasks.md                       # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── store.ex                       # NEW — persistence boundary facade + behaviour
├── store/
│   ├── boot.ex                    # NEW — dir, schema create/verify, migrations, write probe
│   ├── schema.ex                  # NEW — table specs as data (pure)
│   ├── migrations.ex              # NEW — ordered [{version, description, fun}]
│   ├── mnesia.ex                  # NEW — the ONLY :mnesia caller
│   ├── writer.ex                  # NEW — one transaction per durable boundary
│   ├── query.ex                   # NEW — history, detail, checkpoint, transcript, capacity
│   ├── health.ex                  # NEW — persistence breaker (thin GenServer, mirrors Ledger)
│   ├── records.ex                 # NEW — pure structs + tuple codecs
│   ├── ids.ex                     # NEW — pure repo_id / run_id / attempt_id derivation
│   ├── prune.ex                   # NEW — pure prune policy
│   ├── capacity.ex                # NEW — pure capacity policy
│   └── export.ex                  # NEW — pure single-file JSON encoder
│
├── run_manifest.ex                # DELETED (FR-037)
├── checkpoint.ex                  # DELETED (FR-037)
├── transcripts.ex                 # DELETED (FR-037, incl. the .speckit_logs copy)
│
├── application.ex                 # Store.Boot before children; Store.Health child
├── config.ex                      # + store_dir/0, store_capacity_bytes/0, store_headroom_bytes/0
├── repo_identity.ex               # + partition/1 (origin, else path-derived fallback)
├── coordinator.ex                 # :manifest seam → :store seam; Store.Health in advance/1
├── feature_runner.ex              # records attempts/checkpoints/transcripts; drains on Store.Health
├── analyze_runner.ex              # records remediation attempts + their transcripts
├── chunk_runner.ex                # records chunk attempts + substep position
├── phase_step.ex                  # transcript write → Store.Writer
├── describe.ex                    # write_pr/read_pr DELETED → feature_run.pr_description
├── recovery.ex                    # rebuild_layout/reconstruct → run.layout + Store.Query
├── recovery/evidence.ex           # checkpoint/pr/final-marker signals from the store
├── recovery/rebuild.ex            # rebuild proposal against the store record
├── ledger.ex                      # restore/2 seeded from cost-entry roll-up
├── live_config.ex                 # apply/1 records a settings amendment (FR-027)
├── telemetry.ex                   # + [:speckit, :store, :write_failed] and prune/capacity events
└── web/
    ├── router.ex                  # + /runs, /runs/:run_id
    └── live/
        ├── runs_live.ex           # NEW — history list (FR-030b)
        ├── run_detail_live.ex     # NEW — run detail (FR-030b)
        ├── mission_control_live.ex, pipeline_dag_live.ex,
        ├── escalations_live.ex, transcripts_live.ex   # re-pointed at the facade

lib/speckit_orchestrator.ex        # + run_history/1, run_detail/1, transcript/1, resumable/1,
                                   #   prune_preview/1, prune/1, export_run/3, store_capacity/0,
                                   #   resolve_escalation/2; run/resume/resume_run cut over

test/
├── support/store_case.ex          # NEW — shared temp schema, table clearing
├── speckit_orchestrator/store/    # NEW — records, ids, prune, capacity, export (async)
│                                  #       mnesia, boot, writer, query (async: false)
├── speckit_orchestrator/persistence_failure_test.exs   # NEW — FR-010 drain, SC-013
├── speckit_orchestrator/store_boundary_test.exs        # NEW — grep guards (SC-007)
└── (existing manifest/checkpoint/transcript tests replaced in place)
```

**Structure Decision**: single Elixir/OTP application, unchanged. All new code
lands under `lib/speckit_orchestrator/store/` behind one boundary module, exactly
as the harness contract is isolated today (Principle I). The pure/edge split
inside that directory is what keeps policy — capacity, pruning, export, record
decoding — unit-testable with no schema and no running node.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified

One constitution deviation and two deliberate behaviour changes. The deviation is
recorded because the Governance section requires it; the behaviour changes are
recorded because they are visible to the operator and to the target repository,
and should be reviewed as choices rather than discovered as side effects.

**Constitution deviation**

| Deviation | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| The Erlang **node name** is verified and recorded, not explicitly configured. The Persistence subsection says the node name "MUST be configured explicitly and be stable across restarts — the schema is keyed to both." This design accepts whatever `node()` is (`:nonode@nohost` under `mix run` / `iex -S mix`, verified to support a disc schema) | The clause exists so a schema belonging to a different node cannot be silently adopted — its own next sentence says startup finding a foreign schema "MUST fail loud … MUST NOT silently create an empty schema and present a repository as having no history." That purpose is met by verification instead of configuration: `Store.Boot` requires `node()` to appear in `:mnesia.table_info(:schema, :disc_copies)` **and** to match `speckit_meta`'s recorded `:node` row, aborting startup with `{:error, {:schema_node_mismatch, expected, found}}` naming both names (research R2). The name is stable across restarts by default, since nothing in the run path sets one | Forcing `--sname speckit` would add epmd and the whole distribution stack to the runtime surface of a store the same subsection mandates be single-node and machine-local — cost with no benefit. It also would not remove the need for the ownership check: a schema created under a *previously* configured name still has to be detected, so the verification is required either way and the explicit name adds nothing on top of it. Auto-creating a fresh schema on mismatch is barred outright by Principle II |

**Deliberate behaviour changes**

| Change | Why needed | Simpler alternative rejected because |
|--------|------------|--------------------------------------|
| Stop writing `<worktree>/.speckit_logs/` | FR-037 forbids a surviving second copy of the same fact, and `Worktree.commit/2` commits this directory onto the feature branch, so it outlives the worktree in the target repo's git history — it also puts raw tool output (which the spec's accepted-risk clause says may contain credentials) into that history | Keeping it as a read-only convenience copy still leaves a second surviving copy (FR-003/FR-037) and still commits transcripts into the target repo; nothing reads it programmatically today, and `/runs/:run_id` plus `transcript/1` replace the live-tail use case |
| `Store.Health` as a second breaker-like process | FR-010 requires drain-and-halt on a persistence failure, which must be observable from both the `Coordinator` (release nothing) and each `FeatureRunner` Task (halt between phases) — the same shape `Ledger` already solves for cost | Threading a failure flag through return values would put the check inside phase execution, risking a mid-phase abort (barred by FR-010); reusing `Ledger` itself would conflate a budget halt with a persistence halt in reporting, and the two need distinct reasons |
