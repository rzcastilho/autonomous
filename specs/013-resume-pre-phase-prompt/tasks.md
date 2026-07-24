---

description: "Task list for Pre-phase remediation prompt at resume"
---

# Tasks: Pre-phase remediation prompt at resume

**Input**: Design documents from `/specs/013-resume-pre-phase-prompt/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/resume-remediation.md, quickstart.md (all present)

**Tests**: Explicitly designed by this feature's artifacts — `quickstart.md` names four required test files and `plan.md`'s Testing section makes hermetic `FakeSDK` coverage a Constraint. Test tasks are included inline with the story that exercises them, not as a separate opt-in phase.

**Organization**: Tasks are grouped by user story (spec.md priorities). No Setup phase — this is an additive change to an existing, already-scaffolded Elixir project; nothing to initialize.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps to spec.md's US1/US2/US3
- All file paths are relative to the repository root

## Path Conventions

Single-project Elixir layout (per plan.md's Structure Decision):
- Source: `lib/speckit_orchestrator/`
- Tests: `test/speckit_orchestrator/`

---

## Phase 1: Foundational (Blocking Prerequisites)

**Purpose**: The pure request builder, agent state/routing, and the new action shell that every user story's remediation step runs through. No user-story behavior is observable until this phase is done — it introduces the pieces but does not yet wire them into the resume path.

- [X] T001 [P] Add remediation model resolution + validation and a `:remediation` cost estimate in `lib/speckit_orchestrator/config.ex`: a function that resolves the remediation model as override-or-`Config.model_for(target_phase)`, rejects an unknown alias loudly (`{:error, {:unknown_model, alias}}` — Principle II, FR-011), and an entry for `:remediation` in `@default_cost_estimates` (`Cost.for_phase/2`'s fallback path)
- [X] T002 [P] Add `PhaseRequest.build_remediation/3` in `lib/speckit_orchestrator/phase_request.ex`: pure builder `(Feature.t(), model :: String.t(), opts) -> RunRequest.t()` — prompt = framing header (feature id/slug + worktree-relative `breakdown_ref/2`) + operator prompt verbatim, `cwd` = worktree, `permission_mode: :accept_edits` with `allowed_tools: ~w(Read Write Edit Bash Grep Glob)` (FR-009, same as a write phase), no `session_id`
- [X] T003 [P] Add `remediation_prompt` / `remediation_model` schema fields (`{:or, [nil, :string]}`, default `nil`) and the `{"remediation.run", SpeckitOrchestrator.Actions.RunRemediation}` signal route to `lib/speckit_orchestrator/feature_agent.ex`
- [X] T004 Seed `remediation_prompt` / `remediation_model` from params into agent state in `lib/speckit_orchestrator/actions/init_feature.ex` (depends on T003; mirror the existing `resume_prompt` schema/seed pattern already in that file)
- [X] T005 Create `lib/speckit_orchestrator/actions/run_remediation.ex` (`RunRemediation` action, `data: %{}`, reads `feature`/`worktree`/`layout`/`ledger`/`remediation_prompt`/`remediation_model` from agent state): build via `build_remediation/3`, run through `Jido.Harness.run_request(:claude, request, [])`, fold a `PhaseResult`, resolve model via T001, resolve+record cost via `Cost.for_phase(:remediation, result)` → `Ledger.record`, write back `last_result`/`last_outcome` (`:ok`/`:error`, no gate classification)/`cost_total`/a `%{phase: :remediation, outcome, cost}` history entry — mirror `RunFeaturePhase`'s fold shape exactly (depends on T001, T002, T003)
- [X] T006 [P] Add `build_remediation/3` unit tests in `test/speckit_orchestrator/phase_request_test.exs`: model (default vs. override), permissions (`:accept_edits` + the 6 allowed tools), prompt framing (header + verbatim operator text), no `session_id` (depends on T002)
- [X] T007 Create `test/speckit_orchestrator/run_remediation_test.exs`: the action folds cost/history/`last_outcome` on success; an error outcome on a harness failure; no gate signals are ever set (depends on T005)

**Checkpoint**: The remediation step exists and is unit-tested in isolation, but nothing in the resume path calls it yet.

---

## Phase 2: User Story 1 - Fix issues, then re-run the gate phase (Priority: P1) 🎯 MVP

**Goal**: A resume with a non-blank remediation prompt runs the remediation step exactly once, before the target phase, and the phase then observes the corrected artifacts — turning a gate halt into a one-command recovery (FR-002/003/006/008/009/011/012, SC-001/004/005/006).

**Independent Test**: Resume a feature halted at `analyze` with a remediation prompt supplied; with an injected `FakeSDK`, assert the remediation step is invoked exactly once and before the `analyze` phase step, then `analyze` runs against the remediated artifacts and reaches a terminal state.

- [X] T008 [US1] In `lib/speckit_orchestrator/feature_runner.ex`, run the remediation step once — outside and before `loop/…` — when `Keyword.get(opts, :remediation_prompt)` is non-blank: wrap the call in the `[:speckit, :phase]` telemetry span (`meta.phase = :remediation`), write its transcript via `Transcripts.write(worktree, layout, 0, :remediation, result)` (→ `00-remediation.md`), retry on `PhaseResult.transient?/1` via the existing `run_phase_with_retry`-style policy (`Config.phase_max_retries()`); on a genuine post-retry `:error`, finalize the feature `:failed`, checkpoint, keep the worktree, notify, and return **without** entering the phase loop (FR-006, SC-005) (depends on T005)
- [X] T009 [US1] Thread `:remediation_prompt` / `:remediation_model` through `resume/2` in `lib/speckit_orchestrator.ex`: resolve+validate the model via T001's Config function (unknown alias ⇒ `{:error, {:unknown_model, alias}}`, no run started — add this to `resume/2`'s `@spec`), then pass both opts through `inject_resume_strategy/6` → `resume_runner/4` / `resume_executor/4` → `FeatureRunner.run(remediation_prompt: …, remediation_model: …)` (depends on T001, T008)
- [X] T010 [P] [US1] Extend the `FakeSDK` in `test/speckit_orchestrator/feature_runner_test.exs` with `:remediation` / `:remediation_error` / `:remediation_transient_once` scenario branches (mirroring the existing `:transient_once` pattern) so a test can drive the remediation step through success, genuine failure, and one-transient-then-success
- [X] T011 [US1] Add cases to `test/speckit_orchestrator/feature_runner_test.exs`: remediation runs exactly once and completes before the target phase (assert via telemetry span order + presence of `00-remediation.md` before `01-<phase>.md`); the target phase observes artifacts as remediation left them; a transient remediation failure is auto-retried and the resume proceeds; a genuine post-retry remediation failure stops the resume — feature finalizes `:failed`, worktree kept, `analyze` never runs (depends on T008, T010)
- [X] T012 [US1] Add cases to `test/speckit_orchestrator/resume_test.exs`: `:remediation_prompt`/`:remediation_model` reach `FeatureRunner.run/2`; a `:remediation_model` override applies only to the remediation request (the target phase's own model routing is unchanged); an unknown model alias returns `{:error, {:unknown_model, _}}` and starts no run (depends on T009)

**Checkpoint**: A feature halted at `analyze` can be corrected and re-evaluated with a single `resume/2` call carrying a remediation prompt.

---

## Phase 3: User Story 2 - Resume directly, with no remediation (Priority: P1)

**Goal**: A resume with no (or blank) remediation prompt is byte-identical to today's resume — zero remediation steps, zero extra cost or model execution (FR-004, SC-002).

**Independent Test**: Resume a feature with no remediation prompt supplied and confirm no remediation step runs — the target phase executes directly, reaching a terminal state exactly as before this feature.

- [X] T013 [US2] Add a case to `test/speckit_orchestrator/feature_runner_test.exs`: an absent, `""`, or whitespace-only `:remediation_prompt` sends no `"remediation.run"` signal, writes no `00-remediation.md`, records no extra `Ledger` spend, and the target phase runs directly (depends on T008)
- [X] T014 [P] [US2] Add a case to `test/speckit_orchestrator/resume_test.exs`: `resume/2` called with no (or blank) `:remediation_prompt` threads `FeatureRunner.run/2` opts identically to a pre-feature-013 resume (depends on T009)

**Checkpoint**: The default resume path is unchanged and adds no cost, per SC-002.

---

## Phase 4: User Story 3 - Remediation is scoped to this one resume, not the whole pipeline (Priority: P2)

**Goal**: The remediation step precedes only the target phase of this resume and never re-fires as the pipeline advances to later phases (FR-005, SC-003).

**Independent Test**: Drive a resume with a remediation prompt at one target phase through to a later phase; confirm the remediation step ran exactly once (before the target phase) and no remediation step precedes any subsequent phase.

- [X] T015 [US3] Add a case to `test/speckit_orchestrator/feature_runner_test.exs`: resume with a remediation prompt targeting `:analyze` that then advances to `:implement` — exactly one `phase: :remediation` telemetry span occurs across the whole run, and it precedes only `:analyze` (depends on T008)

**Checkpoint**: No remediation leak past the target phase, per SC-003 — structurally guaranteed by T008's placement outside `loop/…`, confirmed here.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: FR-010's independence guarantee (not owned by any single story) and final validation against the feature's own quickstart.

- [X] T016 [P] Add a case to `test/speckit_orchestrator/resume_test.exs` for FR-010: a resume supplying both `:prompt` (feature-004's in-phase note) and `:remediation_prompt` (this feature) applies both independently — the remediation step runs with the remediation text, and the target phase's own prompt still carries the feature-004 operator note; neither suppresses the other
- [X] T017 [P] Run `mise exec -- mix test --cover` and confirm the pure core (`PhaseRequest`, `Config`) stays above the project's >90% coverage target
- [X] T018 Walk `specs/013-resume-pre-phase-prompt/quickstart.md` scenarios 1–6 end-to-end against the implemented code and check off its Expected Outcomes checklist (SC-001 through SC-006)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately. **BLOCKS** all user stories (nothing to wire a remediation step into before T001–T007 exist).
- **User Story 1 (Phase 2)**: Depends on Foundational. Delivers the MVP — this is the feature.
- **User Story 2 (Phase 3)**: Depends on Foundational + T008/T009 (the same `FeatureRunner`/`resume/2` change T008/T009 introduce also contains the blank-check guard this story tests) — sequenced after Phase 2 in this list, but its tests could start as soon as T008/T009 land.
- **User Story 3 (Phase 4)**: Depends on T008 (the structural placement outside `loop/…` that makes at-most-once true). Test-only story.
- **Polish (Phase 5)**: Depends on T009 (FR-010 test needs both opts threaded) and all prior phases for T018's full quickstart walk.

### Within Each Story

- T008 (runtime wiring) before T009 (facade thread-through), before the tests that exercise either (T010–T012)
- Foundational tasks T001/T002/T003 are mutually independent (different files); T004 depends on T003; T005 depends on T001+T002+T003

### Parallel Opportunities

- T001, T002, T003 — different files, no shared dependency
- T006 (after T002) can run alongside T004/T005
- T010 (FakeSDK scenario additions) can be written alongside T009
- T014, T016, T017 — different concerns, safe in parallel once their prerequisites land

---

## Parallel Example: Foundational Phase

```bash
Task: "Add remediation model resolution + validation + cost estimate in lib/speckit_orchestrator/config.ex"
Task: "Add PhaseRequest.build_remediation/3 in lib/speckit_orchestrator/phase_request.ex"
Task: "Add remediation_prompt/remediation_model schema fields + signal route in lib/speckit_orchestrator/feature_agent.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Foundational
2. Complete Phase 2: User Story 1 — this alone delivers SC-001/004/005/006
3. **STOP and VALIDATE**: run `mise exec -- mix test test/speckit_orchestrator/feature_runner_test.exs test/speckit_orchestrator/resume_test.exs test/speckit_orchestrator/phase_request_test.exs test/speckit_orchestrator/run_remediation_test.exs`

### Incremental Delivery

1. Foundational → nothing observable yet, but everything downstream compiles against it
2. + User Story 1 → the halt-fix-rerun loop works end-to-end (MVP)
3. + User Story 2 → zero-overhead default path proven unchanged
4. + User Story 3 → no-leak guarantee proven
5. + Polish → FR-010 independence + full quickstart sign-off

---

## Notes

- No `[Story]` label on Phase 1/5 tasks — they are Foundational/Polish, not story-specific, per the checklist format rules
- Every task names its exact file path; `warnings_as_errors` is ON, so run `mise exec -- mix compile` after each task
- Commit after each task or logical group; stop at each checkpoint to validate independently
