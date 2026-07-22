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

  test "nodes carry pixel coordinates that increase with depth and separate rows within a layer" do
    features = Backlog.load!(@fixture_dir)

    %{nodes: nodes} = PipelineDagLayout.layout(features)
    by_id = Map.new(nodes, &{&1.id, &1})

    assert by_id["001"].x < by_id["002"].x
    assert by_id["002"].x < by_id["003"].x

    layer1_ys = [by_id["002"].y, by_id["005"].y, by_id["007"].y]
    assert layer1_ys == Enum.uniq(layer1_ys)
  end

  test "edges connect each prereq to its dependent with a precomputed SVG path" do
    features = Backlog.load!(@fixture_dir)

    %{edges: edges} = PipelineDagLayout.layout(features)
    pairs = Enum.map(edges, &{&1.from, &1.to})

    assert {"001", "002"} in pairs
    assert {"002", "003"} in pairs
    assert {"002", "004"} in pairs
    assert {"001", "005"} in pairs
    assert {"002", "006"} in pairs
    assert {"001", "007"} in pairs
    assert length(edges) == 6

    assert Enum.all?(edges, &String.starts_with?(&1.d, "M"))
  end

  test "an empty feature list lays out to no nodes/edges/layers" do
    assert PipelineDagLayout.layout([]) == %{nodes: [], edges: [], layers: %{}}
  end

  test "canvas_size is zero for an empty layout and grows to fit positioned nodes" do
    assert PipelineDagLayout.canvas_size(%{nodes: []}) == %{width: 0, height: 0}

    features = Backlog.load!(@fixture_dir)
    layout = PipelineDagLayout.layout(features)
    %{width: width, height: height} = PipelineDagLayout.canvas_size(layout)

    assert width > 0
    assert height > 0
  end
end
