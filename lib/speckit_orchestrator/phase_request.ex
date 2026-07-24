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
  alias SpeckitOrchestrator.{Config, Feature, Layout, Prompts}

  @slash %{
    specify: "/speckit.specify",
    plan: "/speckit.plan",
    tasks: "/speckit.tasks",
    analyze: "/speckit.analyze",
    implement: "/speckit.implement"
  }

  # Tools that must be pre-approved (via `--allowedTools`) so the headless CLI
  # runs them non-interactively — Bash is required because the Spec Kit phase
  # scripts (`.specify/scripts/*.sh`, e.g. setup-plan.sh) run under Bash; without
  # this they hit "This command requires approval" and the phase produces no
  # files (plan.md/tasks.md), silently no-opping everything downstream.
  @write_bash_tools ~w(Read Write Edit Bash Grep Glob)

  @doc """
  Build the RunRequest for `feature` at `phase`.

  Options:
    * `:cwd` — working directory (defaults to `Config.repo/0`; in a real run this
      is the feature worktree, supplied by the runner in Phase 3).
    * `:session_id` — resume an existing Claude session (nil = fresh).
    * `:resume_prompt` — operator's free-text guidance for a resumed phase;
      appended as a trailing section to the built prompt. `nil`/blank = no-op.
    * `:layout` — the run's resolved `%Layout{}` (FR-011), used to resolve the
      **worktree-relative** breakdown ref (`Layout.in_repo_rel/1` — resolves
      analyze finding I1). `nil` (tests, non-layout callers) falls back to
      `Config.breakdown_dir/0`, the pre-012 flat layout.
  """
  @spec build(Feature.t(), atom(), keyword()) :: RunRequest.t()
  def build(%Feature{} = feature, phase, opts \\ []) when is_atom(phase) do
    layout = Keyword.get(opts, :layout)

    %{
      prompt:
        append_resume_prompt(prompt(feature, phase, layout), Keyword.get(opts, :resume_prompt)),
      cwd: Keyword.get(opts, :cwd, Config.repo()),
      model: Config.model_for(phase)
    }
    |> maybe_put(:max_turns, max_turns(phase))
    |> maybe_put(:session_id, Keyword.get(opts, :session_id))
    |> Map.merge(permissions(phase))
    |> RunRequest.new!()
  end

  @doc """
  Build the RunRequest for a pre-phase remediation step (feature 013) — a
  discrete, write-capable execution that runs **before** the target phase on
  resume, distinct from `build/3`'s per-phase prompts.

  Options:
    * `:cwd` — the feature worktree (defaults to `Config.repo/0`).
    * `:layout` — the run's resolved `%Layout{}`, for the worktree-relative
      breakdown ref (same as `build/3`).
    * `:prompt` — the operator's verbatim remediation instruction, appended
      after a short framing header.

  No `session_id` (fresh session, like every phase).
  """
  @spec build_remediation(Feature.t(), String.t(), keyword()) :: RunRequest.t()
  def build_remediation(%Feature{} = feature, model, opts \\ []) when is_binary(model) do
    layout = Keyword.get(opts, :layout)

    %{
      prompt: remediation_prompt(feature, layout, Keyword.get(opts, :prompt)),
      cwd: Keyword.get(opts, :cwd, Config.repo()),
      model: model,
      permission_mode: :accept_edits,
      allowed_tools: @write_bash_tools
    }
    |> RunRequest.new!()
  end

  defp remediation_prompt(feature, layout, prompt) do
    "Remediation for feature #{feature.id} (#{feature.slug}), " <>
      "#{breakdown_ref(feature, layout)}.\n\n---\n" <> (prompt || "")
  end

  # ---- prompt assembly ----------------------------------------------------

  # Pins SPECIFY_FEATURE_DIRECTORY to specs/<id>-<slug> — the exact slug the
  # worktree's branch (feature/<id>-<slug>) already carries — so specify's own
  # short-name generation can never pick a *different* spec-dir slug than the
  # branch. Left to its own heuristic, Claude may condense a description into a
  # shorter/different slug (e.g. "list-all-previous-polls-result" vs
  # "list-polls-results"); every later phase (plan/tasks/analyze/implement) is a
  # bare slash command with no feature-specific text, resolved by the CLI via
  # feature.json/branch-name — a divergent spec dir silently orphans it, so
  # spec.md gets written but plan/tasks/implementation never do (see
  # specs/001-single-spec-run — manual validation caught this in production).
  defp prompt(feature, :specify, layout) do
    "#{@slash.specify} Implement the feature specified in #{breakdown_ref(feature, layout)} " <>
      "(id #{feature.id}, #{feature.slug}). Use SPECIFY_FEATURE_DIRECTORY=specs/#{feature.id}-#{feature.slug}. " <>
      "Follow the constitution."
  end

  defp prompt(feature, :clarify, layout) do
    Prompts.load("clarify") <>
      "\n\n---\nFeature under review: #{feature.id} #{feature.slug} " <>
      "(#{breakdown_ref(feature, layout)})."
  end

  defp prompt(feature, :plan, _layout) do
    case Config.plan_stack() do
      [] ->
        @slash.plan

      stack ->
        "#{@slash.plan} Preferred stack: #{Enum.join(stack, ", ")}. " <> feature_tag(feature)
    end
  end

  defp prompt(_feature, :tasks, _layout), do: @slash.tasks

  defp prompt(_feature, :analyze, _layout), do: "#{@slash.analyze}\n\n" <> Prompts.load("analyze")

  defp prompt(_feature, :implement, _layout), do: @slash.implement

  defp prompt(feature, :converge, _layout),
    do: Prompts.load("converge") <> "\n\n" <> feature_tag(feature)

  defp prompt(feature, :describe, layout) do
    Prompts.load("describe") <>
      "\n\n---\nFeature just built: #{feature.id} #{feature.slug} " <>
      "(#{breakdown_ref(feature, layout)})."
  end

  defp prompt(_feature, phase, _layout) do
    raise ArgumentError, "no prompt defined for phase #{inspect(phase)}"
  end

  # Blank (nil/""/whitespace-only) guidance leaves the prompt byte-identical to
  # the no-opt build — only a non-blank string gets the trailing section.
  defp append_resume_prompt(prompt, resume_prompt) do
    if blank?(resume_prompt) do
      prompt
    else
      prompt <> "\n\n---\nOperator guidance (resume): " <> resume_prompt
    end
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # Worktree-relative (resolves analyze finding I1): a phase runs with
  # `cwd = <worktree>`, so this is joined onto the worktree by the CLI, never
  # an absolute base-repo path. `nil` layout (tests, non-012 callers) falls
  # back to the pre-012 flat `Config.breakdown_dir/0`.
  defp breakdown_ref(%Feature{path: path}, nil) do
    Path.join(Config.breakdown_dir(), Path.basename(path))
  end

  defp breakdown_ref(%Feature{path: path}, layout) do
    Path.join(Layout.in_repo_rel(layout), Path.basename(path))
  end

  defp feature_tag(%Feature{id: id, slug: slug}), do: "Feature #{id} (#{slug})."

  # ---- per-phase knobs ----------------------------------------------------

  defp max_turns(:implement), do: Config.implement_max_turns()
  defp max_turns(_), do: nil

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
