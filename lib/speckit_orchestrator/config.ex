defmodule SpeckitOrchestrator.Config do
  @moduledoc """
  Typed accessors over `config :speckit_orchestrator` (see `config/config.exs`).

  All reads go through `Application.get_env/3` so tests can override values with
  `Application.put_env/3`. Model values are full model strings (not CLI aliases)
  for reproducibility.
  """

  @app :speckit_orchestrator

  # Aliases, not full strings — the pinned ClaudeAgentSDK catalog validates
  # against these (see config/config.exs). Pin reproducibility via
  # ANTHROPIC_DEFAULT_*_MODEL env vars.
  @default_models %{
    specify: "sonnet",
    clarify: "opus",
    plan: "opus",
    tasks: "sonnet",
    analyze: "opus",
    implement: "sonnet",
    converge: "sonnet"
  }

  @doc "Path to the target Spec Kit repo the orchestrator drives."
  @spec repo() :: String.t()
  def repo, do: get(:repo, ".")

  @doc "Directory holding `NNN-*.md` breakdown files, relative to `repo/0`."
  @spec breakdown_dir() :: String.t()
  def breakdown_dir, do: get(:breakdown_dir, "docs/breakdown")

  @doc "Root under which per-feature git worktrees are created."
  @spec worktree_root() :: String.t()
  def worktree_root, do: get(:worktree_root, "../.speckit-worktrees")

  @doc """
  Root for durable per-phase transcripts, resolved relative to `repo/0`. Defaults
  to `<repo>/.speckit-transcripts` — **inside the target repo** so different
  targets never share a transcript dir (a sibling default keyed by feature id
  mixes `001/` across every target). These survive worktree teardown on `:done`
  (the in-worktree `.speckit_logs` copy does not), so plan/tasks/implement output
  stays inspectable. Gitignore `.speckit-transcripts/` in the target repo.
  """
  @spec transcript_root() :: String.t()
  def transcript_root, do: Path.expand(get(:transcript_root, ".speckit-transcripts"), repo())

  @doc "Full per-phase model routing map."
  @spec models() :: %{atom() => String.t()}
  def models, do: get(:models, @default_models)

  @doc """
  Full model string for a phase. Raises if the phase has no configured model —
  a missing route is a config bug, not a silent fallback.
  """
  @spec model_for(atom()) :: String.t()
  def model_for(phase) when is_atom(phase) do
    case Map.fetch(models(), phase) do
      {:ok, model} ->
        model

      :error ->
        raise ArgumentError,
              "no model configured for phase #{inspect(phase)}; " <>
                "known phases: #{inspect(Map.keys(models()))}"
    end
  end

  @doc "Ordered plan stack passed to the plan phase."
  @spec plan_stack() :: [String.t()]
  def plan_stack, do: get(:plan_stack, [])

  @doc "Maximum features running concurrently (worktree-level parallelism)."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: get(:max_concurrency, 2)

  @doc """
  Stacked sequential PR workflow. When true, `run/1` forces sequential execution
  (cap 1), preflights that the target repo has the `pr_remote/0` remote, branches
  each feature from the previous completed feature's branch, and on `:done`
  pushes the branch and opens a PR against that base.
  """
  @spec pr_workflow?() :: boolean()
  def pr_workflow?, do: get(:pr_workflow, false)

  @doc "Root base branch for the first feature's PR in the stacked workflow."
  @spec pr_base() :: String.t()
  def pr_base, do: get(:pr_base, "main")

  @doc "Git remote to push feature branches to (and preflight) in the PR workflow."
  @spec pr_remote() :: String.t()
  def pr_remote, do: get(:pr_remote, "origin")

  @doc "Cost circuit-breaker budget for a run, in USD."
  @spec budget_usd() :: number()
  def budget_usd, do: get(:budget_usd, 25.0)

  @doc "Turn cap for the long-running implement phase."
  @spec implement_max_turns() :: pos_integer()
  def implement_max_turns, do: get(:implement_max_turns, 80)

  @doc "Pinned Spec Kit CLI tag (drift diagnosis)."
  @spec speckit_version() :: String.t()
  def speckit_version, do: get(:speckit_version, "v0.12.11")

  @default_cost_estimates %{
    specify: 0.20,
    clarify: 0.40,
    plan: 0.60,
    tasks: 0.30,
    analyze: 0.40,
    implement: 2.50,
    converge: 0.30
  }

  @doc "Fallback per-phase USD cost estimate (used when the run surfaces no cost)."
  @spec cost_estimate(atom()) :: number()
  def cost_estimate(phase) when is_atom(phase) do
    get(:cost_estimates, @default_cost_estimates) |> Map.get(phase, 0.0)
  end

  @spec get(atom(), term()) :: term()
  defp get(key, default), do: Application.get_env(@app, key, default)
end
