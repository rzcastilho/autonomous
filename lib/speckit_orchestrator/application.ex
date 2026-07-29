defmodule SpeckitOrchestrator.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    check_no_retired_settings!()

    # Store.Boot runs before any child spec (018, FR-009): a run can never
    # begin spending money it cannot record. A failure aborts the OTP
    # application rather than letting a half-ready store be observed.
    with :ok <- SpeckitOrchestrator.Store.Boot.start!() do
      children = [
        # PubSub bus for the control-plane console (008); ConsoleProjection
        # broadcasts, LiveViews subscribe.
        {Phoenix.PubSub, name: SpeckitOrchestrator.PubSub},
        # Cost circuit-breaker, run-scoped budget from config.
        SpeckitOrchestrator.Ledger,
        # Persistence breaker (018) — mirrors Ledger; a write failure drains
        # and halts rather than killing a run mid-phase.
        SpeckitOrchestrator.Store.Health,
        # Console read-model: folds orchestrator telemetry, never persists
        # (FR-036), never mutates orchestrator state.
        SpeckitOrchestrator.ConsoleProjection,
        # Supervises the per-feature FeatureRunner tasks.
        {Task.Supervisor, name: SpeckitOrchestrator.RunnerSup},
        # Owns the per-run Coordinator so its lifetime is the run's, not the
        # caller's. `run/1` used to `start_link` it to whoever asked — fine
        # from `iex` (the shell lives as long as the operator), fatal from the
        # console, where the asking process is a transient Task that exits the
        # moment the call returns and takes the linked Coordinator with it.
        {DynamicSupervisor, name: SpeckitOrchestrator.CoordinatorSup, strategy: :one_for_one},
        # Operator console. `mix phx.server` is the only path that opens the
        # TCP listener; a plain `mix test`/`iex -S mix` boot the endpoint's
        # config process without binding a port (see config/config.exs).
        SpeckitOrchestrator.Web.Endpoint
        # Coordinator is started per-run (see SpeckitOrchestrator.run/0), not here.
      ]

      opts = [strategy: :one_for_one, name: SpeckitOrchestrator.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpeckitOrchestrator.Web.Endpoint.config_change(changed, removed)
    :ok
  end

  # 019: an app-env still naming a retired :pr_workflow/:max_concurrency key
  # (e.g. a stale config file, or an env-var mapping predating the
  # runtime.exs raise) must never boot a supervision tree that could start a
  # run against a setting the system will not honour (contracts/run-start.md
  # § 3).
  @retired_app_env [:pr_workflow, :max_concurrency]

  defp check_no_retired_settings! do
    Enum.each(@retired_app_env, fn key ->
      if Application.get_env(:speckit_orchestrator, key) != nil do
        raise """
        speckit_orchestrator config still names retired setting #{inspect(key)}. \
        019 collapsed every run into one stacked-sequential shape; this key is \
        refused, not read. Remove it from config.
        """
      end
    end)
  end
end
