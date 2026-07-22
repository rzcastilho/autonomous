defmodule SpeckitOrchestrator.Web.PipelineDagLayoutTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Backlog
  alias SpeckitOrchestrator.Web.PipelineDagLayout

  @fixture_dir Path.expand("../../fixtures/breakdown", __DIR__)

  test "node depth is the longest prereq chain; no-prereq features sit at layer 0" do
    features = Backlog.load!(@fixture_dir)

    %{nodes: nodes, layers: layers} = PipelineDagLayout.layout(features)

    depths = Map.new(nodes, &{&1.id, &1.depth})

    assert depths["001"] == 0
    assert depths["002"] == 1
    assert depths["005"] == 1
    assert depths["007"] == 1
    assert depths["003"] == 2
    assert depths["004"] == 2
    assert depths["006"] == 2

    assert Enum.sort(layers[0]) == ["001"]
    assert Enum.sort(layers[1]) == ["002", "005", "007"]
    assert Enum.sort(layers[2]) == ["003", "004", "006"]
  end

  test "edges connect each prereq to its dependent" do
    features = Backlog.load!(@fixture_dir)

    %{edges: edges} = PipelineDagLayout.layout(features)

    assert %{from: "001", to: "002"} in edges
    assert %{from: "002", to: "003"} in edges
    assert %{from: "002", to: "004"} in edges
    assert %{from: "001", to: "005"} in edges
    assert %{from: "002", to: "006"} in edges
    assert %{from: "001", to: "007"} in edges
    assert length(edges) == 6
  end

  test "an empty feature list lays out to no nodes/edges/layers" do
    assert PipelineDagLayout.layout([]) == %{nodes: [], edges: [], layers: %{}}
  end
end
