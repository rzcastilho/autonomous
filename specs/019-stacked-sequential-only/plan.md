# Implementation Plan: Stacked Sequential Runs as the Only Behaviour

**Branch**: `019-stacked-sequential-only` | **Date**: 2026-07-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/019-stacked-sequential-only/spec.md`

## Summary

Collapse two run shapes into one and remove two configuration axes. Every run is
a stacked sequential PR run: one feature at a time, in ascending numeric order,
each branching from the previous completed feature's branch, each completed
branch published as a pull request against that base. There is no toggle, no
concurrency setting, and no dependency declaration — ordering has exactly one
input, the number the operator put in the filename.

Technical approach — subtraction, one new run state, and refusal at every edge.
`Release.next_wave/4` (features, statuses, cap, breaker) becomes
`Release.next/3` returning `{:release, feature} | :none | {:stopped, id, status}`;
that third return value is the whole feature in miniature, because it is what
lets the Coordinator tell "stopped at a broken link" from "nothing left to do" —
today both are an empty wave, which is exactly why stop-on-first-failure could
not be expressed. One-feature-at-a-time becomes a rule inside that function
("anything running ⇒ release nothing") rather than a cap defaulting to 1, so
FR-006's "structural property rather than a configured limit" is provable by
reading one function.

`Feature` loses `prereqs` and the `:blocked` status; it gains `number` (integer,
compared numerically so `002` and `0002` are duplicates and `1000` sorts after
`999`), `group` (`:backlog | :ad_hoc`), and `created_at`. `Backlog` loses its
entire dependency layer — `extract_prereqs/1`, `dependents/1`, the Kahn cycle
detector, `MissingPrereqError`, `CycleError` — and gains
`DuplicateNumberError`. A `## Prerequisites` section becomes inert prose.

A run that stops at a broken link is **parked**: a new `:parked` state on the
existing run record, holding which feature stopped it and why. Parking is
automatic; unparking is not. `resolve/2` gains a required `:decision` of
`:continue` or `:end`, and `Store.Writer.open_run/2` aborts its transaction
against a parked run rather than superseding it — which is what makes "no parked
run is ever lost" a transactional guarantee rather than a best-effort check.
`continue_run/1` is a state flip plus `resume_run/1`'s existing machinery, on
the same `run_id`.

Retired settings are **refused, not ignored**, at three independent edges,
because they are read at three different times: an allow-list on run-start
options, a boot-time application-environment check, and a `raise` in
`config/runtime.exs` for `SPECKIT_PR_WORKFLOW`/`SPECKIT_MAX_CONCURRENCY`.

This is a clean break with no compatibility layer (FR-022). Schema bumps to v2
with a *refusal migration*: registered in the same ordered list as every other
migration, but its function returns an incompatibility error, so a v1 directory
aborts startup naming the problem instead of being silently read or silently
destroyed. Persistence is reset by the operator before the upgrade; the first
run afterwards is run number one.

Two things are deliberately untouched. The gates, the breaker, and the bounded
auto-remediation loop decide whether a *feature* completes; this feature only
decides what the *run* does next. And `Pipeline.next/3`, `Remediation.next/2`,
`Ledger`'s arithmetic, `Worktree`, `TargetPack`, and the scope-guard hook see no
change at all.

## Technical Context

**Language/Version**: Elixir `~> 1.20`, pinned `1.20.2-otp-28` via
`.tool-versions`; OTP 28 system-provided (never mise-managed). Every command
through `mise exec --`.

**Primary Dependencies**: Jido `~> 2.2`; `jido_harness` + `jido_claude` pinned to
GitHub SHAs with `override: true`; Phoenix `~> 1.7` + LiveView `~> 1.0` on
Bandit; `phoenix_pubsub`. **No new dependency** — this feature adds none and
removes none.

**Storage**: Mnesia, single-node, machine-local, under `Config.store_dir/0`
(default `~/.autonomous/mnesia`). Schema version `1 → 2`; `speckit_run` gains a
state and two attributes, `speckit_feature` loses one and gains three. All
mutations transactional; no `:mnesia.dirty_*` writes.

