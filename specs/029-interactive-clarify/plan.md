# Implementation Plan: Interactive Clarify Answering

**Branch**: `029-interactive-clarify` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/029-interactive-clarify/spec.md`

## Summary

Today a clarify `## NEEDS HUMAN` is terminal: the feature escalates and the
run parks. Resuming later is manual. This feature adds a per-run opt-in mode,
**off by default and byte-identical when off**. In that mode the feature's
runner process holds the feature in a new non-terminal `:awaiting_answers`
status and asks the operator the reviewer's questions. It then re-runs
clarify with the answers as authoritative input, all inside the same run.

The approach (see [research.md](research.md)):

1. **Interception after the pure table.** `Pipeline.next/3` is unchanged.
   A new pure `InteractiveClarify.decide/3` looks at the transition and
   returns one of:
   - `:pass`: today's path
   - `:await`
   - `{:escalated, {:needs_human, :rounds_exhausted}}`

   With the mode off it always returns `:pass` (R1, R2).
2. **The wait lives in the runner task.** A `receive … after poll_ms` loop.
   It runs no session and makes no ledger call. It is still registered in
   `WorkerRegistry`, so the feature stays in flight, and `Release.next/3`
   treats `:awaiting_answers` like `:running` (R1, R6).
3. **The store row arbitrates.** Each round is a `speckit_clarify_round` row
   (schema v6, new table). Answer and every other exit are guarded Mnesia
   transactions on `outcome == :open`, so exactly one outcome wins, and a
   stale or duplicate submission is refused (R3, R11).
4. **Every exit other than an answer falls back to today's escalation.**
   Timeout, breaker, drain, restart and exhausted rounds go through the
   existing terminal path with a recorded `{:needs_human, sub}` reason. The
   drain bound for a waiting worker is `poll + grace + 30 s`, independent of
   the answer timeout (R4, R5, R12).
5. **One NEEDS HUMAN rule** (`NeedsHuman`). It also defines the numbered
   `### Qn` format taught in `clarify.md`, parsed all-or-nothing, with a
   freeform fallback (R8, R9).
6. **Surfaces.** A new `--awaiting` status token (design-constitution
   amendment), an answer panel on Escalations, trigger-form controls,
   run-detail round history, `pending_questions/0` and `answer/3` in iex,
   and a status/report line shown only when rounds exist (R13–R15).

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28 (via `mise exec --`)

**Primary Dependencies**: Jido / `jido_harness` (`:claude` provider), Phoenix LiveView + `phoenix_pubsub` (console). No new dependency.

**Storage**: Mnesia. One new `disc_copies` table, `speckit_clarify_round`, created by migration v6 (a create, not a transform). `FeatureRun.status` gains `:awaiting_answers` with no shape change. Settings are three new keys in the free-form `RunSettings.settings` map, with no migration.

**Testing**: ExUnit. Pure table tests (`InteractiveClarify`, `NeedsHuman`, `AnswerSet`, `Settings`). Seam-injected `FeatureRunner` with a stubbed `PhaseStep`/executor, and an injected clock and `poll_ms` for the wait. Store transaction race tests. The `Workers.drain` bound test. LiveView tests for the panel, trigger and run detail. The design guard.

**Target Platform**: macOS/Linux single-node BEAM host driving target repos through git worktrees

**Project Type**: OTP control plane (library + LiveView console)

**Performance Goals**: Answer to re-run start < 5 s (SC-002). One tick = one transactional read plus two ETS reads, at `poll_ms` = 1 000 by default.

**Constraints**:
- `warnings_as_errors`.
- Mode off must be byte-identical: records, report, prompt and console (FR-002, SC-003).
- No spend while waiting (FR-004).
- The drain bound must not depend on the answer timeout (SC-005).
- The design guard stays green (SC-008).
- No new process type.

