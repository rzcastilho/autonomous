---

description: "Task list for Auto-Remediation Exhaustion Policy"
---

# Tasks: Auto-Remediation Exhaustion Policy

**Input**: Design documents from `/specs/021-analyze-exhaustion-policy/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/exhaustion-policy.md, contracts/advanced-record.md, quickstart.md

**Tests**: Included — plan.md and quickstart.md name specific test files and scenarios per module; this is the project's established discipline (pure core >90%, hermetic default suite).

**Organization**: Tasks are grouped by user story (US1/US2/US3, priorities from spec.md). No Setup phase — no new dependency, no new module, no new directory (plan.md "Structure Decision"); work starts at Foundational.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with sibling tasks in the same phase (different files)
- **[Story]**: US1, US2, or US3 — omitted for Foundational and Polish tasks
- File paths are exact, relative to the repository root

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The setting, the gate signal plumbing, and the schema migration that every user story reads or writes through. No user-story work starts until this phase is green.

- [X] T001 [P] Add `exhaustion_policy` field, `parse_policy/1`, the `validate/1` check (appended last, after `model`), and `from_context/1` handling to `Remediation.Settings` in lib/speckit_orchestrator/remediation.ex
- [X] T002 [P] Add the ninth field `auto_remediation_exhaustion_policy` (capture/1, to_map/1, from_map/1, @keys, stringify_policy/1) to lib/speckit_orchestrator/run_context.ex
- [X] T003 [P] Add `Config.auto_remediation_exhaustion_policy/0` (default `:escalate`) in lib/speckit_orchestrator/config.ex and register the key's default in config/config.exs
- [X] T004 Add `:exhausted?` / `:exhaustion_policy` to `Pipeline.signals` and amend `Pipeline.next(:analyze, :ok, signals)`'s decision table (row 1 critical unconditional, row 2 unchanged, row 3 new `high? and exhausted? and policy == :proceed` → advance, row 4 `high?` → escalate, row 5 otherwise), with `exhausted?/1` and `exhaustion_policy/1` defaulting absent signals to today's behaviour, in lib/speckit_orchestrator/pipeline.ex (depends on T001 for the `policy()` type)
- [X] T005 [P] Append the `advanced_with_findings` attribute to `speckit_feature_run` and register schema version 4 (`add_advanced_with_findings/0`, `current_version/0 == 4`) in lib/speckit_orchestrator/store/schema.ex and lib/speckit_orchestrator/store/migrations.ex
- [X] T006 [P] Add the matching `advanced_with_findings` struct field and typespec to `Store.Records.FeatureRun` in lib/speckit_orchestrator/store/records.ex
- [X] T007 Wire `auto_remediation_exhaustion_policy` through `run/1` and `resume/2` preflight validation — reject an unrecognized value with no run started and no store row — in lib/speckit_orchestrator/speckit_orchestrator.ex (depends on T001)
- [X] T008 [P] Gate test matrix: `{policy} × {exhausted?} × {critical, high-below-threshold, high-at/above-threshold, clean}`, plus invariants I1 (Critical always halts), I2 (exhausted? absent ⇒ pre-021 outcome), I3 (`:escalate` ⇒ pre-021 outcome), I4 (policy never changes a non-`:analyze` outcome or an `:error` outcome) in test/speckit_orchestrator/pipeline_test.exs (depends on T004)
- [X] T009 [P] Settings validation/parsing tests — atoms and case-insensitive strings accepted, absent ⇒ default, invalid value ⇒ `{:error, {:invalid_exhaustion_policy, value}}` — in test/speckit_orchestrator/remediation_test.exs (depends on T001)
- [X] T010 [P] Migration test: a v3-shaped `speckit_feature_run` row transforms to v4 with `advanced_with_findings: nil`; `Store.Migrations.current_version/0 == 4` in test/speckit_orchestrator/store/migrations_test.exs (depends on T005)

**Checkpoint**: Setting, gate table, and schema exist and are proven byte-identical on absent signals. User story work can begin.

---

## Phase 3: User Story 1 - Let an unattended run finish despite a stubborn finding (Priority: P1) 🎯 MVP

**Goal**: Under the *proceed* policy, an exhausted loop advances the feature past a residual High finding instead of escalating, records what it advanced past, and surfaces that record in the run's report and the feature's PR body.

**Independent Test**: Launch a run with `exhaustion_policy: :proceed` against a feature whose analyze reports the same High finding on every pass. Verify remediation runs exactly `attempt_limit` times, the feature advances past `:analyze`, reaches `:done` with no operator input, and the unresolved finding is recorded and surfaced against that feature (report + PR body).

- [X] T011 [US1] Implement `Remediation.exhaustion_advance/2` — `{:mark, record} | :none` per the truth table in contracts/advanced-record.md §1.1 — in lib/speckit_orchestrator/remediation.ex (depends on T001, T004)
- [X] T012 [P] [US1] Unit tests for `exhaustion_advance/2`'s full truth table (below-threshold, clean analyze, `:critical` threshold, `:escalate` policy all ⇒ `:none`) in test/speckit_orchestrator/remediation_test.exs (depends on T011)
- [X] T013 [P] [US1] `AnalyzeRunner.exhaustion_signals/3` sets `signals.exhausted? = true` and attaches the final result's residual findings as `analyze_residual_findings` on the exhaustion branch only, in lib/speckit_orchestrator/analyze_runner.ex (depends on T004)
- [X] T014 [US1] `FeatureRunner.gate_signals(:analyze, ...)` injects `:exhaustion_policy` from the run's captured `Remediation.Settings`; thread a `marks` map through `loop/*`; call `exhaustion_advance/2` at the analyze boundary; decorate the eventual `{:done, :done}` transition as `{:done, :advanced_with_unresolved_findings}` when marked, in lib/speckit_orchestrator/feature_runner.ex (depends on T011, T013)
- [X] T015 [US1] `Store.Writer.record_phase_attempt/2` gains an optional `:advanced_with_findings` key, written in the same transaction as the analyze phase-attempt boundary, in lib/speckit_orchestrator/store/writer.ex (depends on T005, T006)
- [X] T016 [US1] Wire `FeatureRunner` to pass the mark record into `Store.Writer.record_phase_attempt/2` at the analyze boundary in lib/speckit_orchestrator/feature_runner.ex (depends on T014, T015)
- [X] T017 [P] [US1] `AnalyzeRunner` test: scripted persistent-High-finding agent asserts `:exhausted?` and residual findings carried verbatim in test/speckit_orchestrator/analyze_runner_test.exs (depends on T013)
- [X] T018 [US1] `FeatureRunner` test: exhaust → advance → annotate → decorated `:done` reason, attempts consumed exactly `attempt_limit` (no more, no fewer) in test/speckit_orchestrator/feature_runner_test.exs (depends on T016)
- [X] T019 [US1] `Store.Writer` test: the phase attempt and the annotation land in one transaction; `run_key: nil` is a silent no-op in test/speckit_orchestrator/store/writer_test.exs (depends on T015)
- [X] T020 [US1] `Coordinator.build_report/2` derives `advanced_with_findings` (a subset of `done`) from the reasons it already retains, with no change to `notify/4`'s arity, in lib/speckit_orchestrator/coordinator.ex (depends on T014)
- [X] T021 [P] [US1] `Coordinator` test: `report.advanced_with_findings ⊆ report.done` in test/speckit_orchestrator/coordinator_test.exs (depends on T020)
- [X] T022 [US1] `Report.format_status/1` gains one conditional "advanced: ..." line, absent entirely when no feature advanced under *proceed*, in lib/speckit_orchestrator/report.ex (depends on T020)
- [X] T023 [US1] `Remediation.pr_note/1` — pure markdown renderer, `pr_note(nil) == ""` — in lib/speckit_orchestrator/remediation.ex (depends on T011)
- [X] T024 [US1] `SpeckitOrchestrator.pr_text/2` appends `pr_note/1`'s output to both the Claude-authored `pr_description` and the template-fallback PR body, reading the annotation from the same `Store.run/1` detail in lib/speckit_orchestrator/speckit_orchestrator.ex (depends on T023)
- [X] T025 [P] [US1] PR body test: findings section renders on both branches; `pr_note(nil)` leaves an ordinary feature's PR body byte-identical to today in test/speckit_orchestrator/pull_request_test.exs (depends on T024)
- [X] T026 [US1] Document `auto_remediation_exhaustion_policy` in `run/1`'s option list and docstring in lib/speckit_orchestrator/speckit_orchestrator.ex (depends on T007)

**Checkpoint**: A run launched with *proceed* completes unattended past a residual High finding, and the advance is recorded in the store, the report, and the PR body.

---

## Phase 4: User Story 2 - Keep today's fail-fast handoff by default (Priority: P2)

**Goal**: Prove the `:escalate` policy (explicit or default) and the auto-remediation-disabled case are byte-for-byte identical to pre-021 behaviour — the conservative default is provably unchanged before *proceed* is safe to offer.

**Independent Test**: Launch a run specifying nothing, and one specifying `:escalate` explicitly, both against a feature reporting a persistent High finding. Verify both escalate with the exhausted-auto-remediation reason, the worktree is retained, and the outcome matches the feature before this feature existed.

- [X] T027 [P] [US2] Pin `:escalate` / default / SC-002 regression assertions (byte-identical terminal state, reason, retained worktree) into the existing cases of test/speckit_orchestrator/pipeline_test.exs (depends on T008, T018)
- [X] T028 [P] [US2] Pin the same regression assertions, plus FR-015 (policy inert with auto-remediation disabled, for either policy value), into the existing cases of test/speckit_orchestrator/remediation_test.exs and test/speckit_orchestrator/feature_runner_test.exs (depends on T009, T018)
- [X] T029 [US2] Add a test proving a run launched with `proceed` does not change the exhaustion policy offered on the next launch (FR-012) in test/speckit_orchestrator/run_context_test.exs (depends on T002, T007)

**Checkpoint**: Every pre-existing assertion about the `:escalate` path still passes, unchanged, and a leak of the new path into the default would now fail a pinned test.

---

## Phase 5: User Story 3 - Choose the policy at launch and see it on the run (Priority: P3)

**Goal**: The operator picks the policy in the console's launch form (pre-filled with the default, unrecognized values refused before the run starts), and the chosen policy plus any advanced-with-findings feature are visible once the run is under way.

**Independent Test**: Open the launch form and confirm the policy control shows the default; launch with *proceed* and confirm the run's recorded settings and the console both show *proceed*; attempt to launch with an unrecognized value and confirm the form names the bad setting and starts no run.

- [ ] T030 [US3] Add the `exhaustion_policy` `<select>` to `#auto-remediation-form` (pre-filled from `Config.auto_remediation_exhaustion_policy/0`, disabled with the rest of the group when auto-remediation is off, reusing the existing `field-label-inline` class) in lib/speckit_orchestrator/web/live/trigger_live.ex (depends on T001, T007)
- [ ] T031 [US3] `"update_remediation"` event reads `params["exhaustion_policy"]`; `start_opts/1` adds `auto_remediation_exhaustion_policy` to the `run/1` opts it dispatches; `validate_remediation/1` maps an invalid value to a `<.form_refusal>` naming `auto-remediation-exhaustion-policy`, in lib/speckit_orchestrator/web/live/trigger_live.ex (depends on T030)
- [ ] T032 [P] [US3] `TriggerLive` test: control pre-filled with `escalate`; refusal on a bad value with no run dispatched; `proceed` captured into the run's settings in test/speckit_orchestrator/web/trigger_live_test.exs (depends on T031)
- [ ] T033 [US3] `Store.Query` carries `advanced_with_findings` into the run-detail feature slice in lib/speckit_orchestrator/store/query.ex (depends on T015)
- [ ] T034 [US3] `RunDetailLive` feature panel gains a `data-advanced-with-findings` block (severity + finding text in the mono family, reusing `run-context`/`run-context-chip` classes only, no status color, no motion) sibling to `data-remediation-attempts`, in lib/speckit_orchestrator/web/live/run_detail_live.ex (depends on T033)
- [ ] T035 [P] [US3] `RunDetailLive` test: settings chip shows the run's captured policy; the feature marker renders for an annotated feature and is absent for a clean one in test/speckit_orchestrator/web/run_detail_live_test.exs (depends on T034)
- [ ] T036 [US3] Run `mix test test/speckit_orchestrator/design_contract_test.exs` and confirm it passes unmodified — no new literal, no status color on the new markup (depends on T034)

**Checkpoint**: An operator can choose, launch with, and observe the exhaustion policy end to end, with no console-side literal or status-color violation.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: The governing-document amendment this feature requires (FR-016), doc sync, and the full validation gate.

- [ ] T037 [P] Amend `.specify/memory/constitution.md` Principle V's exhaustion bullet (2.2.0 → 3.0.0): permit the advance, preserve the unconditional Critical halt, add the record-and-surface obligation, and prepend a Sync Impact Report over the preserved prior reports
- [ ] T038 [P] Update CLAUDE.md, docs/workflow.md, and docs/runbook.md to describe the exhaustion policy and its gate row; leave specs/017-analyze-auto-remediation/ as an accurate historical record
- [ ] T039 Run the full gate: `mise exec -- mix format --check-formatted`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix test`, `mise exec -- mix test --cover` (pure core stays >90%)
- [ ] T040 Run quickstart.md Scenario 10 (opt-in, `mise exec -- mix test --include integration`) against a target repo with a persistent, non-mechanically-fixable High finding, confirming unattended completion, the marked PR body, and the console marker

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 2)**: No dependencies — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational. No dependency on US2/US3.
- **User Story 2 (Phase 4)**: Depends on Foundational; its regression tests pin behaviour that US1's implementation must not disturb, so it runs after US1's code lands (T027-T029 depend on T008/T009/T018) — but adds no new production code.
- **User Story 3 (Phase 5)**: Depends on Foundational (T001, T007) and on US1's store write (T015, for T033). Independent of US2.
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### User Story Dependencies

- **US1 (P1)**: The whole feature's behaviour — no dependency on US2 or US3.
- **US2 (P2)**: Regression-only; depends on US1's code existing so the pin is meaningful, not on US3.
- **US3 (P3)**: Console surface over US1's store write (T015/T033); independent of US2.

### Within Each User Story

- Pure functions before the runner code that calls them (`exhaustion_advance/2` before `FeatureRunner` wiring; `pr_note/1` before `pr_text/2`)
- Schema/writer before the reader that depends on the new column (`Store.Writer` before `Store.Query`, `Coordinator`, `Report`)
- Implementation before its test file in the same task pair, though both are listed together per module

### Parallel Opportunities

- Foundational: T001, T002, T003, T005, T006 (five independent files) can run together; T008, T009, T010 (independent test files) can follow together once their respective prerequisites land
- US1: T012, T013, T017, T021, T025 touch distinct files and can run in parallel with their phase siblings once each one's own prerequisite is done
- US2: T027 and T028 touch distinct files and can run in parallel
- US3: T032 and T035 touch distinct test files and can run in parallel
- Polish: T037 and T038 touch distinct files and can run in parallel

---

## Parallel Example: Foundational

```bash
# Independent-file foundational tasks together:
Task: "Add exhaustion_policy field/parser/validate/from_context to Remediation.Settings in lib/speckit_orchestrator/remediation.ex"
Task: "Add ninth field to RunContext in lib/speckit_orchestrator/run_context.ex"
Task: "Add Config.auto_remediation_exhaustion_policy/0 in lib/speckit_orchestrator/config.ex"
Task: "Append advanced_with_findings + schema v4 migration in store/schema.ex, store/migrations.ex"
Task: "Add advanced_with_findings field to Store.Records.FeatureRun in store/records.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (setting, gate table, schema v4)
2. Complete Phase 3: User Story 1 — the *proceed* path, its record, and its three surfaces (report, console-independent store, PR body)
3. **STOP and VALIDATE**: run quickstart.md Scenarios 1, 3, 5, 7, 9 independently
4. This alone delivers SC-001, SC-003, SC-004, SC-006, SC-008 — the feature's core value

### Incremental Delivery

1. Foundational → US1 (MVP: unattended runs finish past a stubborn finding, recorded and surfaced)
2. Add US2 → regression-pin the `:escalate`/default/disabled paths (SC-002, SC-007's launch-time half)
3. Add US3 → launch control, run-level display, console feature marker (SC-005, SC-007's form-level half)
4. Polish → constitution amendment, doc sync, full gate, opt-in live scenario

---

## Notes

- [P] tasks touch different files with no unmet dependency within their own phase
- [Story] label maps every user-story task to US1/US2/US3 for traceability; Foundational and Polish carry none
- Critical MUST halt at every policy and threshold (FR-005) is enforced structurally by clause order in T004 (row 1), not by a conditional — verified by invariant I1 in T008 and re-pinned in T027
- The `:escalate` path MUST be byte-identical to today (FR-003, SC-002) via defaults on absent signals (T004) — there is no parallel legacy path to keep in sync
- Residual findings MUST NOT reach any downstream phase's input (FR-004a) — no task in this list adds a field any phase after `:analyze` reads
- No new terminal lifecycle status (FR-008a) — the mark is a reason decoration (T014) and a report-derived subset (T020), never a new `Feature` status member
- Commit after each task or logical group; verify a test fails before its corresponding implementation task where the two are ordered test-first
