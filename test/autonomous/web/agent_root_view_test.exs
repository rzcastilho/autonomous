defmodule Autonomous.Web.AgentRootViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.AgentRootView

  test "not advertised is hidden whatever the pack says" do
    assert AgentRootView.state(false, :ok) == :hidden
    assert AgentRootView.state(false, {:warning, {:pack_below_agent_root_contract, 4, 5}}) == :hidden
  end

  test "advertised with a current pack is available" do
    assert AgentRootView.state(true, :ok) == :available
  end

  test "advertised with an old or unreadable pack is outdated" do
    assert AgentRootView.state(true, {:warning, {:pack_below_agent_root_contract, 4, 5}}) ==
             {:pack_outdated, 4}

    assert AgentRootView.state(true, {:warning, {:pack_below_agent_root_contract, :unknown, 5}}) ==
             {:pack_outdated, :unknown}
  end

  test "warning text names the contract" do
    assert AgentRootView.warning({:pack_outdated, 4}) =~ "committed pack is contract 4;"
    assert AgentRootView.warning({:pack_outdated, :unknown}) =~ "contract unknown;"
    assert AgentRootView.summary() == "available — strict allows sudo apt-get/apt install"
  end
end