**Testing**: ExUnit. Default suite hermetic — pure-core decisions tested through
injected seams (`:runner`, `:executor`, `:publisher`), store tests against a
temp-dir schema, LiveView tests through `Phoenix.LiveViewTest`. Real-harness work
stays behind `--include integration`. Coverage above 90% on the pure core.

**Target Platform**: macOS/Linux developer machine driving a sibling target repo
via the `claude` CLI. Single BEAM node.

**Project Type**: Single Elixir/OTP application with an embedded Phoenix LiveView
console (`lib/speckit_orchestrator/web/`). No frontend build step.

**Performance Goals**: Not a performance feature. One constraint holds:
`Release.order/1` and `Release.next/3` run on every release decision and must
stay O(n log n) over a backlog of tens of features — trivially satisfied by a
sort, and strictly cheaper than the Kahn topological walk they replace.

**Constraints**: `warnings_as_errors` is ON — a warning fails the build, which
matters here because deleting `prereqs`, `cap`, and `pr_workflow` will surface
unused-variable and unused-alias warnings across ~30 files. Refusal must precede
every side effect: a refused start supersedes nothing, opens nothing, and writes
nothing. A parked run must never be superseded, garbage-collected, or pruned.

**Scale/Scope**: ~20 `lib/` modules touched (7 substantially rewritten), 5
LiveViews, 2 config files, 1 schema version, ~45 test files, 5 docs. Two modules
deleted outright (`PipelineDagLayout`, and `RunContext`'s two mode helpers along
with `Coordinator.set_cap/2`).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Checked against constitution **2.1.0** (ratified 2026-07-11, last amended
2026-07-29). The three conditionals recorded below were resolved by amendment
2.0.0 → 2.1.0, which **landed before implementation started** rather than
shipping alongside it. They are retained here as the record of why the amendment
was needed; all three now read as PASS against 2.1.0.

| Principle | Verdict | Basis |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | **PASS** | `Release`, `Backlog`, `Feature`, `RunContext` stay free of CLI/harness/Jido/Mnesia. `Release.next/3` remains a pure decision over data with the breaker signal passed in, not read. The parked-run *decision* is pure (`{:stopped, …}`); only the parked-run *recording* touches the store, in the Coordinator. |
| **II. Fail Loud at Boundaries** | **PASS** (was CONDITIONAL — amendment 2.1.0) | 2.1.0 names three refusals this feature implements exactly: raise on numerically equal feature numbers, refuse a retired setting on every surface, refuse a record predating a recorded clean break. The retired dangling-prereq/cycle guards are gone from the principle's text. |
| **III. Least-Privilege Containment** | **PASS** | Untouched. The target pack, `scope_guard.py`, `settings.json`, and per-phase `PhaseRequest` permissions are unchanged. The pack/remote preflight becomes *unconditional* (FR-003), which strictly increases enforcement. |
| **IV. Cost-Bounded Autonomy** | **PASS** | `Ledger` arithmetic untouched. Drain-don't-kill preserved: `Release.next/3` rule 1 returns `:none` on a tripped breaker, and the halted in-flight feature then trips rule 2, so the chain stops for the right reason with no special case. |
| **V. Human-in-the-Loop Escalation** | **PASS** | Gates unchanged. Escalated/halted features still retain their worktree. `resolve/1` still lets a feature re-run on its existing branch; it gains a decision, which *adds* operator agency rather than removing it. A gate diversion is still never auto-retried — continuing is an explicit operator act. |
| **VI. Idiomatic Elixir/OTP** | **PASS** | Multi-clause pattern matching over the three `next/3` outcomes; tagged tuples throughout; `Backlog` raises only at the load boundary; the Coordinator stays a thin shell delegating to `Release`; new store writes are transactions. |
| **Technology Stack — Persistence** | **PASS** (was CONDITIONAL — amendment 2.1.0) | Single-node Mnesia, transactional, no new dependency, `disc_only_copies` unchanged for transcripts. 2.1.0 permits a refusal migration for a recorded clean break, provided the reason no transform exists is recorded in the plan — done in Complexity Tracking below and in `contracts/store-schema-v2.md`. The added ban on auto-deleting an incompatible store at startup is honoured: the reset is an operator action. |
| **Quality & Test Discipline** | **PASS** | Default suite stays hermetic; store tests use temp-dir schemas; coverage target holds; `warnings_as_errors` respected. |
| **Development Workflow** | **PASS** (was CONDITIONAL — amendment 2.1.0) | 2.1.0's worktree clause now reads "one feature at a time". Worktrees, `feature/NNN-slug` naming, scaffold travel, and the `specify init` prohibition are unchanged and still load-bearing. |

