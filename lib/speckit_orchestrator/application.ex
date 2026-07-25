defmodule SpeckitOrchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # PubSub bus for the control-plane console (008); ConsoleProjection
      # broadcasts, LiveViews subscribe.
      {Phoenix.PubSub, name: SpeckitOrchestrator.PubSub},
      # Cost circuit-breaker, run-scoped budget from config.
      SpeckitOrchestrator.Ledger,
      # Console read-model: folds orchestrator telemetry, never persists
      # (FR-036), never mutates orchestrator state.
      SpeckitOrchestrator.ConsoleProjection,
      # Supervises the per-feature FeatureRunner tasks.
      {Task.Supervisor, name: SpeckitOrchestrator.RunnerSup},
      # Operator console. `mix phx.server` is the only path that opens the
      # TCP listener; a plain `mix test`/`iex -S mix` boot the endpoint's
      # config process without binding a port (see config/config.exs).
      SpeckitOrchestrator.Web.Endpoint
      # Coordinator is started per-run (see SpeckitOrchestrator.run/0), not here.
    ]

    opts = [strategy: :one_for_one, name: SpeckitOrchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpeckitOrchestrator.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
