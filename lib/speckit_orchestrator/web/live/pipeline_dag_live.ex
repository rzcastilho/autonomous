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

      assign(socket,
        backlog_error: nil,
        dag_layout: dag_layout,
        canvas: PipelineDagLayout.canvas_size(dag_layout)
      )
    rescue
      e -> assign(socket, backlog_error: Exception.message(e), dag_layout: nil, canvas: nil)
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
        <div class="dag-canvas-header">
          <div class="dag-canvas-title">Dependency DAG</div>
          <div class="dag-canvas-sub">release in dependency-and-cap waves</div>
        </div>

        <div class="dag-scroll">
          <div class="dag-plane" style={"width: #{@canvas.width}px; height: #{@canvas.height}px;"}>
            <svg class="dag-edges-svg" width="100%" height="100%">
              <path
                :for={edge <- @dag_layout.edges}
                d={edge.d}
                class="dag-edge"
                data-dag-edge={"#{edge.from}:#{edge.to}"}
                fill="none"
              />
            </svg>

            <div
              :for={node <- @dag_layout.nodes}
              class="dag-node"
              data-dag-node={node.id}
              data-node-origin="backlog"
              style={"left: #{node.x}px; top: #{node.y}px;"}
              phx-click="select_feature"
              phx-value-id={node.id}
            >
              <div class="dag-node-head">
                <span class="dag-node-id">{node.id}</span>
                <.status_pill status={node_status(@view, node.id)} />
              </div>
              <div class="dag-node-slug">{node.slug}</div>
              <.phase_strip phases={node_phases(@view, node.id)} status={node_status(@view, node.id)} />
              <div class="dag-node-spend">${format_money(node_spend(@view, node.id))}</div>
            </div>
          </div>
        </div>

        <div class="dag-legend">
          <div
            :for={{status, {label, color}} <- palette()}
            class="dag-legend-item"
            data-legend-status={status}
          >
            <span class="legend-swatch" style={"background-color: #{color};"}></span> {label}
          </div>
          <div
            :if={ad_hoc_lane(@dag_layout, @view.per_feature).nodes != []}
            class="dag-legend-item dag-legend-ad-hoc"
            data-legend-origin="ad-hoc"
          >
            <span class="legend-swatch legend-swatch-ad-hoc"></span> Ad-hoc (not in backlog)
          </div>
        </div>
      </div>

      <% ad_hoc_lane = ad_hoc_lane(@dag_layout, @view.per_feature) %>

      <div :if={ad_hoc_lane.nodes != []} class="dag-ad-hoc-lane" data-state="ad-hoc-lane">
        <div
          :for={node <- ad_hoc_lane.nodes}
          class="dag-node"
          data-dag-node={node.id}
          data-node-origin="ad-hoc"
          phx-click="select_feature"
          phx-value-id={node.id}
        >
          <div class="dag-node-head">
            <span class="dag-node-id">{node.id}</span>
            <span class="dag-adhoc-badge" data-adhoc-badge>ad-hoc</span>
            <.status_pill status={node_status(@view, node.id)} />
          </div>
          <div class="dag-node-slug">{node.slug}</div>
          <.phase_strip phases={node_phases(@view, node.id)} status={node_status(@view, node.id)} />
          <div class="dag-node-spend">${format_money(node_spend(@view, node.id))}</div>
        </div>
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

  defp node_status(view, id), do: get_in(view.per_feature, [id, :status]) || :pending
  defp node_spend(view, id), do: get_in(view.per_feature, [id, :spend]) || 0.0
  defp node_phases(view, id), do: get_in(view.per_feature, [id, :phases]) || %{}

  defp ad_hoc_lane(nil, _per_feature), do: %{nodes: []}
  defp ad_hoc_lane(dag_layout, per_feature), do: PipelineDagLayout.ad_hoc_nodes(dag_layout, per_feature)
end
