# Implementation Plan: Pre-phase remediation prompt at resume

**Branch**: `013-resume-pre-phase-prompt` | **Date**: 2026-07-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/013-resume-pre-phase-prompt/spec.md`

## Summary

Add an **optional, operator-supplied remediation step** that runs as its own
model execution *before* the target phase when resuming a feature. Motivating
case: a feature halted at `analyze` on a Critical/High finding. `analyze` is
read-only — re-running it alone changes nothing. The remediation step hands the
model a short instruction ("fix the money-type Critical the gate flagged"),
lets it edit the artifacts in the existing worktree, and only then re-runs the
target phase so the gate re-evaluates the corrected work — turning a halt into a
one-command recovery.

**Technical approach**: the step is a discrete model execution owned by the
`FeatureAgent` (new `RunRemediation` action + `"remediation.run"` signal),
driven **once** by the `FeatureRunner` *before* the phase loop when a non-blank
`remediation_prompt` is present. It reuses every existing seam — the pure
`PhaseRequest` builder (new `build_remediation/3`), `Cost`/`Ledger` accounting,
`run_phase_with_retry` transient-retry policy, the `:telemetry` span, and
`Transcripts.write` — so it is observable, cost-bounded, and contained on par
with a phase with no new infrastructure. It is threaded through `resume/2` via
two new opts (`:remediation_prompt`, `:remediation_model`), strictly independent
of the existing `:prompt` in-phase note (feature 004).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned `.tool-versions`; run via `mise exec --`)

**Primary Dependencies**: Jido/OTP (control plane), `jido_harness` + `jido_claude` `:claude` adapter (data plane, pinned to GitHub SHAs), `:telemetry`

**Storage**: Filesystem — per-feature git worktrees, durable transcripts under `%Layout{}.transcript_root`, JSON checkpoint/manifest (no DB)

**Testing**: ExUnit; hermetic default suite via `FakeSDK` (`:jido_claude, :sdk_module` swap) + injectable `:runner`/`:executor` seams; `--include integration` for real-harness

**Target Platform**: BEAM (local operator CLI / iex)

**Project Type**: Single project — autonomous spec-driven build pipeline (control plane + enforcement pack)

**Performance Goals**: N/A (operator-paced, cost-bounded by the `Ledger` breaker, not throughput-bound)

**Constraints**: `warnings_as_errors` ON; pure core >90% coverage; remediation must add **zero** cost/execution to the no-prompt resume path (SC-002); containment no weaker than a phase (FR-009)

**Scale/Scope**: One remediation step per resume; ~6 source files touched, all additive; no new deps

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How this feature complies |
|-----------|--------|---------------------------|
| **I. Pure Core, Isolated Contracts** | ✅ PASS | Remediation request assembly is a **pure** `PhaseRequest.build_remediation/3` (no IO/CLI), unit-testable like the phase builder. The "run it or not" decision is a side-effect-free blank check. All harness contact stays in the `RunRemediation` action shell. |
| **II. Fail Loud at Boundaries** | ✅ PASS | An unknown `:remediation_model` alias is rejected loudly (not silently defaulted). A genuine remediation failure surfaces and stops the resume (FR-006/SC-005) — never a silent proceed. Blank prompt → no-op is a *defined semantic* (FR-004), not swallowed bad input. |
| **III. Least-Privilege Containment (Fail-Closed)** | ✅ PASS | The step runs under the same committed `scope_guard` hook; its `PhaseRequest` permissions are a write-capable-but-contained set (accept_edits + Read/Write/Edit/Bash/Grep/Glob), **no weaker** than a write phase (FR-009). An operator prompt cannot broaden reach. |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | ✅ PASS | Remediation spend is recorded to the `Ledger` exactly like a phase (`Cost.for_phase/2` → `Ledger.record`), counted toward the run budget and the breaker (FR-008). No new unbounded execution path. |
| **V. Human-in-the-Loop Escalation** | ✅ PASS | The step is **strictly opt-in** (operator supplies the prompt) — the model never decides to run a fixing pass. No auto-loop: a re-run gate that re-diverts halts/escalates to the human again (FR-007). Strengthens HITL. |

**Result**: PASS — no violations. Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/013-resume-pre-phase-prompt/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output — design decisions
├── data-model.md        # Phase 1 output — entities / agent state / control flow
├── quickstart.md        # Phase 1 output — validation scenarios
├── contracts/
│   └── resume-remediation.md   # Phase 1 output — resume/2 opts + step contract
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── speckit_orchestrator.ex        # resume/2: + :remediation_prompt / :remediation_model
│                                  #   opts; thread through resume_runner/4 & resume_executor/4
├── phase_request.ex               # + build_remediation/3 (pure builder: model, write perms,
│                                  #   operator-prompt framing)
├── feature_agent.ex               # + remediation_prompt / remediation_model state fields;
│                                  #   + {"remediation.run", Actions.RunRemediation} route
├── feature_runner.ex              # run the remediation step once before the loop; on
│                                  #   post-retry failure → finalize :failed, keep worktree, notify
├── actions/
│   ├── init_feature.ex            # seed remediation_prompt / remediation_model into state
│   └── run_remediation.ex         # NEW — harness shell: build → run → fold cost/history
└── config.ex                      # remediation model resolution + validation; cost estimate
                                   #   for the :remediation step

test/speckit_orchestrator/
├── phase_request_test.exs         # build_remediation/3: model, perms, prompt framing, blank
├── run_remediation_test.exs       # NEW — action folds cost/history; error outcome on failure
├── feature_runner_test.exs        # step runs once, before phase; blank = no step; failure
│                                  #   stops resume (:failed, worktree kept); retry on transient
└── resume_test.exs                # resume/2 threads opts; independent of :prompt (FR-010)
```

**Structure Decision**: Single-project Elixir layout (Option 1). All changes are
**additive** onto the existing resume machinery (features 002–007) and the
`FeatureAgent`/`FeatureRunner` phase loop. No new top-level modules beyond the
one `RunRemediation` action; the remediation step deliberately reuses the phase
execution, cost, telemetry, transcript, and retry seams rather than duplicating
them.

## Complexity Tracking

*No constitution violations — no entries required.*
