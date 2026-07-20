---

description: "Task list for Resume Checkpoint Persistence"
---

# Tasks: Resume Checkpoint Persistence

**Input**: Design documents from `/specs/002-resume-checkpoint/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/checkpoint.md](./contracts/checkpoint.md), [quickstart.md](./quickstart.md)

**Tests**: Included — quickstart.md mandates one automated scenario per acceptance criterion; tasks below implement that suite.

**Organization**: Tasks are grouped by user story (spec.md) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps to spec.md user stories (US1, US2, US3)

## Path Conventions

Single-project Elixir/OTP layout (plan.md → Project Structure):
- `lib/speckit_orchestrator/checkpoint.ex` — new module
- `lib/speckit_orchestrator/feature_runner.ex` — wiring edit
- `test/speckit_orchestrator/checkpoint_test.exs` — new test file

---

## Phase 1: Setup

Not applicable — this feature extends the existing OTP app (no new project, no new
mix dependency; Jason is already a transitive dep used by `analyze_result.ex` /
`describe.ex`). Proceed directly to Foundational.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Module skeleton and test harness shared by all three user stories.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T001 [P] Create `lib/speckit_orchestrator/checkpoint.ex`: `@moduledoc` per
      contracts/checkpoint.md, `alias SpeckitOrchestrator.Config`, and a private
      `checkpoint_path(feature_id)` helper returning
      `Path.join([Config.transcript_root(), feature_id, "checkpoint.json"])`. Stub
      the three public functions (`write/1`, `read/1`, `delete/1`) with `@spec`s
      matching contracts/checkpoint.md so the module compiles under
      `warnings_as_errors`.
- [X] T002 [P] Create `test/speckit_orchestrator/checkpoint_test.exs`:
      `use ExUnit.Case, async: false` (mutates the global `:transcript_root` app
      env, mirroring `test/speckit_orchestrator/transcripts_test.exs:1-25`),
      `alias SpeckitOrchestrator.Checkpoint`, and a `setup` block that points
      `Application.put_env(:speckit_orchestrator, :transcript_root, tmp_root)` at a
      unique tmp dir, restoring the previous value and `File.rm_rf`-ing the tmp dir
      `on_exit`.

**Checkpoint**: `mise exec -- mix compile` is clean; the test file loads with no
tests yet failing for the wrong reason.

---

## Phase 3: User Story 1 - Diverted feature leaves a durable checkpoint (Priority: P1) 🎯 MVP

**Goal**: A feature that terminates at `:escalated` / `:halted` / `:failed`
produces a `checkpoint.json` recording the halted phase, status, reason, and
session id.

**Independent Test**: Call `Checkpoint.write/1` directly with a diverted
phase/status and confirm the on-disk JSON file (read/decoded independently of
`Checkpoint.read/1`, which doesn't exist yet at this point) matches. Then wire
`FeatureRunner` and confirm the file appears after a real diverted run.

### Tests for User Story 1

> Write these first; they must fail (module raises `:not_implemented` or similar)
> before T007.

- [X] T003 [US1] In `test/speckit_orchestrator/checkpoint_test.exs`: test that
      `Checkpoint.write(%{feature_id: ..., last_phase: :clarify, status:
      :escalated, reason: "needs human", session_id: "s1"})` writes
      `<tmp_root>/<feature_id>/checkpoint.json`, and the file decodes (via
      `File.read!/1` + `Jason.decode!/1`, not `Checkpoint.read/1`) to a JSON
      object with `last_phase == "clarify"` and `status == "escalated"` (SC-001).
- [X] T004 [US1] In the same file: repeat T003 for `last_phase: :analyze, status:
      :halted`, confirming the overwrite semantics aren't required yet (fresh
      feature id) — asserts the halted-phase field matches the diverted phase
      (spec.md acceptance scenario 2).
- [X] T005 [US1] In the same file: test that `Checkpoint.write/1` with a tuple
      `reason` (e.g. `{:breaker, "budget"}`) does not raise, and the decoded
      `reason` field equals `inspect({:breaker, "budget"})` (FR-004, edge
      "non-serializable reason").
- [X] T006 [US1] In the same file: test that a forced write failure (point
      `:transcript_root` at an unwritable path, e.g. `/proc/nonexistent/deny`,
      mirroring `test/speckit_orchestrator/transcripts_test.exs:52-60`) returns
      `:ok` from `Checkpoint.write/1` and raises nothing (FR-008, SC-004).

### Implementation for User Story 1

- [X] T007 [US1] Implement `Checkpoint.write/1` in
      `lib/speckit_orchestrator/checkpoint.ex`: build the JSON-safe map
      (`feature_id` as-is, `last_phase`/`status` via `Atom.to_string/1`, `reason`
      via `inspect/1`, `session_id` string-or-`nil`), `File.mkdir_p!` the
      per-feature dir, `Jason.encode!/1` and `File.write!/2` to
      `checkpoint_path/1`; wrap the whole body in `rescue _ -> :ok` so any
      failure is swallowed and the function always returns `:ok` (FR-008).
- [X] T008 [US1] Wire the write into
      `lib/speckit_orchestrator/feature_runner.ex`: add `Checkpoint` to the
      module's `alias SpeckitOrchestrator.{...}` list; after `loop/7` returns
      (beside the existing `handle_worktree/3` call at `feature_runner.ex:78`),
      on a non-`:done` `status` (`:escalated` / `:halted` / `:failed`) call
      `Checkpoint.write(%{feature_id: feature.id, last_phase: agent.state.phase,
      status: status, reason: reason, session_id: agent.state.session_id})`.
      Must not alter `status`/`reason`/control flow (FR-010).

**Checkpoint**: User Story 1 is fully functional and testable independently —
diverted runs leave a correct, best-effort-written checkpoint file.

---

## Phase 4: User Story 2 - Completed feature leaves no stale pointer (Priority: P2)

**Goal**: A feature reaching `:done` has no lingering checkpoint, whether or not
one existed from a prior diverted attempt.

**Independent Test**: Write a checkpoint via T007, then call `Checkpoint.delete/1`
and confirm the file is gone; also call `delete/1` on a feature with no file and
confirm it's a no-op.

### Tests for User Story 2

- [X] T009 [US2] In `test/speckit_orchestrator/checkpoint_test.exs`: test that
      after `Checkpoint.write/1` creates a checkpoint, `Checkpoint.delete/1`
      removes the file (assert `File.exists?` on the path is now `false`) and
      returns `:ok` (FR-005, spec.md acceptance scenario 1).
- [X] T010 [US2] In the same file: test that `Checkpoint.delete/1` for a feature
      id with no checkpoint file is a no-op that returns `:ok` and raises nothing
      (FR-005 acceptance scenario 2).

### Implementation for User Story 2

- [X] T011 [US2] Implement `Checkpoint.delete/1` in
      `lib/speckit_orchestrator/checkpoint.ex`: `File.rm(checkpoint_path(id))`
      wrapped so a missing file or any error is swallowed; always returns `:ok`
      (FR-007).
- [X] T012 [US2] Wire the delete into `lib/speckit_orchestrator/feature_runner.ex`:
      at the same finalization point as T008, on `status == :done` call
      `Checkpoint.delete(feature.id)` instead of `write/1`. (Sequential with
      T008 — same call site in `run/2`.)

**Checkpoint**: User Stories 1 AND 2 both work independently — diverted runs
checkpoint, completed runs never leave a stale pointer.

---

## Phase 5: User Story 3 - Checkpoint records round-trip reliably (Priority: P2)

**Goal**: `Checkpoint.read/1` returns the written record, a distinct
"no checkpoint" result when absent, and a distinct "corrupt" result when the file
exists but can't be parsed — never confusing the two.

**Independent Test**: Read a feature id with no file (expect
`{:error, :no_checkpoint}`); write a malformed file by hand and read it (expect
`{:error, :corrupt}`); write via T007 then read back and confirm field equality.

### Tests for User Story 3

- [X] T013 [US3] In `test/speckit_orchestrator/checkpoint_test.exs`: test that
      `Checkpoint.read/1` for a feature id with no checkpoint file returns
      `{:error, :no_checkpoint}` (FR-006b).
- [X] T014 [US3] In the same file: test that a hand-written malformed
      `checkpoint.json` (e.g. truncated JSON, or a JSON array instead of an
      object) at the expected path makes `Checkpoint.read/1` return
      `{:error, :corrupt}`, distinct from `{:error, :no_checkpoint}` (FR-006c).
- [X] T015 [US3] In the same file: test that `Checkpoint.write/1` (T007) followed
      by `Checkpoint.read/1` returns `{:ok, record}` whose
      `feature_id`/`last_phase`/`status`/`reason`/`session_id` fields equal what
      was written (SC-003, spec.md acceptance scenario 1).

### Implementation for User Story 3

- [X] T016 [US3] Implement `Checkpoint.read/1` in
      `lib/speckit_orchestrator/checkpoint.ex`: `File.read(checkpoint_path(id))`;
      `{:error, :enoent}` → `{:error, :no_checkpoint}`; on `{:ok, contents}`,
      `Jason.decode(contents)` — a decoded JSON object → `{:ok, map}`, anything
      else (decode error, or a decoded non-object like an array) → `{:error,
      :corrupt}`; any other file-read error also → `{:error, :corrupt}` (never
      fabricate fields — Constitution II, FR-006).

**Checkpoint**: All three user stories are independently functional — write,
delete, and read each behave per contracts/checkpoint.md.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T017 [P] Run `mise exec -- mix compile` and confirm a clean build under
      `warnings_as_errors` (no unused aliases/stubs left from T001).
- [X] T018 Run `mise exec -- mix test` (full suite) and confirm no regression in
      `test/speckit_orchestrator/feature_runner_test.exs` from the T008/T012
      wiring edit.
- [X] T019 Walk through quickstart.md's manual `iex` section end-to-end
      (write → read → delete → read) to confirm the documented output matches.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: N/A — no tasks.
- **Foundational (Phase 2)**: No dependencies — BLOCKS all user stories.
- **User Story 1 (Phase 3)**: Depends on Foundational only. MVP.
- **User Story 2 (Phase 4)**: Depends on Foundational; T012 depends on T008
  (same call site in `feature_runner.ex`).
- **User Story 3 (Phase 5)**: Depends on Foundational; T015 depends on T007
  (needs `write/1` to produce a record to read back).
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### Within Each User Story

- Tests written first, expected to fail, then implementation (T003-T006 →
  T007-T008; T009-T010 → T011-T012; T013-T015 → T016).
- Story complete before moving to the next priority tier (P1 → P2 → P2).

### Parallel Opportunities

- T001 and T002 (Foundational) — different files.
- T017 (Polish, compile check) can run alongside T018/T019 review, though T018
  and T019 are validation steps best run after T017 passes.
- Test tasks within a story (T003-T006, T009-T010, T013-T015) all edit the same
  `checkpoint_test.exs` file — not marked `[P]`; add them as sequential edits to
  one file even though they're logically independent scenarios.
- Across stories: US1 and US2 touch the same `feature_runner.ex` call site
  (T008/T012) — not parallel. US3's read implementation (T016) is a separate
  function in the same module file as T007/T011 — not parallel, but has no
  logical dependency on US2.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational.
2. Complete Phase 3: User Story 1 (write + wiring for diverted terminals).
3. **STOP and VALIDATE**: `mise exec -- mix test test/speckit_orchestrator/checkpoint_test.exs` green for T003-T006; drive a real diverted feature and confirm the file lands under `Config.transcript_root()`.

### Incremental Delivery

1. Foundational → US1 (diverted checkpoints exist) → US2 (done leaves no stale
   pointer) → US3 (read contract, 3-way outcome) → Polish.
2. Each story is independently testable per its "Independent Test" above before
   moving to the next.

---

## Notes

- All three user stories converge on one small module
  (`lib/speckit_orchestrator/checkpoint.ex`, ~3 public functions) and one test
  file (`test/speckit_orchestrator/checkpoint_test.exs`) — parallelism here is
  naturally limited to Foundational (T001/T002); later tasks are sequential by
  shared-file edits, not by story independence.
- Per FR-010 / plan.md scope: this feature only produces/removes the record.
  Nothing reads a checkpoint back into a run — that's the future resume feature.
- Verify tests fail before implementing (T003-T006, T009-T010, T013-T015 each
  before their corresponding implementation task).
