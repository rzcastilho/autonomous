# Implementation Plan: Headless Background-Wait Hardening

**Branch**: `032-headless-background-wait` | **Date**: 2026-10-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/032-headless-background-wait/spec.md`

## Summary

Implement sessions on fretboard-master (012–014) stall because the CLI
auto-backgrounds a long verification command at its built-in 10-minute Bash
cap. The model then ends its turn "waiting", and in a headless session ending
the turn ends the session. The orchestrator scores that as success, and the
loop grinds on until `{:stuck_task_phase, …}`.

This plan closes the hole in four layers. Each layer stands alone and can be
tested alone:

1. **Detect** (US1). A pure detector over `PhaseResult.tool_events` finds
   commands moved to the background (by marker wording or by explicit
   `run_in_background`). A command counts as resolved only when a later event
   references its task id or output path. Each session-driving site (phases,
   implement chunks, remediation) classifies a stranded command as
   incomplete. The phase or chunk is retried once with a corrective note.
   A second stranding fails the feature with
   `{:backgrounded_command, where, commands}`. Research R6 found that chunks
   and remediation have **no** incomplete-session gate today. This is why the
   fretboard stall looked like "stuck".
2. **Prevent with timeouts** (US2). The new pure
   `ShellTimeouts.for_deadline/1` computes max = min(45, d − 5) and
   default = min(30, max) minutes. For d ≤ 10 min it pins the CLI built-ins.
   The values go to every session through the launch env **and**
   `--settings` (flag settings beat the target's `settings.json` env, per
   research R2).
3. **Prevent with prompt and tools** (US3, US4). A versioned headless rule is
   appended to the implement task-phase, sweep and whole-list prompts and to
   the converge prompt. `Monitor` joins `@headless_disallowed` under both
   profiles.
4. **Pack contract 4** (US5). The pack's `settings.json` carries the default
   timeouts in `env`. Install merges `env`, and the target wins on a conflict.
   The permissive preflight requires contract 4.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (mise-pinned), Erlang/OTP 28.5.0.6; Python 3 for the pack hook

**Primary Dependencies**: Jido 2.2, `jido_harness` + `jido_claude` (GitHub SHAs), `claude_agent_sdk` (`:settings` → `--settings`), Claude Code CLI **2.1.287** (verified: `BASH_*_TIMEOUT_MS`, marker wording, `Monitor` tool, settings-env precedence)

**Storage**: Mnesia. **No schema change**: new failure-reason tuples and signal keys are open terms in existing records.

**Testing**: ExUnit (hermetic default suite), plus `--include integration` for two real-CLI probes (quickstart §2), plus `scope_guard_test` against the real hook

**Target Platform**: Linux host and the feature-031 container (same CLI pin)

**Project Type**: OTP control-plane library/application with a LiveView console

**Performance Goals**: N/A. Detection is an O(events × backgrounded) pass over an already-folded list.

**Constraints**: `warnings_as_errors`. The pure core stays free of CLI, harness and Jido (the marker wording is isolated in `BackgroundMarker`). Prompts and permissions of untouched phases stay byte-identical. The CLI's Bash maximum always sits ≥ 5 min below the session deadline.

**Scale/Scope**: about 12 modules touched, 3 new (`BackgroundMarker`, `ShellTimeouts`, prompt file `headless_rule.md`), 1 pack contract bump, 3 docs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Notes |
|---|---|---|
| I. Pure Core, Isolated Contracts | PASS | CLI marker wording lives in one boundary module (`BackgroundMarker`) recorded in `harness-contract.md`. `PhaseResult`/`ShellTimeouts` are pure. `Pipeline.next/3` and `Chunking.next/2` receive the extracted `backgrounded` signal as an argument and never parse anything. |
| II. Fail Loud at Boundaries | PASS | A fake success becomes a named failure. `install/2` refuses an unparseable target `settings.json` instead of overwriting it. The permissive preflight refuses contract 3 by name. |
| III. Least-Privilege Containment | PASS (PATCH note) | Adds one exclusion (`Monitor`). Nothing is relaxed. The permissive bullet's stated purpose ("keep sessions from ending while they wait on background work") covers it exactly. A PATCH 6.0.1 wording that names the background-watcher tool is planned as a task (research R10). Correctness gates behave identically under both profiles, as required. |
| IV. Cost-Bounded Autonomy | PASS | The retry reuses the existing budget (`phase_max_retries`, default 1). A chunk re-dispatch counts against the frozen session ceiling. Every retried session goes through Ledger. The deadline always fires before the CLI's own maximum. |
| V. Human-in-the-Loop | PASS | No gate diversion is retried. The new outcome is `:failed` with the worktree kept. No new lifecycle status. |
| VI. Idiomatic Elixir/OTP | PASS | Pure functions with `@spec`, multi-clause/pattern-matched gate ordering, no new processes. |
| VII. Operator Surfaces Tell the Truth | PASS | The reason renders through `Report.format_reason/1` with the real command text (mono via the existing reason components). No new UI element. |
| Quality & Test Discipline | PASS | Pure modules are unit-tested to > 90%. Real-CLI probes are opt-in. The hook contract is tested against the real hook. |

**Post-design re-check (after Phase 1)**: unchanged, all PASS. The design
adds no dependency, no process and no schema migration.

## Project Structure

### Documentation (this feature)

```text
specs/032-headless-background-wait/
├── plan.md              # this file
├── research.md          # R1–R11: CLI facts, precedence, decisions
├── data-model.md        # BackgroundedCommand, signal, reasons, ChunkState, timeouts, pack contract
├── quickstart.md        # validation guide
├── contracts/
│   ├── background-detection.md   # US1: marker grammar, resolution, gate order, retry, rendering
│   ├── session-timeouts.md       # US2: formula, delivery channels, precedence
│   ├── prompt-and-tools.md       # US3/US4/FR-002a: rule, corrective note, Monitor exclusion
│   └── target-pack-v4.md         # US5: settings env, merge, contract 4, preflight
└── tasks.md             # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── background_marker.ex        # NEW: CLI 2.1.287 marker regexes + explicit-mode check (boundary)
├── shell_timeouts.ex           # NEW: pure for_deadline/1
├── phase_result.ex             # + backgrounded_commands/1, stranded_background/1
├── phase_request.ex            # + :deadline_ms / :background_retry opts; env+settings timeouts;
│                               #   headless rule on implement scopes + converge; Monitor excluded
├── phase_step.ex               # retry_reason: backgrounded; thread background_retry into retry
├── pipeline.ex                 # next/3 clause → {:failed, {:backgrounded_command, phase, cmds}}
├── chunking.ex                 # ChunkState.background_retried?; row B
├── chunk_runner.ex             # lift :backgrounded signal; re-dispatch with background_retry
├── report.ex                   # format_reason/1 clause
├── target_pack.ex              # @pack_contract "4"; merge_settings/2; install error on bad JSON
└── actions/
    ├── run_feature_phase.ex    # background gate (order + suppression); pass deadline + background_retry
    ├── run_auto_remediation.ex # background gate; pass deadline
    └── run_remediation.ex      # background gate; pass deadline