**Scale/Scope**: About 20 modules touched plus 4 new pure modules and 1 new table (see Structure). There is one waiting feature per run at most, by construction.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Pure Core, Isolated Contracts | ✅ The decisions are pure: `InteractiveClarify.decide/3` / `on_exit/1`, `Settings.validate/1`, `NeedsHuman.parse_questions/1` and `AnswerSet.build/2`. `Pipeline.next/3` is untouched. Mnesia stays behind `Store.Writer`, and the receive loop and store I/O stay in `FeatureRunner`. |
| II. Fail Loud at Boundaries | ✅ Settings are validated in `run/1` preflight and the trigger form, never clamped. Answers are validated before any write. A stale `seq` is refused by name (`{:stale_round, outcome}`). The question parser is all-or-nothing, falling back to freeform and never inventing a partial parse. Migration v6 is explicit and versioned. |
| III. Least-Privilege Containment | ✅ Unchanged. The clarify re-run uses the existing clarify permissions (`:accept_edits`, Read/Write/Edit/Grep/Glob). |
| IV. Cost-Bounded Autonomy | ✅ No reserve or commit while waiting. The breaker is checked every tick and again before the re-run. A drain ends the wait within `poll + grace + 30 s` (drain, don't kill). A re-run is an ordinary Ledger-accounted clarify session. |
| V. Human-in-the-Loop Escalation (5.0.0) | ✅ This implements the 5.0.0 amendment clause by clause: off by default and byte-identical when off (FR-002); only a human answer resolves (`decide/3` has no default-answer path, and a recommended default is used only when the operator leaves the field blank in a submission they make); bounded by the recorded timeout and rounds; every other exit (timeout, rounds, breaker, drain, restart) is today's escalation with a named reason; no session or cost while waiting; worktree retained; every round recorded and surfaced. |
| VI. Idiomatic Elixir/OTP | ✅ Tagged tuples, multi-clause pure tables, and `with` in the facade. The blocking `receive` lives in a supervised `Task` (not a GenServer callback). The Coordinator gains two thin `handle_info` clauses. |
| VII. Operator Surfaces Tell the Truth | ✅ There is a distinct named status with its own token, added via a design-constitution amendment (Governance), not ad-hoc colour. Waited and left are derived from recorded `started_at`/`deadline_at`. The submit button states its consequence. Answers show whether they were typed or an accepted default. Real identifiers (`Q1`, `seq`, `{:needs_human, :answer_timeout}`) are shown in mono. |
| Technology Stack / Persistence | ✅ No new dependency. The new table is `disc_copies`, a deliberate small/hot choice. All writes are transactional, and gate-feeding reads are transactional. There is a versioned migration. The pure core does not depend on Mnesia. |

**Result: PASS.** The constitution amendment is already ratified (5.0.0, FR-019). One governed design-surface amendment lands with this feature: `docs/design-constitution.md` gains the eighth status colour `--awaiting`, as pre-flagged ⚠ in the 5.0.0 Sync Impact Report.

**Post-design re-check (after Phase 1): PASS.** The contracts add no process type and no external dependency. They add one new status atom and one schema version, both justified above. The mode-off path is structurally untouched because `decide/3` returns `:pass` first.

## Project Structure

### Documentation (this feature)

```text
specs/029-interactive-clarify/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── facade-api.md
│   ├── needs-human-format.md
│   ├── wait-protocol.md
│   └── operator-surfaces.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── needs_human.ex                      # NEW pure: marker/present?/extract/parse_questions + Question
├── interactive_clarify.ex              # NEW pure: decide/3, on_exit/1, Settings, AnswerSet
├── run_context.ex                      # +3 keys (interactive_clarify, clarify_answer_timeout_s, clarify_max_rounds)
├── config.ex                           # defaults + clarify_poll_ms
├── feature.ex                          # status :awaiting_answers (non-terminal)
├── release.ex                          # :awaiting_answers counts as in flight
├── coordinator.ex                      # {:feature_awaiting,_}/{:feature_resumed,_}; clarify_rounds in report
├── feature_runner.ex                   # decide/3 interception, await_answers/tick, answered path
├── workers.ex (+ workers/bound.ex)     # waiting/1 short deadline
├── actions/run_feature_phase.ex        # use NeedsHuman; pass :operator_answers
├── phase_request.ex                    # append_clarify_answers/2
├── store/schema.ex, records.ex         # speckit_clarify_round; FeatureRun status
├── store/migrations.ex                 # v6 create table
├── store/writer.ex                     # record_feature_awaiting/resumed, answer_round, close_round, mark_round_applied; supersede mapping
├── store/query.ex                      # rounds in run_detail / pending read
├── recovery.ex, recovery/reconcile.ex  # :awaiting_answers → escalated {:needs_human, :restart}
├── telemetry.ex, console_projection.ex # [:speckit, :clarify, *] events → :feature_updated
├── report.ex                           # awaiting: line, clarify: block, {:needs_human, sub} reasons
└── web/
    ├── components/core_components.ex   # label/status_class/statuses
    └── live/{escalations,trigger,run_detail,mission_control}_live.ex
lib/speckit_orchestrator.ex             # opts preflight, pending_questions/0,1, answer/3,4, guard, resume reuse of unapplied answers, export/prune include rounds
priv/prompts/clarify.md                 # numbered question format section
priv/static/assets/console.css          # --awaiting token + [data-status] block
docs/design-constitution.md             # eighth status colour (governed amendment)
docs/runbook.md, CLAUDE.md              # FR-020

test/speckit_orchestrator/
├── needs_human_test.exs, interactive_clarify_test.exs          # NEW pure
├── feature_runner_clarify_wait_test.exs                        # NEW seam-injected wait
├── store/clarify_round_test.exs                                # NEW transactions + migration v6
├── release_test, coordinator_test, run_feature_phase_test, phase_request_test,
│   workers_test, recovery_test, report_test, resume_test, run_context_test   # extended
└── web/{escalations,trigger,run_detail}_live_test.exs, design_contract_test  # extended
test/support/design_contract.ex         # status lists
```

**Structure Decision**: This is the existing single-project OTP layout. Two new pure modules sit beside `Pipeline`/`Remediation`. The table, migration and writer functions follow the v4/v5 precedent. Everything else is an edit at the call sites named in research R1–R15.

## Delivery order

1. **Foundation.**
   - `NeedsHuman` (move the regex and extract, with no behaviour change,
     SC-003).
   - `InteractiveClarify` pure modules.
   - `RunContext` keys and preflight.
   - Schema v6, the table and the Writer functions.
   - `:awaiting_answers` in `Feature` / `Release` / `Coordinator`.
2. **US1 + US2 (P1, MVP).**
   - The runner interception, wait loop and answered path.
   - `PhaseRequest` answer block and `clarify.md` answer-folding.
   - `Workers.waiting/1`.
   - All fallbacks, restart reconcile, and `answer/3` + `pending_questions/0`.
   - A freeform-only console panel.
3. **US3 (P2).** The numbered format in `clarify.md`, per-question fields,
   "use recommended", and `AnswerSet` defaults.
4. **US4 (P2).** The trigger-form controls, the status token and design
   amendment on every surface, run-detail history, and report / `print_status`
   lines.
5. **Docs** (FR-020): runbook "Interactive clarify" section and the CLAUDE.md
   Pipeline paragraph ("clarify gate has no knobs" → the one knob).
6. **Live validation** (SC-007): LedgerLite 007 with the mode on.

## Complexity Tracking

| Item | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| New Mnesia table + schema v6 | Rounds need durable, transactional arbitration (FR-005, SC-006) and history (FR-015) | Storing rounds in `FeatureRun` would need a transform on a hot table plus list-in-row updates, with no clean per-round guard. Storing them in-memory only would break the restart and history requirements |
| Eighth status colour | FR-014 requires a distinct status. The design constitution caps statuses at seven | Reusing `--escalated` or `--running` would make a waiting feature look terminal or active-spending, which misstates state (Principle VII) |
