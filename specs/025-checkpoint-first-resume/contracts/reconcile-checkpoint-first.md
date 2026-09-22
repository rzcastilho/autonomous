# Contract: checkpoint-first resume position

**Kind**: pure decision-table extension (Principle I — no I/O).
**Module**: `SpeckitOrchestrator.Recovery.Reconcile`
**Supersedes for clause 5**: `specs/014-recovery-reconciliation/contracts/reconcile.md`
**Satisfies**: FR-001, FR-002, FR-003, FR-004, FR-005, FR-009a, FR-010,
FR-011, FR-012, FR-013, FR-014

---

## 1. Public surface

```elixir
@type conflict_reason :: atom() | {atom(), map()}

@type result ::
        :done
      | {:resume, Pipeline.phase()}
      | :pending
      | :escalated
      | :halted
      | :failed
      | {:conflict, conflict_reason()}

@spec status(Feature.status(), Evidence.t(), run_shape()) :: result()

@typedoc "Exposed for direct unit test; `status/3` is the only production caller."
@type resume_position ::
        {:resume, Pipeline.phase()}
      | {:conflict, conflict_reason()}
      | :no_position

@spec resume_position(map() | nil, Pipeline.phase() | nil) :: resume_position()
```

`status/3` gains **no new arity and no new argument** — the checkpoint
already travels inside `%Evidence{}` (FR-013: evidence is gathered upstream
by `Recovery.Evidence`, never read inside the decision).

---

## 2. `resume_position/2`

`resume_position(checkpoint, last_boundary_phase)`.

### 2.1 No checkpoint

| `checkpoint` | Result |
|---|---|
| `nil` | `:no_position` |
| not a map | `:no_position` |

`:no_position` hands the decision to the caller's trail clause — FR-002's
fallback, byte-identical to today.

### 2.2 Damaged checkpoint (FR-011)

When **neither** `checkpoint.phase` nor `checkpoint.last_completed_phase`
satisfies `Pipeline.phase?/1`:

```elixir
{:conflict, {:damaged_checkpoint, %{phase: raw_phase, last_completed_phase: raw_last}}}
```

The raw values are carried verbatim for the operator; they are never
`String.to_atom/1`-ed and never coerced to a neighbouring phase
(Principle II). `Pipeline.step_of/1` is called only behind a
`Pipeline.phase?/1` guard — it returns `nil + 1` on an unknown atom.

A checkpoint with a damaged `last_completed_phase` but a recognised `phase`
is **not** damaged: it falls to §2.4's `predecessor(phase)` derivation.

### 2.3 Completion signal (FR-010)

When `checkpoint.last_completed_phase == :converge` (the last member of
`Pipeline.phases/0`): `:no_position`.

Converge completing means the run is over; a completed-through of `:converge`
is a completion signal, so it is never offered as a resume position, and the
caller's `done_signal?/2` (already evaluated first) or clause 6/7 decides.

**Reachability**: unreachable through the shipped writer —
`FeatureRunner.checkpoint_for({:done, :done}, …)` returns `nil` and
`Store.Writer.record_feature_terminal/4` deletes the row. Defensive only.

**Note**: `checkpoint.phase == :converge` is **not** this case — it means
converge has *not* run. See research R3.

### 2.4 Completed-through derivation

```
completed_through =
  cp.last_completed_phase   when Pipeline.phase?(cp.last_completed_phase)
  predecessor(cp.phase)     when Pipeline.phase?(cp.phase)
```

where `predecessor/1` is the phase before `phase` in `Pipeline.phases/0`, and
`nil` for `Pipeline.first()`. `rank(nil) = 0`; `rank(phase) = Pipeline.step_of(phase)`.

### 2.5 Verdict

Let `trail = last_boundary_phase`.

| Condition | Result | FR |
|---|---|---|
| `trail == nil` | `{:resume, cp.phase}` | FR-001 |
| `rank(completed_through) >= rank(trail)` | `{:resume, cp.phase}` | FR-004, FR-014 |
| `rank(completed_through) < rank(trail)` | `{:conflict, {:checkpoint_behind_trail, %{checkpoint: cp.phase, trail: trail}}}` | FR-005 |

`cp.phase` is the resume position whenever the checkpoint wins — it is
already the *next* phase (`FeatureRunner.checkpoint_for/3` records the next
phase at `{:cont, _}` and the diverted phase itself at a gate), so no
`Pipeline.next/3` re-derivation happens here. This is the same value
`SpeckitOrchestrator.resolve_start_phase/2` uses for a single-feature
`resume/2`, which is what makes FR-003 hold.

When `cp.phase` is not a recognised phase but `completed_through` was derived
from `last_completed_phase`, the position is `Pipeline.next(completed_through, :ok, %{})`'s
`{:cont, next}` — a record that knows what finished but not what is next is
recoverable, not damaged.

---

## 3. `status/3` clause order