priv/
├── prompts/headless_rule.md    # NEW
└── target_pack/.claude/
    ├── settings.json           # + env timeouts
    └── hooks/scope_guard.py    # PACK_CONTRACT = 4

test/autonomous/
├── background_marker_test.exs  # NEW
├── shell_timeouts_test.exs     # NEW
├── phase_result_test.exs       # detection table + SC-001 fixture
├── phase_request_test.exs      # timeouts, rule placement, byte-identity, Monitor
├── phase_step_test.exs / pipeline_test.exs / chunking_test.exs / chunk_runner_test.exs
├── target_pack_test.exs / scope_guard_test.exs
└── integration/background_wait_test.exs   # NEW, @moduletag :integration
test/fixtures/sessions/background_wait_014.exs  # NEW synthetic replay (research R11)

docs/
├── harness-contract.md         # 10-min cap, markers, env vars, precedence, tool names (FR-016)
├── runbook.md                  # symptom/cause/fix entry (FR-015)
└── (CLAUDE.md)                 # session-deadline paragraph: shell timeouts vs deadlines (FR-016)
.specify/memory/constitution.md # PATCH 6.0.1 wording (R10)
```

**Structure Decision**: single OTP project, with the existing
`lib/autonomous` / `test/autonomous` layout. New code goes into two small
pure modules plus clauses in the existing gate, retry and request modules.
No new directories except the test fixture subfolder.

## Implementation Order (for /speckit-tasks)

Each step is independently shippable, in priority order:

1. **US1 detection core**: `BackgroundMarker`, `PhaseResult` functions,
   fixtures, tests (pure, no wiring).
2. **US1 wiring**: gate in the three actions, `Pipeline` clause,
   `PhaseStep` retry and note plumbing, `Chunking` row B, `ChunkRunner`
   lift and re-dispatch, `Report` clause. Depends on the `PhaseRequest`
   `:background_retry` option (step 4 prompt half), which can land first as
   a no-op-when-empty option.
3. **US2 timeouts**: `ShellTimeouts`, `PhaseRequest` `:deadline_ms` + two
   channels, callers pass deadlines.
4. **US3/US4**: `headless_rule.md`, placement, corrective note, `Monitor`.
5. **US5 pack**: settings env, `merge_settings/2`, contract 4, preflight.
6. **Docs and constitution PATCH**: harness-contract, runbook, CLAUDE.md,
   6.0.1.
7. **Validation**: full suite, integration probes, SC-006 field run
   (operator).

## Flagged Deviations from Spec Text (for /speckit-analyze)

| ref | spec says | plan does | why |
|---|---|---|---|
| FR-008 / SC-003 | d ≤ 10 min → set **no** override | pins the CLI built-ins (120 000 / 600 000) via the same channels | with the contract-4 pack installed, "no override" would let the pack's 30/45 min govern a ≤ 10-min session. Pinning yields the outcome FR-008 intends (research R3) |
| FR-005 | the gate "already applies" at chunks and remediation | adds it there (it applies nowhere at chunks or remediation today) | the premise is inaccurate, so the plan follows the intent (research R6) |
| FR-009 | task-phase block, sweep block, converge | also the `:whole_list` implement scope | same risk, and US3 says "every implement … prompt" (research R8) |
| FR-011 | exclude a background-output reader "if exposed" | none excluded | 2.1.287 registers no such tool; `Read` of the output path is the resolution path (research R5) |
| FR-013 | install merges env | install also **refuses** an unparseable existing `settings.json` | Principle II: never silently overwrite unreadable target config |

## Complexity Tracking

No constitution violations. Nothing to justify.
