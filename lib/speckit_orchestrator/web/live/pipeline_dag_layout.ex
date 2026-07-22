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
  """

  alias SpeckitOrchestrator.Feature

  @type dag_node :: %{
          id: String.t(),
          slug: String.t(),
          depth: non_neg_integer(),
          prereqs: [String.t()]
        }
  @type edge :: %{from: String.t(), to: String.t()}
  @type t :: %{nodes: [dag_node()], edges: [edge()], layers: %{non_neg_integer() => [String.t()]}}

  @doc """
  Layered layout: nodes carrying their depth, prereq→dependent edges, and
  node ids grouped by layer.
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

    edges = for f <- features, prereq <- f.prereqs, do: %{from: prereq, to: f.id}

    layers = nodes |> Enum.group_by(& &1.depth, & &1.id)

    %{nodes: nodes, edges: edges, layers: layers}
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
