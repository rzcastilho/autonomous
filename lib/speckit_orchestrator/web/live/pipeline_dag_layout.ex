defmodule SpeckitOrchestrator.Web.PipelineDagLayout do
  @moduledoc """
  Pure layered layout for the Pipeline DAG view (FR-025,
  `specs/008-control-plane/tasks.md` T054/T057). Node depth = the length of
  the longest prereq chain; features with no prereqs sit at layer 0. Plain
  data in (`Feature.t/0` list), plain data out — no Phoenix/LiveView
  dependency (Constitution I: Pure Core, Isolated Contracts), so it is
  unit-tested directly against `test/fixtures/breakdown/`.

  Assumes a DAG already validated by `Backlog.load!/1` (no dangling prereqs,
  no cycles) — callers must validate before calling `layout/1`.

  Nodes also carry explicit pixel coordinates (`x`, `y`) so the template can
  draw SVG bezier edges without recomputing the wave/column math; `edges`
  carry a precomputed `d` path string between each prereq's right edge and
  its dependent's left edge (contracts/design-system.md §3 DAG canvas).
  """

  alias SpeckitOrchestrator.Feature

  @node_width 168
  @node_height 92
  @col_gap 60
  @row_gap 20
  @margin 20

  @type dag_node :: %{
          id: String.t(),
          slug: String.t(),
          depth: non_neg_integer(),
          prereqs: [String.t()],
          x: non_neg_integer(),
          y: non_neg_integer()
        }
  @type edge :: %{from: String.t(), to: String.t(), d: String.t()}
  @type t :: %{nodes: [dag_node()], edges: [edge()], layers: %{non_neg_integer() => [String.t()]}}

  @type ad_hoc_node :: %{
          id: String.t(),
          slug: String.t() | nil,
          origin: :ad_hoc,
          depth: 0,
          prereqs: [],
          x: non_neg_integer(),
          y: non_neg_integer()
        }
  @type ad_hoc_lane :: %{nodes: [ad_hoc_node()]}

  @doc """
  Layered layout: nodes carrying their depth + pixel position, prereq→dependent
  edges (with a precomputed SVG path), and node ids grouped by layer.
  """
  @spec layout([Feature.t()]) :: t()
  def layout(features) do
    depths = depths(features)

    nodes =
      features
      |> Enum.map(fn f ->
        %{id: f.id, slug: f.slug, depth: Map.fetch!(depths, f.id), prereqs: f.prereqs}
      end)
      |> Enum.sort_by(&{&1.depth, &1.id})
      |> position()

    edges =
      for f <- features, prereq <- f.prereqs, do: edge_path(%{from: prereq, to: f.id}, nodes)

    layers = nodes |> Enum.group_by(& &1.depth, & &1.id)

    %{nodes: nodes, edges: edges, layers: layers}
  end

  @doc """
  Pixel size of the plane the nodes are positioned within, so the template
  can size the scrollable SVG canvas. `%{width: 0, height: 0}` for an empty
  layout.
  """
  @spec canvas_size(t()) :: %{width: non_neg_integer(), height: non_neg_integer()}
  def canvas_size(%{nodes: []}), do: %{width: 0, height: 0}

  def canvas_size(%{nodes: nodes}) do
    %{
      width: (nodes |> Enum.map(& &1.x) |> Enum.max()) + @node_width + @margin,
      height: (nodes |> Enum.map(& &1.y) |> Enum.max()) + @node_height + @margin
    }
  end

  @doc """
  Pure set-difference + lane positioning for ad-hoc (non-backlog) live
  features (contracts/dag-ad-hoc-render.md §1). An id is ad-hoc iff it's a
  key of `live` absent from `backlog_layout.nodes` (VR-1); positions are
  computed in a dedicated single-row lane, independent of the backlog
  plane's depth/column math, so backlog geometry is unchanged whether or
  not ad-hoc nodes exist.
  """
  @spec ad_hoc_nodes(t(), %{String.t() => map()}) :: ad_hoc_lane()
  def ad_hoc_nodes(%{nodes: backlog_nodes}, live) when is_map(live) do
    backlog_ids = MapSet.new(backlog_nodes, & &1.id)

    nodes =
      live
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(backlog_ids, &1))
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {id, index} ->
        %{
          id: id,
          slug: get_in(live, [id, :slug]),
          origin: :ad_hoc,
          depth: 0,
          prereqs: [],
          x: @margin + index * (@node_width + @col_gap),
          y: @margin
        }
      end)

    %{nodes: nodes}
  end

  defp position(nodes) do
    nodes
    |> Enum.group_by(& &1.depth)
    |> Enum.flat_map(fn {depth, depth_nodes} ->
      depth_nodes
      |> Enum.sort_by(& &1.id)
      |> Enum.with_index()
      |> Enum.map(fn {node, row} ->
        Map.merge(node, %{
          x: @margin + depth * (@node_width + @col_gap),
          y: @margin + row * (@node_height + @row_gap)
        })
      end)
    end)
    |> Enum.sort_by(&{&1.depth, &1.id})
  end

  defp edge_path(%{from: from_id, to: to_id}, nodes) do
    from_node = Enum.find(nodes, &(&1.id == from_id))
    to_node = Enum.find(nodes, &(&1.id == to_id))

    x1 = from_node.x + @node_width
    y1 = from_node.y + div(@node_height, 2)
    x2 = to_node.x
    y2 = to_node.y + div(@node_height, 2)
    mx = div(x1 + x2, 2)

    %{from: from_id, to: to_id, d: "M#{x1},#{y1} C#{mx},#{y1} #{mx},#{y2} #{x2},#{y2}"}
  end

  defp depths(features) do
    by_id = Map.new(features, &{&1.id, &1})

    Enum.reduce(features, %{}, fn f, acc ->
      {_depth, acc} = depth_of(f.id, by_id, acc)
      acc
    end)
  end

  defp depth_of(id, by_id, acc) do
    case Map.fetch(acc, id) do
      {:ok, depth} ->
        {depth, acc}

      :error ->
        feature = Map.fetch!(by_id, id)

        {prereq_depths, acc} =
          Enum.map_reduce(feature.prereqs, acc, fn prereq_id, acc ->
            depth_of(prereq_id, by_id, acc)
          end)

        depth = if prereq_depths == [], do: 0, else: Enum.max(prereq_depths) + 1
        {depth, Map.put(acc, id, depth)}
    end
  end
end