### The three conditionals — resolved by amendment 2.1.0

All three resolved to **one constitution amendment**, **2.0.0 → 2.1.0 (MINOR)**,
committed with its own Sync Impact Report before implementation began. Details
and justification in Complexity Tracking below. What each was, and what 2.1.0
now says:

1. **Principle II** names two guards by example: *"The backlog loader MUST raise
   on a dangling prerequisite or a dependency cycle at load time."* This feature
   retires prerequisites, making both guards vacuous. The principle itself —
   reject at the edge, never carry silently inward — is not relaxed; it is
   *strengthened* (three new loud refusals). The clause needs its subject
   replaced: raise on **duplicate feature numbers**.

2. **Technology Stack → Persistence** requires *"a recorded schema version plus
   `:mnesia.transform_table` migrations applied at startup"*. FR-022/FR-023
   require refusing a pre-change record rather than migrating it. The refusal
   migration (research R9) keeps evolution explicit and versioned while
   producing the mandated refusal; the section should acknowledge a refusal as a
   legitimate migration outcome for a recorded clean break.

3. **Development Workflow** states *"Parallelism across features uses git
   worktrees on `feature/NNN-slug` branches"*. Worktrees and branch naming
   survive; the parallelism does not. The clause should read that each feature
   runs in its own worktree on `feature/NNN-slug`, one at a time.

**Gate status: PASS.** No principle was violated in substance — the retired
clauses described mechanisms this feature removes, and each is replaced by an
equal-or-stronger guarantee. The net effect of 2.1.0 is more mandated loud
failures and fewer permitted silent ones, which is why it is MINOR (an expansion
of governance) rather than MAJOR (a relaxation, as 2.0.0 was).

### Post-Phase-1 re-check

Re-evaluated after `data-model.md` and the five contracts. **No new violations.**
Two design choices were specifically checked:

- *Does the parked state weaken Principle V?* No. A parked run is an explicit
  human handoff — the opposite of fabricating a resolution. FR-019a forbids the
  system from choosing on the operator's behalf, which is stronger than today,
  where a stopped run simply drained and left the operator to reconstruct what
  happened.
- *Does `Release.next/3` entangle decision with state?* No. It takes features,
  statuses, and a boolean; it returns a decision. The store write that records
  the park happens in the Coordinator, as `Store.Writer.close_run/3` already
  does — the same seam, the same layer.

## Project Structure

### Documentation (this feature)

