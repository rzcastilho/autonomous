defmodule SpeckitOrchestrator.Web.Endpoint do
  @moduledoc """
  Bandit-backed console endpoint. Bound to loopback, no auth pipeline
  (FR-035) — see `specs/008-control-plane/contracts/routes.md`. `mix
  phx.server` is the only path that actually opens the TCP listener; a plain
  `mix test`/`iex -S mix` boot the endpoint's config process without binding a
  port (see `config/config.exs`).
  """

  use Phoenix.Endpoint, otp_app: :speckit_orchestrator

  @session_options [
    store: :cookie,
    key: "_speckit_orchestrator_console_key",
    signing_salt: "sO2z3sYq",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Console has no asset build step (no esbuild/npm) — `app.js` is a plain
  # script in priv/static/assets, and the LiveView JS client is served
  # straight out of its hex package's own priv/static (both ship a UMD
  # build there), avoiding an extra JS toolchain for six routes of chrome.
  plug(Plug.Static,
    at: "/assets",
    from: :speckit_orchestrator,
    only: ~w(app.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart],
    pass: ["*/*"]
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SpeckitOrchestrator.Web.Router)
end
