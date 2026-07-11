defmodule SpeckitOrchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Cost circuit-breaker, run-scoped budget from config.
      SpeckitOrchestrator.Ledger,
      # Supervises the per-feature FeatureRunner tasks.
      {Task.Supervisor, name: SpeckitOrchestrator.RunnerSup}
      # Coordinator is started per-run (see SpeckitOrchestrator.run/0), not here.
    ]

    opts = [strategy: :one_for_one, name: SpeckitOrchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
