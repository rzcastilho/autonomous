# Data Model: Checkpoint-First Resume

**Branch**: `025-checkpoint-first-resume` | **Spec**: [spec.md](./spec.md) |
**Research**: [research.md](./research.md)

This feature adds **no table and no schema version**. It changes which
existing field a pure decision reads, populates one existing-but-unwritten
field, and widens one in-memory reason value. Entities below are the spec's
Key Entities mapped onto the shipped types.

---

## 1. Durable checkpoint (existing — `Store.Records.Checkpoint`)

One row per feature run, keyed by `feature_key`. Written inside the same
transaction as the phase attempt it describes
(`Store.Writer.record_phase_attempt/2` → `write_checkpoint/3`).

| Field | Type | Written by | Role in this feature |
|---|---|---|---|
| `phase` | `Pipeline.phase()` | `FeatureRunner.checkpoint_for/3` | the **next** phase to run — becomes the resume position (FR-001) |
| `last_completed_phase` | `Pipeline.phase()` | same | the **completed-through** value compared against the trail (FR-004/FR-005) |
| `status` | `:in_progress \| :escalated \| :halted \| :failed` | same | **not consulted** — recorded status still governs (FR-008) |
| `reason` | `term() \| nil` | same | unchanged |
| `session_id` | `String.t() \| nil` | same | unchanged |
| `implement_chunk` | `map() \| nil` | **new: `ChunkRunner.record_chunk_attempt/6`** | the implementation progress position (FR-007) |
| `analyze_remediation` | `map() \| nil` | `FeatureRunner`/`AnalyzeRunner` | unchanged |
| `updated_at` | `DateTime.t()` | `Store.Writer` | unchanged |

### 1.1 `implement_chunk` shape

Unchanged from
`specs/015-implement-phase-chunking/contracts/checkpoint-implement-chunk.md` §1.
This feature makes the field actually carry a value; it does not redefine it.

| Key | Type | Value |
|---|---|---|
| `ordinal` | `pos_integer()` | task-phase just completed |
| `number` | `String.t() \| nil` | its `tasks.md` number — the strongest `TaskPlan.locate/2` match |
| `title` | `String.t() \| nil` | its heading — the second-strongest match |
| `total` | `pos_integer()` | task-phase count in the plan at write time |
| `sessions_used` | `non_neg_integer()` | run-wide session count, carried across a resume |
| `scope` | `:task_phase \| :sweep \| :whole_list` | which chunk scope produced the row |

**Validation**: every key is optional on read. `ChunkRunner.ref_from_record/1`
tolerates absent keys (`Map.get/2`), and `TaskPlan.locate/2` degrades
`number → title → ordinal → first-incomplete`. A `nil` `implement_chunk` is
the pre-existing-record shape and is **not** a discrepancy (FR-007a).

**Write rule**: written only for `scope == {:task_phase, _}` boundaries, and
only after `maybe_commit_boundary/4` returned — a crash between commit and
checkpoint leaves the *older* position, which re-runs committed work
idempotently; the reverse order would point at work that was never committed.

---

## 2. Boundary commit trail (existing — `Recovery.Evidence`)

Unchanged. Collected by `Evidence.default_git/1`, parsed by
`@boundary_re` = `^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$`.

| Field | Type | Role |
|---|---|---|
| `branch_committed?` | `boolean()` | FR-009/FR-009a — whether the branch exists at all |
| `last_boundary_phase` | `Pipeline.phase() \| nil` | the trail's completed-through value; FR-002's fallback position |
| `checkpoint` | `map() \| nil` | already collected today; **newly read for position** |
| `pr_record?` / `pr_remote?` / `final_marker?` | — | unchanged, still decide `done_signal?/2` |

Implementation progress commits
(`"speckit: <id> implement task-phase N/M <title>"`) deliberately still do
**not** match `@boundary_re`. Making them match was considered and rejected
(spec Assumptions; research R1).

---

## 3. Resume position (new pure value — `Reconcile`)

The intermediate the new pure helper returns before `Reconcile.status/3`
folds it into a `result()`.

```elixir
@type resume_position ::
        {:resume, Pipeline.phase()}
        | {:conflict, conflict_reason()}
        | :no_position
```

- `{:resume, phase}` — the phase the feature restarts at (FR-001/FR-002/FR-003).
- `{:conflict, reason}` — blocks the feature (FR-005/FR-009a/FR-011).
- `:no_position` — the checkpoint offers nothing usable and the caller must
  fall through to the trail clause (FR-002) or to clauses 6/7.

