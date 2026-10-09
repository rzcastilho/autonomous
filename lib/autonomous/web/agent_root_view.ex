defmodule Autonomous.Web.AgentRootView do
  @moduledoc """
  Pure view state for the Configuration page's "Agent root" row (feature 037,
  data-model.md). `:hidden` renders nothing, so a default instance's page stays
  byte-identical. Never calls `inspect/1`.
  """

  @type state :: :hidden | :available | {:pack_outdated, integer() | :unknown}

  @doc """
  `advertised?` is `AgentRoot.advertised?/0`; `warning` is
  `TargetPack.agent_root_warning/1`.
  """
  @spec state(boolean(), :ok | {:warning, {:pack_below_agent_root_contract, term(), term()}}) ::
          state()
  def state(false, _warning), do: :hidden
  def state(true, :ok), do: :available

  def state(true, {:warning, {:pack_below_agent_root_contract, found, _min}}),
    do: {:pack_outdated, found}

  @doc "The row's value text."
  @spec summary() :: String.t()
  def summary, do: "available — strict allows sudo apt-get/apt install"

  @doc "The warning line for an outdated or unreadable committed pack."
  @spec warning({:pack_outdated, integer() | :unknown}) :: String.t()
  def warning({:pack_outdated, found}) do
    "committed pack is contract #{found_text(found)}; re-run TargetPack.install/2 and commit for the exception to apply"
  end

  defp found_text(:unknown), do: "unknown"
  defp found_text(n) when is_integer(n), do: Integer.to_string(n)
end
