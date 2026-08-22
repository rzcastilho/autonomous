defmodule SpeckitOrchestrator.ArtifactSubstance do
  @moduledoc """
  Decides whether a phase artifact on disk is **real output or untouched
  scaffolding**.

  The artifact gate in `SpeckitOrchestrator.Actions.RunFeaturePhase` used to ask
  only "does the file exist". That is not the same question as "did the phase do
  its job", because Spec Kit's own setup scripts create the file *before* the
  model writes a word: `.specify/scripts/bash/setup-plan.sh` copies
  `plan-template.md` over `specs/<feature>/plan.md` on entry. A plan session that
  ends early — dispatching background subagents and then ending its turn, which
  in a headless one-shot ends the session — leaves that copy behind, and the gate
  waves it through. The emptiness then surfaces a phase later, from the `tasks`
  phase refusing to work from an empty plan: a true message pointing at the wrong
  phase.

  This module is the substance half of that gate. It is pure apart from reading
  the artifact and globbing for templates: no git, no `System.cmd`, no model
  call.

  ## Calibration

  The target is **template passthrough**, not plan quality. Scoring reflects
  that: `:template_copy` is conclusive on its own, and otherwise **two distinct
  families** must agree before the verdict is `:unfilled`. So a real plan that
  happens to leave one `[DATE]` behind passes, and a real plan that quotes the
  phrase "ACTION REQUIRED" in prose passes. The `plan.md` that motivated this
  module matches five.

  An unreadable file reads as `:filled` — this gate exists to fail loud when a
  phase produced nothing, and a broken probe is not evidence that it did
  nothing. Same direction as the implement gate's treatment of a failed `git`.

  ## Profiles

    * `:plan` — every family. `setup-plan.sh` creates the file, so plan is the
      phase actually exposed to passthrough.
    * `:tasks` — `:template_copy` only. `setup-tasks.sh` resolves its template
      path but never writes `tasks.md`, so tasks is honest today; byte-equality
      with a template in the same worktree still cannot be legitimate output.
      Deliberately **not** given `:all_gates_unchecked`: a freshly generated
      `tasks.md` is legitimately all `- [ ]`.
  """

  @type family ::
          :template_copy
          | :action_required_comment
          | :header_placeholder
          | :structure_decision_placeholder
          | :all_gates_unchecked

  @type verdict :: :filled | {:unfilled, [family()]}

  @profiles %{
    plan: [
      :template_copy,
      :action_required_comment,
      :header_placeholder,
      :structure_decision_placeholder,
      :all_gates_unchecked
    ],
    tasks: [:template_copy]
  }

  @templates %{plan: "plan-template.md", tasks: "tasks-template.md"}

  # The phrase only counts inside an HTML comment — the template's own
  # `<!-- ACTION REQUIRED: ... -->` blocks — so prose mentioning it does not
  # trip the family.
  @action_required ~r/<!--(?:(?!-->).)*?ACTION REQUIRED/s

  @header_placeholders [
    ~r/^#\s+Implementation Plan:\s*\[FEATURE\]\s*$/m,
    ~r/^\*\*Branch\*\*:.*\[###-feature-name\]/m,
    ~r/\*\*Date\*\*:\s*\[DATE\]/
  ]

  @unchecked ~r/^\s*-\s\[ \]/m
  @checked ~r/^\s*-\s\[[xX]\]/m

  @doc """
  Whether `artifact_path` is filled-in output or untouched scaffolding.

  `profile` selects which families apply (`:plan` / `:tasks`); an unknown
  profile checks nothing and returns `:filled`.

  Options:

    * `:worktree` — the worktree root, used to locate the phase's template for
      the byte-identity check. Omitted (or with no template on disk) simply
      drops the `:template_copy` family; the remaining families still apply.
  """
  @spec verdict(Path.t(), atom(), keyword()) :: verdict()
  def verdict(artifact_path, profile, opts \\ []) do
    with families when families != [] <- Map.get(@profiles, profile, []),
         {:ok, body} <- File.read(artifact_path) do
      case Enum.filter(families, &family?(&1, body, profile, opts)) do
        [] -> :filled
        [:template_copy | _] = matched -> {:unfilled, matched}
        matched when length(matched) >= 2 -> {:unfilled, matched}
        _single -> :filled
      end
    else
      _ -> :filled
    end
  end

  # ---- families -----------------------------------------------------------

  # Byte-identity (modulo surrounding whitespace) with the template this phase
  # would have been seeded from.
  #
  # Discovered by wildcard, never by a fixed path: `resolve_template()` in
  # `.specify/scripts/bash/common.sh` prefers `.specify/templates/overrides/`,
  # then registry-sorted `.specify/presets/*`, and only then the plain
  # `.specify/templates/` path. The `**` glob covers all three without
  # reimplementing that resolver.
  defp family?(:template_copy, body, profile, opts) do
    case {Keyword.get(opts, :worktree), Map.get(@templates, profile)} do
      {worktree, leaf} when is_binary(worktree) and is_binary(leaf) ->
        target = String.trim(body)

        worktree
        |> Path.join(".specify/**/" <> leaf)
        |> Path.wildcard()
        |> Enum.any?(fn t ->
          match?({:ok, ^target}, with({:ok, c} <- File.read(t), do: {:ok, String.trim(c)}))
        end)

      _ ->
        false
    end
  end

  defp family?(:action_required_comment, body, _profile, _opts),
    do: Regex.match?(@action_required, body)

  # One family, not three: the title, branch, and date placeholders are a single
  # untouched header block, so counting them separately would let the header
  # alone reach the two-family threshold.
  defp family?(:header_placeholder, body, _profile, _opts),
    do: Enum.any?(@header_placeholders, &Regex.match?(&1, body))

  defp family?(:structure_decision_placeholder, body, _profile, _opts),
    do: structure_decision_placeholder?(body)

  # Every gate still unanswered. Requires at least three boxes so a document
  # with one or two incidental checkboxes cannot match, and no `- [x]` anywhere.
  defp family?(:all_gates_unchecked, body, _profile, _opts),
    do: length(Regex.scan(@unchecked, body)) >= 3 and not Regex.match?(@checked, body)

  # The template wraps the Structure Decision value across two lines, so this
  # reads the value as everything up to the next blank line rather than trying
  # to express the wrap in one regex. A value that both opens `[` and closes `]`
  # is the untouched instruction text; a markdown link (`[text](url)`) is not,
  # because it does not end at `]`.
  defp structure_decision_placeholder?(body) do
    case Regex.run(~r/\*\*Structure Decision\*\*:(.*?)(?:\n[ \t]*\n|\z)/s, body,
           capture: :all_but_first
         ) do
      [value] ->
        trimmed = value |> String.replace(~r/\s+/, " ") |> String.trim()
        String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]")

      _ ->
        false
    end
  end
end
