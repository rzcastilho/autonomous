defmodule SpeckitOrchestrator.Web do
  @moduledoc """
  Entrypoint for the console's web interface (Phoenix 1.7+ convention).

  `use SpeckitOrchestrator.Web, :live_view` / `:router` / `:html` inside the
  relevant modules under `lib/speckit_orchestrator/web/` instead of repeating
  the same `use`/`import` boilerplate in every LiveView and component module.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {SpeckitOrchestrator.Web.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.Component
      import SpeckitOrchestrator.Web.CoreComponents
      import SpeckitOrchestrator.Web.FeatureDrawerComponent
    end
  end

  @doc """
  When used, dispatch to the appropriate `SpeckitOrchestrator.Web` definition
  (`use SpeckitOrchestrator.Web, :live_view`, etc).
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