```text
specs/019-stacked-sequential-only/
├── plan.md                        # This file
├── research.md                    # Phase 0 — R1..R10, all unknowns resolved
├── data-model.md                  # Phase 1 — entities, fields added/deleted, transitions
├── quickstart.md                  # Phase 1 — 7 runnable validation scenarios
├── contracts/
│   ├── run-start.md               # run/1 + run_spec/2: accepted, refused, preflight order
│   ├── release-policy.md          # Release.next/3 + order/1, the pure decision surface
│   ├── parked-run.md              # park / continue / end, and the new-work refusal
│   ├── backlog-order.md           # the numbering contract (FR-013's operator doc source)
│   └── store-schema-v2.md         # schema v2, refusal migration, reset procedure
├── spec.md                        # Input
└── tasks.md                       # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── feature.ex                     # REWRITE: -prereqs, -:blocked, +number/group/created_at
├── backlog.ex                     # REWRITE: delete dependency layer, +DuplicateNumberError
├── release.ex                     # REWRITE: next_wave/4 -> next/3 + order/1
├── run_context.ex                 # EDIT: 10 fields -> 8; delete stacked?/1, effective_max_concurrency/2
├── coordinator.ex                 # EDIT: -cap, -set_cap/2, +stopped_by, park on :stopped
├── config.ex                      # EDIT: delete pr_workflow?/0, max_concurrency/0
├── live_config.ex                 # EDIT: delete both fields from change type, validation, dispatch
├── single_spec.ex                 # EDIT: stamp group: :ad_hoc + created_at
├── stack_tracker.ex               # EDIT: docs only — advanced by :done backlog features
├── application.ex                 # EDIT: +boot-time retired-app-env check
├── console_read_model.ex          # EDIT: -prereqs, +group, +parked run projection
├── report.ex                      # EDIT: -blocked, +stopped_by in the iex table
├── speckit_orchestrator.ex        # REWRITE (facade): one run path; +continue_run/1, end_run/1;
│                                  #   resolve/2 :decision; retired-option refusal; parked guard
├── recovery/
│   ├── reconcile.ex               # EDIT: drop :blocked handling
│   ├── rebuild.ex                 # EDIT: drop prereq consistency check
│   └── report.ex                  # EDIT: -blocked
├── store/
│   ├── schema.ex                  # EDIT: speckit_run +stopped_by/+stopped_reason;
│   │                              #   speckit_feature -prereqs +number/+group/+created_at
│   ├── records.ex                 # EDIT: state/outcome/status unions
│   ├── migrations.ex              # EDIT: current_version 2 + refusal migration
│   ├── writer.ex                  # EDIT: +park_run/2, continue_run/1, end_run/2; open_run parked guard
│   ├── query.ex                   # EDIT: +parked_run/1
│   └── export.ex                  # EDIT: field changes
└── web/
    ├── components/layouts.ex      # EDIT: delete run_mode/1 + run_cap/1 (status bar)
    └── live/
        ├── trigger_live.ex        # EDIT: delete toggle + effective-concurrency line
        ├── config_live.ex         # EDIT: delete slider + toggle
        ├── mission_control_live.ex# EDIT: +parked banner with continue/end actions
        ├── pipeline_dag_live.ex   # REWRITE: DAG -> two-group ordered chain view
        └── pipeline_dag_layout.ex # DELETE: depth/edge layout has no subject

config/
├── config.exs                     # EDIT: delete :pr_workflow, :max_concurrency
└── runtime.exs                    # EDIT: raise when SPECKIT_PR_WORKFLOW / SPECKIT_MAX_CONCURRENCY set

test/speckit_orchestrator/
├── release_test.exs               # REWRITE to next/3 + order/1
├── backlog_test.exs               # REWRITE: -cycle/-dangling, +duplicate numbers, +gaps
├── coordinator_test.exs           # REWRITE: stop-on-first, no cap
├── retired_settings_test.exs      # NEW: three-surface refusal (SC-005)
├── parked_run_test.exs            # NEW: park / continue / end / refuse-new-work (US4, SC-009)
├── pr_workflow_test.exs           # RENAME -> stacked_run_test.exs, drop the toggle-off cases
├── (~40 further files)            # EDIT: drop prereqs/cap/pr_workflow from fixtures and assertions
└── fixtures/breakdown_cyclic/     # DELETE (+ breakdown_missing/): no longer error cases
    fixtures/breakdown_duplicate/  # NEW: two files, numerically equal numbers

docs/
├── breakdown-format.md            # EDIT: numbering contract (FR-013); prereqs now inert prose
├── runbook.md                     # EDIT: parked runs; the store reset procedure
├── workflow.md                    # EDIT: one run shape; chain, not DAG
├── speckit-orchestrator-implementation-plan.md  # EDIT: record 019
└── (.specify/memory/constitution.md)            # DONE: amended 2.0.0 -> 2.1.0 before implementation

CLAUDE.md                          # EDIT: Release/Backlog/Feature descriptions, run shape
```

