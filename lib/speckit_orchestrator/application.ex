defmodule SpeckitOrchestrator.Application do
  @moduledoc false

  use Application

  # Boot (FR-029..FR-031) runs a real Preflight and a potential auto-start —
  # only meaningful for a booted release (:prod), where Container.Env's
  # required vars (SPECKIT_REPO, ...) are guaranteed by the launcher. Baked in
  # at compile time (Mix is a build-time-only tool, unavailable in a release
  # at runtime) so :dev/:test boot the same tree minus Boot — otherwise every
  # `mix test` would crash-loop the supervisor the moment Boot's
  # `Container.Env.load!/0` raised on a missing SPECKIT_REPO (Constitution II).
  @boot? Mix.env() == :prod

  @impl true
  def start(_type, _args) do
    # Phase/terminal-state events reach stdout unconditionally (FR-028), so
    # `docker logs -f` carries them with no interactive session required.
    SpeckitOrchestrator.Telemetry.attach_default_logger()

    children =
      [
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
      ] ++ boot_children()

    opts = [strategy: :one_for_one, name: SpeckitOrchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  if @boot? do
    # Idle by default; preflights then optionally auto-starts (FR-029/030/031).
    # Last in the list — it depends on nothing else here, and its own work is
    # deferred to `handle_continue/2` regardless of ordering. `:coordinator_name`/
    # `:ledger_name` opt Boot into the FR-027 shutdown flush (Boot's terminate/2)
    # for the real, well-known-named processes only — see `Boot`'s moduledoc.
    defp boot_children,
      do: [
        {SpeckitOrchestrator.Boot,
         coordinator_name: SpeckitOrchestrator.Coordinator, ledger_name: SpeckitOrchestrator.Ledger}
      ]
  else
    defp boot_children, do: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpeckitOrchestrator.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