Replaces the `recorded in [:running, :pending]` body. Every other clause of
`status/3` is **byte-identical** to 014.

```elixir
def status(recorded, %Evidence{} = evidence, run_shape) when recorded in [:running, :pending] do
  cond do
    # Clause 4 — completion wins over every position source (FR-008, FR-010).
    done_signal?(evidence, run_shape) ->
      :done

    # Clause 4b (025) — checkpoint-first (FR-001/003/004/005/011).
    position = checkpoint_position(recorded, evidence) ->
      position

    # Clause 5 — trail fallback, verbatim from 014 (FR-002).
    recorded == :running and evidence.last_boundary_phase in @resumable_boundaries ->
      {:resume, phase_after(evidence.last_boundary_phase)}

    # Clause 6 — nothing to salvage (FR-009). Unchanged.
    no_artifacts?(evidence) ->
      :pending

    # Clause 6b (025) — checkpoint but no branch (FR-009a).
    not evidence.branch_committed? and not is_nil(evidence.checkpoint) ->
      {:conflict, :checkpoint_without_branch}

    # Clause 7 — unchanged.
    evidence.pr_record? and not evidence.branch_committed? ->
      {:conflict, :pr_without_branch}

    true ->
      {:conflict, :ambiguous_evidence}
  end
end
```

`checkpoint_position/2` returns `false` (not `:no_position`) so the `cond`
falls through; it is the only new private helper on the hot path.

### 3.1 `recorded == :pending` and a checkpoint

Clause 4b is reached for `:pending` as well as `:running`. This is not a
widening: `Recovery.store_recorded_status/1` already promotes a `:pending`
row carrying a checkpoint to `:running` before `status/3` is called, so the
only `:pending` rows that reach clause 4b carry `checkpoint == nil` and take
`:no_position`. The clause is written without the `recorded == :running`
guard so the two callers (`Recovery.plan_run/2` and
`Recovery.Rebuild.propose/3`, which supplies a literal `:pending` for an
`:absent_from_record` feature) cannot diverge — FR-012.

---

## 4. Worked cases

| # | Recorded | Checkpoint | Trail | Result | FR |
|---|---|---|---|---|---|
| 1 | `:running` | `phase: :implement, last_completed_phase: :analyze` | `:tasks` | `{:resume, :implement}` | FR-001 (the defect) |
| 2 | `:running` | `phase: :analyze, last_completed_phase: :tasks` | `:tasks` | `{:resume, :analyze}` | FR-014 (agreement, unchanged) |
| 3 | `:running` | `nil` | `:tasks` | `{:resume, :analyze}` | FR-002 (fallback, unchanged) |
| 4 | `:running` | `phase: :plan, last_completed_phase: :clarify` | `:analyze` | `{:conflict, {:checkpoint_behind_trail, %{checkpoint: :plan, trail: :analyze}}}` | FR-005 |
| 5 | `:running` | `phase: :clarify, last_completed_phase: :clarify` (escalate divert) | `:specify` | `{:resume, :clarify}` | FR-003 (matches `resume/2`) |
| 6 | `:running` | `phase: :converge, last_completed_phase: :implement` | `:tasks` | `{:resume, :converge}` | FR-014 (research R3) |
| 7 | `:running` | `last_completed_phase: :converge` | any | falls through (`:no_position`) | FR-010 |
| 8 | `:running` | `phase: "implemnt"` (string), `last_completed_phase: nil` | `:tasks` | `{:conflict, {:damaged_checkpoint, …}}` | FR-011 |
| 9 | `:running` | `phase: :implement, …`, `branch_committed?: false`, no PR, no marker | `nil` | `{:conflict, :checkpoint_without_branch}` — clause 4b returns `{:resume, :implement}`? **No**: see §4.1 | FR-009a |
| 10 | `:pending` | `nil`, no branch, no PR, no marker | `nil` | `:pending` | FR-009 |
| 11 | `:escalated` | anything | anything | `:escalated` | FR-008 |
| 12 | `:done` | anything | done-signal present | `:done` | FR-008 |

### 4.1 Case 9 — ordering of 4b against 6b

A checkpoint with **no committed branch** must block (FR-009a), not resume:
there is no branch to resume onto. `checkpoint_position/2` therefore returns
`{:conflict, :checkpoint_without_branch}` — not `{:resume, _}` — when
`evidence.branch_committed? == false`, and clause 6b exists only to catch a
checkpoint too damaged to have produced a position. Both spellings yield the
same reason, so the ordering is not observable; the guard lives in
`checkpoint_position/2` because that is where the branch fact is already in
scope.

---

## 5. Non-goals

- No change to how boundary commits are written or what subject they carry.
- No change to `done_signal?/2`, `phase_after/1`, `no_artifacts?/1`, or the
  `:escalated`/`:halted`/`:failed`/`:done` clauses.
- No change to `Release`, `Coordinator`, or `Feature.status()`.
- No new operator surface (see `report-discrepancy.md`).
