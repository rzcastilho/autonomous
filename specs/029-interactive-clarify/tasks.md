# Tasks: Interactive Clarify Answering

**Input**: Design documents from `/specs/029-interactive-clarify/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — quickstart.md and the contracts specify exact test files/scenarios; tests are part of this feature's acceptance criteria (SC-001..SC-008).

**Organization**: Tasks are grouped by user story per plan.md's Delivery order — Foundation, then US1 (P1, MVP), US2 (P1), US3 (P2), US4 (P2), then docs and live validation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, or independent functions/sections, no dependency on an incomplete task)
- **[Story]**: US1, US2, US3, US4 — maps to spec.md user stories
- All paths are relative to repository root

## Phase 1: Setup

**Purpose**: No new dependency (plan.md Technical Context). Nothing to scaffold before Foundational.

- [X] T001 Confirm `mise exec -- mix test` is green on `main` before touching code (baseline for SC-003's "byte-identical when off" comparison)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The two new pure modules (`NeedsHuman`, `InteractiveClarify`), the settings/config plumbing, the new Mnesia table, and the non-terminal `:awaiting_answers` status that every user story depends on.

**⚠️ CRITICAL**: US1, US2, US3 and US4 all call into these. Complete this phase first.

- [X] T002 [P] Create `SpeckitOrchestrator.NeedsHuman` in `lib/speckit_orchestrator/needs_human.ex` — `Question` struct, `marker/0` (`~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m`), `present?/1`, `extract/1` (moved verbatim from `EscalationsLive.extract_needs_human/1` / `RunFeaturePhase`'s local regex, byte-identical), `parse_questions/1` returning `{:numbered, [Question.t()]} | {:freeform, String.t()}`, never a partial parse (contracts/needs-human-format.md, research.md R8, data-model.md)
- [X] T003 [P] `needs_human_test.exs` — `present?/1`/`extract/1` match today's moved-regex tests byte-for-byte; `parse_questions/1` on well-formed numbered, malformed (non-contiguous ids, an item missing both Options and Recommended, text before `### Q1`), and empty/whitespace blocks (contracts/needs-human-format.md, research.md R8)
- [X] T004 [P] Point `RunFeaturePhase`'s clarify gate and `spec.md` scan (`lib/speckit_orchestrator/actions/run_feature_phase.ex`) at `NeedsHuman.present?/1` / `extract/1`; delete the local regex (FR-018, contracts/needs-human-format.md)
- [X] T005 [P] Point `EscalationsLive.extract_needs_human/1` callers (`lib/speckit_orchestrator/web/live/escalations_live.ex`) at `NeedsHuman.extract/1`; delete the local copy (FR-018, contracts/needs-human-format.md)
- [X] T006 [P] Create `SpeckitOrchestrator.InteractiveClarify.Settings` in `lib/speckit_orchestrator/interactive_clarify.ex` — `enabled?` (bool, default `false`), `answer_timeout_s` (`60..86_400`, default `1_800`), `max_rounds` (`1..5`, default `3`); `validate/1` never clamps, non-boolean `enabled?` raises `ArgumentError`; `from_context/1` accepts a `RunContext`, a string/atom-keyed map, or `nil` (data-model.md, mirrors `Remediation.Settings`)
- [X] T007 [P] Add `InteractiveClarify.decide/3` and `on_exit/1` to the same file — the decision table (`:pass | :await | {:escalated, {:needs_human, :rounds_exhausted}}`) and the exit→reason map (`:answer_timeout | :breaker | :drained | :restart` → `{:needs_human, sub}`) (data-model.md Decision table, research.md R2/R5)
- [X] T008 [P] Add `InteractiveClarify.AnswerSet` to the same file — `build(parsed, raw_params)` (numbered blank-with-default → `{:default, text}`, blank-without-default → `{:error, {:missing_answer, qid}}`; freeform blank → `{:error, :empty_answer}`) and `render(t, round)` producing the "Operator answers" prompt block (data-model.md, research.md R7/R9)
- [X] T009 [P] `interactive_clarify_test.exs` — `Settings.validate/1`/`from_context/1` (bounds, non-boolean raises, absent-key defaults); the full `decide/3` table; `on_exit/1` mapping; `AnswerSet.build/2` (numbered blank w/ and w/o default, freeform blank); `AnswerSet.render/2` block format (data-model.md, research.md R2/R5/R7/R9)
- [X] T010 [P] Add the three `RunContext` keys (`interactive_clarify`, `clarify_answer_timeout_s`, `clarify_max_rounds`) in `lib/speckit_orchestrator/run_context.ex`, following existing `merge/2` precedence (explicit opt > recorded > Config) (research.md R10, FR-017)
- [X] T011 [P] `run_context_test.exs` extended — new keys default when absent, merge precedence explicit > recorded > Config, a pre-029 recorded run without the keys falls back to Config defaults (research.md R10)
- [X] T012 [P] Add Config defaults for the three settings plus `clarify_poll_ms` (default `1_000`) in `lib/speckit_orchestrator/config.ex` (research.md R10)
- [X] T013 Add `preflight_interactive_clarify/1` to `run/1` preflight in `lib/speckit_orchestrator.ex`, alongside `preflight_remediation/1` — returns `{:error, {:preflight, [{:invalid_answer_timeout, v} | {:invalid_max_rounds, v}]}}` before any store write (contracts/facade-api.md Run options, FR-001)
- [X] T014 [P] Add the `speckit_clarify_round` table definition (frozen attribute list per data-model.md) to `lib/speckit_orchestrator/store/schema.ex` and `lib/speckit_orchestrator/store/records.ex`
- [X] T015 Add migration `{6, "create speckit_clarify_round", &create_clarify_round/0}` in `lib/speckit_orchestrator/store/migrations.ex` (a create, not a transform); `current_version/0` becomes `6` (research.md R11)
- [X] T016 [P] Add `Writer.record_feature_awaiting/3` and `Writer.record_feature_resumed/2` in `lib/speckit_orchestrator/store/writer.ex` — one transaction opens the round and sets `FeatureRun.status = :awaiting_answers` / sets it back to `:running` (data-model.md invariants, research.md R6)
- [X] T017 [P] Add `Writer.answer_round/3`, `Writer.close_round/3` and `Writer.mark_round_applied/2` in the same file — guarded on `outcome == :open`, submitted `seq` matching the row, `now < deadline_at` for answers; any other state returns `{:error, {:stale_round, current}}` (research.md R3, data-model.md invariants)
- [X] T018 [P] `store/clarify_round_test.exs` — migration v6 creates the table; a concurrent `answer_round/3` vs `close_round/3` race resolves to exactly one outcome and the loser gets `{:stale_round, _}`; an answer past `deadline_at` is rejected; `mark_round_applied/2` is idempotent (research.md R3, SC-006)
- [X] T019 [P] Add `:awaiting_answers` to `Feature.status` (non-terminal) in `lib/speckit_orchestrator/feature.ex`; `Feature.terminal?/1` returns `false` for it (data-model.md Feature lifecycle)
- [X] T020 [P] Update `Release.next/3` in `lib/speckit_orchestrator/release.ex` — the one-at-a-time clause becomes `status in [:running, :awaiting_answers] ⇒ :none` (research.md R6, US1 stacked-backlog edge case)
- [X] T021 [P] `release_test.exs` extended — an `:awaiting_answers` feature counts as in-flight and blocks release of the next backlog feature
- [X] T022 Add `{:feature_awaiting, id}` / `{:feature_resumed, id}` `handle_info` clauses to the Coordinator (`lib/speckit_orchestrator/coordinator.ex`) — update `statuses`; the status is never terminal, so `classify/1` and the final report are unaffected until Phase 6 adds `clarify_rounds` (research.md R6) (depends on T019, T020)
- [X] T023 [P] `coordinator_test.exs` extended — `{:feature_awaiting, id}` / `{:feature_resumed, id}` update `statuses` without ending the run or releasing another feature

