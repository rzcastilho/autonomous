defmodule SpeckitOrchestrator.Actions.RunPhase do
  @moduledoc """
  Jido action that runs one pipeline phase through the harness.

  Given a pre-built `%Jido.Harness.RunRequest{}` (see
  `SpeckitOrchestrator.PhaseRequest.build/3`), it dispatches to the `:claude`
  provider, folds the event stream into a `%PhaseResult{}`
  (`PhaseResult.reduce/1`), resolves the phase cost (`Cost.for_phase/2`), and
  records it against the `Ledger` when one is supplied.

  The pure seams — request building, stream folding, cost resolution — live in
  their own modules and are unit-tested without a CLI. This action is the thin
  side-effecting shell, exercised by the `@tag :integration` live test.
  """

  use Jido.Action,
    name: "run_phase",
    description: "Run one Spec Kit pipeline phase via the Claude harness",
    schema: [
      request: [type: :map, required: true],
      phase: [type: :atom, required: true],
      ledger: [type: :any, default: nil]
    ]

  alias SpeckitOrchestrator.{Cost, Ledger, PhaseResult}

  @impl true
  def run(%{request: request, phase: phase} = params, _context) do
    case Jido.Harness.run_request(:claude, request, []) do
      {:ok, stream} ->
        result = PhaseResult.reduce(stream)
        {amount, source} = Cost.for_phase(phase, result)
        record_cost(Map.get(params, :ledger), amount)

        {:ok, %{phase_result: result, cost_usd: amount, cost_source: source}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_cost(nil, _amount), do: :ok
  defp record_cost(ledger, amount), do: Ledger.record(ledger, nil, amount)
end
