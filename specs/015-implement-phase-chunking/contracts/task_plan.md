# Contract: `SpeckitOrchestrator.TaskPlan`

**Kind**: pure core module (Constitution I) + one documented edge reader.
**File**: `lib/speckit_orchestrator/task_plan.ex`
**Satisfies**: FR-001, FR-003, FR-004, FR-006, FR-007, FR-007a, FR-020a, FR-025

---

## 1. Grammar

A `tasks.md` is scanned line by line. Fenced code regions (opened and closed by a
line whose first non-space characters are ```` ``` ````) are skipped entirely.

| Production | Regex | Notes |
|---|---|---|
| task-phase heading | `^##\s+Phase\s+(?<number>[^:\n]+?)\s*:\s*(?<title>.+?)\s*$` | `number` opaque string; `title` trimmed |
| other `##` heading | `^##\s+` not matching the above | closes the current task-phase |
| task | `^\s*-\s+\[(?<mark>[ xX])\]\s+(?<rest>.*)$` | belongs to the open task-phase |
| task id | `^(?<id>T\d+)\b` applied to `rest` | optional |

`complete? = mark in ["x", "X"]`.

Deeper headings (`###`, `####`) do **not** close a task-phase — `### Tests for
User Story 1` is inside its `## Phase 3:` section.

---

## 2. Public API

```elixir
@spec parse(String.t(), keyword()) :: TaskPlan.t()
@spec load(String.t()) :: TaskPlan.t()

@spec total_tasks(TaskPlan.t()) :: non_neg_integer()
@spec completed_tasks(TaskPlan.t()) :: non_neg_integer()
@spec incomplete(TaskPlan.t()) :: [Task.t()]
@spec complete?(TaskPlan.t()) :: boolean()
@spec task_phase_count(TaskPlan.t()) :: non_neg_integer()
@spec at(TaskPlan.t(), pos_integer()) :: {:ok, TaskPhase.t()} | :error
@spec first_incomplete(TaskPlan.t()) :: {:ok, TaskPhase.t()} | :error
@spec locate(TaskPlan.t(), TaskPhaseRef.t() | nil) ::
        {:ok, TaskPhase.t(), :number | :title | :ordinal | :fallback}
      | {:error, :unstructured}
@spec ref(TaskPhase.t()) :: TaskPhaseRef.t()
```

- `parse/2` is **pure**: markdown in, struct out. `:source` opt only sets the
  diagnostic field.
- `load/1` is the single edge function: takes a **worktree path**, globs
  `specs/**/tasks.md`, reads the first match, and delegates to `parse/2`. It
  **never raises** — an absent, unreadable, or empty file yields
  `%TaskPlan{structured?: false, task_phases: [], source: nil}`, which is the
  FR-004 fallback. (Mirrors the globbing rationale already documented for the
  artifact gate in `Actions.RunFeaturePhase`: the failure being guarded is "the
  file exists nowhere".)

---

## 3. Behavioural requirements

| # | Requirement | FR |
|---|---|---|
| T1 | ≥1 task-phase heading ⇒ `structured? == true`; zero ⇒ `false` | FR-001, FR-004 |
| T2 | `task_phases` are in file order; `ordinal` is 1-based and gapless | FR-001, "duplicate/non-sequential numbering" edge case |
| T3 | A heading with no tasks is retained with `tasks: []` and is `complete?` | "Task-phase with no tasks" edge case, FR-003 |
| T4 | Checkboxes outside any task-phase are excluded from all counts | FR-001 |
| T5 | Checkboxes inside fenced blocks are excluded | §1 |
| T6 | `complete?/1` on the plan ⇔ `incomplete/1 == []` | FR-007a |
| T7 | `incomplete/1` preserves file order across task-phases | FR-007 |
| T8 | `locate/2` follows §5 of data-model.md exactly, including the fall-through on ambiguity | FR-025 |
| T9 | `locate(plan, nil)` ⇒ `{:ok, tp, :fallback}` on a structured plan | FR-025 |
| T10 | `load/1` never raises and never returns `{:error, _}` | FR-004 |

---

## 4. Worked example (`specs/014-recovery-reconciliation/tasks.md`)

```
ordinal 1  number "1"  "Setup"
ordinal 2  number "2"  "Foundational (Blocking Prerequisites)"
ordinal 3  number "3"  "User Story 1 - Reconcile a stale \"running\" feature … 🎯 MVP"
ordinal 4  number "4"  "User Story 2 - Reconcile a \"running\" feature that stopped partway (Priority: P1)"
ordinal 5  number "5"  "User Story 3 - … (Priority: P2)"
ordinal 6  number "6"  "User Story 4 - … (Priority: P2)"
ordinal 7  number "7"  "Polish & Cross-Cutting Concerns"
```

`## Dependencies & Execution Order`, `## Parallel Example: Phase 2
(Foundational)`, `## Implementation Strategy`, `## Notes` are **not**
task-phases (no `Phase <n>:` prefix), and the `# T002 first (struct shape)` line
inside the Parallel Example's fenced block is **not** a task.

---

## 5. Test obligations

Hermetic, fixture-driven, no worktree:

- `test/fixtures/tasks/structured.md` — the 5-task-phase quickpoll shape (SC-001).
- `test/fixtures/tasks/unstructured.md` — checkboxes, no `Phase n:` headings.
- `test/fixtures/tasks/empty_task_phase.md` — a heading with zero tasks.
- `test/fixtures/tasks/duplicate_numbers.md` — two `## Phase 3:` headings.
- `test/fixtures/tasks/fenced.md` — checkbox-looking lines inside ```` ``` ````.
- `test/fixtures/tasks/no_checkboxes.md` — prose plan ⇒ vacuously `complete?`.

Plus a golden test parsing the **real** `specs/014-recovery-reconciliation/tasks.md`
from this repo, asserting the §4 table — so upstream template drift fails the
suite loudly rather than silently degrading to the fallback path.
