defmodule SpeckitOrchestrator.PhaseRequest do
  @moduledoc """
  Pure builder: `(feature, phase)` → `%Jido.Harness.RunRequest{}`.

  Keeps request construction side-effect free (no IO, no CLI) so it is fully
  unit-testable. The prompt invokes the Spec Kit command by its **slash name**
  and lets the CLI's own discovery resolve it — paths to prompt files are never
  hardcoded (they moved between Spec Kit 0.9 → 0.12). Phases without a native
  Spec Kit command (`clarify` reviewer, `converge`) use the versioned prompt
  packs in `priv/prompts/`.

  Per-phase permissions are set as **first-class RunRequest fields**
  (`permission_mode`, `allowed_tools`, `disallowed_tools`) — Phase 0 confirmed
  the adapter forwards them. This is belt-and-suspenders with the committed
  `.claude/settings.json` scope guard (Phase 5).
  """

  alias Jido.Harness.RunRequest
  alias SpeckitOrchestrator.{Config, Feature, Prompts}

  @slash %{
    specify: "/speckit.specify",
    plan: "/speckit.plan",
    tasks: "/speckit.tasks",
    analyze: "/speckit.analyze",
    implement: "/speckit.implement"
  }

  @doc """
  Build the RunRequest for `feature` at `phase`.

  Options:
    * `:cwd` — working directory (defaults to `Config.repo/0`; in a real run this
      is the feature worktree, supplied by the runner in Phase 3).
    * `:session_id` — resume an existing Claude session (nil = fresh).
  """
  @spec build(Feature.t(), atom(), keyword()) :: RunRequest.t()
  def build(%Feature{} = feature, phase, opts \\ []) when is_atom(phase) do
    %{
      prompt: prompt(feature, phase),
      cwd: Keyword.get(opts, :cwd, Config.repo()),
      model: Config.model_for(phase)
    }
    |> maybe_put(:max_turns, max_turns(phase))
    |> maybe_put(:session_id, Keyword.get(opts, :session_id))
    |> Map.merge(permissions(phase))
    |> RunRequest.new!()
  end

  # ---- prompt assembly ----------------------------------------------------

  defp prompt(feature, :specify) do
    "#{@slash.specify} Implement the feature specified in #{breakdown_ref(feature)} " <>
      "(id #{feature.id}, #{feature.slug}). Follow the constitution."
  end

  defp prompt(feature, :clarify) do
    Prompts.load("clarify") <>
      "\n\n---\nFeature under review: #{feature.id} #{feature.slug} " <>
      "(#{breakdown_ref(feature)})."
  end

  defp prompt(feature, :plan) do
    case Config.plan_stack() do
      [] ->
        @slash.plan

      stack ->
        "#{@slash.plan} Preferred stack: #{Enum.join(stack, ", ")}. " <> feature_tag(feature)
    end
  end

  defp prompt(_feature, :tasks), do: @slash.tasks

  defp prompt(_feature, :analyze), do: "#{@slash.analyze}\n\n" <> Prompts.load("analyze")

  defp prompt(_feature, :implement), do: @slash.implement

  defp prompt(feature, :converge), do: Prompts.load("converge") <> "\n\n" <> feature_tag(feature)

  defp prompt(feature, :describe) do
    Prompts.load("describe") <>
      "\n\n---\nFeature just built: #{feature.id} #{feature.slug} " <>
      "(#{breakdown_ref(feature)})."
  end

  defp prompt(_feature, phase) do
    raise ArgumentError, "no prompt defined for phase #{inspect(phase)}"
  end

  defp breakdown_ref(%Feature{path: path}) do
    Path.join(Config.breakdown_dir(), Path.basename(path))
  end

  defp feature_tag(%Feature{id: id, slug: slug}), do: "Feature #{id} (#{slug})."

  # ---- per-phase knobs ----------------------------------------------------

  defp max_turns(:implement), do: Config.implement_max_turns()
  defp max_turns(_), do: nil

  # Tools that must be pre-approved (via `--allowedTools`) so the headless CLI
  # runs them non-interactively — Bash is required because the Spec Kit phase
  # scripts (`.specify/scripts/*.sh`, e.g. setup-plan.sh) run under Bash; without
  # this they hit "This command requires approval" and the phase produces no
  # files (plan.md/tasks.md), silently no-opping everything downstream.
  @write_bash_tools ~w(Read Write Edit Bash Grep Glob)

  # analyze is read-only. The phases that run Spec Kit scripts and/or write repo
  # files (specify, plan, tasks, implement, converge) get non-interactive
  # write+Bash. clarify only edits the spec, so it needs no Bash.
  defp permissions(:analyze) do
    %{
      permission_mode: :plan,
      allowed_tools: ~w(Read Grep Glob),
      disallowed_tools: ~w(Write Edit)
    }
  end

  defp permissions(:clarify) do
    %{permission_mode: :accept_edits, allowed_tools: ~w(Read Write Edit Grep Glob)}
  end

  # describe is read-only but needs Bash to inspect the diff (git diff/log/status).
  defp permissions(:describe) do
    %{
      permission_mode: :plan,
      allowed_tools: ~w(Read Grep Glob Bash),
      disallowed_tools: ~w(Write Edit)
    }
  end

  defp permissions(phase) when phase in [:specify, :plan, :tasks, :implement, :converge] do
    %{permission_mode: :accept_edits, allowed_tools: @write_bash_tools}
  end

  defp permissions(_phase), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
