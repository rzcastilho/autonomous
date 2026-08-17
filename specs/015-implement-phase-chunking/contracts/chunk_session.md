# Contract: the chunk session (request, outcome, transcript, commit)

**Kind**: edge — `ChunkRunner` + extensions to `PhaseRequest`,
`Actions.RunFeaturePhase`, `PhaseResult`, `Transcripts`, `Worktree` usage.
**Files**: `lib/speckit_orchestrator/chunk_runner.ex` (new),
`phase_request.ex`, `actions/run_feature_phase.ex`, `phase_result.ex`,
`transcripts.ex`, `feature_runner.ex`
**Satisfies**: FR-002, FR-005, FR-006, FR-009, FR-010, FR-014, FR-023a, FR-023b,
FR-026, FR-027

---

## 1. Request scoping (`PhaseRequest.build/3`)

New option `:scope` (a `ChunkScope.t()`), honoured **only** for
`phase == :implement`. Everything else about the request — model
(`Config.model_for(:implement)`), `max_turns`
(`Config.implement_max_turns/0`, unchanged per the spec's "Turn cap unchanged"
assumption), `permission_mode: :accept_edits`, `allowed_tools` — is byte-identical
to today.

| Scope | Prompt |
|---|---|
| `:whole_list` / absent | `/speckit.implement` — **byte-identical to today** (SC-005) |
| `{:task_phase, tp}` | `/speckit.implement` + the scoping block below |
| `{:sweep, tasks}` | `/speckit.implement` + the sweep block below |

**Task-phase scoping block** (FR-005 — all four clauses are mandatory):

```
Implement ONLY the tasks in "Phase <number>: <title>" of tasks.md.
Do NOT start, plan, or edit files for tasks belonging to any other phase.
Mark each task as [X] in tasks.md immediately as you complete it — do not
batch this to the end of the session.
This session is scoped deliberately: completing this phase alone is a
successful outcome. Ignore any instruction to keep working until every task
in tasks.md is complete — that condition does not apply to this session.
```

**Sweep block** (FR-007):

```
Complete ONLY these remaining unchecked tasks from tasks.md, in this order:
<T007, T012, …>.
Mark each task as [X] in tasks.md immediately as you complete it — do not
batch this to the end of the session.
Completing exactly these tasks is a successful outcome for this session.
```

The last clause of each block is the explicit release FR-005 requires from the
`speckit-implement` skill's `## Done When` → "All tasks in tasks.md completed and
marked `[X]`" (research R4).

The tick-immediately clause is load-bearing for §3's progress measurement, not
a style preference. Progress is *only* the checked-task count moving, and an
`error_max_turns` kill lands before any end-of-session bookkeeping — so a
session that batches its ticks reports zero progress however much code it
wrote, and `implement_no_progress_limit` such sessions in a row trip
`{:stuck_task_phase, …}` on a task-phase that was actually advancing (observed
live: `overrun` feature 001, task-phase 2, 2426 lines written across two
sessions, zero boxes ticked).

`:resume_prompt` composition is unchanged: operator guidance is appended after
the scoping block, and reaches **only the first dispatched chunk** of the
resumed step (FR-024) — the existing `resume_phase`-anchored rule in
`Actions.RunFeaturePhase.resume_prompt_for/2` is narrowed by one extra guard on
`attempt == 1 and first_dispatch?`.

---

## 2. Signal / action changes

`"phase.run"` signal data gains an optional `scope`:

```elixir
%{phase: :implement, scope: ChunkScope.t()}
```

`Actions.RunFeaturePhase`:

- threads `scope:` into `PhaseRequest.build/3`;
- **skips the `:implement` artifact gate for a scoped run** (research R10) —
  `classify(:implement, …)` returns `{:ok, %{}}` when `scope` is present, and
  the gate is evaluated once by `ChunkRunner` on the roll-up so
  `Pipeline.next(:implement, …)` still receives exactly the signal map it
  understands today (FR-008);
- is otherwise unchanged: cost resolution, ledger recording, `history`,
  `session_id`, `last_result` all behave as they do now.

---

## 3. Outcome classification (FR-010)

`PhaseResult` gains `subtype: String.t() | nil`, folded from the
`:session_failed` payload's `"subtype"` (research R1), and:

```elixir
@spec exhausted?(t() | nil) :: boolean()
def exhausted?(%__MODULE__{subtype: "error_max_turns"}), do: true
def exhausted?(_), do: false
```

`ChunkRunner` classifies each session in this fixed order:

