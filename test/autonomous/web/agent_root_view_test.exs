defmodule Autonomous.Web.AgentRootViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.AgentRootView

  test "not advertised is hidden" do
    assert AgentRootView.state(false) == :hidden
  end

  test "advertised is available (039: no pack-contract warning state)" do
    assert AgentRootView.state(true) == :available
  end

  test "summary names the capability without a profile" do
    assert AgentRootView.summary() =~ "available"
    refute AgentRootView.summary() =~ ~r/strict|permissive/
  end
end
