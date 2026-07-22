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

  describe "ad_hoc_nodes/2" do
    test "C1: live ids subset of backlog node ids -> no ad-hoc nodes" do
      backlog = %{nodes: [%{id: "001"}, %{id: "002"}]}
      live = %{"001" => %{slug: "a"}, "002" => %{slug: "b"}}

      assert PipelineDagLayout.ad_hoc_nodes(backlog, live) == %{nodes: []}
    end

    test "C2: one live id absent from backlog -> one ad-hoc orphan node" do
      backlog = %{nodes: [%{id: "001"}]}
      live = %{"001" => %{slug: "a"}, "009" => %{slug: "ad-hoc-slug"}}

      assert %{nodes: [node]} = PipelineDagLayout.ad_hoc_nodes(backlog, live)
      assert node.id == "009"
      assert node.slug == "ad-hoc-slug"
      assert node.origin == :ad_hoc
      assert node.depth == 0
      assert node.prereqs == []
    end

    test "C3: N absent ids -> N nodes at distinct positions" do
      backlog = %{nodes: [%{id: "001"}]}
      live = %{"001" => %{}, "009" => %{}, "010" => %{}, "011" => %{}}

      %{nodes: nodes} = PipelineDagLayout.ad_hoc_nodes(backlog, live)

      assert length(nodes) == 3
      assert Enum.map(nodes, & &1.id) |> Enum.sort() == ["009", "010", "011"]

      positions = Enum.map(nodes, &{&1.x, &1.y})
      assert positions == Enum.uniq(positions)
    end

    test "C4: an id present in both sets resolves to backlog-only (VR-1)" do
      backlog = %{nodes: [%{id: "001"}, %{id: "002"}]}
      live = %{"001" => %{}, "002" => %{}, "009" => %{}}

      %{nodes: nodes} = PipelineDagLayout.ad_hoc_nodes(backlog, live)

      refute Enum.any?(nodes, &(&1.id in ["001", "002"]))
      assert Enum.map(nodes, & &1.id) == ["009"]
    end

    test "C5: id proximity to a backlog id doesn't affect classification (VR-3)" do
      backlog = %{nodes: [%{id: "008"}]}
      live = %{"008" => %{}, "009" => %{}}

      %{nodes: nodes} = PipelineDagLayout.ad_hoc_nodes(backlog, live)

      assert Enum.map(nodes, & &1.id) == ["009"]
    end

    test "C6: a nil slug is tolerated without raising (VR-4)" do
      backlog = %{nodes: []}
      live = %{"009" => %{slug: nil}}

      assert %{nodes: [%{id: "009", slug: nil}]} = PipelineDagLayout.ad_hoc_nodes(backlog, live)
    end

    test "C7: pure function - deterministic on plain data, no process/Phoenix calls" do
      backlog = %{nodes: [%{id: "001"}]}
      live = %{"009" => %{slug: "x"}}

      assert PipelineDagLayout.ad_hoc_nodes(backlog, live) ==
               PipelineDagLayout.ad_hoc_nodes(backlog, live)
    end

    test "an empty live map yields no ad-hoc nodes" do
      assert PipelineDagLayout.ad_hoc_nodes(%{nodes: []}, %{}) == %{nodes: []}
    end
  end
end
