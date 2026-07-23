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
    converge: "sonnet",
    describe: "sonnet"
  }

  @doc "Path to the target Spec Kit repo the orchestrator drives."
  @spec repo() :: String.t()
  def repo, do: get(:repo, ".")

  @doc """
  **Legacy (pre-012).** Directory holding `NNN-*.md` breakdown files, relative
  to `repo/0` — the flat, single-package layout `Layout`/`specs_root/0`
  superseded (`specs/autonomous/breakdown/<slug>`, FR-005/FR-007). No new
  write path resolves through this function; it survives only as the
  `layout: nil` fallback in `PhaseRequest`, the facade's own placeholder/
  legacy-package-detection scope, `SingleSpec`, and the read-only LiveViews —
  every one of them a backward-compatibility path for a repo that hasn't
  adopted `specs/autonomous/breakdown/` yet (FR-013).
  """
  @spec breakdown_dir() :: String.t()
  def breakdown_dir, do: get(:breakdown_dir, "docs/breakdown")

  @doc """
  **Legacy (pre-012).** Root under which per-feature git worktrees are
  created — the sibling-of-repo default `Layout.worktree_root` (machine-global,
  keyed by repository identity, FR-003) superseded. No new write path resolves
  through this function; `Worktree.create/2`'s `layout: nil` (test/legacy)
  fallback is its only remaining caller.
  """
  @spec worktree_root() :: String.t()
  def worktree_root, do: get(:worktree_root, "../.speckit-worktrees")

  @doc """
  **Legacy (pre-012).** Root for durable per-phase transcripts, resolved
  relative to `repo/0`. Defaults to `<repo>/.speckit-transcripts` — the
  in-repo-per-target default `Layout.transcript_root` (machine-global,
  keyed by repository identity + run scope, FR-004) superseded. No new write
  path resolves through this function; `Transcripts`/`Checkpoint`/`Describe`'s
  `layout: nil` (test/legacy) fallback is its only remaining caller. Gitignore
  `.speckit-transcripts/` in the target repo if still relied on.
  """
  @spec transcript_root() :: String.t()
  def transcript_root, do: Path.expand(get(:transcript_root, ".speckit-transcripts"), repo())

  @doc """
  Machine-global base for worktrees + durable transcripts, keyed by repository
  identity (`RepoIdentity.segment/1`). Default `~/.autonomous`, expanded at read
  time; overridable via `Application.put_env/3` (tests point it at a tmp dir).
  """
  @spec autonomous_root() :: String.t()
  def autonomous_root, do: get(:autonomous_root, "~/.autonomous") |> Path.expand()

  @doc """
  In-repo root for committed breakdown/ad-hoc feature files, relative to
  `repo/0`. Default `specs/autonomous`.
  """
  @spec specs_root() :: String.t()
  def specs_root, do: get(:specs_root, "specs/autonomous")

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

  @doc """
  How many times to retry a phase that fails **transiently** (a server/API drop —
  see `PhaseResult.transient?/1`) before failing the feature. A real,
  deterministic failure is never retried.
  """
  @spec phase_max_retries() :: non_neg_integer()
  def phase_max_retries, do: get(:phase_max_retries, 1)

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
