defmodule Autonomous.Web.ContainerEngineViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.ContainerEngineView

  test "state/1: not requested is hidden, requested starts checking" do
    assert ContainerEngineView.state(false) == :hidden
    assert ContainerEngineView.state(true) == :checking
  end

  test "from_probe/1 maps the probe result" do
    assert ContainerEngineView.from_probe({:ok, "29.9.2"}) == {:available, "29.9.2"}
    assert ContainerEngineView.from_probe({:error, "no daemon"}) == {:unreachable, "no daemon"}
  end

  test "crashed/0 names the reload remedy" do
    assert {:unreachable, "the engine probe crashed — reload to retry"} =
             ContainerEngineView.crashed()
  end

  test "summary/1 renders each state" do
    assert ContainerEngineView.summary(:checking) == "checking…"
    assert ContainerEngineView.summary({:available, "29.9.2"}) == "available — engine 29.9.2"
    assert ContainerEngineView.summary({:unreachable, "boom"}) == "unreachable — boom"
    assert ContainerEngineView.summary(:hidden) == ""
  end

  test "summary text is plain (no inspect/1 output)" do
    for state <- [:checking, {:available, "1"}, {:unreachable, "x"}] do
      refute ContainerEngineView.summary(state) =~ ~r/[{}\[\]]|%\{|:ok|:error/
    end
  end
end
