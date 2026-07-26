# Phase 1 Data Model: Implement Phase Chunking

**Branch**: `015-implement-phase-chunking` | **Spec**: [spec.md](./spec.md) |
**Research**: [research.md](./research.md)

All entities below are plain Elixir structs/maps in the pure core. There is no
database (Constitution, Technology Stack): durable state is the existing
file-backed checkpoint, extended with one optional key.

---

## 1. `TaskPlan` (new, pure — `lib/speckit_orchestrator/task_plan.ex`)

The ordered set of task-phases derived from a feature's `tasks.md`. **Derived,
never authoritative** — re-parsed before every dispatch (FR-006).

```elixir
defstruct task_phases: [],   # [TaskPhase.t()], file order
          structured?: false, # false ⇒ FR-004 fallback path
          source: nil        # path the plan was parsed from, for diagnostics
```

| Field | Type | Notes |
|---|---|---|
| `task_phases` | `[TaskPhase.t()]` | Empty on the fallback path. |
| `structured?` | `boolean()` | `true` iff at least one `## Phase <n>: <title>` heading was found. |
| `source` | `String.t() \| nil` | Absolute path of the parsed `tasks.md`. |

**Derived accessors** (all pure, all `@spec`'d):

- `total_tasks/1`, `completed_tasks/1` → `non_neg_integer()` — whole-list counts;
  the progress signal of FR-011/012 (research R7).
- `incomplete/1` → `[Task.t()]` — every unchecked task in file order; the sweep
  scope (FR-007).
- `complete?/1` → `boolean()` — `incomplete/1 == []`; the FR-007a success test.
- `first_incomplete_index/1` → `non_neg_integer() \| nil` — the FR-025 fallback
  target.
- `locate/2` → see §5.

**Validation rules**

- A `## Phase <number>: <title>` heading with **zero** tasks is retained in
  `task_phases` (so ordinals stay stable) and skipped at dispatch (FR-003 /
  "Task-phase with no tasks" edge case).
- Heading `number` is an **opaque string**; order of appearance is authoritative
  under duplicate or non-sequential numbering.
- Checkbox lines before the first `## Phase` heading, or under a non-`Phase`
  `##` heading, belong to no task-phase and are excluded from every count.
- Content inside fenced code blocks is ignored entirely.
- An unreadable/absent `tasks.md` yields `%TaskPlan{structured?: false,
  task_phases: []}` — the FR-004 fallback, not a raise. (The upstream `tasks`
  phase already has its own artifact gate for a genuinely missing file.)

---

## 2. `TaskPlan.TaskPhase` (new, pure)

One numbered, titled section — the unit of work for one bounded session.

```elixir
defstruct ordinal: 0, number: "", title: "", tasks: []
```

| Field | Type | Notes |
|---|---|---|
| `ordinal` | `pos_integer()` | 1-based position in file order. Authoritative. |
| `number` | `String.t()` | Heading's declared number, verbatim (`"3"`, `"N"`). |
| `title` | `String.t()` | Text after the colon, trimmed (`"User Story 1 - … (Priority: P1) 🎯 MVP"`). |
| `tasks` | `[Task.t()]` | File order. May be empty. |

Derived: `complete?/1` (all member tasks `[X]`, vacuously true when empty) —
the FR-003 skip test.

---

## 3. `TaskPlan.Task` (new, pure)

```elixir
defstruct id: nil, text: "", complete?: false, line: 0
```

| Field | Type | Notes |
|---|---|---|
| `id` | `String.t() \| nil` | `"T017"` when the line carries one; `nil` otherwise. |
| `text` | `String.t()` | First line of the checkbox item, trimmed. |
| `complete?` | `boolean()` | `[X]`/`[x]` ⇒ `true`, `[ ]` ⇒ `false`. |
| `line` | `pos_integer()` | 1-based source line, for diagnostics/naming a stuck task. |

Naming in operator-facing failures (FR-007a): `id` when present, else
`"line <line>: <first 60 chars of text>"`.

---

## 4. `ChunkScope` (new, pure — the unit dispatched to one session)

```elixir
@type t ::
        {:task_phase, TaskPhase.t()}
      | {:sweep, [Task.t()]}
      | :whole_list
```

| Variant | When | Prompt shape |
|---|---|---|
| `{:task_phase, tp}` | structured path, normal case | scoped to `tp.number`/`tp.title` |
| `{:sweep, tasks}` | FR-007, after all task-phases dispatched, ≤ once (FR-007b) | scoped to the listed task ids |
| `:whole_list` | FR-004 fallback (unstructured plan) | today's bare `/speckit.implement`, byte-identical (SC-005) |

---

## 5. `TaskPhaseRef` (new, pure — the durable position marker)

The three-part identity FR-020a requires, and the resolution rules of FR-025.

```elixir
defstruct ordinal: nil, number: nil, title: nil
```

`TaskPlan.locate(plan, ref)` → `{:ok, TaskPhase.t(), match_kind}` where
`match_kind ∈ [:number, :title, :ordinal, :fallback]`, resolved **in that fixed
order**:

| Order | Rule | `match_kind` |
|---|---|---|
| 1 | unique task-phase whose `number == ref.number` | `:number` |
| 2 | unique task-phase whose `title == ref.title` (exact, trimmed) | `:title` |
| 3 | task-phase at `ordinal == ref.ordinal` | `:ordinal` |
| 4 | first task-phase with incomplete tasks | `:fallback` |
| — | plan has no task-phases at all | `{:error, :unstructured}` |

A non-unique match at step 1 or 2 falls through to the next rule rather than
guessing (Constitution II). Any `match_kind` other than `:number` MUST be
reported to the operator (FR-025a) — see
[contracts/telemetry-chunk.md](./contracts/telemetry-chunk.md).

---

## 6. `ChunkAttempt` (new, pure — one dispatched session)

The spec's *Chunk Attempt* entity. Carried through the loop and rendered into
transcripts, telemetry and the roll-up.

```elixir
defstruct scope: nil,        # ChunkScope.t()
          attempt: 1,        # 1-based, per scope; >1 ⇒ continuation (FR-017)
          outcome: nil,      # :ok | :exhausted | :error
          completed_before: 0,
          completed_after: 0,
          cost: 0.0,
          transcript: nil    # relative transcript filename
```

Derived: `progress?/1` = `completed_after > completed_before` — the FR-011 vs
FR-012 discriminator.

---

## 7. `ChunkState` (new, pure — the loop's whole state)

Input to `Chunking.next/2`. Holds no process state, no IO handles.

```elixir
defstruct plan: nil,             # TaskPlan.t(), re-read before each decision
          cursor: 1,             # ordinal of the task-phase under consideration
          attempt: 1,            # attempts on the current scope
          no_progress: 0,        # consecutive no-progress attempts (FR-013)
          sessions_used: 0,      # counted against the ceiling (FR-013a/b)
          ceiling: 0,            # frozen at step start (research R8)
          swept?: false,         # FR-007b — sweep runs at most once
          history: []            # [ChunkAttempt.t()], newest first
```

**Invariants**

- `sessions_used` increments on **every** dispatched session — task-phase,
  continuation, and sweep alike (FR-013a).
- `no_progress` resets to `0` on any attempt with `progress?/1 == true`
  (FR-013), and on every advance of `cursor`.
- `ceiling` is frozen at implement-step start and never recomputed (research R8).
- `swept?` is monotonic.

---

## 8. `Checkpoint` record — extended (existing)

One new **optional** top-level key. Every other field is unchanged, and a
pre-015 checkpoint (no key) remains valid — it resolves via the `:fallback` rule
of §5, which is exactly the FR-025 "missing or unreadable" behaviour.

```json
{
  "feature_id": "001",
  "last_phase": "implement",
  "status": "failed",
  "reason": "...",
  "session_id": "...",
  "slug": "...", "path": "...", "context": { },

  "implement_chunk": {
    "ordinal": 3,
    "number": "3",
    "title": "User Story 1 - Long task lists finish (Priority: P1) 🎯 MVP",
    "total": 5,
    "sessions_used": 7,
    "ceiling": 14,
    "scope": "task_phase"
  }
}
```

| Field | Type | Requirement |
|---|---|---|
| `ordinal`/`number`/`title` | int/string/string | FR-020a — all three recorded |
| `total` | int | task-phase count at write time; display only |
| `sessions_used` | int | FR-013b — durable, operator-visible |
| `ceiling` | int | frozen ceiling, so the console can render `7/14` |
| `scope` | `"task_phase"` \| `"sweep"` \| `"whole_list"` | which scope was in flight |

**Write timing** (FR-020): at every task-phase boundary (after the boundary
commit) and on the implement step's terminal outcome. Same best-effort
semantics as today — a checkpoint write failure never breaks a run.

**Reset on resume** (FR-013b): an operator-initiated `resume/2` writes
`sessions_used: 0` before the first dispatch; resuming is an explicit human
decision to grant more budget.

---

## 9. `PhaseResult` — extended (existing)

| Field | Change |
|---|---|
| `subtype` | **new** `String.t() \| nil` — the `:session_failed` payload's `"subtype"` (research R1). `nil` on success and on harness-level errors. |

New predicate `PhaseResult.exhausted?/1` → `subtype == "error_max_turns"`.
`transient?/1` is unchanged (FR-014).

---

## 10. Console read-model slice — extended (existing)

`ConsoleReadModel`'s `feature_slice` gains one optional field:

```elixir
chunk: %{
  ordinal: pos_integer(),
  total: pos_integer(),
  title: String.t(),
  attempt: pos_integer(),
  scope: :task_phase | :sweep | :whole_list,
  sessions_used: non_neg_integer(),
  ceiling: pos_integer()
} | nil
```

`nil` for every feature not currently in a chunked implement step, and left
`nil` for rendering purposes when `scope == :whole_list` — FR-019's "no empty or
misleading task-phase indicator" is satisfied by absence, not by a `1/1`.

---

## 11. Entity ↔ requirement map

| Spec entity | Here | Key FRs |
|---|---|---|
| Task Plan | §1 `TaskPlan` | FR-001, FR-004, FR-006 |
| Task Phase | §2 `TaskPhase` | FR-002, FR-003 |
| Task | §3 `Task` | FR-005, FR-007a |
| Chunk Attempt | §6 `ChunkAttempt` | FR-010..FR-013a, FR-017, FR-026 |
| Run State Record (extended) | §8 checkpoint + §5 ref | FR-013b, FR-020, FR-020a, FR-021, FR-025 |
| — (loop state) | §7 `ChunkState` | FR-007b, FR-009, FR-013a |
