defmodule Autonomous.Web.ConversationPanelLive do
  @moduledoc """
  Mission Control's embedded live session (feature 040): `ConversationLive`
  mounted as a child LiveView. A child may not define `handle_params/3`, so this
  module only delegates mount, events, messages and render, forcing the
  embedded mode (follow conversations on by default, switching in place, never
  navigating the page it sits in).
  """

  use Autonomous.Web, :live_view

  alias Autonomous.Web.ConversationLive

  @impl true
  def mount(_params, session, socket),
    do: ConversationLive.mount(:not_mounted_at_router, Map.put(session, "embedded", true), socket)

  @impl true
  defdelegate handle_event(event, params, socket), to: ConversationLive

  @impl true
  defdelegate handle_info(message, socket), to: ConversationLive

  @impl true
  defdelegate render(assigns), to: ConversationLive
end
