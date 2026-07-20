# Implementation Plan: Resume Facade (`resume/2` operator entry point)

**Branch**: `005-resume-facade` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-resume-facade/spec.md`

## Summary

Add `SpeckitOrchestrator.resume(feature_id, opts \\ [])` — the single
operator-facing entry point that restarts one halted/escalated feature at its
checkpointed phase, reusing the feature branch and the human's committed fix,
instead of the full-restart `resolve/1` path. It wires together three
already-built prerequisites — checkpoint persistence (`Checkpoint.read/1`), the
runner resume entry point (`FeatureRunner.run` `:start_phase`/`:resume_prompt`),
and branch-reusing worktree recreation (`Worktree.create`) — behind the same
one-feature-wave + runner-wrapper pattern already proven by `run_spec`. All
failure modes (no checkpoint, corrupt checkpoint, unknown feature id, invalid
`:from` override, missing branch) return their own distinct result and start no
run (Principle II — fail loud at boundaries).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned via `.tool-versions`; run through `mise exec --`)

**Primary Dependencies**: Existing pure/control-plane modules only — `Checkpoint`, `FeatureRunner`, `Worktree`, `Pipeline`, `Coordinator`, `Config`, `Ledger`, `Backlog`. No new external deps.

**Storage**: Reads the existing checkpoint JSON at `<Config.transcript_root>/<feature_id>/checkpoint.json` (read-only; shape unchanged by this feature).

**Testing**: ExUnit (`mise exec -- mix test`); unit via injected `:runner` seam (hermetic, no CLI/worktree). `warnings_as_errors` ON.

**Target Platform**: BEAM / local operator `iex` session.

**Project Type**: Single project (Elixir OTP app), CLI/facade surface.

**Performance Goals**: N/A — a single interactive operator call that starts one wave; no throughput target.

**Constraints**: Must not re-execute already-completed phases (SC-002); must not clobber the operator's committed fix; `resolve/1` (full-restart path) must remain unchanged and distinct (FR-009).

**Scale/Scope**: One feature per call (FR-010). One new public function + private resume-runner wrapper; no new modules expected.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Pure Core, Isolated Contracts** — PASS. Phase-string→atom validation
  reuses `Pipeline.phases/0` (pure). The facade stays in the impure boundary
  layer (`SpeckitOrchestrator`), alongside `run/1`/`resolve/1`; no CLI/harness
  contract leaks into pure modules. No pure module is changed.
- **II. Fail Loud at Boundaries** — PASS (central to this feature). Every unsafe
  precondition is rejected at the facade edge with a **distinct** result and
  **zero** run started: `{:error, :no_checkpoint}`, `{:error, :corrupt_checkpoint}`,
  `{:error, {:unknown_feature, id}}`, `{:error, {:unknown_phase, phase}}`, and a
  propagated worktree error. No fallback to phase one or a fresh branch (SC-005).
- **III. Least-Privilege Containment** — PASS. Resume runs the same
  worktree + `.claude` pack + per-phase permission path as `run/1`; it adds no
  new tool grants and skips no containment. `Worktree.create` lays the committed
  scaffold into the recreated tree exactly as the normal path does.
- **IV. Cost-Bounded Autonomy** — PASS. The resumed feature runs through the same
  `Ledger`-governed `FeatureRunner`; the breaker and drain semantics are
  inherited unchanged. Resume starts strictly ≤ the phases a fresh run would, so
  it cannot increase worst-case spend.
- **V. Human-in-the-Loop Escalation** — PASS (this feature *is* the resolution
  path). Resume is the operator-driven continuation after a human fix; it does
  not fabricate resolution of the original gate, and it re-runs the gate on the
  resumed phase. `resolve/1` remains available as the separate full-restart path
  (FR-009).

**Result**: PASS, no violations. Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/005-resume-facade/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── resume.md        # Phase 1 output — resume/2 behavioral contract
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator.ex          # + resume/2 public fn; + private resume runner wrapper + phase-resolution helpers
lib/speckit_orchestrator/
├── pipeline.ex                       # (read-only) Pipeline.phases/0 used for override validation; add phase?/1 helper if absent
├── checkpoint.ex                     # (read-only) Checkpoint.read/1
├── feature_runner.ex                 # (read-only) FeatureRunner.run :start_phase/:resume_prompt
└── worktree.ex                       # (read-only) Worktree.create branch reuse / Worktree.locate

test/speckit_orchestrator/
└── resume_test.exs                   # new — unit tests via :runner seam + fixture checkpoint
test/fixtures/
└── checkpoint/                        # fixture checkpoint(s) if not reusing 002's
```

**Structure Decision**: Single Elixir project, no new top-level layout. The
change is additive to the existing operator facade `lib/speckit_orchestrator.ex`
(where `run/1`, `run_spec/2`, `resolve/1` already live) plus one new test file.
Prerequisite modules are consumed read-only; the only possible non-facade edit is
a small pure `Pipeline.phase?/1` (or `known_phase?/1`) predicate if one does not
already exist, used to validate the `:from` override and the checkpoint's stored
phase string at the boundary.

## Complexity Tracking

> No constitution violations — section intentionally empty.
