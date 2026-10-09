defmodule Autonomous.Actions.RunRemediation do
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

  require Logger

  @step "remediation"

  alias Autonomous.{
    AgentRoot,
    BranchGuard,
    Config,
    Cost,
    Ledger,
    PhaseRequest,
    PhaseResult,
    PhaseSession,
    WorkspaceTrust,
    Worktree
  }

  @impl true
  def run(_params, context) do
    state = context[:agent].state

    case Config.remediation_model(state.phase, state.remediation_model) do
      {:ok, model} -> run_remediation(state, model)
      {:error, reason} -> {:ok, error_update(state, reason)}
    end
  end

  defp run_remediation(state, model) do
    collector = WorkspaceTrust.Collector.start()

    request =
      PhaseRequest.build_remediation(state.feature, model,
        stderr_collector: collector,
        cwd: worktree_path(state.worktree),
        layout: state.layout,
        prompt: state.remediation_prompt,
        deadline_ms: Config.phase_timeout()
      )

    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseSession.reduce(stream, Config.phase_timeout())
        AgentRoot.log_installs(state.feature, :remediation, result)
        result = WorkspaceTrust.settle(result, collector)

        {outcome, signals} = classify(state.worktree, result)

        {amount, _source} = Cost.for_phase(:remediation, result)
        record_cost(state.ledger, amount)

        {:ok,
         %{
           last_result: result,
           last_outcome: outcome,
           last_signals:
             signals
             |> PhaseResult.reset_background(Map.get(state, :last_signals))
             |> PhaseResult.reset_session_died(Map.get(state, :last_signals)),
           session_id: result.session_id || state.session_id,
           cost_total: (state.cost_total || 0.0) + amount,
           history: [entry(outcome, amount, result) | state.history]
         }}

      {:error, reason} ->
        WorkspaceTrust.Collector.stop(collector)

        {:ok, error_update(state, reason)}
    end
  end

  # Branch-drift gate (027, US2) — same rule as RunFeaturePhase: a drifted
  # session's outcome is always an error, regardless of what the transcript
  # itself reported.
  defp classify(worktree, result) do
    case branch_drift(worktree) do
      nil -> classify_died(result)
      drift -> {:error, %{branch_drift: drift}}
    end
  end

  # Session-death gate (034) — after drift, ahead of the background-wait gate.
  defp classify_died(%PhaseResult{error: {:session_died, _, _}} = result),
    do: {:error, %{session_died: PhaseResult.session_died(result)}}

  defp classify_died(result), do: classify_background(result)

  # Background-wait gate (032, US1): a session that ended while a command the CLI
  # moved to the background was still running is an incomplete session, never a
  # success. No suppression here — remediation has no artifact gate to vouch for it.
  defp classify_background(result) do
    case PhaseResult.stranded_background(result) do
      [_ | _] = cmds ->
        Logger.warning(
          "#{@step} ended waiting on backgrounded command(s): " <>
            "#{Enum.join(cmds, "; ")} — treating as incomplete"
        )

        {:error, %{outstanding_work?: true, backgrounded: cmds}}

      [] ->
        {outcome_of(result), %{}}
    end
  end

  defp branch_drift(%Worktree{branch: expected} = worktree) do
    case Worktree.current_branch(worktree) do
      {:ok, observed} ->
        case BranchGuard.check(expected, observed) do
          :ok -> nil
          {:drift, d} -> d
        end

      {:error, _reason} ->
        %{expected: expected, observed: {:detached, "unknown"}}
    end
  end

  defp branch_drift(_worktree), do: nil

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

  defp entry(outcome, amount, %PhaseResult{error: {:session_died, _, _} = error}),
    do: %{phase: :remediation, outcome: outcome, cost: amount, error: error}

  defp entry(outcome, amount, _result), do: %{phase: :remediation, outcome: outcome, cost: amount}

  defp worktree_path(%{path: path}), do: path
  defp worktree_path(_), do: Config.repo()

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
