defmodule SpeckitOrchestrator.Actions.InitFeature do
  @moduledoc """
  Seed a `FeatureAgent`'s state with its feature, worktree, and ledger, and set
  it running at the first pipeline phase. Routed by the `"feature.init"` signal.
  """

  use Jido.Action,
    name: "init_feature",
    description: "Seed feature + worktree into the agent state",
    schema: [
      feature: [type: :any, required: true],
      worktree: [type: :any, default: nil],
      ledger: [type: :any, default: nil]
    ]

  alias SpeckitOrchestrator.Pipeline

  @impl true
  def run(params, _context) do
    {:ok,
     %{
       feature: params.feature,
       worktree: params.worktree,
       ledger: Map.get(params, :ledger),
       phase: Pipeline.first(),
       status: :running,
       history: []
     }}
  end
end
