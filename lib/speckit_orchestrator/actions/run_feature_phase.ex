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
  * `:analyze` → `critical?` from `AnalyzeResult.parse/1`; **malformed analyze
    JSON is an error outcome**, never a silent pass.
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

  @impl true
  def run(%{phase: phase}, context) do
    state = context[:agent].state

    # Each Spec Kit phase is a fresh `claude -p` session — phase state persists in
    # repo files, not the session. We capture the session id into agent state for
    # observability/cancellation, but never resume it into the next phase's
    # request (that would hit the adapter's resume path). Mid-pipeline session
    # resume is a v2 concern.
    request = PhaseRequest.build(state.feature, phase, cwd: worktree_path(state.worktree))

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
      {:ok, parsed} -> {:ok, %{critical?: parsed.critical?}}
      # malformed / absent analyze JSON = failure, not a silent pass
      {:error, _reason} -> {:error, %{critical?: false}}
    end
  end

  defp classify(_phase, %PhaseResult{} = r, _state), do: {outcome_of(r), %{}}

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
