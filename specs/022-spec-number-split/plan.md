# Implementation Plan: Spec Number Split

**Branch**: `022-spec-number-split` | **Date**: 2026-09-04 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/022-spec-number-split/spec.md`

## Summary

Separate the **wave-local feature number** (canonical identity: store key,
operator label, breakdown filename, release ordering) from a new
**repo-monotonic spec number** (spec directory, branch name, artifact
resolution), and add two independent nets against silent false-green phases.

Technical approach, in three separable pieces:

1. **Identity.** `Feature` gains `spec_number`. It is allocated once, before the
   feature's first phase and before its worktree exists, as one past the highest
   conforming `NNN-slug` directory on the base git ref (`git ls-tree`), and
   recorded durably under schema v5 (backfilled from `number` for pre-022 rows).
   A fresh allocation whose directory already exists refuses by name.
2. **Net one — resolution.** All three of `SpecDir`'s candidates are constrained
   to the feature's own spec id, including the `.specify/feature.json` candidate
   that currently carries the *previous* feature's directory into a stacked
   worktree. An ambiguous prefix match is unresolved, never ordered.
3. **Net two — empty checkpoint.** A new pure `Checkpoint` decision table fails
   `:specify`/`:plan`/`:tasks` when the boundary commit is `:noop` **and** the
   phase's artifact was absent when the phase started.

The three pieces share no code and no signal, which is what makes SC-007
(each net catches the failure alone) mechanically true.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28, pinned via `.tool-versions`; every
command through `mise exec --`.

**Primary Dependencies**: Jido `~> 2.2`, `jido_harness` / `jido_claude` (GitHub
SHAs), Phoenix `~> 1.7` + LiveView `~> 1.0`, Bandit. **No new dependency.**

**Storage**: Mnesia, single-node, machine-local. This feature appends one
attribute to `speckit_feature_run` under schema version 5.

**Testing**: ExUnit. Default suite hermetic (own temp Mnesia schema);
real-harness work behind `--include integration`. Coverage target >90% on the
pure core; the two new pure modules are total decision tables and reach 100%.

**Target Platform**: macOS/Linux developer machine running the orchestrator
against a sibling target repository.

**Project Type**: Single Elixir/OTP application (control plane + LiveView
console), no Node/npm build step.

**Performance Goals**: N/A. Allocation adds exactly one `git ls-tree` per
feature run; the arming probe adds one `File.regular?` per armed phase.

**Constraints**: `warnings_as_errors` is ON. The pure core must not depend on
the CLI, the harness, Jido, or Mnesia. No new operator-surface color, radius,
font-size, or spacing literal (`test/support/design_contract.ex` fails loud).

**Scale/Scope**: ~2 new pure modules, ~10 modified modules, 1 schema migration,
3 operator surfaces. Waves of 7–20 features against one target repository.

## Constitution Check

*GATE: passed before Phase 0; re-evaluated after Phase 1 design — still passes.*

| Principle | Verdict | Evidence |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | PASS | `SpecNumber` and `Checkpoint` are new pure modules with no IO. Allocation's only IO is `Worktree.spec_dirs/2` (git, at the existing git boundary); the empty-checkpoint signal is probed upstream in `RunFeaturePhase` and passed in, exactly as every existing gate signal is. Neither new module touches Mnesia. |
| **II. Fail Loud at Boundaries** | PASS | FR-003a is a named refusal (`{:spec_dir_exists, entry}`) that stops the feature before its first phase. A second allocation aborts (`{:already_allocated, …}`). Migration 5 is explicit and versioned; the v2 refusal migration and the unknown-version abort are untouched. Nothing is dropped, truncated, or auto-deleted. |
| **III. Least-Privilege Containment** | PASS | No change to `priv/target_pack/`, `scope_guard.py`, `settings.json`, or per-phase permissions. Allocation runs in the orchestrator, not in a model session. |
| **IV. Cost-Bounded Autonomy** | PASS | Allocation and the checkpoint verdict cost nothing and reserve nothing. Net two failing a phase *saves* the spend that phase's downstream would have burned — the observed failure cost ~20 minutes of `analyze`, auto-remediation, and a zero-length `implement`. Drain-don't-kill order at the boundary is preserved (see below). |
| **V. Human-in-the-Loop Escalation** | PASS | No gate changes. The empty-checkpoint verdict produces `:failed` — an existing terminal status — not a gate diversion, and is not retried past a human. The clarify and analyze gates, the remediation loop, thresholds, and the exhaustion policy are untouched. A failed feature keeps its worktree for post-mortem, unchanged. |
| **VI. Idiomatic Elixir/OTP** | PASS | Two multi-clause pure decision tables; tagged tuples throughout; `with` on the allocation pipeline; `@spec` on every new public function; no new process, no new supervision. |
| **VII. Operator Surfaces Tell the Truth** | PASS *(conditional)* | FR-008 adds `spec_number` beside `number` on the run report, `RunDetailLive`, and the PR body, under the record's real field names (no friendly renames), rendered mono as machine values, `not allocated` when absent. No new token, no new color, no animation. `design_contract_test.exs` must stay green — enforced as an exit criterion. |

**Persistence subsection**: transaction-per-boundary preserved (§Phase-boundary
ordering); storage type unchanged (`disc_copies`); export carries the new field
with no export-code change; the pure core still does not depend on Mnesia.

**Phase-boundary ordering note.** `FeatureRunner.loop/12`'s `{:cont, next}`
branch is reordered so the boundary commit runs *before* `record_attempt/9`
(research R7). This keeps one transaction per boundary and keeps the record
written before recursing; the breaker and persistence drain checks stay exactly
where they are, after the commit and before the next phase. Principle IV's
drain-don't-kill behaviour is unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/022-spec-number-split/
├── plan.md                              # This file
├── spec.md                              # Input
├── research.md                          # Phase 0 output
├── data-model.md                        # Phase 1 output
├── quickstart.md                        # Phase 1 output
├── checklists/                          # From /speckit-specify
├── contracts/                           # Phase 1 output
│   ├── spec-number-allocation.md
│   ├── spec-dir-resolution.md
│   ├── empty-checkpoint.md
│   └── store-schema-v5.md
└── tasks.md                             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── spec_number.ex                       # NEW — pure allocation decision table
├── checkpoint.ex                        # NEW — pure empty-checkpoint table
├── feature.ex                           # + :spec_number, spec_id/1, spec_label/1
├── spec_dir.ex                          # candidates constrained to spec_id (net one)
├── worktree.ex                          # locate/2 composes from spec_id; + spec_dirs/2
├── feature_runner.ex                    # boundary reorder + Checkpoint verdict
├── phase_request.ex                     # SPECIFY_FEATURE_DIRECTORY uses spec_id
├── report.ex                            # wave + spec number on the report line
├── backlog.ex                           # spec_number: nil (explicit); guard confirmed
├── single_spec.ex                       # spec_number: nil (explicit)
├── recovery.ex                          # store record -> %Feature{} carries spec_number
├── actions/
│   └── run_feature_phase.ex             # artifact_absent_at_start? probe (net two)
├── store/
│   ├── schema.ex                        # + :spec_number attribute
│   ├── migrations.ex                    # + migration 5, current_version -> 5
│   ├── records.ex                       # FeatureRun struct + encode/decode
│   ├── writer.ex                        # + record_spec_number/3
│   └── query.ex                         # spec_number in run_detail/1
├── store.ex                             # + spec_number/2 read
├── web/live/
│   ├── run_detail_live.ex               # both numbers, mono, "not allocated"
│   └── escalations_live.ex              # hand-built %Feature{} carries spec_number
└── ../speckit_orchestrator.ex           # allocation in the executor seam; PR body header

test/speckit_orchestrator/
├── spec_number_test.exs                 # NEW
├── checkpoint_test.exs                  # NEW
├── spec_number_split_regression_test.exs # NEW — FR-017
├── spec_dir_test.exs                    # net one cases
├── feature_runner_test.exs              # net two at the boundary
├── worktree_test.exs                    # spec_dirs/2, locate/2 naming
├── backlog_test.exs                     # FR-016 confirmation
├── store/{writer,migrations,query}_test.exs
├── report_test.exs
└── web/…                                # surface rendering

docs/
├── runbook.md                           # operator: reading both numbers, the new refusal
└── workflow.md                          # the two nets in the phase loop
CLAUDE.md                                # Feature/SpecDir/schema-version descriptions
```

