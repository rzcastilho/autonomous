defmodule SpeckitOrchestrator.BranchGuard do
  @moduledoc """
  Pure branch-drift decision (027, US2).

  The mod-player incident's root cause was a target-side git hook moving a
  worktree off the orchestrator's branch mid-`specify`, with nothing reading
  `HEAD` afterward — every subsequent commit landed on the stray branch. This
  is the check that closes that gap: compare the branch the orchestrator
  expects against what `Worktree.current_branch/1` actually observed.

  No IO, no CLI, no harness, no Jido — fed only the two strings/terms its
  caller already read.
  """

  @type observed :: String.t() | {:detached, String.t()}
  @type drift :: %{expected: String.t(), observed: observed()}

  @doc """
  `:ok` when `observed` is exactly `expected`; `{:drift, %{expected,
  observed}}` for anything else — a different branch name, or a detached
  `HEAD`. There is no partial match: a branch name is either the one the
  orchestrator is driving or it is not.
  """
  @spec check(expected :: String.t(), observed :: observed()) :: :ok | {:drift, drift()}
  def check(expected, expected) when is_binary(expected), do: :ok

  def check(expected, observed) when is_binary(expected) do
    {:drift, %{expected: expected, observed: observed}}
  end
end