**Derivation of the comparable ordinal** (research R2):

```
completed_through(cp) =
  cp.last_completed_phase          when Pipeline.phase?(cp.last_completed_phase)
  predecessor(cp.phase)            when Pipeline.phase?(cp.phase)
  :damaged                         otherwise
```

`predecessor(Pipeline.first()) = nil`, ordered below every phase.

**Comparison** against `evidence.last_boundary_phase`:

| Relation | Verdict | FR |
|---|---|---|
| trail absent | checkpoint wins | FR-001 |
| `step_of(completed_through) > step_of(trail)` | checkpoint wins, no discrepancy | FR-004 |
| `step_of(completed_through) == step_of(trail)` | agreement — checkpoint wins, no discrepancy | FR-014 |
| `step_of(completed_through) < step_of(trail)` | `{:conflict, {:checkpoint_behind_trail, …}}` | FR-005 |

---

## 4. Discrepancy (existing row, widened reason)

Carried in `Recovery.Report`'s existing `conflicts` list — no new field, no
new surface.

```elixir
@type conflict_row :: %{id: String.t(), reason: conflict_reason()}
@type conflict_reason :: atom() | {atom(), map()}
```

### 4.1 Reason vocabulary

| Reason | Raised when | FR |
|---|---|---|
| `{:checkpoint_behind_trail, %{checkpoint: phase, trail: phase}}` | checkpoint's completed-through is strictly below the trail's | FR-005 |
| `:checkpoint_without_branch` | checkpoint present, `branch_committed? == false`, no other corroborating artifact (replaces today's `:ambiguous_evidence` for this shape) | FR-009a |
| `{:damaged_checkpoint, %{phase: term(), last_completed_phase: term()}}` | neither checkpoint phase field names a `Pipeline` phase | FR-011 |
| `:pr_without_branch` | unchanged | 014 |
| `:ambiguous_evidence` | unchanged (residual) | 014 |
| `:done_without_artifacts` | unchanged | 014 |

Every reason maps through the unchanged
`Recovery.persisted_status({:conflict, _}) → {:blocked, nil}`.

### 4.2 Rendering

`Recovery.Report.reason_label/1` (new, pure):

```
:checkpoint_without_branch
  -> "checkpoint_without_branch"
{:checkpoint_behind_trail, %{checkpoint: :analyze, trail: :implement}}
  -> "checkpoint_behind_trail (checkpoint: analyze, trail: implement)"
{:damaged_checkpoint, %{phase: "implemnt", last_completed_phase: nil}}
  -> "damaged_checkpoint (phase: \"implemnt\", last_completed_phase: nil)"
```

Used at both existing sites — `reconciled_label({:conflict, reason})` and
`note/4`'s `"CONFLICT — … ; human resolve"`. Per Principle VII the label is
the real atom an operator would type, never a friendlier synonym.

---

## 5. Feature status (unchanged)

`:blocked` remains what it is today: produced only by `persisted_status/1`,
absent from `Feature.@terminal_statuses`, never released by `Release.next/3`,
never a `{:stopped, _, _}`. No new status is introduced (research R6).

---

## 6. State transitions touched

```
Reconcile.status(recorded, evidence, run_shape)   recorded ∈ [:running, :pending]

  1. done_signal?(evidence, run_shape)      -> :done          (unchanged, FR-008/FR-010)
  2. checkpoint present                     -> resume_position/2
         {:resume, phase}                   -> {:resume, phase}      FR-001/003/004
         {:conflict, reason}                -> {:conflict, reason}   FR-005/009a/011
         :no_position                       -> fall through
  3. recorded == :running and
     last_boundary_phase ∈ @resumable       -> {:resume, phase_after(…)}  FR-002 (today's rule, verbatim)
  4. no_artifacts?(evidence)                -> :pending       (unchanged, FR-009)
  5. pr_record? and not branch_committed?   -> {:conflict, :pr_without_branch}
  6. otherwise                              -> {:conflict, :ambiguous_evidence}
```

Clauses 1 (`:escalated`/`:halted`), 2 (`:failed`) and 3 (`:done`) of
`Reconcile.status/3` — the human-gate and completion passthroughs — are
untouched, satisfying FR-008 structurally: the checkpoint is never consulted
for a feature whose recorded status is terminal.
