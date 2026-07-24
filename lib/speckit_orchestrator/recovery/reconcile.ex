defmodule SpeckitOrchestrator.Recovery.Reconcile do
  @moduledoc """
  Pure repository-as-truth decision table (Principle I — no I/O, no git/file/CLI
  access; evidence is gathered upstream by `Recovery.Evidence` and passed in).
  See `specs/014-recovery-reconciliation/contracts/reconcile.md`.

  Implements the full 7-clause precedence order: 1 (gate passthrough), 2
  (failed passthrough), 3 (done corroboration), 4 (non-terminal done-signal,
  US1), 5 (mid-run resume, US2), 6 (nothing-to-salvage — no evidence at all,
  US2; applies to both `:pending` and a `:running` feature that crashed
  before any boundary commit landed), 7 (contradictions, US3). `:blocked` (a
  prior conflict already held, or any other status outside the documented
  vocabulary) passes through unchanged — the safe, never-fabricate default
  (Principle II).
  """

  alias SpeckitOrchestrator.{Feature, Pipeline}
  alias SpeckitOrchestrator.Recovery.Evidence

  @typedoc "Which release-workflow shape the run was started under."
  @type run_shape :: {:breakdown, String.t()} | :ad_hoc

  @typedoc "The reconciled decision for one feature."
  @type result ::
          :done
          | {:resume, Pipeline.phase()}
          | :pending
          | :escalated
          | :halted
          | :failed
          | {:conflict, atom()}

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

  # Clause 3 — `done` requires corroboration (US3): same shape-aware
  # done-signal formula as clause 4, applied to an already-terminal `:done`.
  def status(:done, %Evidence{} = evidence, run_shape) do
    if done_signal?(evidence, run_shape) do
      :done
    else
      {:conflict, :done_without_artifacts}
    end
  end

  # Clauses 4-7 — `running`/`pending`.
  def status(recorded, %Evidence{} = evidence, run_shape) when recorded in [:running, :pending] do
    cond do
      # Clause 4 — non-terminal done-signal (FR-003).
      done_signal?(evidence, run_shape) ->
        :done

      # Clause 5 — mid-run resume (FR-004/FR-005): only `:running` may resume.
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

      # Clause 7 — contradictions (FR-014): a local PR record without a
      # committed branch can never happen honestly.
      evidence.pr_record? and not evidence.branch_committed? ->
        {:conflict, :pr_without_branch}

      # Clause 7 — residual ambiguity: never a silent guess.
      true ->
        {:conflict, :ambiguous_evidence}
    end
  end

  # `:blocked` (a prior conflict already held) and any other status outside
  # the documented vocabulary pass through unchanged — never fabricated
  # (Principle II).
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
end