**Structure Decision**: single Elixir project, existing layout. Both new modules
land in the pure core (`lib/speckit_orchestrator/`) beside `Pipeline`,
`Release`, `Severity`, and `Remediation` — the established home for
side-effect-free decision tables. No new directory, no new application, no new
supervision child.

## Design summary

Full detail in `contracts/`; this is the shape.

**Allocation** (`contracts/spec-number-allocation.md`). In the executor seam,
per feature, before `Worktree.create/2`: reuse `Store.spec_number/2` when
present; otherwise `Worktree.spec_dirs(repo, base)` →
`SpecNumber.allocate(entries, slug)` → `Writer.record_spec_number/3`. Any
failure notifies `:failed` with a `{:spec_number, reason}` term and runs no
phase. Reuse deliberately skips the existence check — an existing directory is
the expected case there (FR-003a's carve-out).

**Naming.** `Feature.spec_id/1` composes the spec directory, the branch, the
worktree path, and `SPECIFY_FEATURE_DIRECTORY`. `feature.id` keeps every other
job it has: store key, telemetry `feature_id`, log lines, and the boundary
commit subject `speckit: <id> checkpoint after <phase>` that
`Recovery.Evidence`'s `@boundary_re` parses.

**Net one** (`contracts/spec-dir-resolution.md`). Candidate 1 composed from
`spec_id`; candidate 2 (`.specify/feature.json`) accepted only when its
basename's numeric prefix equals `spec_id`; candidate 3 (`specs/<spec_id>-*`)
accepted only on exactly one match. Downstream meanings of `nil` are unchanged.

**Net two** (`contracts/empty-checkpoint.md`). `RunFeaturePhase` probes
`SpecDir.file/3` for `%{specify: "spec.md", plan: "plan.md", tasks: "tasks.md"}`
before issuing the request and emits `artifact_absent_at_start?`.
`Checkpoint.verdict/3` turns `{phase, absent?, commit_result}` into `:advance`
or `{:failed, {:empty_checkpoint, phase}}`. Not retried.

**Schema** (`contracts/store-schema-v5.md`). Append `spec_number`, backfill from
the row's own `number`, `current_version/0` → 5.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| `Feature.spec_id/1` falls back to `id` when `spec_number` is `nil`, rather than raising (Principle II's "reject at the edge" read strictly) | Path composition is reached by dry runs and the pure unit suite, which legitimately have no spec number, and by wave-1 features where the two numbers coincide by arithmetic. The real edge is "the executor must not create a worktree for an unallocated feature" — allocation refuses there, loudly, naming the feature, before any path is composed. | *Raising in `spec_id/1`* moves the failure to a call site that cannot report which feature or why, and breaks every dry-run and unit-test path for no added safety — allocation has already refused by then in production. *A `nil`-returning single accessor* lets `"specs/#{nil}-slug"` interpolate silently, which is the failure class this whole feature exists to remove. Mitigation: the fallback is documented at the function, and `spec_label/1` (the surface accessor) returns `nil` so no operator surface can borrow the wave number. |

No other deviation. No new dependency, no new process, no gate change, no
constitution amendment required — the spec's own Assumptions record that the
per-wave uniqueness guard (FR-016) is confirmed and tested rather than changed.
