defmodule SpeckitOrchestrator.Actions.RunFeaturePhase do
  @moduledoc """
  Run one pipeline phase for the agent's feature and fold the result back into
  agent state. Routed by the `"phase.run"` signal (`data: %{phase: atom}`).

  Reads `feature`, `worktree`, `session_id`, and `ledger` from the agent state
  (`context[:agent].state`), builds the request with
  `PhaseRequest.build/3`, runs it through the harness, folds a `PhaseResult`,
  extracts the phase's **gate signals**, resolves and records cost, and writes
  `last_outcome` / `last_signals` / `session_id` / `history` / `cost_total` back
  to state. It does **not** decide the transition — the `FeatureRunner` owns
  `Pipeline.next/3`.

  Gate extraction:
  * `:clarify` → `needs_human?` when the transcript carries the literal
    `## NEEDS HUMAN` marker.
  * `:analyze` → `critical?` / `high?` from `AnalyzeResult.parse/1`; **malformed
    analyze JSON is an error outcome**, never a silent pass.
  * `:plan` / `:tasks` / `:implement` → `missing_artifact` when the phase
    returned a successful transcript but produced none of the files it exists to
    write. A phase can refuse, ask an unanswerable question, or no-op on a
    missing upstream artifact and still look perfectly successful — only the
    filesystem tells the truth.
  * `:converge` → `not_ready?` from the `## CONVERGE: NOT READY` marker.
  """

  use Jido.Action,
    name: "run_feature_phase",
    description: "Run one Spec Kit phase and record the result into agent state",
    schema: [phase: [type: :atom, required: true]]

  alias SpeckitOrchestrator.{AnalyzeResult, Cost, Ledger, PhaseRequest, PhaseResult}

  # The escalation signal is the literal `## NEEDS HUMAN` heading emitted by the
  # clarify reviewer. Match it only as a real Markdown heading (line start, whole
  # line) — a naive substring match trips on prose that *mentions* the marker,
  # e.g. "No `## NEEDS HUMAN` — nothing material left", turning a clean pass into
  # a false escalation.
  @needs_human_marker ~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m

  # Converge's verdict line (see priv/prompts/converge.md). Line-anchored for the
  # same reason as the NEEDS HUMAN marker: prose that *mentions* the marker must
  # not trip the gate. Absence of any marker is treated as ready — the artifact
  # gate is the primary net for an unbuilt feature, so a model that forgets the
  # line does not fail an otherwise good run.
  @converge_not_ready_marker ~r/^\#\#[ \t]+CONVERGE:[ \t]+NOT READY[ \t]*$/m

  @impl true
  def run(%{phase: phase}, context) do
    state = context[:agent].state

    # Each Spec Kit phase is a fresh `claude -p` session — phase state persists in
    # repo files, not the session. We capture the session id into agent state for
    # observability/cancellation, but never resume it into the next phase's
    # request (that would hit the adapter's resume path). Mid-pipeline session
    # resume is a v2 concern.
    request =
      PhaseRequest.build(state.feature, phase,
        cwd: worktree_path(state.worktree),
        resume_prompt: resume_prompt_for(state, phase),
        layout: state.layout
      )

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseResult.reduce(stream)
        {outcome, signals} = classify(phase, result, state)
        {amount, _source} = Cost.for_phase(phase, result)
        record_cost(state.ledger, amount)

        {:ok,
         %{
           phase: phase,
           last_result: result,
           last_outcome: outcome,
           last_signals: signals,
           session_id: result.session_id || state.session_id,
           cost_total: (state.cost_total || 0.0) + amount,
           history: [entry(phase, outcome, amount) | state.history]
         }}

      {:error, reason} ->
        {:ok,
         %{
           phase: phase,
           last_outcome: :error,
           last_signals: %{},
           last_result: nil,
           history: [%{phase: phase, outcome: :error, error: reason} | state.history]
         }}
    end
  end

  # Operator guidance is scoped to exactly the phase the run was resumed at —
  # the fixed `resume_phase` anchor, not the currently-advancing `phase`.
  defp resume_prompt_for(state, phase) when phase == state.resume_phase, do: state.resume_prompt
  defp resume_prompt_for(_state, _phase), do: nil

  # ---- gate classification ------------------------------------------------

  # Escalate if the marker is in the clarify RESPONSE **or** left unresolved in
  # the spec file. The reviewer can write `## NEEDS HUMAN` into `spec.md` while
  # its response summary reads clean — checking only the response lets a real,
  # material escalation slip past the gate, and the next phase (`plan`) then
  # refuses on the unresolved clarification but reports `:ok` (a false-green).
  defp classify(:clarify, %PhaseResult{} = r, state) do
    needs_human? =
      Regex.match?(@needs_human_marker, r.final_text || "") or
        spec_has_needs_human?(state.worktree, state.feature)

    {outcome_of(r), %{needs_human?: needs_human?}}
  end

  defp classify(:analyze, %PhaseResult{status: :ok} = r, _state) do
    case AnalyzeResult.parse(r.final_text) do
      {:ok, parsed} -> {:ok, %{critical?: parsed.critical?, high?: parsed.high?}}
      # malformed / absent analyze JSON = failure, not a silent pass
      {:error, _reason} -> {:error, %{critical?: false}}
    end
  end

  # Artifact gate: a successful transcript proves nothing — check the tree.
  defp classify(phase, %PhaseResult{status: :ok}, state)
       when phase in [:plan, :tasks, :implement] do
    case missing_artifact(state.worktree, phase) do
      nil -> {:ok, %{}}
      artifact -> {:ok, %{missing_artifact: artifact}}
    end
  end

  defp classify(:converge, %PhaseResult{status: :ok} = r, _state) do
    {:ok, %{not_ready?: Regex.match?(@converge_not_ready_marker, r.final_text || "")}}
  end

  defp classify(_phase, %PhaseResult{} = r, _state), do: {outcome_of(r), %{}}

  # ---- artifact gate ------------------------------------------------------

  # Globbed rather than pinned to `specs/<id>-<slug>/`: the failure this catches
  # is "the file exists nowhere", and globbing avoids a false failure if the
  # target's Spec Kit names the directory differently. Mirrors the clarify
  # gate's `specs/**/spec.md` scan.
  @phase_artifacts %{plan: "specs/**/plan.md", tasks: "specs/**/tasks.md"}

  # Paths that exist even when nothing was implemented — spec/plan/task docs, the
  # single-spec seed, and the orchestrator's own logs.
  @non_implementation_prefixes ~w(specs/ docs/breakdown/ .speckit_logs/ .speckit-transcripts/ .specify/)

  # No worktree (dry runs / unit tests) → nothing to check.
  defp missing_artifact(%{path: path}, phase) when is_binary(path) do
    case phase do
      :implement -> if implementation_changes?(path), do: nil, else: "implementation changes"
      _ -> glob_artifact(path, @phase_artifacts[phase])
    end
  end

  defp missing_artifact(_worktree, _phase), do: nil

  defp glob_artifact(worktree_path, pattern) do
    case worktree_path |> Path.join(pattern) |> Path.wildcard() do
      [] -> pattern
      _ -> nil
    end
  end

  # True when the worktree carries at least one change outside the spec/doc
  # scaffolding — i.e. implement actually wrote code. A git failure returns true
  # (can't tell → don't fail the feature on a broken probe).
  defp implementation_changes?(worktree_path) do
    case System.cmd("git", ["-C", worktree_path, "status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&changed_path/1)
        |> Enum.any?(&implementation_path?/1)

      _ ->
        true
    end
  end

  # Porcelain v1 line: 2 status chars + space + path (renames use "old -> new").
  defp changed_path(line) do
    line |> String.slice(3..-1//1) |> String.split(" -> ") |> List.last() |> String.trim("\"")
  end

  defp implementation_path?(""), do: false

  defp implementation_path?(path),
    do: not Enum.any?(@non_implementation_prefixes, &String.starts_with?(path, &1))

  # True when any `spec.md` under the feature's worktree still carries an
  # unresolved `## NEEDS HUMAN` heading (line-anchored, same as the response
  # check). No worktree (dry runs / tests) → false.
  defp spec_has_needs_human?(%{path: path}, _feature) when is_binary(path) do
    path
    |> Path.join("specs/**/spec.md")
    |> Path.wildcard()
    |> Enum.any?(fn file ->
      case File.read(file) do
        {:ok, content} -> Regex.match?(@needs_human_marker, content)
        _ -> false
      end
    end)
  end

  defp spec_has_needs_human?(_worktree, _feature), do: false

  # A run that did not reach a successful terminal event is an error outcome
  # (covers :error and :incomplete).
  defp outcome_of(%PhaseResult{status: :ok}), do: :ok
  defp outcome_of(%PhaseResult{}), do: :error

  # ---- helpers ------------------------------------------------------------

  defp entry(phase, outcome, amount), do: %{phase: phase, outcome: outcome, cost: amount}

  defp worktree_path(%{path: path}), do: path
  defp worktree_path(_), do: SpeckitOrchestrator.Config.repo()

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
