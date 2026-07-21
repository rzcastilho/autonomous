# Implementation Plan: Self-Sufficient Resume (Checkpoint Carries Identity + Run Context)

**Branch**: `007-resume-self-sufficient` | **Date**: 2026-07-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-resume-self-sufficient/spec.md`

## Summary

Two resume defects, one root cause: the checkpoint does not carry everything a
resume needs, so `resume/2` leans on the live backlog (for identity) and the live
process environment (for run-shaping context). Fix by making the checkpoint
**self-sufficient**: extend the durable per-feature record with (a) the feature's
**identity** (slug + breakdown/artifact path) so `resume/2` can rebuild the
work-unit from the id alone, and (b) the **run context** (pr_workflow, concurrency
cap, budget, plan_stack, pr_base, pr_remote) captured at run start so a resume
re-executes under the original run shape. Precedence is fixed and documented:
explicit `resume` option > recorded checkpoint value > live env/Config/default;
missing recorded values fall back to live config with an observable log line
(fail-loud-at-boundary). All existing distinct failure outcomes (no-checkpoint,
corrupt, unknown-phase, unknown-feature, branch-missing) are preserved, and the
current `resume/2` signature stays backward compatible (id-only form is additive).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned in `.tool-versions`; run via
`mise exec --`). `warnings_as_errors` ON.

**Primary Dependencies**: Jido/OTP (control plane), `jido_harness` + `jido_claude`
(data plane, GitHub-pinned), Jason (checkpoint JSON).

**Storage**: One JSON file per feature at
`<Config.transcript_root>/<feature_id>/checkpoint.json` (extended in place — no
new store).

**Testing**: ExUnit (`mise exec -- mix test`); pure-core coverage target >90%;
real-harness paths behind `--include integration`.

**Target Platform**: BEAM / local operator `iex` session.

**Project Type**: Single Elixir library/CLI control plane.

**Performance Goals**: N/A (operator-invoked resume; not a hot path).

**Constraints**: Checkpoint write stays best-effort (never breaks a run). No
secrets/credentials in the persisted record. No `String.to_atom/1` on file
contents (atom-table safety — reuse the existing `String.to_existing_atom` +
`Pipeline.phase?/1` guard).

**Scale/Scope**: Small, surgical. Touches `Checkpoint`, `FeatureRunner` (write
site + a threaded `run_context`), the `SpeckitOrchestrator` facade (`resume/2`
identity reconstruction + context reapplication + PR-workflow routing), one new
pure `RunContext` module, and the runbook doc (FR-012).

## Constitution Check

*GATE: passed before Phase 0; re-checked after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | New `RunContext` is a pure struct + capture/merge helpers (no IO). Checkpoint IO stays in `Checkpoint`; resume orchestration stays in the facade. Serialization boundary (map ↔ JSON) is isolated in `Checkpoint`. **Pass.** |
| **II. Fail Loud at Boundaries** | All five distinct failure outcomes preserved and start no run (FR-005). Corrupt checkpoint never fabricates identity/context (edge: corrupt). Missing/partial context falls back to live config **and logs** the fallback (FR-008) — a visible boundary event, not a silent default. **Pass.** |
| **III. Least-Privilege Containment** | No change to the enforcement pack or CLI permissions. Persisted context is explicitly secret-free (FR-011). **Pass.** |
| **IV. Cost-Bounded Autonomy** | Budget is part of the recorded context; a resumed run reapplies the original budget so the `Ledger` breaker governs it identically. No change to reserve/trip/drain semantics. **Pass.** |
| **V. Human-in-the-Loop Escalation** | `resume/2` **is** the human resolution path; this feature makes it id-only. Escalated/halted worktrees still retained; identity recovered from the checkpoint the diversion wrote. **Pass.** |

**Quality gates**: mise-only commands; warnings-as-errors respected; pure
`RunContext` unit-tested; checkpoint round-trip + resume precedence tested through
existing seams (`:features`, `:runner`/`:executor`) with no CLI dependency; the
default suite stays hermetic. **No violations — Complexity Tracking empty.**

## Project Structure

### Documentation (this feature)

```text
specs/007-resume-self-sufficient/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── checkpoint.md    # Extended Checkpoint write/read record
│   ├── run_context.md   # New RunContext module contract
│   └── resume.md        # resume/2 identity + context precedence contract
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── run_context.ex          # NEW — pure: capture(opts) + merge/precedence + to_map/from_map
├── checkpoint.ex           # EXTEND — persist/read identity (slug, path) + context map
├── feature_runner.ex       # EXTEND — accept :run_context, pass it into Checkpoint.write
├── feature.ex              # (read-only) work-unit rebuilt from checkpoint identity
└── speckit_orchestrator.ex # EXTEND — resume/2: id-only identity recovery + context reapply
                            #          + PR-workflow-aware runner/executor selection

test/speckit_orchestrator/
├── run_context_test.exs        # NEW — pure capture/merge/precedence + round-trip
├── checkpoint_test.exs         # EXTEND — identity + context round-trip; corrupt/partial
└── speckit_orchestrator_resume_test.exs # EXTEND — id-only resume, context reapply,
                                         #          precedence, PR-workflow routing, fallbacks

docs/runbook.md             # EXTEND — document id-only resume as the canonical form (FR-012)
```

**Structure Decision**: Single Elixir project, existing layout. One new pure
module (`RunContext`) keeps the run-shaping settings in one typed place and keeps
the merge/precedence logic unit-testable off the IO path (Principle I). Everything
else is a surgical extension of the three modules already on the resume path.

## Complexity Tracking

> No constitution violations. Section intentionally empty.
