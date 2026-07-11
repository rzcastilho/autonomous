defmodule SpeckitOrchestrator.Actions.FinalizeFeature do
  @moduledoc """
  Write a terminal status onto the agent so `status/0` introspection reflects
  the final outcome. Routed by `"feature.finalize"` (`data: %{status, reason}`).
  """

  use Jido.Action,
    name: "finalize_feature",
    description: "Set the feature agent's terminal status",
    schema: [
      status: [type: :atom, required: true],
      reason: [type: :any, default: nil]
    ]

  @impl true
  def run(params, _context) do
    {:ok, %{status: params.status, terminal_reason: Map.get(params, :reason)}}
  end
end
