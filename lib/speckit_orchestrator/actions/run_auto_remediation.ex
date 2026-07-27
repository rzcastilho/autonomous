defmodule SpeckitOrchestrator.Actions.RunAutoRemediation do
  @moduledoc """
  Run one corrective step of the analyze auto-remediation loop (feature 017)
  and fold the result into agent state. Routed by the `"auto_remediation.run"`
  signal (`data: %{prompt:, model:, attempt:}`).

  The request is built by the **existing** `PhaseRequest.build_remediation/3`,
  so the step inherits `permission_mode: :accept_edits`, the
  `Read Write Edit Bash Grep Glob` tool set, and the worktree `cwd` unchanged —
  no new request builder, no new permission (FR-014). Cost is charged under the
  dedicated `:auto_remediation` tag so an attempt with no reported actual is
  never free (FR-009b, SC-008).

  Like `RunRemediation`, it decides **no** control flow: `AnalyzeRunner` owns
  the loop's proceed/stop decision via `Remediation.next/2`.

  See `specs/017-analyze-auto-remediation/contracts/analyze_loop.md` §7.
  """

  use Jido.Action,
    name: "run_auto_remediation",
    description: "Run one analyze auto-remediation attempt and record it into agent state",
    schema: [
      prompt: [type: :string, required: true],
      model: [type: :string, required: true],
      attempt: [type: :pos_integer, required: true]
    ]

  alias SpeckitOrchestrator.{Config, Cost, Ledger, PhaseRequest, PhaseResult}

  @impl true
  def run(%{prompt: prompt, model: model, attempt: attempt}, context) do
    state = context[:agent].state

    request =
      PhaseRequest.build_remediation(state.feature, model,
        cwd: worktree_path(state.worktree),
        layout: state.layout,
        prompt: prompt
      )

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseResult.reduce(stream)
        outcome = outcome_of(result)
        {amount, _source} = Cost.for_phase(:auto_remediation, result)
        record_cost(state.ledger, amount)

        {:ok,
         %{
           last_result: result,
           last_outcome: outcome,
           last_signals: %{},
           session_id: result.session_id || state.session_id,
           cost_total: (state.cost_total || 0.0) + amount,
           history: [entry(attempt, outcome, amount) | state.history]
         }}

      {:error, reason} ->
        {:ok,
         %{
           last_outcome: :error,
           last_signals: %{},
           last_result: nil,
           history: [
             %{phase: :auto_remediation, attempt: attempt, outcome: :error, error: reason}
             | state.history
           ]
         }}
    end
  end

  # A run that did not reach a successful terminal event is an error outcome
  # (covers :error and :incomplete) — same rule as RunFeaturePhase.
  defp outcome_of(%PhaseResult{status: :ok}), do: :ok
  defp outcome_of(%PhaseResult{}), do: :error

  defp entry(attempt, outcome, amount),
    do: %{phase: :auto_remediation, attempt: attempt, outcome: outcome, cost: amount}

  defp worktree_path(%{path: path}), do: path
  defp worktree_path(_), do: Config.repo()

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
