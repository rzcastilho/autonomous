defmodule SpeckitOrchestrator.Web.Router do
  @moduledoc """
  The console routes (`contracts/routes.md`) behind a fixed left nav, no
  auth pipeline (FR-035). `/runs` and `/runs/:run_id` (018,
  contracts/console-runs.md) are the run-history and run-detail views added
  on top of the original six.
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
    live("/runs", RunsLive)
    live("/runs/:run_id", RunDetailLive)
    live("/transcripts", TranscriptsLive)
    live("/config", ConfigLive)
  end
end
