defmodule SpeckitOrchestrator.StackTracker do
  @moduledoc """
  Per-run holder of the current **stack top** branch for the stacked sequential
  PR workflow.

  Each feature branches from, and its PR targets, the branch on top of the stack
  when it starts: the first feature stacks on `pr_base` (e.g. `main`), and every
  subsequent feature stacks on the previous completed feature's branch. The
  facade seeds this with `pr_base`, reads `top/1` when creating a worktree and
  opening a PR, and `set_top/2` after a feature reaches `:done`.

  A plain `Agent`. Safe under the workflow's strict-sequential execution (cap 1),
  where exactly one feature is ever in flight, so there is no concurrent update.
  """

  use Agent

  @spec start_link(String.t()) :: Agent.on_start()
  def start_link(base) when is_binary(base) do
    Agent.start_link(fn -> base end)
  end

  @doc "The branch currently on top of the stack (the next feature's base)."
  @spec top(Agent.agent()) :: String.t()
  def top(agent), do: Agent.get(agent, & &1)

  @doc "Push a newly-completed feature branch onto the stack as the new top."
  @spec set_top(Agent.agent(), String.t()) :: :ok
  def set_top(agent, branch) when is_binary(branch), do: Agent.update(agent, fn _ -> branch end)

  @spec stop(Agent.agent()) :: :ok
  def stop(agent), do: Agent.stop(agent)
end
