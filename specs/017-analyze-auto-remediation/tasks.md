---

description: "Task list for Analyze Auto-Remediation Loop"
---

# Tasks: Analyze Auto-Remediation Loop

**Input**: Design documents from `/specs/017-analyze-auto-remediation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — plan.md's Project Structure and Testing strategy enumerate
a specific test file per new/extended module, and Constitution Principle VI
requires `@spec` + hermetic pure-core coverage. Every implementation task below
has a matching test task.

**Organization**: Phase 2 (Foundational) carries the two pure decision surfaces
(`Severity`, `Remediation`) and the extended durable records — every user story
reads them. Phases 3–5 map to US1/US2/US3 exactly as in spec.md.

## Path Conventions

Single Elixir application. Source under `lib/speckit_orchestrator/`, tests
under `test/speckit_orchestrator/`, fixtures under `test/fixtures/`, per
plan.md's Project Structure.

---

## Phase 1: Setup

**Purpose**: Config surface and the prompt pack the whole loop depends on.

- [X] T001 [P] Add `auto_remediation`, `auto_remediation_threshold`, `auto_remediation_attempt_limit`, `auto_remediation_model` keys plus `cost_estimates[:auto_remediation]` (1.26) and `cost_estimates[:remediation]` (0.95, closes research R6's 0.0 hole) in `config/config.exs`
- [X] T002 [P] Create `priv/prompts/analyze_remediation.md` corrective-instruction framing pack (contracts/remediation.md §3)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure decision surfaces and the durable-record extensions every
user story is built on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T003 [P] Create `SpeckitOrchestrator.Severity` pure module in `lib/speckit_orchestrator/severity.ex` — `values/0`, `rank/1`, `parse/1`, `parse_finding/1`, `at_or_above?/2`, `max/1` (contracts/severity.md §1-2, §4)
- [X] T004 [P] `test/speckit_orchestrator/severity_test.exs` — total order, `"blocker"` synonym, `:unknown` matches no threshold including `:low` (research R3)
- [X] T005 [P] Add `auto_remediation?/0`, `auto_remediation_threshold/0`, `auto_remediation_attempt_limit/0`, `auto_remediation_model/0` accessors to `lib/speckit_orchestrator/config.ex`
- [X] T006 Add `auto_remediation`, `auto_remediation_threshold`, `auto_remediation_attempt_limit`, `auto_remediation_model` fields to `RunContext` (`capture/1`, `to_map/1`, `from_map/1`, `@keys`) in `lib/speckit_orchestrator/run_context.ex` (contracts/checkpoint-analyze-remediation.md §1)
- [X] T007 [P] Extend `test/speckit_orchestrator/run_context_test.exs` — 4-field capture/round-trip/merge precedence (explicit opt > recorded > live Config)
- [X] T008 Create `SpeckitOrchestrator.Remediation.Settings` struct + `validate/1` + `from_context/1` in `lib/speckit_orchestrator/remediation.ex` (contracts/remediation.md §1)
- [X] T009 Add `Remediation.next/2` — the full 7-row decision table (enabled?, analyze-error, remediation-error, breaker, below-threshold, exhausted, remediate) — same file (contracts/remediation.md §2)
- [X] T010 Add `Remediation.instruction/2` and `Remediation.terminal_reason/2` — same file (contracts/remediation.md §3-4)
- [X] T011 [P] `test/speckit_orchestrator/remediation_test.exs` — `Settings.validate/1` (bad threshold/limit/model, no clamping), `next/2` row order (2-before-4, 3-before-4, 5-before-6, 6-before-7), `instruction/2` determinism and verbatim findings, `terminal_reason/2` decoration and byte-identical-when-off
- [X] T012 Extract `run_phase/7` + `run_phase_with_retry/8` out of `lib/speckit_orchestrator/feature_runner.ex` into new `SpeckitOrchestrator.PhaseStep` (`lib/speckit_orchestrator/phase_step.ex`), parameterized by `:label` (default phase name), `:retries`, `:span_meta`; `feature_runner.ex` delegates (research R8)
- [X] T013 [P] Create `test/speckit_orchestrator/phase_step_test.exs` proving the extraction is behaviour-preserving (same span, same meta, same retry policy, same transcript write)
- [X] T014 Add `max_severity/1`, `findings_at_or_above/2`, `unknown_severities/1` to `lib/speckit_orchestrator/analyze_result.ex`; leave `critical?/1`/`high?/1` untouched (contracts/severity.md §5)
- [X] T015 [P] Extend `test/speckit_orchestrator/analyze_result_test.exs` — severity accessors, unknown-severity findings preserved verbatim and not dropped
- [X] T016 Amend `.specify/memory/constitution.md` Principle V per contracts/constitution-amendment.md §3, prepend Sync Impact Report (§5), bump `**Version**: 1.1.0 → 1.2.0` and `Last Amended`, retain prior report history
- [X] T017 [P] Update this repo's `CLAUDE.md` architecture section so the analyze-gate description mentions the auto-remediation loop (contracts/constitution-amendment.md §6)

**Checkpoint**: Foundation ready — pure decision surfaces exist and are tested; user story implementation can now begin.

---

## Phase 3: User Story 1 - Self-heal an analyze finding without waking a human (Priority: P1) 🎯 MVP

**Goal**: An analyze run with an at-or-above-threshold finding triggers one
remediation attempt and a re-run; a clean re-run advances the feature exactly
as an initially clean analyze would, with the self-heal fully recorded.

**Independent Test**: A feature whose analyze reports one High finding on pass
1 and none on pass 2 reaches `:done` with no operator input; a remediation step
ran between the two analyze runs; the final recorded analyze outcome is the
clean one.

### Tests for User Story 1

- [X] T018 [P] [US1] Create `test/fixtures/analyze/` findings JSON fixtures: `high-then-clean.json`, `medium-only.json`, `unknown-severity.json`, `malformed.json` (plan.md Project Structure)
- [X] T019 [P] [US1] `test/speckit_orchestrator/analyze_runner_test.exs` against a scripted fake agent — converge case (`{:remediate, …}` on pass 1, `{:gate, …}` on pass 2), disabled short-circuit makes no second harness call (FR-016/SC-004), below-threshold-only makes no harness call beyond the first analyze run, transcripts named `05-analyze-a1.md` / `05-remediation-a1.md` / `05-analyze-a2.md` / `05-analyze.md`

### Implementation for User Story 1

- [X] T020 [P] [US1] Create `Actions.RunAutoRemediation` ("auto_remediation.run" action) in `lib/speckit_orchestrator/actions/run_auto_remediation.ex` — data `%{prompt:, model:, attempt:}`, built via existing `PhaseRequest.build_remediation/3`, folds `last_result`/`last_outcome`/`session_id`/`cost_total` and a `%{phase: :auto_remediation, attempt:, outcome:, cost:}` history entry, decides no control flow (contracts/analyze_loop.md §7)
- [X] T021 [US1] Route `"auto_remediation.run"` signal to the new action in `lib/speckit_orchestrator/feature_agent.ex`
- [X] T022 [US1] Create `SpeckitOrchestrator.AnalyzeRunner` edge module in `lib/speckit_orchestrator/analyze_runner.ex` — `run/1` entry point, disabled short-circuit (one plain-labelled analyze run, no `Remediation.next/2` call), remediate loop dispatching `"auto_remediation.run"`, attempt-numbered records via `PhaseStep` (`label: "analyze-a#{k}"`), charges `Cost.for_phase(:auto_remediation, result)` per attempt (contracts/analyze_loop.md §1-6)
- [X] T023 [US1] Add `run_step/9` clause for `phase == :analyze` in `lib/speckit_orchestrator/feature_runner.ex` delegating to `AnalyzeRunner.run/1`, resolving `Remediation.Settings` once per feature run from the captured `RunContext`; decorate the gate reason via `Remediation.terminal_reason/2` before recording/notifying
- [X] T024 [US1] Generalize `chunk_terminal_override/1` to `terminal_override/1` in `lib/speckit_orchestrator/feature_runner.ex` (same two clauses, no behaviour change) so both `ChunkRunner` and `AnalyzeRunner` share the seam
- [X] T025 [US1] Add `[:speckit, :remediation, :start|:stop|:exception]` event names, `remediation_span/0`, and an `attach_default_logger/0` clause (attempt/limit/outcome/cost) in `lib/speckit_orchestrator/telemetry.ex`; extend the `[:speckit, :phase]` span metadata for `phase: :analyze` with `attempt`/`limit` only when the loop is enabled
- [X] T026 [US1] Add `maybe_put_analyze_remediation/2` (same omit-when-absent shape as `maybe_put_implement_chunk/2`) writing the `analyze_remediation` checkpoint key in `lib/speckit_orchestrator/checkpoint.ex` (contracts/checkpoint-analyze-remediation.md §2)
- [X] T027 [US1] In `test/speckit_orchestrator/feature_runner_test.exs`, pin `auto_remediation: false` on the existing analyze-gate assertions (research R16, around the current High/Critical gate tests) and add a delegation test proving `phase == :analyze` calls `AnalyzeRunner.run/1`
- [X] T028 [P] [US1] Extend `test/speckit_orchestrator/checkpoint_test.exs` — `analyze_remediation` round-trip, pre-017 checkpoint (no key) resolves unchanged

**Checkpoint**: At this point, User Story 1 is fully functional — a feature with a mechanically fixable finding self-heals and reaches `:done`, independently testable via `analyze_runner_test.exs`.

---

## Phase 4: User Story 2 - Give up safely and hand the human a full history (Priority: P2)

**Goal**: When findings persist past the attempt limit, or a remediation step
itself fails, or the breaker trips mid-loop, the feature reaches the correct
terminal state with a complete, auditable attempt history and a fresh budget on
any later resume.

**Independent Test**: A feature whose analyze reports the same
at-or-above-threshold finding every pass attempts remediation exactly
`attempt_limit` times, then reaches the same human-facing terminal state as
with the loop disabled, with the worktree retained and every attempt recorded.

### Tests for User Story 2

- [X] T029 [P] [US2] Add `test/fixtures/analyze/persistent-high.json` and `test/fixtures/analyze/worsening.json` (High → Critical across attempts) to `test/fixtures/analyze/`
- [X] T030 [P] [US2] Extend `test/speckit_orchestrator/analyze_runner_test.exs` — exactly `n` attempts for limit `n` never `n+1` (SC-003, also asserted on `NN-remediation-a*.md` file count), remediation step failure stops immediately with `{:failed, :remediation_failed}` without consuming remaining attempts (FR-008), breaker tripped mid-loop halts with `{:halted, :breaker}` after the in-flight step finishes, worsening findings (High→Critical) decided by the **final** run only

### Implementation for User Story 2

- [X] T031 [US2] In `lib/speckit_orchestrator/analyze_runner.ex`, wire the exhaustion path (`{:gate, {:exhausted, n}, _}`), the remediation-failure path (`{:failed, :remediation_failed, _}`), and the between-steps breaker check (`Ledger.breaker_tripped?/1` → `{:halted, :breaker, _}`) into the loop driven in T022, returning the agent shape per contracts/analyze_loop.md §3 table
- [X] T032 [US2] In `lib/speckit_orchestrator/feature_runner.ex`, ensure `terminal_override/1` (T024) covers `AnalyzeRunner`'s `:failed`/`:halted` terminal shapes the same way it already covers `ChunkRunner`'s
- [X] T033 [US2] Ensure `resume/2`, `resume_run/1` and `resolve/1` always start the loop at `attempts_used == 0` for a new feature run regardless of a checkpoint's recorded `analyze_remediation.attempts_used` (FR-015) — audit call sites in `lib/speckit_orchestrator.ex` / `lib/speckit_orchestrator/coordinator.ex`
- [X] T034 [US2] Add an "auto-remediation: n/m attempts exhausted (threshold X)" summary line, reading the checkpoint's `analyze_remediation` key, above the resume controls in `lib/speckit_orchestrator/web/live/escalations_live.ex` (contracts/telemetry-console.md §5)
- [X] T035 [P] [US2] Extend `test/speckit_orchestrator/resume_test.exs` — a resumed run starts at `attempts_used == 0` even though the checkpoint records an exhausted budget
- [X] T036 [P] [US2] Extend `test/speckit_orchestrator/web/escalations_live_test.exs` — exhausted-attempts summary line renders with the right counts and threshold

**Checkpoint**: At this point, User Stories 1 AND 2 both work independently — self-healing and safe exhaustion/failure/breaker handling are both correct and auditable.

---

## Phase 5: User Story 3 - Launch a run with or without auto-remediation (Priority: P3)

**Goal**: An operator chooses on/off, threshold, and attempt limit at launch,
pre-filled from configured defaults, validated before the run starts, with no
write-back to global config.

**Independent Test**: Three runs against the same feature reporting a High
finding — off, on-with-Critical-threshold, on-with-High-threshold — escalate,
escalate, and remediate respectively; a fourth run specifying nothing defaults
to on.

### Tests for User Story 3

- [X] T037 [P] [US3] Extend `test/speckit_orchestrator/web/trigger_live_test.exs` — 3 controls pre-filled from `Config`, threshold/limit disabled while switch is off, field-level rejection of an out-of-range limit or unrecognized threshold before the run starts (no run created), a run launched off doesn't change the next mount's defaults
- [X] T038 [P] [US3] Extend `test/speckit_orchestrator/console_read_model_test.exs` — `feature.remediation` fold from `[:speckit, :remediation, :*]` events, cost added only once (no double-count against the analyze phase span), cleared on `[:speckit, :feature, :terminal]`

### Implementation for User Story 3

- [X] T039 [US3] Add a preflight call to `Remediation.Settings.validate/1` in `SpeckitOrchestrator.run/1` (`lib/speckit_orchestrator.ex`), refusing with `{:error, {:preflight, [reason]}}` and starting no work on an invalid threshold/limit/model (FR-011)
- [X] T040 [US3] Add the three launch controls (auto-remediation switch, threshold `<select>` over `Severity.values/0`, attempt-limit number input) to `lib/speckit_orchestrator/web/live/trigger_live.ex`, pre-filled from `Config`, validated via `Remediation.Settings.validate/1` before dispatch, passed as run opts only (no env write-back) — mirrors the existing stacked-PR toggle markup
- [X] T041 [US3] Rename the chunk `phase-chunk-sublabel` CSS/markup to `phase-sublabel` in `lib/speckit_orchestrator/web/components/core_components.ex`, update the chunk call site, and render `attempt k/n` under the `analyze` cell when `@remediation` is present
- [X] T042 [US3] Fold `[:speckit, :remediation, :*]` events into the per-feature `remediation` slice (and feed entries) in `lib/speckit_orchestrator/console_read_model.ex`, clearing it on feature-terminal (contracts/telemetry-console.md §2)

**Checkpoint**: All three user stories are independently functional — the loop self-heals, gives up safely, and is fully operator-configurable at launch.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T043 [P] `test/speckit_orchestrator/integration/analyze_loop_test.exs` — real-CLI coverage behind `mix test --include integration` (quickstart.md US1 Integration)
- [X] T044 [P] Run `mise exec -- mix test`, `mise exec -- mix test --cover` (pure core >90%), and `mise exec -- mix test --include integration`; fix any regression
- [X] T045 [P] Verify `test/speckit_orchestrator/pipeline_test.exs` needs no change (transition table is untouched — research R16) and run it explicitly
- [X] T046 `rtk git diff .specify/memory/constitution.md` against contracts/constitution-amendment.md §6 acceptance criteria — version `1.2.0`, Sync Impact Report prepended, prior report retained, no other principle's text changed
- [X] T047 Walk `quickstart.md` end to end (by-hand console section: `/trigger` defaults, field error on limit `7`, switch dims other controls; `iex` section: `SpeckitOrchestrator.run/1` with overrides, `print_status/0` phase strip)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — can start immediately.
- **Foundational (Phase 2)**: depends on Setup (T001's cost-estimate keys and T002's prompt pack are read by later phases, but Foundational's own tasks don't need them to compile) — BLOCKS all user stories.
- **User Story 1 (Phase 3)**: depends on Foundational completion. No dependency on US2/US3.
- **User Story 2 (Phase 4)**: depends on Foundational; extends the `AnalyzeRunner`/`FeatureRunner` wiring US1 builds in T022-T024, so implement after US1 lands (shares files, not a hard test dependency — US2's independent test only requires the exhaustion/failure/breaker rows of `Remediation.next/2`, already present from T009).
- **User Story 3 (Phase 5)**: depends on Foundational only (`Remediation.Settings.validate/1` from T008, `Severity.values/0` from T003). Can proceed in parallel with US2 if staffed separately, since it touches only `lib/speckit_orchestrator.ex` and `web/`.
- **Polish (Phase 6)**: depends on all desired user stories being complete.

### Within Each User Story

- Tests before implementation where both exist for the same behaviour (T019 before T020-T026; T030 before T031-T034; T037-T038 before T039-T042).
- `AnalyzeRunner`/`FeatureRunner` wiring (T022-T024) before checkpoint/telemetry hookups that read its output (T025-T026).

### Parallel Opportunities

- T001, T002 in parallel.
- T003/T004, T005, T007, T011, T013, T015, T017 in parallel within Foundational (different files); T006 before T007; T008-T010 before T011; T012 before T013; T014 before T015; T016 before T017 is not required (different files) but keep sequential for review clarity.
- T018, T019 in parallel (fixtures vs. test file) but both before T020-T026.
- T020 in parallel with nothing else in US1 (it's a prerequisite for T021); T025 and T026 can run in parallel with each other and with T027/T028.
- US2 and US3 phases can be staffed in parallel once Foundational is done, since they touch disjoint files (`analyze_runner.ex`/`feature_runner.ex`/`escalations_live.ex` vs. `speckit_orchestrator.ex`/`trigger_live.ex`/`core_components.ex`/`console_read_model.ex`).

---

## Parallel Example: Foundational Phase

```bash
# Independent pure modules and their tests:
Task: "Create Severity module in lib/speckit_orchestrator/severity.ex"
Task: "Extend run_context_test.exs for the 4 new fields"
Task: "Extract PhaseStep into lib/speckit_orchestrator/phase_step.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (CRITICAL — blocks all stories).
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: run `analyze_runner_test.exs` and `feature_runner_test.exs`; confirm a feature with a High-then-clean fixture reaches `:done` unattended.
5. Deploy/demo if ready — US1 alone delivers the entire self-healing value (spec.md's own framing).

### Incremental Delivery

1. Setup + Foundational → decision surfaces exist and are tested.
2. Add US1 → self-healing works → validate → demo (MVP).
3. Add US2 → safe exhaustion/failure/breaker handling → validate → demo.
4. Add US3 → operator launch controls → validate → demo.
5. Polish → full suite, integration tests, constitution diff, quickstart walk-through.

### Parallel Team Strategy

With multiple developers, once Foundational is done: Developer A takes US1;
once US1's `AnalyzeRunner`/`FeatureRunner` wiring lands, Developer B extends it
for US2 while Developer C works US3 against the same Foundational base
(disjoint files, per Parallel Opportunities above).

---

## Notes

- [P] tasks = different files, no dependencies.
- [Story] label maps task to specific user story for traceability.
- FR-017's constitution amendment (T016) is Foundational, not Polish — it must
  land before any code that assumes the softened Principle V, and its
  acceptance is re-verified in Polish (T046) against the actual diff.
- Research R16 (T027) is a known, enumerable edit, not incidental churn: the
  default flips to on, so existing analyze-gate tests must pin it off
  explicitly or they will exercise the new loop by accident.
- Commit after each task or logical group; stop at any checkpoint to validate
  a story independently.
