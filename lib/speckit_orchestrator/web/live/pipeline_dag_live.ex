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
    Checkpoint,
    Config,
    ConsoleProjection,
    ConsoleReadModel,
    Coordinator,
    Ledger,
    RepoIdentity,
    RunManifest
  }

  alias SpeckitOrchestrator.Web.PipelineDagLayout

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    repo = Config.repo()
    segment = resolve_segment(repo)
    packages = package_slugs(Path.join([repo, Config.specs_root(), "breakdown"]))
    selected_package = default_package(packages, manifest_record(), segment)

    {:ok,
     socket
     |> assign(
       page_title: "Pipeline DAG",
       current_path: "/dag",
       selected_feature_id: nil,
       repo: repo,
       segment: segment,
       packages: packages,
       selected_package: selected_package
     )
     |> load_layout()
     |> seed()}
  end

  # Default the drawn wave to the active/last run's package (manifest scope,
  # gated on a matching segment so a stale manifest from another repo can't
  # steer this view); otherwise the first alphabetical package (U2, FR-012).
  defp default_package(packages, record, segment) do
    with true <- matching_segment?(record, segment),
         %{"breakdown" => slug} <- record["scope"],
         true <- slug in packages do
      slug
    else
      _ -> List.first(packages)
    end
  end

  # Best-effort — a repo with no origin (or not yet a git repo) still renders
  # the DAG from the backlog; it simply never overlays a manifest (no segment
  # to match against, U2).
  defp resolve_segment(repo) do
    case RepoIdentity.resolve(repo) do
      {:ok, segment} -> segment
      {:error, _reason} -> nil
    end
  end

  defp load_layout(socket) do
    try do
      # A missing/empty breakdown dir is a valid empty backlog (e.g. a project
      # run only via single-spec/ad-hoc mode never creates one) — not a parse
      # error; only an existing-but-invalid backlog (dangling prereq, cycle,
      # unreadable file) should surface as backlog_error.
      features = load_features(socket.assigns.repo, socket.assigns.selected_package)
      dag_layout = PipelineDagLayout.layout(features)

      assign(socket,
        backlog_error: nil,
        dag_layout: dag_layout,
        canvas: PipelineDagLayout.canvas_size(dag_layout)
      )
    rescue
      e -> assign(socket, backlog_error: Exception.message(e), dag_layout: nil, canvas: nil)
    end
  end

  # Per-package breakdown dir (FR-012, 012): the operator-selected package under
  # specs/autonomous/breakdown/ is shown (defaulting to the active run's wave,
  # see default_package/3); zero packages falls back to the pre-012 flat
  # Config.breakdown_dir/0 (an old-layout repo, or one that hasn't adopted
  # packages yet).
  defp load_features(repo, nil), do: legacy_features(repo)

  defp load_features(repo, slug) do
    Backlog.load!(Path.join([repo, Config.specs_root(), "breakdown", slug]))
  end

  defp legacy_features(repo) do
    source = Path.join(repo, Config.breakdown_dir())
    if File.dir?(source), do: Backlog.load!(source), else: []
  end

  defp package_slugs(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp seed(socket) do
    view =
      ConsoleReadModel.merge(coordinator_status(), ledger_snapshot(), ConsoleProjection.read())

    assign(socket, view: overlay_manifest(socket, view))
  end

  # No live Coordinator (fresh boot, no resume yet) — fall back to the
  # durable run manifest (specs/009-crash-recovery) so the DAG reflects the
  # last known status instead of every node defaulting to :pending, and each
  # feature's own checkpoint so its phase timeline shows what actually ran
  # rather than looking like nothing happened. Only overlays when the
  # manifest's recorded segment matches the repo this DAG is viewing (resolves
  # analyze finding U2) — a stale manifest from a different target repo must
  # not paint this DAG.
  defp overlay_manifest(socket, view) do
    record = manifest_record()

    if matching_segment?(record, socket.assigns.segment) do
      layout = RunManifest.rebuild_layout(record, socket.assigns.repo)
      ConsoleReadModel.overlay_last_known_statuses(view, record, checkpoints_for(record, layout))
    else
      view
    end
  end

  defp matching_segment?(%{"segment" => segment}, segment) when is_binary(segment), do: true
  defp matching_segment?(_record, _segment), do: false

  defp manifest_record do
    case RunManifest.read() do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp checkpoints_for(%{"statuses" => statuses}, layout) when is_map(statuses) do
    Map.new(statuses, fn {id, _status} -> {id, Checkpoint.read(id, layout)} end)
  end

  defp checkpoints_for(_record, _layout), do: %{}

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
    {:noreply, assign(socket, view: overlay_manifest(socket, view))}
  end

  def handle_info({:console, :run_finished, report}, socket) do
    view = socket.assigns.view
    {:noreply, assign(socket, view: %{view | finished?: true, report: report})}
  end

  # ---- drawer ---------------------------------------------------------------

  @impl true
  def handle_event("select_package", %{"slug" => slug}, socket) do
    {:noreply,
     socket
     |> assign(selected_package: slug, selected_feature_id: nil)
     |> load_layout()
     |> seed()}
  end

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
          <div>
            <div class="dag-canvas-title">Dependency DAG</div>
            <div class="dag-canvas-sub">release in dependency-and-cap waves</div>
          </div>
          <form
            :if={length(@packages) > 1}
            id="wave-picker-form"
            phx-change="select_package"
            class="dag-wave-picker"
            data-form="wave-picker"
          >
            <select name="slug" data-package-select>
              <option
                :for={slug <- @packages}
                value={slug}
                selected={slug == @selected_package}
              >
                {slug}
              </option>
            </select>
          </form>
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
