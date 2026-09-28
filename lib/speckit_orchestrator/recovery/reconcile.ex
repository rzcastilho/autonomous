defmodule SpeckitOrchestrator.Recovery.Reconcile do
  @moduledoc """
  Pure repository-as-truth decision table (Principle I — no I/O, no git/file/CLI
  access; evidence is gathered upstream by `Recovery.Evidence` and passed in).
  See `specs/014-recovery-reconciliation/contracts/reconcile.md` and, for the
  checkpoint-first extension, `specs/025-checkpoint-first-resume/contracts/reconcile-checkpoint-first.md`.

  Implements the full 7-clause precedence order (with two 025 sub-clauses): 1
  (gate passthrough), 2 (failed passthrough), 3 (done corroboration), 4
  (non-terminal done-signal, US1), **4b (checkpoint-first resume position,
  025 US1/US2/US3)**, 5 (mid-run resume via the commit trail, US2 — the
  no-checkpoint fallback), 6 (nothing-to-salvage — no evidence at all, US2;
  applies to both `:pending` and a `:running` feature that crashed before any
  boundary commit landed), **6b (checkpoint with no branch to resume onto,
  025 US3)**, 7 (contradictions, US3). Any status outside the documented
  vocabulary passes through unchanged — the safe, never-fabricate default
  (Principle II).
  """

  alias SpeckitOrchestrator.{Feature, Pipeline}
  alias SpeckitOrchestrator.Recovery.Evidence

  @typedoc "Which release-workflow shape the run was started under."
  @type run_shape :: {:breakdown, String.t()} | :ad_hoc

  @typedoc "A conflict reason: a bare atom, or a tag carrying diagnostic detail (025)."
  @type conflict_reason :: atom() | {atom(), map()}

  @typedoc """
  The reconciled decision for one feature. `{:escalated, reason}` (029) is
  the one variant that carries a reason — every other bare atom is
  passthrough or clause 1's unconditional gate.
  """
  @type result ::
          :done
          | {:resume, Pipeline.phase()}
          | :pending
          | :escalated
          | {:escalated, term()}
          | :halted
          | :failed
          | {:conflict, conflict_reason()}

  @typedoc "Exposed for direct unit test; `status/3` is the only production caller."
  @type resume_position ::
          {:resume, Pipeline.phase()}
          | {:conflict, conflict_reason()}
          | :no_position

  # The boundary phases a mid-run resume can follow. `:converge` is excluded —
  # a boundary commit "after converge" is a done-signal (clause 4), not a
  # resume (clause 5); see `phase_after/1`.
  @resumable_boundaries [:specify, :clarify, :plan, :tasks, :analyze, :implement]

  @doc """
  The whole repository-as-truth decision for one feature. See
  `contracts/reconcile.md` for the full 7-clause precedence order.
  """
  @spec status(Feature.status(), Evidence.t(), run_shape()) :: result()

  # Clause 1 — human gates are inviolable: unchanged regardless of evidence
  # (FR-007, SC-004). No input combination may advance a gate.
  def status(:escalated, %Evidence{}, _run_shape), do: :escalated
  def status(:halted, %Evidence{}, _run_shape), do: :halted

  # Clause 2 — `failed` stays `failed` (US3).
  def status(:failed, %Evidence{}, _run_shape), do: :failed

  # 029, research.md R12: a persisted `:awaiting_answers` row reconciled at
  # all only means its worker is already dead (a live one is drained and
  # records its own escalation first, ahead of ever reaching restart
  # reconciliation) — unconditional, like clause 1, since no amount of
  # evidence makes an orphaned wait resumable on its own.
  def status(:awaiting_answers, %Evidence{}, _run_shape),
    do: {:escalated, {:needs_human, :restart}}

  # Clause 3 — `done` requires corroboration (US3): same shape-aware
  # done-signal formula as clause 4, applied to an already-terminal `:done`.
  def status(:done, %Evidence{} = evidence, run_shape) do
    if done_signal?(evidence, run_shape) do
      :done
    else
      {:conflict, :done_without_artifacts}
    end
  end

  # Clauses 4-7 (plus 025's 4b/6b) — `running`/`pending`.
  def status(recorded, %Evidence{} = evidence, run_shape) when recorded in [:running, :pending] do
    cond do
      # Clause 4 — non-terminal done-signal (FR-003).
      done_signal?(evidence, run_shape) ->
        :done

      # Clause 4b (025) — checkpoint-first resume position (FR-001/003/004/
      # 005/011). Written without a `recorded == :running` guard on purpose
      # (contracts/reconcile-checkpoint-first.md §3.1): the only `:pending`
      # rows that reach here already carry `checkpoint == nil` (promoted to
      # `:running` upstream otherwise), so `checkpoint_position/2` falls
      # through to `false` for them exactly like today.
      position = checkpoint_position(recorded, evidence) ->
        position

      # Clause 5 — mid-run resume via the commit trail (FR-002/FR-004/
      # FR-005), unchanged from 014 — the no-checkpoint fallback. Only
      # `:running` may resume.
      recorded == :running and evidence.last_boundary_phase in @resumable_boundaries ->
        {:resume, phase_after(evidence.last_boundary_phase)}

      # Clause 6 — nothing to salvage: no branch, no corroborating artifact of
      # any kind. Textually FR-008 names `:pending` only, but a `:running`
      # feature with zero durable evidence (crashed before its first
      # boundary commit landed) is the same "nothing happened yet" case, not
      # a contradiction — indistinguishable from never-started, so it gets
      # the same safe-restart treatment rather than an unresolvable conflict.
      no_artifacts?(evidence) ->
        :pending

      # Clause 6b (025) — a checkpoint with no committed branch to resume
      # onto (FR-009a): there is nothing to resume, so it blocks rather than
      # falling through to clause 7's residual-ambiguity guess.
      not evidence.branch_committed? and not is_nil(evidence.checkpoint) ->
        {:conflict, :checkpoint_without_branch}

      # Clause 7 — contradictions (FR-014): a local PR record without a
      # committed branch can never happen honestly.
      evidence.pr_record? and not evidence.branch_committed? ->
        {:conflict, :pr_without_branch}

      # Clause 7 — residual ambiguity: never a silent guess.
      true ->
        {:conflict, :ambiguous_evidence}
    end
  end

  # Any status outside the documented vocabulary passes through unchanged —
  # never fabricated (Principle II).
  def status(recorded, %Evidence{}, _run_shape), do: recorded

  @doc """
  Whether `evidence` proves `run_shape`'s workflow finished, independent of
  the recorded status (FR-003). The local PR record is authoritative —
  `evidence.pr_remote?` never downgrades a local `true` (offline-first,
  FR-018).
  """
  @spec done_signal?(Evidence.t(), run_shape()) :: boolean()
  def done_signal?(%Evidence{} = evidence, {:breakdown, _slug}) do
    evidence.pr_record? and evidence.branch_committed?
  end

  def done_signal?(%Evidence{} = evidence, :ad_hoc) do
    evidence.final_marker? and evidence.branch_committed?
  end

  @doc """
  The `Pipeline` phase following the latest committed boundary `phase`. Only
  meaningful for a non-terminal boundary — a `:converge` boundary is a
  done-signal (clause 4), never passed here.
  """
  @spec phase_after(Pipeline.phase()) :: Pipeline.phase()
  def phase_after(phase) when phase in @resumable_boundaries do
    case Pipeline.next(phase, :ok, %{}) do
      {:cont, next} -> next
    end
  end

  # Clause 6: a genuinely never-started feature has no corroborating evidence
  # of any kind — no committed branch, no local PR record, no checkpoint, no
  # converge marker.
  defp no_artifacts?(%Evidence{} = evidence) do
    not evidence.branch_committed? and not evidence.pr_record? and
      not evidence.final_marker? and is_nil(evidence.checkpoint)
  end

  # ---- checkpoint-first resume position (025) --------------------------------
  # See contracts/reconcile-checkpoint-first.md §2.

  @doc """
  The resume position a durable `checkpoint` names, verified against the
  commit-trail `last_boundary_phase` — `:no_position` hands the decision to
  the caller's trail fallback (clause 5), byte-identical to today
  (contracts/reconcile-checkpoint-first.md §2.1).
  """
  @spec resume_position(map() | nil, Pipeline.phase() | nil) :: resume_position()
  def resume_position(checkpoint, _trail) when not is_map(checkpoint), do: :no_position

  def resume_position(checkpoint, trail) do
    raw_phase = Map.get(checkpoint, :phase)
    raw_last = Map.get(checkpoint, :last_completed_phase)

    cond do
      # §2.3 — completed-through of `:converge` is a completion signal, never
      # a resume position; unreachable through the shipped writer, defensive
      # only.
      raw_last == :converge ->
        :no_position

      # §2.2 — neither half of the checkpoint names a recognised phase. Raw
      # values carried verbatim (Principle II) — never coerced, never
      # `String.to_atom/1`-ed.
      not Pipeline.phase?(raw_phase) and not Pipeline.phase?(raw_last) ->
        {:conflict, {:damaged_checkpoint, %{phase: raw_phase, last_completed_phase: raw_last}}}

      true ->
        completed_through = completed_through(raw_phase, raw_last)
        verdict(raw_phase, completed_through, trail)
    end
  end

  # §2.4 — `last_completed_phase` wins when it names a recognised phase;
  # otherwise fall back to the phase immediately before `phase`. One of the
  # two always matches here — the damaged case above already excluded
  # "neither".
  defp completed_through(raw_phase, raw_last) do
    cond do
      Pipeline.phase?(raw_last) -> raw_last
      Pipeline.phase?(raw_phase) -> predecessor(raw_phase)
    end
  end

  # The phase immediately before `phase` in `Pipeline.phases/0`; `nil` for
  # `Pipeline.first()`. Only ever called with a phase already known valid.
  defp predecessor(phase) do
    phases = Pipeline.phases()

    case Enum.find_index(phases, &(&1 == phase)) do
      0 -> nil
      idx -> Enum.at(phases, idx - 1)
    end
  end

  defp rank(nil), do: 0
  defp rank(phase), do: Pipeline.step_of(phase)

  # §2.5 — the checkpoint wins on a tie (FR-004/FR-014); behind the trail is a
  # genuine contradiction (FR-005), never silently resolved.
  defp verdict(raw_phase, completed_through, trail) do
    cond do
      is_nil(trail) ->
        {:resume, resume_phase(raw_phase, completed_through)}

      rank(completed_through) >= rank(trail) ->
        {:resume, resume_phase(raw_phase, completed_through)}

      true ->
        {:conflict, {:checkpoint_behind_trail, %{checkpoint: raw_phase, trail: trail}}}
    end
  end

  # `cp.phase` is already the next phase to run (FeatureRunner.checkpoint_for/3
  # records it that way) and is used verbatim whenever it is itself a
  # recognised phase. A record that knows what finished but not what phase is
  # next (an unrecognised `phase` alongside a valid `last_completed_phase`) is
  # recoverable, not damaged — derive it from `Pipeline.next/3` instead.
  defp resume_phase(raw_phase, completed_through) do
    if Pipeline.phase?(raw_phase) do
      raw_phase
    else
      {:cont, next} = Pipeline.next(completed_through, :ok, %{})
      next
    end
  end

  # Clause 4b's helper (contracts/reconcile-checkpoint-first.md §3): returns
  # `false` — not `:no_position` — so the caller's `cond` falls through to
  # clause 5. `recorded` is unused (see §3.1: the guard is deliberately
  # omitted so `:pending` and `:running` can never diverge).
  defp checkpoint_position(_recorded, %Evidence{checkpoint: nil}), do: false

  defp checkpoint_position(_recorded, %Evidence{} = evidence) do
    case resume_position(evidence.checkpoint, evidence.last_boundary_phase) do
      :no_position ->
        false

      # §4.1 — a checkpoint with no committed branch has nowhere to resume
      # onto; report it distinctly rather than dispatching onto a branch that
      # was never created.
      {:resume, _phase} when not evidence.branch_committed? ->
        {:conflict, :checkpoint_without_branch}

      other ->
        other
    end
  end
end