**Checkpoint**: `NeedsHuman`, `InteractiveClarify`, the settings plumbing, the new table, and the non-terminal status all exist and are unit-green. US1-US4 work can now proceed.

---

## Phase 3: User Story 1 - Answer the reviewer's questions live and keep the run going (Priority: P1) 🎯 MVP

**Goal**: With interactive clarify on, a clarify-phase `## NEEDS HUMAN` puts the feature into a visible `:awaiting_answers` state (worktree live, run not parked, nothing else released) instead of escalating; the operator answers via a single freeform field, clarify re-runs with the answers as authoritative input, and the feature proceeds to plan in the same run.

**Independent Test**: Start a run with the switch on against a feature whose clarify reliably produces `## NEEDS HUMAN` (LedgerLite 007). Answer the question, then observe: the feature leaves `awaiting_answers`, clarify re-runs with the answer, the spec records it under Clarifications, the feature proceeds to `:plan`, and the run never parks (spec.md US1).

### Implementation for User Story 1

- [X] T024 [US1] Add the `InteractiveClarify.decide/3` interception to the clarify branch of `FeatureRunner.loop/12` (`lib/speckit_orchestrator/feature_runner.ex`) — `:pass` takes today's unchanged path, `{:escalated, reason}` goes to the existing terminal path, `:await` calls `await_answers/…` (contracts/wait-protocol.md Entry, research.md R1/R2)
- [X] T025 [US1] Implement `await_answers/…` in the same file — `NeedsHuman.extract/1` + `parse_questions/1` on the final text, write the escalated checkpoint at `:clarify` (same as today's terminal path), `Writer.record_feature_awaiting/3`, `notify {:feature_awaiting, id}`, emit `[:speckit, :clarify, :awaiting]` with `%{feature_id, seq, round, max_rounds, deadline_at}` (contracts/wait-protocol.md Entry, research.md R1)
- [X] T026 [US1] Implement the tick loop in the same file — per tick, in order: `Workers.waiting(poll_ms)`, `Workers.drain_requested?()`, `Ledger.breaker_tripped?(ledger)`, the round row's `outcome`, the deadline, else `receive {:clarify_answered, ^key} -> tick; after poll_ms -> tick`; act on the transaction result, not the triggering message (contracts/wait-protocol.md Tick, research.md R3/R4)
- [X] T027 [US1] Add `Workers.waiting/1` in `lib/speckit_orchestrator/workers.ex` — writes `deadline_at = now + poll_ms` to `Workers.Deadlines` so `Workers.Bound.wait_ms/3` for a waiting worker is `poll_ms + call_grace + 30s`, independent of `answer_timeout_s` (research.md R4, contracts/wait-protocol.md Invariants, SC-005)
- [X] T028 [P] [US1] `workers_test.exs` extended — `Workers.waiting/1` sets the short deadline; `Workers.Bound.wait_ms/3` for a waiting worker ignores `answer_timeout_s`
- [X] T029 [US1] Implement the answered path in `feature_runner.ex` — re-check `Ledger.breaker_tripped?`/`Workers.drain_requested?` (escalate if tripped, leaving the round `:answered` with `applied_at: nil`); else `Writer.record_feature_resumed/2` + `Writer.mark_round_applied/2`, emit `[:speckit, :clarify, :answered]`, `notify {:feature_resumed, id}`, `PhaseStep.run(pid, feature, :clarify, operator_answers: AnswerSet.render(...))`, then `Pipeline.next/3` again and `decide/3` with `rounds_used + 1` (contracts/wait-protocol.md Answered path, research.md R1) (depends on T024-T027)
- [X] T030 [US1] Add `PhaseRequest.append_clarify_answers/2` in `lib/speckit_orchestrator/phase_request.ex` — renders the "Operator answers (authoritative, round N)" block (contracts/needs-human-format.md Answer-folding instruction), kept separate from `append_resume_prompt/2` so both may appear (research.md R7)
- [X] T031 [US1] Thread `:operator_answers` through the `"phase.run"` signal params → `Actions.RunFeaturePhase` → `PhaseRequest.build/3` as `clarify_answers:`, only for `:clarify` (`lib/speckit_orchestrator/actions/run_feature_phase.ex`, `lib/speckit_orchestrator/phase_request.ex`) (research.md R7) (depends on T030)
- [X] T032 [P] [US1] `phase_request_test.exs` extended — `append_clarify_answers/2` renders the answer block correctly and coexists with `append_resume_prompt/2`; mode off never sets `clarify_answers` (FR-002)
- [X] T033 [US1] Add `SpeckitOrchestrator.pending_questions/0,1` in `lib/speckit_orchestrator.ex` — a transactional read of `:open` round rows for the current repo's current run; `[]` when nothing waits, never raises on an absent run (contracts/facade-api.md) (depends on T017)
- [X] T034 [US1] Add `SpeckitOrchestrator.answer/3,4` in the same file — builds an `AnswerSet` from the round's stored parse before any write, calls `Writer.answer_round/3`, on success sends `{:clarify_answered, round_key}` to the repo's registered worker(s), `opts[:via]` (`:console | :iex`, default `:iex`) recorded as `answered_via` (contracts/facade-api.md `answer/3,4`) (depends on T008, T017)
- [X] T035 [P] [US1] Add the pending/open-round read used by `pending_questions/0` (and later Run Detail) to `lib/speckit_orchestrator/store/query.ex` (research.md R11, contracts/facade-api.md)
- [X] T036 [US1] Add a freeform-only "Awaiting answers" section to `EscalationsLive` (`lib/speckit_orchestrator/web/live/escalations_live.ex`), rendered only when `pending_questions/0` is non-empty, marked `data-awaiting-answers`: header (feature id, slug, round n/m, waited/left), a `<pre>` of the raw block plus `<textarea name="answers[*]">`, hidden `feature_id`/`seq`, `phx-submit="answer"` → `SpeckitOrchestrator.answer/3`, refusals via `<.form_refusal>`, live updates through the existing catch-all `handle_info` (contracts/operator-surfaces.md Escalations view) (depends on T033, T034)
- [X] T037 [P] [US1] `feature_runner_clarify_wait_test.exs` — mode on: clarify's `{:escalated, :needs_human}` → `:awaiting_answers`, worktree retained, run not parked, `Release.next/3` → `:none`, zero `Ledger` calls while waiting (quickstart.md, spec.md US1 Acceptance Scenario 1/3, FR-004)
- [X] T038 [P] [US1] `feature_runner_clarify_wait_test.exs` — `answer/3` triggers the clarify re-run with the Operator-answers block, and a clean re-run advances the feature to `:plan` in the same run (quickstart.md, spec.md US1 Acceptance Scenario 2, SC-002)
- [X] T039 [P] [US1] `feature_runner_clarify_wait_test.exs` — mode off: `## NEEDS HUMAN` produces `{:escalated, :needs_human}` exactly as before, with identical records and report (quickstart.md, spec.md US1 Acceptance Scenario 4, FR-002, SC-003)

**Checkpoint**: User Story 1 is fully functional and independently testable — a run with the switch on no longer parks on an answerable question.

---

## Phase 4: User Story 2 - Fall back safely when nobody answers (Priority: P1)

**Goal**: Every non-answer exit from `awaiting_answers` — timeout, breaker trip, supersession drain, exhausted rounds, or an orchestrator restart — escalates the feature exactly as today's `## NEEDS HUMAN` escalation would, apart from a more specific reason, with no spend while waiting and no feature left hanging.

**Independent Test**: Set a short answer timeout, let a feature reach `awaiting_answers`, and do not answer — confirm it escalates and the run parks exactly as today. Repeat once each for a breaker trip, a supersession drain, and a feature whose re-run keeps asking until the round limit (spec.md US2).

### Implementation for User Story 2

- [X] T040 [US2] Finish the timeout branch of the tick loop (T026) — `now >= deadline_at` → `Writer.close_round(:timed_out)` → escalate `{:needs_human, :answer_timeout}` through the existing terminal path (contracts/wait-protocol.md Tick #5, research.md R5) (depends on T026)
- [X] T041 [US2] Finish the drain/breaker branches of the tick loop (T026) — `Workers.drain_requested?()` → `Writer.close_round(:drained)` → escalate `{:needs_human, :drained}`; `Ledger.breaker_tripped?/1` → `Writer.close_round(:breaker)` → escalate `{:needs_human, :breaker}`; neither starts a session (contracts/wait-protocol.md Tick #2-#3, research.md R4/R5, FR-011) (depends on T026)
- [X] T042 [US2] Wire the rounds-exhausted exit — when the answered path's `decide/3` (T029) returns `{:escalated, {:needs_human, :rounds_exhausted}}`, escalate with `evidence: %{questions: raw, rounds_used: n}` on the escalation record (data-model.md Escalation.evidence, research.md R5) (depends on T029)
- [X] T043 [US2] Update `Report.format_reason/1` (`lib/speckit_orchestrator/report.ex`) to render `{:needs_human, sub}` for each `sub` (`:rounds_exhausted | :answer_timeout | :breaker | :drained | :restart`); plain `:needs_human` (mode off) renders unchanged (research.md R5)
- [X] T044 [P] [US2] `report_test.exs` extended — `format_reason/1` for every `{:needs_human, sub}` variant, plain `:needs_human` byte-identical to before
- [X] T045 [US2] Update `Recovery.Reconcile.status/3` (`lib/speckit_orchestrator/recovery/reconcile.ex`) — a persisted `:awaiting_answers` row with no live worker becomes `{:escalated, {:needs_human, :restart}}`; `reconcile_run/2` closes the open round `:interrupted` and records the escalation in one transaction, preserving the questions (research.md R12, FR-016)
- [X] T046 [US2] Update `Writer.supersede_in_flight!` (`lib/speckit_orchestrator/store/writer.ex`) to map an `:awaiting_answers` row the same way it maps other in-flight rows, for the dead-worker case only — a live worker is drained by T041 and records its own escalation first (research.md R12)
- [X] T047 [P] [US2] `recovery_test.exs` extended — reconciling a persisted `:awaiting_answers` row produces `{:escalated, {:needs_human, :restart}}`, the round is `:interrupted`, and the questions are kept (quickstart.md, FR-016)
- [X] T048 [US2] Add `{:error, {:awaiting_answers, feature_id}}` to `guard_active_run/1` (`lib/speckit_orchestrator.ex`), checked ahead of `{:active_run, pid}`; `resume/2`, `continue_run/1` and `resume_run/1` return it for an awaiting feature; `force: true` drains the waiting worker (which escalates `{:needs_human, :drained}` via T041) and then proceeds as today (contracts/facade-api.md Resume guard, research.md R14) (depends on T041)
- [X] T049 [P] [US2] `resume_test.exs` extended — `resume/2` without force on an awaiting feature returns `{:error, {:awaiting_answers, id}}`; with `force: true` it drains and proceeds (contracts/facade-api.md)
- [X] T050 [P] [US2] `feature_runner_clarify_wait_test.exs` — a short injected timeout produces `{:needs_human, :answer_timeout}` and the run parks (spec.md US2 Acceptance Scenario 1)
- [X] T051 [P] [US2] `feature_runner_clarify_wait_test.exs` — a tripped breaker while waiting escalates with zero `PhaseStep` calls (spec.md US2 Acceptance Scenario 2)
- [X] T052 [P] [US2] `feature_runner_clarify_wait_test.exs` — `Workers.drain/1` while waiting returns within `poll_ms + grace + 30s` regardless of `answer_timeout_s` (spec.md US2 Acceptance Scenario 3, SC-005)
- [X] T053 [P] [US2] `feature_runner_clarify_wait_test.exs` — a re-run that keeps reporting `## NEEDS HUMAN` opens rounds 1..max and then escalates `{:needs_human, :rounds_exhausted}` (spec.md US2 Acceptance Scenario 4/5)
- [X] T054 [P] [US2] `store/clarify_round_test.exs` — a second `answer/3` for the same `seq`, an answer racing a `close_round(:timed_out)`, and a submission against an old `seq` all resolve to exactly one outcome; every stale one is refused with no effect (SC-006)

**Checkpoint**: User Stories 1 and 2 together make the switch safe to leave on — every exit path is covered and none hangs or spends.

---

## Phase 5: User Story 3 - Answer question by question, from console or iex (Priority: P2)

**Goal**: The clarify reviewer writes numbered questions (Q1..Qn); the operator gets one answer field per question with a one-click recommended default, the same round is answerable from iex, and an unstructured block still gets a single field.

**Independent Test**: Let a feature await answers with numbered questions. Confirm the console shows one field per question with each recommended default available. Answer via iex and confirm the feature proceeds. Repeat with an unstructured block and confirm a single field appears (spec.md US3).

### Implementation for User Story 3

- [X] T055 [US3] Add the "Question format" section to `priv/prompts/clarify.md` — numbered `### Q1..Qn`, `**Context**`, `**Options**`/`**Recommended**` (at least one required), materiality and "bound and batch" rules unchanged (contracts/needs-human-format.md Format, FR-012)
- [X] T056 [US3] Verify/extend `append_clarify_answers/2` (T030) against the parsed numbered questions so rendered lines read `Qn: <answer>` or `Qn (accepted recommended): <default>` per question (contracts/needs-human-format.md Answer-folding instruction) (depends on T030, T055)
- [X] T057 [US3] Extend the Escalations "Awaiting answers" section (T036) with the numbered-question layout — one block per `Qn` with `data-question="Qn"`: question text, context, options as chips, `<textarea name="answers[Qn]">`, and a "Use recommended" button (`phx-click="use_default"`) that fills the field and notes that a blank field takes the default, when `recommended` is set (contracts/operator-surfaces.md Escalations view) (depends on T036)
- [X] T058 [US3] Wire `AnswerSet.build/2` (T008) into the console and facade `answer/3` submission path (T034) so a blank numbered answer with a default is accepted as that default (recorded `{:default, text}`), and a question with no default is rejected with `{:missing_answer, qid}` before any write (research.md R9, contracts/facade-api.md `answer/3` step 1) (depends on T008, T034)
- [X] T059 [P] [US3] `escalations_live_test.exs` — numbered questions render one field per `Qn` with context/options/recommended; "Use recommended" fills the field; an unstructured block still renders a single field (quickstart.md, spec.md US3 Acceptance Scenario 1/4)
- [X] T060 [P] [US3] Confirm `pending_questions/0,1` (T033) returns the full per-question shape (`feature_id, spec_label, round, max_rounds, seq, questions, started_at, deadline_at`) needed for iex listing (contracts/facade-api.md) (depends on T033)
- [X] T061 [P] [US3] iex-parity test — `pending_questions/0` lists the feature, round and each question; `answer/3` submitted from iex proceeds exactly as a console submission (quickstart.md §2, spec.md US3 Acceptance Scenario 2)
- [X] T062 [P] [US3] `store/clarify_round_test.exs` or `interactive_clarify_test.exs` — answers submitted against a round that is no longer current (already answered, timed out, or superseded) are rejected with a stated reason and have no effect (spec.md US3 Acceptance Scenario 3)
- [X] T063 [P] [US3] Close any remaining `NeedsHuman.parse_questions/1` gaps found while wiring T055-T058 (malformed numbered blocks always fall back to `{:freeform, block}`, never a partial parse) (spec.md US3 Acceptance Scenario 4, FR-018) (extends T003 if needed)
- [X] T064 [P] [US3] `interactive_clarify_test.exs` — a numbered question left blank with a recommended default is answered with that default; a question with no default blocks submission until answered (spec.md US3 Acceptance Scenario 5) (extends T009 if needed)

**Checkpoint**: All user stories through US3 are independently functional — structured answering is faster, but the freeform path from US1 still works unchanged.

---

## Phase 6: User Story 4 - See and configure it per run (Priority: P2)

**Goal**: The operator chooses interactive clarify, its timeout and round limit from the trigger form; the choice is recorded and shown on run detail/report/resume; awaiting-answers features are visually distinct on every status surface.

**Independent Test**: Start two runs, one with the switch on and one off. Confirm each run's recorded settings and detail view show the chosen mode, timeout and round limit. Confirm an awaiting feature shows a distinct status everywhere (spec.md US4).

### Implementation for User Story 4

- [X] T065 [US4] Amend `docs/design-constitution.md` — an eighth status colour, `--awaiting` (`#fb923c`), added to the status table and the fenced `:root` block, "seven" → "eight", as pre-flagged in the 5.0.0 Sync Impact Report (contracts/operator-surfaces.md Status token, governed amendment)
- [X] T066 [P] [US4] Add the `--awaiting` token and `[data-status="awaiting_answers"] { --sc: var(--awaiting); }` block to `priv/static/assets/console.css` — no keyframe, no animation (contracts/operator-surfaces.md) (depends on T065)
- [X] T067 [P] [US4] Extend `CoreComponents` (`lib/speckit_orchestrator/web/components/core_components.ex`) — `@labels[:awaiting_answers] = "awaiting answers"`, the `status_class/1` guard, `statuses/0` (contracts/operator-surfaces.md) (depends on T065)
- [X] T068 [P] [US4] Extend `test/support/design_contract.ex` — `@contract_colors`, `@status_hexes`, `@status_names` for `awaiting_answers` (contracts/operator-surfaces.md, SC-008) (depends on T065)
- [X] T069 [US4] Add the interactive-clarify block to the trigger form (`lib/speckit_orchestrator/web/live/trigger_live.ex`), copying the auto-remediation block's shape — a switch (`phx-click="toggle_interactive_clarify"`, `data-interactive-clarify`), `form#interactive-clarify-form phx-change="update_clarify"` with `answer_timeout_min` (1..1440, `data-clarify-timeout`) and `max_rounds` (1..5, `data-clarify-rounds`), both `disabled` while the switch is off; validates via `InteractiveClarify.Settings.validate/1` before the run starts, refusing out-of-range via `<.form_refusal>`; `start_opts/1` converts minutes to `clarify_answer_timeout_s` (contracts/operator-surfaces.md Trigger form, FR-001) (depends on T006)
- [X] T070 [P] [US4] `trigger_live_test.exs` extended — toggling on enables the inputs, out-of-range values are refused inline before the run starts, `start_opts/1` converts minutes to seconds (quickstart.md §3.1, spec.md US4 Acceptance Scenario 1)
- [X] T071 [US4] Wire the `awaiting answers` pill (round n/m, waited, left, derived from the open round's `started_at`/`deadline_at` via the existing elapsed-tick mechanism) into Mission Control's row and status-count strip, the Pipeline DAG node and legend, the Runs list, the Run Detail card, and the feature drawer (`lib/speckit_orchestrator/web/live/{mission_control,pipeline_dag,runs,run_detail}_live.ex`) (contracts/operator-surfaces.md Every status surface, FR-014) (depends on T067)
- [X] T072 [US4] Make the Mission Control row for an awaiting feature link to `/escalations#awaiting-<id>` (`lib/speckit_orchestrator/web/live/mission_control_live.ex`) (contracts/operator-surfaces.md) (depends on T071)
- [X] T073 [P] [US4] `mission_control_live_test.exs` / `pipeline_dag_live_test.exs` extended — the awaiting pill renders with round/waited/left; the DAG legend includes the new status (quickstart.md §3.2)
- [X] T074 [US4] Add the round-history block to Run Detail (`lib/speckit_orchestrator/web/live/run_detail_live.ex`) — `data-clarify-rounds`, one row per round (`data-round={seq}`): round n/m, asked at, questions (collapsed `<details>`), answers (marked `typed`/`accepted recommended`) with answered-at/via, or the outcome chip; a final row for `{:needs_human, :rounds_exhausted}` from the escalation's evidence (contracts/operator-surfaces.md Run Detail, FR-015) (depends on T035, T042)
- [X] T075 [P] [US4] `run_detail_live_test.exs` extended — the round-history block renders per round with the correct outcome chips; the settings chips already show the three new keys with no extra code (quickstart.md §3.4)
- [X] T076 [US4] Treat `:awaiting_answers` as an active-attention cell in `phase_cell_state/2` (research.md R13) (depends on T067)
- [X] T077 [US4] Extend `print_status/0`'s STATUS output and add the `awaiting:` line (`feature round n/m waited Xm Ym left`), shown only when non-empty, so mode-off output is byte-identical (`lib/speckit_orchestrator.ex`, `lib/speckit_orchestrator/report.ex`) (contracts/facade-api.md Status, research.md R14/R15)
- [X] T078 [US4] Add `clarify_rounds: %{feature_id => [round_summary]}` to the Coordinator's final report (`lib/speckit_orchestrator/coordinator.ex`) — `%{}` when the mode is off; `Report` prints a `clarify:` block only when it is non-empty (data-model.md Coordinator report, research.md R15) (depends on T022)
- [X] T079 [P] [US4] `report_test.exs` / `coordinator_test.exs` extended — `clarify_rounds` is populated correctly per feature, `%{}` when the mode is off, and the `clarify:` block is absent (not empty) when there is nothing to show (quickstart.md, FR-015)
- [X] T080 [P] [US4] `print_status` test — STATUS shows `awaiting_answers`; the `awaiting:` line appears only when a feature is waiting (contracts/facade-api.md)
- [X] T081 [US4] Confirm `resume/2`, `resume_run/1` and `continue_run/1` apply a resumed run's recorded interactive-clarify settings unless the operator explicitly overrides them (research.md R10 notes this holds "for free" via `RunContext.merge/2`; this task closes any gap found at the resume call sites) (FR-017)
- [X] T082 [P] [US4] `resume_test.exs` extended — a resumed run keeps its recorded interactive-clarify settings; an explicit override at resume takes precedence (spec.md US4 Acceptance Scenario 4)
- [X] T083 [P] [US4] `run/1` preflight test — `clarify_answer_timeout_s: 30` / `clarify_max_rounds: 6` returns `{:error, {:preflight, _}}` before any store write (quickstart.md, spec.md US4 Acceptance Scenario 1) (depends on T013)

**Checkpoint**: All four user stories are independently functional and visible — the mode is fully configurable, recorded, and legible on every operator surface.

---

## Phase 7: Docs & Polish

**Purpose**: Cross-cutting documentation required by the plan (FR-020); final full-suite and live validation.

- [X] T084 [P] Add an "Interactive clarify" section to `docs/runbook.md` — the mode, its three settings, the answering surfaces (console, iex), and every fallback (timeout, breaker, drain, restart, rounds exhausted) (FR-020, plan.md Delivery order step 5)
- [X] T085 [P] Update the Pipeline paragraph in `CLAUDE.md` — "the clarify gate has no knobs at all" gains the one knob (interactive clarify, off by default) (FR-020, plan.md Delivery order step 5)
- [X] T086 Confirm `design_contract_test.exs` stays green after all console changes (T065-T068, T071-T076) (SC-008)
- [X] T087 Run the full suite: `mise exec -- mix test` (quickstart.md §1) — zero regressions, `warnings_as_errors` clean, all new tests from Phases 2-6 pass
- [X] T088 Run `mise exec -- mix test --cover` — confirm the coverage target holds on the new pure core (`NeedsHuman`, `InteractiveClarify`)
- [X] T089 Drive the live scenario, manual, per quickstart.md §2-§4 — against `../ledgerlite` via a synthetic single-spec feature (the original feature-007 backlog trap no longer exists in the target repo; interactive clarify on, answer via iex then console, confirm the re-run starts within 5s, `spec.md` shows the answers under `## Clarifications` with `## NEEDS HUMAN` removed, the feature reaches `:plan` with the run never parked; then the four fallback drills (timeout, breaker, supersession, restart) (SC-001, SC-002, SC-004, SC-005, SC-007). The restart drill's first pass found a real durability gap — `Store.Mnesia.transaction/1` used `:mnesia.transaction/1` instead of `:mnesia.sync_transaction/1`, so a hard kill right after a feature entered `:awaiting_answers` could lose the round entirely; fixed (single choke point, `lib/speckit_orchestrator/store/mnesia.ex`) and re-verified live — the round now survives a hard kill and reconciles to `:escalated {:needs_human, :restart}` with its questions intact.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS every user story. `NeedsHuman` (T002) and `InteractiveClarify` (T006-T008) are needed by the wait protocol (US1/US2), the console panel (US1/US3), and the trigger form (US4). The table/migration/Writer functions (T014-T017) are needed by US1's `await_answers`/`answer` path.
- **US1 (Phase 3)**: Depends on Foundational (T002, T006-T010, T012, T014-T020). Independent of US2/US3/US4 in scope, but shares files with them (see below).
- **US2 (Phase 4)**: Depends on Foundational and on US1's tick-loop/answered-path scaffolding (T024-T029), since the fallback exits are branches of that same loop.
- **US3 (Phase 5)**: Depends on Foundational (T002 `parse_questions/1`, T008 `AnswerSet`) and on US1's console panel (T036) and facade `answer/3` (T034), which it extends rather than replaces.
- **US4 (Phase 6)**: Depends on Foundational (T019 status, T022 Coordinator) and, for the round-history block, on US1's `Query` read (T035) and US2's rounds-exhausted evidence (T042).
- **Docs & Polish (Phase 7)**: Depends on US1-US4 all complete.

### User Story Dependencies

- **US1 (P1)**: The whole value of the feature; makes the mode usable at all with a single freeform field.
- **US2 (P1)**: Without it the mode would be unsafe to leave on — it shares `feature_runner.ex`'s tick loop and answered path with US1 rather than introducing new ones.
- **US3 (P2)**: A no-op without US1's console panel and `answer/3` to extend.
- **US4 (P2)**: A no-op without US1/US2's `:awaiting_answers` status and rounds to display; not required for the mode to function correctly.

### Within Each Phase

- Pure modules (`NeedsHuman`, `InteractiveClarify`, `BranchGuard`-style helpers) before call-site wiring
- Schema/migration/Writer functions before any runner code that calls them
- The tick-loop entry (T024-T026) before the answered path (T029) and before US2's fallback branches (T040-T042)
- Facade functions (`pending_questions/0,1`, `answer/3,4`) before the console panel that calls them
- Console/status-surface wiring (US4) after the status and rounds exist (Foundational, US1, US2)

### Parallel Opportunities

- T002-T009 (the two new pure modules and their tests, independent functions within each file) run in parallel
- T010-T012 (RunContext keys, Config defaults, their test) run in parallel with T002-T009
- T014, T016, T017 (schema/records, Writer functions — independent functions) run in parallel; T015 (migration) depends on T014
- T019-T021 (Feature/Release changes + test) run in parallel with T002-T018
- Within US1: T028, T032, T037-T039 (independent test files/additions) run in parallel once their subjects (T024-T036) land
- Within US2: T044, T047, T049-T054 run in parallel once T040-T048 land
- Within US3: T059-T064 run in parallel once T055-T058 land
- Within US4: T066-T068 (design-constitution follow-ups, different files) run in parallel once T065 lands; T070, T073, T075, T079, T080, T082, T083 run in parallel once their subjects land
- T084, T085 (docs) run in parallel with each other and with T086-T088

---

## Parallel Example: Foundational Phase

```bash
# Launch the two new pure modules and their tests together (different files):
Task: "Create SpeckitOrchestrator.NeedsHuman in lib/speckit_orchestrator/needs_human.ex"
Task: "Create InteractiveClarify.Settings/decide/on_exit/AnswerSet in lib/speckit_orchestrator/interactive_clarify.ex"
Task: "Add the three RunContext keys in lib/speckit_orchestrator/run_context.ex"
Task: "Add Config defaults + clarify_poll_ms in lib/speckit_orchestrator/config.ex"
Task: "Add the speckit_clarify_round table in store/schema.ex and store/records.ex"
```

## Parallel Example: User Story 1 tests

```bash
Task: "feature_runner_clarify_wait_test.exs — mode on reaches :awaiting_answers, no Ledger calls"
Task: "feature_runner_clarify_wait_test.exs — answer/3 triggers a clean re-run to :plan"
Task: "feature_runner_clarify_wait_test.exs — mode off is byte-identical to today"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: `feature_runner_clarify_wait_test.exs` (T037-T039) green — an attended run no longer parks on an answerable question (spec.md SC-001, minus the guaranteed-exit safety net US2 adds)

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. Add US1 → validate independently → the mode delivers its core value (MVP)
3. Add US2 → validate independently → the mode is now safe to leave on unattended
4. Add US3 → validate independently → answering gets faster and iex-parity lands
5. Add US4 → validate independently → the mode is visible and configurable everywhere
6. Docs & Polish → runbook, CLAUDE.md, full suite, live LedgerLite 007 validation

### Parallel Team Strategy

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: US1 (Phase 3) — `feature_runner.ex` wait entry/tick/answered path, `phase_request.ex`, facade `pending_questions/answer`, the freeform Escalations panel
   - Developer B: US2 (Phase 4), once US1's tick loop exists — the fallback branches, `report.ex`, `recovery/reconcile.ex`, `writer.ex` supersession, the resume guard
   - Developer C: US3 (Phase 5), once US1's panel exists — `clarify.md`, the per-question UI, `AnswerSet` wiring; then US4 (Phase 6) — design-constitution amendment, trigger form, status surfaces, round history, report lines
3. Docs & Polish (Phase 7) lands once US1-US4 are all merged

---

## Notes

- `warnings_as_errors` is on; run everything through `mise exec --`
- Mode off must stay byte-identical (FR-002, SC-003) — every task that touches a shared call site (`RunFeaturePhase`, `Report`, `print_status`, the trigger form, `resume/2`) must verify the off-path is unchanged, not just the on-path
- The design-contract guard (`design_contract_test.exs`) must stay green — one new status token, no ad-hoc colour, no new keyframe (T065-T068, T086)
- No `Ledger.reserve/commit` and no `PhaseStep` call may happen between wait entry and the answered path (FR-004) — this is the single most load-bearing invariant in Phase 3/4 and is worth asserting directly in T037/T051
- Commit after each task or logical group; verify new tests fail before their implementation task lands
