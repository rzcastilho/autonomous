# Implementation Plan: Implement Phase Chunking

**Branch**: `015-implement-phase-chunking` | **Date**: 2026-07-25 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/015-implement-phase-chunking/spec.md`

## Summary

Split the `implement` pipeline step into one bounded agent session per
**task-phase** of the feature's `tasks.md`, so a real feature's task list no
longer has to fit inside a single turn cap; and reclassify **turn exhaustion**
from a terminal failure into partial progress that continues in a fresh session.

Technical approach — two new pure modules and one new edge module, plus small
extensions to six existing ones. `TaskPlan` parses `## Phase <n>: <title>`
sections and their `- [ ]`/`- [X]` tasks into an ordered, re-derivable plan.
`Chunking.next/2` is the pure decision surface for the whole loop (dispatch /
skip / sweep / continue / halt / fail), the direct analogue of
`Pipeline.next/3`. `ChunkRunner` is the edge that drives it: one `"phase.run"`
signal per chunk (so the existing action timeout, telemetry span, per-session
transcript and cost accounting all keep their meaning), a `Worktree.commit/2`
at each task-phase boundary, and a checkpoint carrying the task-phase position.
Turn exhaustion is detected from the harness result **subtype**
`"error_max_turns"`, which the adapter already emits and `PhaseResult` currently
discards. The seven-step pipeline, its ordering and its gates are untouched
(FR-008): `Pipeline.next/3` still sees exactly one `:implement` outcome.

## Technical Context

**Language/Version**: Elixir `~> 1.20`, pinned `1.20.2-otp-28` via `.tool-versions`;
OTP 28 system-provided. Every command through `mise exec --`.

**Primary Dependencies**: none added. Existing: Jido `~> 2.2`, `jido_harness` +
`jido_claude` (GitHub SHA pins, `override: true` on the harness), Phoenix `~> 1.7`
/ LiveView `~> 1.0` on Bandit, `phoenix_pubsub`, Jason, `:telemetry`.

**Storage**: no database. Durable state stays file-backed — the existing
per-feature `checkpoint.json` under the run's `%Layout{}.transcript_root`, gains
one optional `implement_chunk` key; the run manifest is unchanged.

**Testing**: ExUnit. Default suite hermetic (pure modules + injected seams: the
`:runner` seam, the LiveView `:console_test_runner` seam, a fake agent for
`ChunkRunner`); real-harness coverage behind `mix test --include integration`.
`warnings_as_errors` is on.

**Target Platform**: BEAM control plane on developer/CI machines (darwin +
linux), driving the `claude` CLI against a target git repo.

**Project Type**: single Elixir application (`speckit_orchestrator`) — OTP
control plane with an embedded Phoenix LiveView operator console.

**Performance Goals**: SC-003 — a task-phase boundary is visible in the console
within 5s (satisfied by the existing broadcast-on-event path plus the 2s
reconcile tick). SC-007 — chunking adds ≤20% to implement cost for a feature
that previously completed in one session.

**Constraints**: per-session turn cap unchanged (`implement_max_turns: 80`);
`config :jido_action, default_timeout: 45 min` bounds **one** chunk session, and
`FeatureRunner`'s 50-min `AgentServer.call` timeout must stay strictly larger —
both preserved by dispatching one action per chunk. No JS build step, no new
runtime dependency, no new OTP process.

**Scale/Scope**: 3 new modules, extensions to ~8 existing ones, ~5 new/extended
test files plus fixtures. Task lists observed in practice: 5–7 task-phases,
18–40 tasks.

## Constitution Check

*GATE: passed before Phase 0 research; re-evaluated after Phase 1 design — still passing.*

| Principle | Assessment |
|---|---|
| **I. Pure Core, Isolated Contracts** | PASS. `TaskPlan` (parse + derived counts) and `Chunking.next/2` are pure and CLI/harness/Jido-free; every gate signal (progress, exhaustion, breaker state, session counts) is extracted upstream in `ChunkRunner` and passed in as arguments, mirroring `Pipeline.next/3`. The one moving external contract this feature touches — the CLI's `error_max_turns` result subtype — is absorbed at the existing boundary (`PhaseResult.reduce/1`) and exposed as `exhausted?/1`, so no pure module encodes a guess about it. `TaskPlan.load/1` is the single, documented edge reader (same shape as `Backlog.load!/1`). |
| **II. Fail Loud at Boundaries** | PASS. Unchecked tasks surviving the sweep fail the step by name (FR-007a); a stuck task-phase and an exhausted session budget are **distinct**, named reasons (SC-002); ambiguous task-phase resolution falls through rather than guessing, and any match weaker than by-number is reported (FR-025a). Nothing is invented to paper over a malformed task list: an unparseable one degrades to the spec-mandated FR-004 single-session path, which is a documented contract, not a silent repair. Research R9 records the one place this reading is contested (FR-007a vs SC-005) and the decision taken. |
| **III. Least-Privilege Containment** | PASS. Chunk sessions reuse `:implement`'s existing `permission_mode: :accept_edits` + `@write_bash_tools` verbatim; no new tool, path, or permission is granted. Containment continues to rest on the committed target pack + scope-guard hook. |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | PASS, and strengthened. The breaker is checked at each **task-phase boundary**: the in-flight task-phase finishes, then the feature halts between task-phases (FR-009) — the same drain-don't-kill rule at finer granularity. A new per-feature session ceiling (FR-013a) bounds the worst case that chunking otherwise multiplies. Per-chunk cost keeps flowing through `Cost.for_phase/2` → `Ledger.record/3` unchanged, with an explicit no-double-count rule in the console fold. |
| **V. Human-in-the-Loop Escalation** | PASS. No gate semantics change. The escalations surface gains a task-phase picker defaulting to the recorded position (FR-022), and an operator resume explicitly re-grants session budget (FR-013b) — an autonomy bound released by a human, not by the system. |
| **VI. Idiomatic Elixir/OTP** | PASS. Pure transforms over immutable structs; a table-driven multi-clause `next/2` with guards rather than nested conditionals; tagged tuples throughout (`{:dispatch, …}` / `{:failed, reason}`), raising reserved for programmer error. **No new process**: `ChunkRunner` is a plain module called from the existing supervised `Task`, so nothing new needs a restart strategy and no long-running work moves inside a `GenServer` callback. `@spec` on every public function; `mix format` mandatory. |
| **Technology Stack** | PASS. No new runtime dependency, no database, no JS build step. The console stays an observability surface fed by telemetry + checkpoints — it never becomes a second source of truth for chunk position. |

