# Implementation Plan: Publish Integrity

**Branch**: `027-publish-integrity` | **Date**: 2026-09-23 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/027-publish-integrity/spec.md`

## Summary

The mod-player incident (2026-09-23) had one root cause and two amplifiers.

- **Root cause.** The target's mandatory speckit git hook moved the worktree off the orchestrator's branch during `specify`.
- **First amplifier.** Nothing read HEAD afterwards, so every commit landed on the stray branch.
- **Second amplifier.** The best-effort publish advanced the stack onto an empty branch, and the next feature was built without its predecessor.

The plan closes each one:

1. **Branch-drift gate (US2).** After every session (phase, analyze run, implement chunk, remediation), a pure `BranchGuard.check/2` compares `Worktree.current_branch/1` to the orchestrator's branch. Drift fails the phase with `{:branch_drift, phase, %{expected, observed}}`. It is never retried, and no git write follows it.
2. **Publish stops the chain (US1).** The publisher first proves the branch has commits beyond the base the PR targets. Any backlog publish failure, normalized to `{:publish_failed, kind, detail}`, is converted by `pr_notify` from `:done` to `:failed`. The stack does not advance, and the Coordinator's existing stop/park path parks the run. `continue_run/1` resumes a publish-failed feature on a **publish-only** route, with no phases re-run.
3. **Branch pin (US3).** The specify prompt passes `GIT_BRANCH_NAME=feature/<spec_id>-<slug>` with reuse semantics.

Plus one latent bug found while tracing: `stack_seed/1` names chain branches by backlog number instead of `spec_number`, which silently collapses a continued chain to the trunk. It is fixed because US1's continue depends on it.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28 (via `mise exec --`)

**Primary Dependencies**: Jido / `jido_harness` (`:claude` provider), Phoenix LiveView (console), `gh` CLI and `git` (via `System.cmd`)

**Storage**: Mnesia store (`Store.Writer`). **No schema migration.** New facts live in the existing `terminal_reason` / `stopped_reason` term columns (research R4).

**Testing**: ExUnit. Seam-injected stacked runs (`:publisher`, `:executor`), real temp git repos for `Worktree` and the empty-branch check, and a stubbed harness stream for drift.

**Target Platform**: macOS/Linux BEAM host driving target repos through git worktrees

**Project Type**: OTP control plane (library + LiveView console)

**Performance Goals**: Drift check adds ≤2 `git` invocations per session. Publish adds 1 `rev-list`.

**Constraints**: `warnings_as_errors`; the design-contract guard stays green; no new status atom; drain-don't-kill is untouched.

**Scale/Scope**: About 12 modules touched (see Structure). No new process, and no new persistence.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Pure Core, Isolated Contracts | ✅ Decisions are pure: `BranchGuard.check/2`, the new `Pipeline.next/3` / `Chunking.next/2` clauses, and `PublishOutcome.describe/1`. Git reads stay in `Worktree`. Gate signals are extracted upstream and passed in. |
| II. Fail Loud at Boundaries | ✅ This is the core of the feature. An unreadable HEAD counts as drift, and an unverifiable branch counts as unpublishable (both fail closed). A publish failure parks the run instead of being swallowed. |
| III. Least-Privilege Containment | ✅ Unchanged. The orchestrator's own git calls already bypass the scope guard by design (`PullRequest` moduledoc), and the new calls are reads plus the existing push. |
| IV. Cost-Bounded Autonomy | ✅ This strengthens the principle: drift stops spend immediately (SC-003), and a broken chain no longer spends on the next feature. The breaker and drain paths are untouched, and a publish-failure park spends nothing. |
| V. Human-in-the-Loop Escalation | ✅ Non-`:done` terminals keep the worktree (drift). The publish-failed branch is kept, and the operator resolves via `continue_run/1` / `end_run/1` / `resolve/1`. No gate is relaxed. |
| VI. Idiomatic Elixir/OTP | ✅ Tagged tuples, a multi-clause pure decision function, `with` pipelines in the publisher, no new processes. |
| VII. Operator Surfaces Tell the Truth | ✅ Reasons render with real identifiers (`publish_failed :push_failed`, branch names, `gh pr create`) and verbatim tool output. No new colour, status or token, and no inline style. |

**Result: PASS.** Constitution amendment: none (the behaviour tightens existing gates). **Post-design re-check (after Phase 1): PASS.** The contracts added no process, no schema version, no status atom and no configuration key (FR-015).

## Project Structure

### Documentation (this feature)

```text
specs/027-publish-integrity/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── branch-guard.md
│   ├── publish-outcome.md
│   ├── specify-branch-pin.md
│   └── operator-surfaces.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── branch_guard.ex                 # NEW: pure check/2 (US2)
├── publish_outcome.ex              # NEW: pure describe/1 + normalize helpers (US1, surfaces)
├── worktree.ex                     # current_branch/1, commits_beyond/3, branch_name/1 (locate uses it)
├── actions/run_feature_phase.ex    # drift extraction + first classify clause
├── actions/run_auto_remediation.ex # drift check after reduce
├── actions/run_remediation.ex      # drift check after reduce
├── phase_step.ex                   # retry_reason: branch_drift never retried
├── pipeline.ex                     # next(phase, :error, %{branch_drift: d})
├── chunking.ex                     # first row: branch_drift → failed
├── chunk_runner.ex                 # skip boundary commit on drift; pass signal
├── feature_runner.ex               # handle_worktree: no commit on drift terminal
├── phase_request.ex                # specify prompt: GIT_BRANCH_NAME pin
├── report.ex                       # format_reason → PublishOutcome.describe
├── telemetry.ex                    # publish.failed logger uses describe; kind in metadata
└── web/live/{mission_control,run_detail,runs}_live.ex   # describe-or-inspect
lib/speckit_orchestrator.ex         # publish_feature/3 (pr_url short-circuit, empty check,
                                    #   normalized errors), pr_notify/5 (chain stop),
                                    #   resume/2 publish-only route, stack_seed/1 spec_id fix

test/speckit_orchestrator/
├── branch_guard_test.exs           # NEW
├── publish_outcome_test.exs        # NEW
├── worktree_test.exs, run_feature_phase_test.exs, phase_step_test.exs,
│   pipeline_test.exs, chunking_test.exs, chunk_runner_test.exs,
│   feature_runner_test.exs, phase_request_test.exs,
│   stacked_run_test.exs, resume_test.exs              # extended
docs/runbook.md                     # "Publish failure parked the run" + "Branch drift" recovery
CLAUDE.md                           # one paragraph under Control plane / Pipeline gates
```

**Structure Decision**: This is the existing single-project OTP layout. Two new pure modules sit beside their peers (`BranchGuard` next to `Pipeline`/`Chunking`; `PublishOutcome` next to `Report`). Everything else is an edit at the call sites named in research R2–R10.

## Delivery order

1. **US1 first (P1, MVP).** `Worktree.commits_beyond/3`, the normalized publisher, the `pr_notify` stop, the `stack_seed` fix, the publish-only continue route, `PublishOutcome.describe/1` and the surfaces. On its own, this would have bounded the incident to one feature.
2. **US2 (P1).** `Worktree.current_branch/1`, `BranchGuard`, the `RunFeaturePhase` clause, `Pipeline` / `PhaseStep` / `Chunking` / `ChunkRunner` / `FeatureRunner` propagation, and the remediation actions.
3. **US3 (P2).** `Worktree.branch_name/1` and the specify prompt pin.
4. **Docs.** Runbook recovery steps and the CLAUDE.md summary.

## Complexity Tracking

No constitution violations. Nothing to justify.
