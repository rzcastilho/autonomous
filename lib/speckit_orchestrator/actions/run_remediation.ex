defmodule SpeckitOrchestrator.Actions.RunRemediation do
  @moduledoc """
  Run the operator-supplied pre-phase remediation step and fold the result into
  agent state. Routed by the `"remediation.run"` signal (`data: %{}`).

  Reads `feature`, `worktree`, `layout`, `ledger`, `remediation_prompt`,
  `remediation_model` from agent state (`state.phase` is the target phase —
  remediation always runs before that phase advances). Resolves the model
  (`Config.remediation_model/2`), builds the request with
  `PhaseRequest.build_remediation/3`, runs it through the harness, folds a
  `PhaseResult`, resolves+records cost, and writes `last_result` /
  `last_outcome` (`:ok` | `:error` — no gate classification) / `session_id` /
  `cost_total` / a `%{phase: :remediation, …}` `history` entry back to state.
  Mirrors `RunFeaturePhase`'s fold shape; it does **not** decide control
  flow — `FeatureRunner` owns the proceed/stop decision.
  """

  use Jido.Action,
    name: "run_remediation",
    description: "Run the pre-phase remediation step and record the result into agent state",
    schema: []

  alias SpeckitOrchestrator.{Config, Cost, Ledger, PhaseRequest, PhaseResult}

  @impl true
  def run(_params, context) do
    state = context[:agent].state

    case Config.remediation_model(state.phase, state.remediation_model) do
      {:ok, model} -> run_remediation(state, model)
      {:error, reason} -> {:ok, error_update(state, reason)}
    end
  end

  defp run_remediation(state, model) do
    request =
      PhaseRequest.build_remediation(state.feature, model,
        cwd: worktree_path(state.worktree),
        layout: state.layout,
        prompt: state.remediation_prompt
      )

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseResult.reduce(stream)
        outcome = outcome_of(result)
        {amount, _source} = Cost.for_phase(:remediation, result)
        record_cost(state.ledger, amount)

        {:ok,
         %{
           last_result: result,
           last_outcome: outcome,
           last_signals: %{},
           session_id: result.session_id || state.session_id,
           cost_total: (state.cost_total || 0.0) + amount,
           history: [entry(outcome, amount) | state.history]
         }}

      {:error, reason} ->
        {:ok, error_update(state, reason)}
    end
  end

  defp error_update(state, reason) do
    %{
      last_outcome: :error,
      last_signals: %{},
      last_result: nil,
      history: [%{phase: :remediation, outcome: :error, error: reason} | state.history]
    }
  end

  # A run that did not reach a successful terminal event is an error outcome
  # (covers :error and :incomplete) — same rule as RunFeaturePhase.
  defp outcome_of(%PhaseResult{status: :ok}), do: :ok
  defp outcome_of(%PhaseResult{}), do: :error

  defp entry(outcome, amount), do: %{phase: :remediation, outcome: outcome, cost: amount}

  defp worktree_path(%{path: path}), do: path
  defp worktree_path(_), do: Config.repo()

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