**Post-design re-check**: unchanged. Two structural risks were found during
Phase 1 design and closed *inside* the design rather than deferred: task-phase
commit subjects must not match `Recovery.Evidence`'s boundary regex (research
R5), and chunk transcripts must not consume pipeline step numbers or
`07-converge.md` stops resolving (research R6). Both have named regression tests.

## Project Structure

### Documentation (this feature)

```text
specs/015-implement-phase-chunking/
├── plan.md                                  # This file
├── research.md                              # Phase 0 output — R1..R12
├── data-model.md                            # Phase 1 output
├── quickstart.md                            # Phase 1 output
├── contracts/                               # Phase 1 output
│   ├── task_plan.md                         # grammar + parser API
│   ├── chunking.md                          # pure decision table
│   ├── chunk_session.md                     # request/outcome/transcript/commit
│   ├── checkpoint-implement-chunk.md        # durable state + resume
│   └── telemetry-chunk.md                   # events + console rendering
├── spec.md
└── tasks.md                                 # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── task_plan.ex                  # NEW — pure parser + derived counts + locate/2
├── chunking.ex                   # NEW — pure decision surface (Chunking.next/2)
├── chunk_runner.ex               # NEW — edge: drives the loop, one session per chunk
├── phase_result.ex               # + subtype field, exhausted?/1
├── phase_request.ex              # + :scope option, scoped implement prompts
├── actions/run_feature_phase.ex  # + scope passthrough, artifact gate deferred for scoped runs
├── feature_runner.ex             # + delegate :implement to ChunkRunner; :start_task_phase opt
├── checkpoint.ex                 # + optional implement_chunk key
├── transcripts.ex                # + write_labelled/6; error/subtype in render
├── telemetry.ex                  # + [:speckit, :chunk, …] event names
├── console_read_model.ex         # + chunk slice, boundary/continuation feed entries
├── config.ex                     # + chunk bound accessors
└── web/
    ├── components/core_components.ex   # phase_strip: implement sub-label
    └── live/escalations_live.ex        # task-phase picker on resume

config/config.exs                 # + implement_no_progress_limit,
                                  #   implement_sessions_per_task_phase,
                                  #   implement_sessions_headroom

test/speckit_orchestrator/
├── task_plan_test.exs            # NEW
├── chunking_test.exs             # NEW
├── chunk_runner_test.exs         # NEW (fake agent seam + tmp git repo)
├── phase_result_test.exs         # + exhaustion classification
├── phase_request_test.exs        # + scoped prompts, byte-identical fallback
├── checkpoint_test.exs           # + implement_chunk round-trip, pre-015 compat
├── console_read_model_test.exs   # + chunk fold, no double-count
├── resume_test.exs               # + :from_task_phase, weak-match reporting
├── recovery/evidence_test.exs    # + task-phase commits are not phase boundaries
└── web/escalations_live_test.exs # + task-phase picker

test/fixtures/tasks/              # NEW — structured / unstructured / empty
                                  #   task-phase / duplicate numbers / fenced /
                                  #   no-checkboxes
```

**Structure Decision**: single Elixir application, unchanged. New pure modules
sit alongside the existing pure core (`Pipeline`, `Release`, `Ledger`,
`Backlog`); the new edge module sits alongside `FeatureRunner`, which calls it.
No new supervision-tree children, no new directory conventions, and no change to
the `specs/`, worktree, or transcript layouts established by feature 012.

## Complexity Tracking

> No Constitution Check violations. Table intentionally empty.

## Notable design decisions carried from Phase 0

Recorded here because they constrain implementation and are easy to get wrong:

1. **Exhaustion is a subtype, not a string match** — `PhaseResult` must capture
   `"subtype"` from `:session_failed`; `transient?/1` is left untouched (R1).
2. **The loop lives in the runner, not the action** — one action per chunk, or
   the 45-minute action timeout and the per-phase telemetry span both lose their
   meaning (R3).
3. **Task-phase commits must not look like phase boundaries** — or crash
   recovery resumes a half-built feature at `converge` (R5).
4. **Chunk transcripts must not consume step numbers** — or
   `Recovery.Evidence.final_marker?/2` stops finding `07-converge.md` (R6).
5. **Progress is a whole-list `[X]` delta**, so out-of-scope completions count
   as progress (R7).
6. **The session ceiling is a frozen formula**, resolved once at step start —
   otherwise a session that appends task-phases raises its own budget (R8).
7. **FR-007a applies on the fallback path too**, with the sweep extended there
   to keep SC-005's spirit; the residual risk is stated explicitly (R9).
8. **The artifact gate stays whole-step**, evaluated once on the roll-up, or a
   doc-only early task-phase would fail the feature mid-implement (R10).
