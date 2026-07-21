---

description: "Task list for Self-Sufficient Resume (checkpoint carries identity + run context)"
---

# Tasks: Self-Sufficient Resume (Checkpoint Carries Identity + Run Context)

**Input**: Design documents from `/specs/007-resume-self-sufficient/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/checkpoint.md,
contracts/run_context.md, contracts/resume.md, quickstart.md

**Tests**: Included — quickstart.md's six hermetic scenarios are the primary validation
path (Constitution: pure/seam tests, >90% coverage on core) and the three contracts
define the exact shapes `checkpoint_test.exs`, `run_context_test.exs`, and
`resume_test.exs` must cover.

**Organization**: Two user stories, both Priority P1 (the spec treats them as a matched
pair — Story 2 must land alongside Story 1 for resume to be trustworthy). US1 (identity
recovery) lands first since US2's context-reapply and PR-workflow routing sit inside the
same `resume/2` function body US1 reshapes. US2 is additive on top of US1's reshaped
`resume/2` and introduces the new `RunContext` module; neither story requires reverting
work from the other.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2)

## Path Conventions

Single Elixir project (existing). All paths are repo-root-relative. Run everything
through `mise exec --` (see CLAUDE.md — `warnings_as_errors` is ON).

---

## Phase 1: User Story 1 - Resume from the feature id alone (Priority: P1) 🎯 MVP

**Goal**: `Checkpoint.write/1` persists `slug`/`path` alongside the existing fields;
`resume/2` reconstructs `%Feature{id, slug, path, status: :pending}` from the checkpoint
when the caller supplies no explicit/backlog definition, and no longer requires a
loadable backlog to resume.

**Independent Test**: Write a checkpoint for id `"042"` carrying `slug: "widget"` and
`path`, then call `resume("042", features: [], runner: fake_runner)` — no explicit
feature, empty backlog — and confirm the fake runner receives `%Feature{id: "042",
slug: "widget", path: ...}` starting at the checkpointed phase, with no
`{:unknown_feature, _}`.

### Tests for User Story 1

- [X] T001 [P] [US1] Extend `test/speckit_orchestrator/checkpoint_test.exs`: `write/1`
      given `slug`/`path` persists them; `read/1` round-trips them losslessly; an old-shape
      write map without `slug`/`path` (simulating a caller that doesn't yet thread them)
      still writes successfully (contracts/checkpoint.md write/1 + persisted record table)
- [X] T002 [P] [US1] Add fixtures to `test/speckit_orchestrator/resume_test.exs`: a
      `Checkpoint.write/1` call carrying `slug`/`path` under the existing temp
      `transcript_root` pattern, for reuse by the tests below
- [X] T003 [US1] Add test "resume/2 reconstructs the feature from checkpoint identity when
      `:features` is empty and no explicit feature is supplied — no
      `{:unknown_feature, _}`, fake runner invoked with the checkpoint's `slug`/`path`"
      (spec Story 1 AS1; SC-001; quickstart Scenario 1) — depends on T002
- [X] T004 [US1] Add test "resume/2 carries an optional `:prompt` guidance note into the
      resumed phase as `resume_prompt` while identity still comes from the checkpoint"
      (spec Story 1 AS2; quickstart Scenario 1 optional note) — depends on T002
- [X] T005 [US1] Add test "resume/2 prefers an explicit/backlog feature over checkpoint
      identity when both exist for the same id (FR-003), and the outcome does not depend
      on which is supplied first" (spec Story 1 AS3; edge: identity drift) — depends on
      T002
- [X] T006 [US1] Add test "resume/2 for an id with neither an explicit/backlog feature nor
      checkpoint identity (e.g. corrupt-but-absent-identity old checkpoint, or truly
      unknown id) returns `{:error, {:unknown_feature, id}}` and starts no run" (spec Story
      1 AS4; edge: unknown-feature; quickstart Scenario 5) — depends on T002
- [X] T007 [US1] Add test "resume/2 for an id with no checkpoint on disk still returns
      `{:error, :no_checkpoint}` and starts no run, unchanged" (spec edge: corrupt
      checkpoint counterpart; quickstart Scenario 5) — depends on T002
- [X] T008 [US1] Add test "resume/2 does not call `load_backlog/0` (or tolerates its
      failure) when a checkpoint identity is present — a missing/unloadable backlog is
      non-fatal" (FR-004; research D1 "Alternatives considered") — depends on T002

### Implementation for User Story 1

- [X] T009 [US1] Extend `Checkpoint.write/1` in `lib/speckit_orchestrator/checkpoint.ex`:
      accept `slug` and `path` keys in the input map, add them to the encoded `record` as
      `slug: slug, path: path` (plain strings, no atom conversion — no change to the
      `rescue -> :ok` best-effort behavior) — depends on T001
- [X] T010 [US1] In `lib/speckit_orchestrator/feature_runner.ex`'s `checkpoint/4` (the
      diverted-terminal write site, ~line 201), pass `slug: feature.slug, path:
      feature.path` into the `Checkpoint.write/1` call — depends on T009
- [X] T011 [US1] Reshape identity resolution in `SpeckitOrchestrator.resume/2`
      (`lib/speckit_orchestrator.ex`): read the checkpoint **first** via
      `Checkpoint.read/1` (dispatching `:no_checkpoint`/`:corrupt_checkpoint` as today);
      resolve identity by trying the explicit/backlog list first (best-effort
      `load_backlog/0` — a load failure or missing feature is non-fatal, not raised), else
      reconstructing `%Feature{id: feature_id, slug: record["slug"], path: record["path"],
      status: :pending}` when the checkpoint carries both; else
      `{:error, {:unknown_feature, feature_id}}` — depends on T009, T010
- [X] T012 [US1] Update the `resume/2` moduledoc in `lib/speckit_orchestrator.ex` to
      document the id-only form (identity recovered from the checkpoint when omitted) and
      the FR-003 precedence rule (explicit/backlog feature wins over checkpoint identity)
      — depends on T011

**Checkpoint**: User Story 1 is independently functional — `resume(id)` restarts a
checkpointed feature using only its id, with every existing failure outcome
(no-checkpoint, corrupt-checkpoint, unknown-phase, unknown-feature) still distinct.
`mise exec -- mix test` passes.

---

## Phase 2: User Story 2 - Resume reuses the original run context (Priority: P1)

**Goal**: A new pure `RunContext` module captures the six run-shaping settings
(`pr_workflow`, `max_concurrency`, `budget_usd`, `plan_stack`, `pr_base`, `pr_remote`) at
`run/1` time, threads through to `Checkpoint.write/1` as a `context` object, and
`resume/2` reapplies the recorded context (explicit resume opt > recorded > live
Config/default) — including routing a resumed PR-workflow feature through the stacked
executor path so cap-1/preflight/stacking/PR-on-done are preserved.

**Independent Test**: Start a run with `pr_workflow: true`, drive a feature to a
checkpointed non-done state, flip `Application.put_env(:speckit_orchestrator,
:pr_workflow, false)` to simulate a fresh env, then `resume(id, features: [], executor:
fake_executor)` and confirm the resumed feature runs through the PR-workflow path (cap 1,
stacking) despite the live default being off.

### Tests for User Story 2

- [X] T013 [P] [US2] Create `test/speckit_orchestrator/run_context_test.exs`: `capture/1`
      resolves each of the six fields from `Keyword.get(opts, key, Config.<accessor>())`
      (both the opts-present and opts-absent/Config-fallback cases per field); `to_map/1`
      produces a JSON-ready string-keyed map of exactly the six settings and nothing else
      (contracts/run_context.md capture/1, to_map/1)
- [X] T014 [P] [US2] Add to `run_context_test.exs`: `from_map/1` returns an all-`nil`
      struct for `nil`/`%{}` (old/absent checkpoint); a partial map populates only present
      keys, leaving the rest `nil`; never raises on an unexpected/extra key
      (contracts/run_context.md from_map/1; data-model.md edge: partial)
- [X] T015 [P] [US2] Add to `run_context_test.exs`: `merge/2` — an opts-supplied key always
      wins over recorded (not counted as a fallback); a recorded non-`nil` value is
      injected into `merged_opts` when opts lacks the key; a key present in neither is left
      absent and reported in `fell_back_keys`; result is independent of `opts` vs
      `recorded` argument order (contracts/run_context.md merge/2)
- [X] T016 [P] [US2] Extend `test/speckit_orchestrator/checkpoint_test.exs`: `write/1`
      given a `run_context: %RunContext{}` persists `RunContext.to_map/1` under the
      `"context"` key; `write/1` given `run_context: nil` omits the `"context"` key
      entirely; round-trip through `read/1` is lossless (contracts/checkpoint.md
      persisted record table)
- [X] T017 [US2] Add test "resume/2 routes a checkpoint recording `pr_workflow: true`
      through the PR-workflow path (stacking/preflight/PR-on-done, cap 1) even when live
      `Config.pr_workflow?/0` is `false`" to `test/speckit_orchestrator/resume_test.exs`
      (spec Story 2 AS1; SC-002; quickstart Scenario 2) — depends on T013–T016
- [X] T018 [US2] Add test "resume/2 reapplies recorded `max_concurrency`/`budget_usd`/
      `plan_stack`/`pr_base` over live Config defaults" (spec Story 2 AS2; quickstart
      Scenario 2 non-PR settings) — depends on T017
- [X] T019 [US2] Add test "resume/2 with an explicit `pr_workflow: false` resume opt wins
      over a checkpoint recording `pr_workflow: true` — non-PR path runs" (spec Story 2
      AS3; FR-007; quickstart Scenario 3) — depends on T017
- [X] T020 [US2] Add test "resume/2 on a checkpoint with no `context` key falls back to
      live Config for all six settings, succeeds without crashing, and logs a `Logger.info`
      line naming the fallen-back settings (captured via `ExUnit.CaptureLog`)" (spec Story
      2 AS4; FR-008; SC-004; quickstart Scenario 4) — depends on T017
- [X] T021 [US2] Add test "resume/2 on a checkpoint recording only `pr_workflow: true`
      (partial context) reapplies that value and falls back + logs for the other five"
      (data-model.md edge: partial context; quickstart Scenario 4 partial variant) —
      depends on T020
- [X] T022 [US2] Add integration test (`@tag :integration`) "a checkpoint write failure
      (unwritable `transcript_root`) with `slug`/`path`/`run_context` present still reaches
      the run's terminal result — `Checkpoint.write/1` returns `:ok` (rescued), no new
      break" to `test/speckit_orchestrator/checkpoint_test.exs` or `feature_runner_test.exs`
      (FR-010; SC-005; quickstart Scenario 6) — depends on T009 (US1), T024

### Implementation for User Story 2

- [X] T023 [P] [US2] Create `lib/speckit_orchestrator/run_context.ex`: pure struct
      `defstruct pr_workflow: nil, max_concurrency: nil, budget_usd: nil, plan_stack: nil,
      pr_base: nil, pr_remote: nil`; `capture/1`, `to_map/1`, `from_map/1`, `merge/2` per
      contracts/run_context.md — no IO beyond reading `Config` in `capture/1` — depends on
      T013–T015
- [X] T024 [US2] Extend `Checkpoint.write/1` in `lib/speckit_orchestrator/checkpoint.ex`:
      accept an optional `run_context` key; when non-`nil`, add `context:
      RunContext.to_map(run_context)` to the encoded record; when `nil`/absent, omit the
      key — no new raising path (best-effort preserved) — depends on T023, T016
- [X] T025 [US2] Add a `:run_context` option to `FeatureRunner.run/2`
      (`lib/speckit_orchestrator/feature_runner.ex`), default `nil`; pass it into the
      `checkpoint/4` call site alongside `slug`/`path` (T010) — depends on T024
- [X] T026 [US2] In `SpeckitOrchestrator.run/1` (`lib/speckit_orchestrator.ex`), capture
      `RunContext.capture(effective_opts)` from the opts `run/1` actually uses (post
      `:pr_workflow`/`:max_concurrency`/etc. resolution) and thread it as `run_context:`
      into every runner/executor closure that calls `FeatureRunner.run/2`:
      `default_runner/2`, `seed_runner/1`'s inner fun, `seed_executor/1`'s inner fun (via
      `run_seeded/4`), and `default_executor/3` — depends on T023, T025
- [X] T027 [US2] In `SpeckitOrchestrator.resume/2`, after resolving identity (US1) and
      start phase: compute `ctx = RunContext.from_map(record["context"])`, `{merged_opts,
      fell_back} = RunContext.merge(opts, ctx)`; when `fell_back != []`, emit one
      `Logger.info` naming the fallen-back settings (FR-008) — depends on T011, T023
- [X] T028 [US2] In `resume/2`, select the worktree strategy from `merged_opts`'s effective
      `pr_workflow`: when `false` (unchanged), inject `:runner` = the existing
      `resume_runner/2`; when `true`, inject `:executor` = a new resume-executor variant
      (same `resume_worktree/1` reuse/recreate logic, `(feature, base, notify) -> :ok`
      shape) so the resumed run goes through `run_stacked/1`'s wrapping (stacking +
      `pr_notify` + cap 1) instead of bypassing it — a caller-supplied `:runner`/
      `:executor` still wins — depends on T027
- [X] T029 [US2] Thread `run_context: <captured run_context>` from `merged_opts` into the
      resume-runner (T028's `resume_runner/2`) and resume-executor's `FeatureRunner.run/2`
      call, so a resumed feature's *own* checkpoint (if it diverts again) still carries the
      reapplied context forward — depends on T026, T028
- [X] T030 [US2] `resume/2` calls `run(merged_opts)` instead of `run(opts)` so the
      reapplied context (including `pr_workflow`) reaches `run/1`'s own
      `pr_workflow`-branch dispatch (`run_stacked/1` vs `start_run/2`) consistently with
      the T028 worktree-strategy selection — depends on T027, T028
- [X] T031 [US2] Update the `resume/2` moduledoc and `run/1` moduledoc in
      `lib/speckit_orchestrator.ex` to document run-context capture/reapply and the
      precedence rule (explicit resume opt > recorded context > live Config/default) —
      depends on T030

**Checkpoint**: User Stories 1 AND 2 both work independently — a resumed feature recovers
its identity from the checkpoint alone (US1) and re-executes under its original run shape,
including the PR workflow, without needing the environment to re-declare it (US2).
`mise exec -- mix test` and `mise exec -- mix test --cover` (>90% core) pass.

---

## Phase 3: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and full-suite validation across both stories.

- [X] T032 [P] Update `docs/runbook.md`: document the id-only `resume(id)` invocation as
      the canonical form (dropping the hand-supplied `%Feature{}` example as primary),
      note that `:features`/explicit definitions remain supported for backward
      compatibility, and document the run-context reapply + fallback log line (FR-012)
- [X] T033 Run `mise exec -- mix test --cover` and confirm `RunContext`, the extended
      `Checkpoint`, and the reshaped `resume/2` sit above the project's >90% core coverage
      target
- [X] T034 Run `mise exec -- mix test --include integration` and walk quickstart.md's six
      scenarios end-to-end against the real harness seams, confirming no regression in the
      five preserved distinct failure outcomes (FR-005; SC-003)

---

## Dependencies & Execution Order

### Phase Dependencies

- **User Story 1 (Phase 1)**: No dependencies — start immediately. Reshapes `resume/2`'s
  identity resolution and extends `Checkpoint.write/1`'s input map.
- **User Story 2 (Phase 2)**: Builds on US1's reshaped `resume/2` (T011) and extended
  `Checkpoint.write/1` (T009) — the `RunContext` module itself (T023) and its unit tests
  (T013–T015) have no US1 dependency and can start in parallel with Phase 1.
- **Polish (Phase 3)**: Depends on both user stories being complete.

### Within Each User Story

- Tests before implementation (write first, confirm they fail, then implement)
- `RunContext` (pure, T023) before anything that threads it through `Checkpoint`/
  `FeatureRunner`/the facade
- `Checkpoint.write/1` extension before the `FeatureRunner` write-site update before the
  facade capture/reapply wiring

### Parallel Opportunities

- T001, T002 (US1 test setup) in parallel — different concerns, same file only if T001
  lands first; otherwise independent additions
- T013, T014, T015 (RunContext unit tests, single new file) can be drafted in parallel by
  different people, then merged into one `run_context_test.exs`
- T023 (RunContext implementation) can start as soon as T013–T015 exist, independently of
  all US1 implementation tasks
- T032 (runbook) is independent of T033/T034 and can run in parallel with them

---

## Parallel Example: User Story 2 foundation

```bash
# RunContext is pure and has no dependency on the US1 identity work — draft its tests
# and implementation alongside Phase 1:
Task: "run_context_test.exs — capture/1 resolves opts-vs-Config per field"
Task: "run_context_test.exs — from_map/1 tolerant decode (nil/partial/unknown keys)"
Task: "run_context_test.exs — merge/2 precedence and fallback reporting"
Task: "lib/speckit_orchestrator/run_context.ex — struct + capture/to_map/from_map/merge"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: User Story 1 (identity-only resume)
2. **STOP and VALIDATE**: `resume(id, features: [], runner: fake)` works with zero
   hand-typed identity fields; all five failure outcomes still distinct
3. This alone fixes the primary operator ergonomic defect (SC-001) even before Story 2
   lands

### Incremental Delivery

1. User Story 1 → id-only resume works, backward compatible → validate → (optional
   intermediate checkpoint)
2. User Story 2 → run context (including PR workflow) survives resume → validate → both
   stories together satisfy the spec's SC-001..SC-005
3. Polish → runbook + full-suite + integration validation

---

## Notes

- [P] tasks = different files, no dependencies (or genuinely independent additions to a
  shared new file, called out per-task above)
- [Story] label maps task to specific user story for traceability
- Both stories touch `lib/speckit_orchestrator/checkpoint.ex` and
  `lib/speckit_orchestrator.ex` — sequential by design (US2's edits build on US1's), not a
  same-file conflict since neither phase parallelizes across the story boundary
- No `String.to_atom/1` on any file-sourced value (atom-table safety) — `slug`/`path` are
  strings; `context` values decode as JSON primitives, never atoms (research D7)
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at the Phase 1 checkpoint to validate Story 1 independently before starting Phase 2
