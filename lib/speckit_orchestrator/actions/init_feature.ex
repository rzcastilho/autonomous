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
      ledger: [type: :any, default: nil],
      phase: [type: :atom, default: nil],
      # `type: :string, default: nil` fails Jido's schema validation on an
      # omitted key — it fills the default in and then validates it against
      # the declared type, so `nil` (a valid, intended default) trips
      # "expected string, got: nil". `{:or, [nil, :string]}` accepts both.
      resume_prompt: [type: {:or, [nil, :string]}, default: nil]
    ]

  alias SpeckitOrchestrator.Pipeline

  @impl true
  def run(params, _context) do
    phase = params.phase || Pipeline.first()

    {:ok,
     %{
       feature: params.feature,
       worktree: params.worktree,
       ledger: Map.get(params, :ledger),
       phase: phase,
       resume_phase: phase,
       resume_prompt: params.resume_prompt,
       status: :running,
       history: []
     }}
  end
end
