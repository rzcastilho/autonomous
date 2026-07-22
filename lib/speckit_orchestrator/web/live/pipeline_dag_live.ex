defmodule SpeckitOrchestrator.Web.PipelineDagLive do
  @moduledoc """
  US4 — Pipeline DAG (`/dag`): features as nodes placed by dependency depth
  (longest prereq chain, `PipelineDagLayout`), prereq→dependent edges, a
  shared-palette legend, and node-click into the same `FeatureDrawerComponent`
  as Mission Control (`specs/008-control-plane/tasks.md` T057-T058).

  The node/edge shape comes from `Backlog.load!/1` — the full backlog, not
  just the live run's subset (`contracts/routes.md`) — same source Trigger's
  backlog preview reads. Node status/phase/spend are merged in from
  `Coordinator.status/0` + `Ledger.snapshot/1` + `ConsoleProjection.read/0`,
  the same read-model `MissionControlLive` seeds from, and kept in step via
  the same PubSub broadcasts (FR-025, FR-026, FR-034). An invalid DAG
  (`Backlog.load!/1` raises) or an empty backlog each render a coherent
  state, never a broken layout (SC-006).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{
    Backlog,
    Config,
    ConsoleProjection,
    ConsoleReadModel,
    Coordinator,
    Ledger
  }

  alias SpeckitOrchestrator.Web.PipelineDagLayout

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    {:ok,
     socket
     |> assign(page_title: "Pipeline DAG", current_path: "/dag", selected_feature_id: nil)
     |> load_layout()
     |> seed()}
  end

  defp load_layout(socket) do
    source = Path.join(Config.repo(), Config.breakdown_dir())

    try do
      dag_layout = source |> Backlog.load!() |> PipelineDagLayout.layout()
      assign(socket, backlog_error: nil, dag_layout: dag_layout)
    rescue
      e -> assign(socket, backlog_error: Exception.message(e), dag_layout: nil)
    end
  end

  defp seed(socket) do
    view =
      ConsoleReadModel.merge(coordinator_status(), ledger_snapshot(), ConsoleProjection.read())

    assign(socket, view: view)
  end

  defp coordinator_status do
    if Process.whereis(Coordinator), do: Coordinator.status(Coordinator)
  end

  defp ledger_snapshot do
    if Process.whereis(Ledger), do: Ledger.snapshot(Ledger)
  end

  # ---- live updates (mirrors MissionControlLive; reconcile is authoritative
  # on drift, FR-033/SC-005) -------------------------------------------------

  @impl true
  def handle_info({:console, :feature_updated, %{id: id, feature: feature}}, socket) do
    view = socket.assigns.view
    default = %{status: :pending, elapsed_ms: nil, slug: nil, prereqs: []}
    merged = Map.merge(Map.get(view.per_feature, id, default), feature || %{})
    {:noreply, assign(socket, view: %{view | per_feature: Map.put(view.per_feature, id, merged)})}
  end

  def handle_info({:console, :feed, _entry}, socket), do: {:noreply, socket}

  def handle_info(
        {:console, :reconciled, %{coordinator: coordinator_status, ledger: ledger_snapshot}},
        socket
      ) do
    view = ConsoleReadModel.merge(coordinator_status, ledger_snapshot, ConsoleProjection.read())
    {:noreply, assign(socket, view: view)}
  end

  def handle_info({:console, :run_finished, report}, socket) do
    view = socket.assigns.view
    {:noreply, assign(socket, view: %{view | finished?: true, report: report})}
  end

  # ---- drawer ---------------------------------------------------------------

  @impl true
  def handle_event("select_feature", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_feature_id: id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_feature_id: nil)}
  end

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-pipeline-dag" data-view="pipeline-dag">
      <p :if={@backlog_error} class="field-error" data-state="dag-invalid">{@backlog_error}</p>

      <div
        :if={@dag_layout && @dag_layout.nodes == []}
        class="empty-state"
        data-state="empty-backlog"
      >
        <p>No features in the backlog.</p>
      </div>

      <div :if={@dag_layout && @dag_layout.nodes != []} class="dag-canvas" data-state="dag">
        <div class="dag-legend">
          <div
            :for={{status, {label, color}} <- palette()}
            class="dag-legend-item"
            data-legend-status={status}
          >
            <span class="legend-swatch" style={"background-color: #{color};"}></span> {label}
          </div>
        </div>

        <div class="dag-layers">
          <div :for={depth <- dag_depths(@dag_layout)} class="dag-layer" data-layer={depth}>
            <div
              :for={node <- nodes_at(@dag_layout, depth)}
              class="dag-node"
              data-dag-node={node.id}
              phx-click="select_feature"
              phx-value-id={node.id}
            >
              <span class="dag-node-id">{node.id}</span>
              <span class="dag-node-slug">{node.slug}</span>
              <.status_pill status={node_status(@view, node.id)} />
              <span class="dag-node-spend">${format_money(node_spend(@view, node.id))}</span>
            </div>
          </div>
        </div>

        <ul class="dag-edges">
          <li :for={edge <- @dag_layout.edges} data-dag-edge={"#{edge.from}:#{edge.to}"}>
            {edge.from} &rarr; {edge.to}
          </li>
        </ul>
      </div>

      <.feature_drawer
        :if={@selected_feature_id}
        feature_id={@selected_feature_id}
        feature={Map.get(@view.per_feature, @selected_feature_id)}
        on_close="close_drawer"
      />
    </div>
    """
  end

  defp dag_depths(layout), do: layout.layers |> Map.keys() |> Enum.sort()
  defp nodes_at(layout, depth), do: Enum.filter(layout.nodes, &(&1.depth == depth))

  defp node_status(view, id), do: get_in(view.per_feature, [id, :status]) || :pending
  defp node_spend(view, id), do: get_in(view.per_feature, [id, :spend]) || 0.0
end
