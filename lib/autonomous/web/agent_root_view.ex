defmodule Autonomous.Web.AgentRootView do
  @moduledoc """
  Pure view state for the Configuration page's "Agent root" row (feature 037,
  data-model.md). `:hidden` renders nothing, so a default instance's page stays
  byte-identical. 039: no pack-contract warning — the always-on preflight
  refuses an outdated pack instead. Never calls `inspect/1`.
  """

  @type state :: :hidden | :available

  @doc "`advertised?` is `AgentRoot.advertised?/0`."
  @spec state(boolean()) :: state()
  def state(false), do: :hidden
  def state(true), do: :available

  @doc "The row's value text."
  @spec summary() :: String.t()
  def summary, do: "available — sessions may sudo apt-get/apt install missing packages"
end
