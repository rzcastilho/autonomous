defmodule SpeckitOrchestrator.Web.Router do
  @moduledoc """
  The six console routes (`contracts/routes.md`) behind a fixed left nav, no
  auth pipeline (FR-035). Each `live` route below is an empty-shell LiveView
  in this phase — real content lands feature-by-feature in later phases (see
  `specs/008-control-plane/tasks.md` Phase 3-8).
  """

  use SpeckitOrchestrator.Web, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SpeckitOrchestrator.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SpeckitOrchestrator.Web do
    pipe_through(:browser)

    live("/", MissionControlLive)
    live("/dag", PipelineDagLive)
    live("/trigger", TriggerLive)
    live("/escalations", EscalationsLive)
    live("/transcripts", TranscriptsLive)
    live("/config", ConfigLive)
  end
end