**Structure Decision**: Single Elixir/OTP application with an embedded Phoenix
LiveView console — the existing layout, unchanged. This feature adds no new
top-level directory and no new dependency; it edits the pure core
(`feature.ex`, `backlog.ex`, `release.ex`, `run_context.ex`), the control plane
(`coordinator.ex`, the facade), the persistence boundary (`store/`), and the
console (`web/live/`). The one deletion, `pipeline_dag_layout.ex`, goes because
its entire subject — prerequisite depth — no longer exists.

Sequencing note for `/speckit-tasks`: the pure core must land first
(`Feature` → `Backlog` → `Release`), because everything downstream compiles
against those shapes and `warnings_as_errors` will not tolerate a half-migrated
tree. The store schema is second (it is what the Coordinator's park writes
into), the facade and Coordinator third, the console fourth, and docs last. The
constitution amendment is **already done** — it landed before implementation, so
no task depends on it.

## Complexity Tracking

> Filled because the Constitution Check raised three conditionals. All three were
> resolved by the **same single amendment**, **2.0.0 → 2.1.0 (MINOR)**, already
> committed with its own Sync Impact Report per the Governance section. Retained
> as the record of why the amendment was needed and what was rejected.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| **Principle II's backlog clause** — retiring `MissingPrereqError` and `CycleError`, which the principle names explicitly | FR-010 makes ordering have exactly one input, the numbering. Prerequisites cease to exist, so a guard against a dangling one guards nothing. The clause's *subject* is retired, not its *rule*: the loader still raises at load time, now on duplicate numbers (FR-012), and the feature adds two further loud refusals (retired settings, pre-019 records). | *Keep parsing prerequisites and validating them while ignoring them for ordering* — rejected: it preserves a parser, two exception types, and a Kahn walk that nothing consumes, and it makes a backlog with an inert prose cycle fail to load, directly contradicting the spec's assumption that prerequisite sections may remain as documentation. Dead validation that can still reject valid input is worse than no validation. |
| **Persistence clause requiring `transform_table` migrations** — v2's migration refuses instead of transforming | FR-022 forbids a compatibility path and FR-023 requires refusing a pre-change record by name. The reset guarantees no v1 record exists, so a real transform would be dead code that has never run and can never be tested against real data. The refusal is registered as an ordinary migration entry, so the version is still recorded, still ordered, still applied at startup — only its outcome is a loud error. | *Write a genuine v1→v2 `transform_table`* — rejected: FR-022 forbids the compatibility path outright, and an untestable, never-executed migration is a liability that invites someone to trust it later. *Skip the version bump and change tables in place* — rejected as strictly worse: a v2 build would read a differently-shaped v1 record as its own, which is the silent-bad-state failure Principle II exists to prevent. *Auto-delete the store directory at boot* — rejected: the constitution forbids handling state incompatibility by silently dropping recorded state. |
| **Development Workflow's parallelism clause** | FR-006 makes one-feature-at-a-time a structural property. Worktrees and the `feature/NNN-slug` branch convention are unchanged and still load-bearing (each feature is isolated, and the chain is built from those branches); only the concurrency the sentence assumes is gone. | *Leave the sentence and treat it as historical* — rejected: the constitution is described as runtime guidance for autonomous and human contributors alike, and a clause promising parallelism would send both toward a capability the system refuses to provide. |

**Not** recorded as violations, having been checked and found compliant: the
Coordinator remaining a plain `GenServer` (already a recorded deviation,
unchanged by this feature); the parked state adding a lifecycle rather than a
table (Principle VI, one record one state); and the unconditional PR-remote
preflight (Principle III, strictly more enforcement than before).