1. `PhaseResult.exhausted?/1` ⇒ `:exhausted`
2. `last_outcome == :error` and `PhaseResult.transient?/1` ⇒ `:error` with
   `transient?: true` (row 1 of the chunking table — the **existing** retry
   ladder, `Config.phase_max_retries/0`, applies unchanged)
3. `last_outcome == :error` ⇒ `:error`, `transient?: false`
4. otherwise ⇒ `:ok`

`transient?/1` itself is **not modified** (FR-014). Ordering exhaustion first is
what prevents a max-turns result being mistaken for either a transient drop or a
deterministic failure.

Progress is measured as `TaskPlan.completed_tasks/1` over a **freshly loaded**
plan immediately before and immediately after each session (research R7,
FR-006).

---

## 4. Per-task-phase commit (FR-023a / FR-023b)

After each task-phase completes (and after the sweep), before advancing:

```
Worktree.commit(wt, "speckit: <id> implement task-phase <ordinal>/<total> <title>")
```

**This subject MUST NOT match** `Recovery.Evidence`'s boundary regex
`^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$`
(`recovery/evidence.ex:75`) — a match would make crash recovery believe
`implement` had completed and resume at `converge` over a half-built tree
(research R5). A regression test asserts non-match directly against
`Evidence`'s parser.

`:done` squashing needs **no change**: `FeatureRunner.handle_worktree/4` already
collapses everything since `merge_base(repo, branch)` into one terminal commit,
so task-phase commits vanish from a completed feature's history (FR-023b). On a
non-`:done` terminal they remain as the post-mortem trail, unchanged.

---

## 5. Transcripts (FR-026, FR-027)

| File | When |
|---|---|
| `06-implement-p<NN>-a<N>.md` | one per task-phase attempt |
| `06-implement-sweep-a<N>.md` | one per sweep attempt |
| `06-implement.md` | roll-up, written once when the implement step ends |

Chunks **never consume step numbers** — `converge` must stay at
`07-converge.md`, which `Recovery.Evidence.final_marker?/2` reads by hard-coded
path (research R6). `Transcripts.write/5` gains a sibling
`write_labelled/6` taking a label string instead of a phase atom; the existing
arity/behaviour is untouched.

`Transcripts.render/2` gains two header lines (FR-027):

```
- error: <inspect(r.error)>
- subtype: <r.subtype>
```

The roll-up additionally carries a table of every `ChunkAttempt` (scope,
attempt, outcome, tasks before→after, cost, transcript filename) and, on
failure, the §3-of-chunking.md sentence for the terminal reason — so SC-006
("cause identifiable from the operator surfaces alone") holds without reading
agent-tool logs.

---

## 6. `FeatureRunner` integration

`FeatureRunner.run_phase_with_retry/8` gains one clause: when
`phase == :implement`, delegate to `ChunkRunner.run/1`, which returns the same
`agent` the rest of the loop expects, with:

- `last_outcome` — `:ok` when the step completed, `:error` otherwise;
- `last_signals` — `%{}` on success, or the artifact-gate signal from the
  single whole-step evaluation (§2);
- `terminal_reason` — carried through to `Pipeline.next/3`'s `{:failed, reason}`
  so the four SC-002 reasons reach the checkpoint and the console verbatim.

Everything after that — `Pipeline.next/3`, the phase-boundary checkpoint, the
`checkpoint after implement` commit, the breaker check, the advance to
`converge` — is unchanged (FR-008).

Two `FeatureRunner.run/2` options are added and threaded from the facade:

- `:start_task_phase` — a `TaskPhaseRef.t()` or ordinal (FR-021/FR-022);
- `:reset_implement_sessions` — `true` on an operator resume (FR-013b).

---

## 7. Test obligations

Hermetic (fake agent seam, tmp git repo):

- Scoped prompt contains all four FR-005 clauses; `:whole_list` prompt is
  **byte-identical** to `PhaseRequest.build(feature, :implement, [])` today
  (SC-005) — asserted by string equality against the pre-change output.
- `PhaseResult.reduce/1` over a `:session_failed` event with
  `"subtype" => "error_max_turns"` ⇒ `exhausted?/1 == true`, `transient?/1 ==
  false`.
- A `:session_failed` with a server-error subtype ⇒ `exhausted?/1 == false`,
  `transient?/1` unchanged from today.
- Task-phase commit subject does **not** match `Evidence`'s boundary regex, and
  `Evidence.default_git/1` over a branch carrying both commit kinds still
  reports `last_boundary_phase: :tasks`.
- Chunk transcripts land at `06-implement-p03-a1.md`; `07-converge.md` still
  resolves for `Evidence.final_marker?/2` after a chunked run.
- Integration (`--include integration`): one real chunked implement against a
  fixture target repo.
