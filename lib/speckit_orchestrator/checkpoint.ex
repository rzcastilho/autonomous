defmodule SpeckitOrchestrator.Checkpoint do
  @moduledoc """
  The empty-checkpoint decision table (net two) — the direct analogue of
  `Remediation.next/2` sitting under `Pipeline.next/3`.

  A phase whose contract is to produce a named file, that starts with that
  file absent and commits nothing at its boundary, fails at that phase. See
  `specs/022-spec-number-split/contracts/empty-checkpoint.md`.
  """

  alias SpeckitOrchestrator.Pipeline

  @armed_phases [:specify, :plan, :tasks]

  @type commit_result :: :ok | :noop | {:error, term()}

  @doc "Whether `phase` is armed for the empty-checkpoint net."
  @spec armed?(Pipeline.phase()) :: boolean()
  def armed?(phase), do: phase in @armed_phases

  @doc """
  `{:failed, {:empty_checkpoint, phase}}` only when an armed phase started
  with its artifact absent and committed nothing (`:noop`). Every other
  combination — an unarmed phase, an artifact already present at start, or a
  commit result other than `:noop` (`:ok`, or a git failure which is not
  evidence the phase wrote nothing) — advances.
  """
  @spec verdict(Pipeline.phase(), boolean(), commit_result()) ::
          :advance | {:failed, {:empty_checkpoint, Pipeline.phase()}}
  def verdict(phase, true, :noop) when phase in @armed_phases,
    do: {:failed, {:empty_checkpoint, phase}}

  def verdict(phase, _absent?, _commit_result) when phase in @armed_phases, do: :advance
  def verdict(_phase, _absent?, _commit_result), do: :advance
end
