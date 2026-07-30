defmodule SpeckitOrchestrator.StackTracker do
  @moduledoc """
  Per-run holder of the **stack chain** for the stacked sequential PR workflow.

  Each feature branches from, and its PR targets, the branch below it in the
  stack: the first feature stacks on `pr_base` (e.g. `main`), and every
  subsequent feature stacks on the previous completed feature's branch.

  The chain is a list, newest first — not a single "top" — because a branch can
  stop being a valid base after it is created. Once a feature's PR is **merged
  into `pr_base`**, its branch is no longer something to stack on: the next
  feature belongs directly on `pr_base`, or on the newest completed branch that
  is still unmerged.

      main <- 001, 001 <- 002, 002 <- 003        # nothing merged yet
      main <- 001 (merged), main <- 002, 002 <- 003

  Keeping the whole chain lets the facade skip merged links and fall through to
  whatever is still open, instead of guessing between "the one branch I
  remember" and `pr_base`. This module stays pure state — deciding which links
  are still valid is git I/O and lives in the facade (`resolve_base/2`).

  019: only a `:done` **backlog** feature ever joins the chain. An ad-hoc
  feature (`group: :ad_hoc`) runs alone in its own run and always stacks on
  `pr_base` directly, so it never pushes (FR-028, R6).

  A plain `Agent`. Safe under the workflow's strict-sequential execution (one
  feature at a time — 019, `Release.next/3` rule 3), where exactly one feature
  is ever in flight, so there is no concurrent update.

  Its lifetime must be the **run's**, not the caller's — the facade starts it
  under `CoordinatorSup` beside the Coordinator it serves. An `Agent` linked to
  whoever asked for the run dies with them, and the surviving Coordinator then
  crashes on the next `push/2` with `no process`.
  """

  use Agent

  @type state :: %{base: String.t(), chain: [String.t()]}

  @doc """
  Start a tracker on `base`. `:chain` seeds already-completed branches, newest
  first — a resumed run's chain is not empty (see `SpeckitOrchestrator`'s
  `stack_seed/1`).
  """
  @spec start_link(String.t(), keyword()) :: Agent.on_start()
  def start_link(base, opts \\ []) when is_binary(base) do
    {chain, opts} = Keyword.pop(opts, :chain, [])
    Agent.start_link(fn -> %{base: base, chain: chain} end, opts)
  end

  @doc "The run's `pr_base` — the bottom of the stack, always a valid base."
  @spec base(Agent.agent()) :: String.t()
  def base(agent), do: Agent.get(agent, & &1.base)

  @doc "Completed feature branches, newest first. `pr_base` is not a member."
  @spec chain(Agent.agent()) :: [String.t()]
  def chain(agent), do: Agent.get(agent, & &1.chain)

  @doc "Push a newly-completed feature branch onto the chain as the newest link."
  @spec push(Agent.agent(), String.t()) :: :ok
  def push(agent, branch) when is_binary(branch),
    do: Agent.update(agent, &%{&1 | chain: [branch | &1.chain]})

  @spec stop(Agent.agent()) :: :ok
  def stop(agent), do: Agent.stop(agent)
end
