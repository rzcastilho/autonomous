# Implementation Plan: Resume Checkpoint Persistence

**Branch**: `002-resume-checkpoint` | **Date**: 2026-07-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-resume-checkpoint/spec.md`

## Summary

Add a new infrastructure module `SpeckitOrchestrator.Checkpoint` that persists a
durable, machine-readable pointer (`checkpoint.json`) recording the phase a
feature reached when it terminated, its terminal status, reason, and session id —
stored under the existing durable transcript root, keyed by feature id. Wire
`FeatureRunner.run/2` to write the checkpoint after the phase loop returns on any
non-`:done` terminal, and to delete it on `:done` (a completed feature needs no
resume pointer). Write is best-effort (a failure never breaks the run); read has
three distinct outcomes — record, absent, corrupt. This feature only *produces*
the record; nothing reads it back into a run (that is feature 002+).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned in `.tool-versions`, run via `mise exec --`)

**Primary Dependencies**: Jason (JSON encode/decode — already used by `AnalyzeResult`/`Describe`); Elixir stdlib `File`/`Path`

**Storage**: One JSON file per feature at `<Config.transcript_root>/<feature_id>/checkpoint.json`

**Testing**: ExUnit (`mise exec -- mix test`); hermetic — checkpoint I/O redirected to a `tmp_dir` transcript root, no CLI/worktree needed

**Target Platform**: BEAM / local filesystem

**Project Type**: Single project (Elixir/OTP control plane)

**Performance Goals**: N/A — one small file write/read per feature termination

**Constraints**: Best-effort write MUST NOT fail/halt/crash the run (FR-008); read MUST distinguish absent from corrupt (FR-006); `warnings_as_errors` ON

**Scale/Scope**: One module (~3 public functions) + one wiring point in `FeatureRunner`; at most one record per feature

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Pure Core, Isolated Contracts** — PASS. `Checkpoint` is an infrastructure
  module performing file I/O, peer to `Transcripts`, not part of the pure core
  (`Feature`/`Config`/`Pipeline`/`Ledger`/`Release`/`Backlog`). It adds no
  CLI/harness/Jido dependency to the pure core. The halted-phase/status/reason
  signals it persists are *read out of already-computed run state* at the
  finalization point — the decision surface (`Pipeline.next/3`) is untouched.
- **II. Fail Loud at Boundaries** — PASS (with a documented, spec-mandated
  asymmetry). The *read* path fails loud: a checkpoint file that cannot be parsed
  returns a distinct `{:error, :corrupt}` — never fabricated fields (FR-006, edge
  "corrupt or partially written"). The *write* path is deliberately best-effort
  (FR-008): checkpoint persistence is an observability aid, not a correctness
  gate, and MUST never break an in-flight run — the same best-effort contract
  `Transcripts.maybe_write_durable/4` already follows. Read does not invent data
  to paper over a malformed file.
- **III. Least-Privilege Containment** — N/A. No new CLI-executed actions, tools,
  or target-repo writes; all writes are to the orchestrator's own durable root.
- **IV. Cost-Bounded Autonomy** — N/A. No spend, no reservation, no breaker
  interaction. Runs after the phase loop has already drained.
- **V. Human-in-the-Loop Escalation** — PASS / supportive. The checkpoint records
  where a diverted (`:escalated`/`:halted`/`:failed`) feature stopped without
  altering gate behavior; it strengthens the post-mortem trail the escalation
  principle depends on, and does not fabricate resolution.

No violations → Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/002-resume-checkpoint/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── checkpoint.md    # Phase 1 output — Checkpoint module contract
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── checkpoint.ex        # NEW — write/1, read/1, delete/1 (best-effort write, 3-way read)
├── feature_runner.ex    # EDIT — after loop/7 returns, checkpoint or delete beside handle_worktree/3
├── transcripts.ex       # REFERENCE — durable-root + best-effort write pattern to mirror
└── config.ex            # REFERENCE — Config.transcript_root/0 (existing, unchanged)

test/speckit_orchestrator/
└── checkpoint_test.exs  # NEW — round-trip, absent, corrupt, best-effort-write, delete-on-done
```

**Structure Decision**: Single-project Elixir/OTP layout. The new module lives in
`lib/speckit_orchestrator/` alongside the peer infrastructure module it mirrors
(`transcripts.ex`), and its unit test in `test/speckit_orchestrator/`. The only
production edit outside the new module is the finalization wiring in
`feature_runner.ex` (beside the existing `handle_worktree/3` call, ~line 78).

## Complexity Tracking

> No constitution violations — section intentionally empty.
