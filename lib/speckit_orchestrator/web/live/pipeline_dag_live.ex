defmodule SpeckitOrchestrator.Web.PipelineDagLive do
  @moduledoc """
  Pipeline chain view (`/dag`, name kept for route/URL stability). 019
  retired dependency prerequisites, so there is no DAG to lay out any more —
  every run is one linear chain, ascending by feature number, one feature at
  a time (`Release.order/1`, `Release.next/3`). This view renders exactly
  that: a numbered-backlog chain and a distinct Ad-hoc chain (FR-027), each
  link showing the branch it stacks on (FR-018).

  The backlog chain's source is `Backlog.load!/1` — the full backlog, not
  just the live run's subset (`contracts/routes.md`) — same source Trigger's
  backlog preview reads. The Ad-hoc chain is whatever live/last-known
  features aren't in that backlog (an ad-hoc feature has no breakdown file).
  Node status/phase/spend are merged in from `Coordinator.status/0` +
  `Ledger.snapshot/1` + `ConsoleProjection.read/0`, the same read-model
  `MissionControlLive` seeds from, and kept in step via the same PubSub
  broadcasts. An invalid backlog (`Backlog.load!/1` raises) or an empty one
  each render a coherent state, never a broken layout (SC-006).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{
    Backlog,
    Config,
    ConsoleProjection,
    ConsoleReadModel,
    Coordinator,
    Ledger,
    Release
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    repo = Config.repo()
    packages = package_slugs(Path.join([repo, Config.specs_root(), "breakdown"]))
    selected_package = default_package(packages, current_run_detail())

    {:ok,
     socket
     |> assign(
       page_title: "Pipeline Chain",
       current_path: "/dag",
       selected_feature_id: nil,
       repo: repo,
       packages: packages,
       selected_package: selected_package,
       known_backlog_ids: known_backlog_ids(repo, packages)
     )
     |> load_backlog()
     |> seed()}
  end

  # Default the drawn wave to the current in-flight run's package; otherwise
  # the first alphabetical package (U2, FR-012). `Store.current_run_key/1` is
  # already scoped to this repo's `repo_id` (018), so no cross-repo staleness
  # check is needed — unlike the pre-018 manifest file.
  defp default_package(packages, %{run: %{scope: {:breakdown, slug}}}) do
    if slug in packages, do: slug, else: List.first(packages)
  end

  defp default_package(packages, _run_detail), do: List.first(packages)

  defp load_backlog(socket) do
    try do
      # A missing/empty breakdown dir is a valid empty backlog (e.g. a project
      # run only via single-spec/ad-hoc mode never creates one) — not a parse
      # error; only an existing-but-invalid backlog (duplicate numbers,
      # unreadable file) should surface as backlog_error.
      features = load_features(socket.assigns.repo, socket.assigns.selected_package)
      assign(socket, backlog_error: nil, features: Release.order(features))
    rescue
      e -> assign(socket, backlog_error: Exception.message(e), features: [])
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
    status = coordinator_status()
    view = ConsoleReadModel.merge(status, ledger_snapshot(), ConsoleProjection.read())
    assign(socket, view: overlay_manifest(view))
  end

  # No live Coordinator (fresh boot, no resume yet) — fall back to the store's
  # current in-flight run (018) so the chain reflects the last known status
  # instead of every node defaulting to :pending, and each feature's own
  # checkpoint so its phase timeline shows what actually ran rather than
  # looking like nothing happened. `Store.current_run_key/1` is already
  # scoped to this repo, so no cross-repo staleness check is needed.
  defp overlay_manifest(view) do
    ConsoleReadModel.overlay_last_known_statuses(view, current_run_detail())
  end

  defp current_run_detail do
    case SpeckitOrchestrator.current_run_id() do
      nil ->
        nil

      run_id ->
        case SpeckitOrchestrator.run_detail(run_id) do
          {:ok, detail} -> detail
          _ -> nil
        end
    end
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
    default = %{status: :pending, elapsed_ms: nil, slug: nil, group: nil}
    merged = Map.merge(Map.get(view.per_feature, id, default), feature || %{})
    {:noreply, assign(socket, view: %{view | per_feature: Map.put(view.per_feature, id, merged)})}
  end

  def handle_info({:console, :feed, _entry}, socket), do: {:noreply, socket}

  def handle_info(
        {:console, :reconciled, %{coordinator: coordinator_status, ledger: ledger_snapshot}},
        socket
      ) do
    view = ConsoleReadModel.merge(coordinator_status, ledger_snapshot, ConsoleProjection.read())
    {:noreply, assign(socket, view: overlay_manifest(view))}
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
     |> load_backlog()
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
    pr_base = Config.pr_base()

    ad_hoc =
      assigns
      |> ad_hoc_chain()
      |> Enum.with_index(1)
      |> Enum.map(fn {feature, position} ->
        %{feature: feature, position: position, base: pr_base}
      end)

    backlog = links(assigns.features, pr_base: pr_base)
    assigns = assign(assigns, backlog_links: backlog, ad_hoc_links: ad_hoc)

    ~H"""
    <div class="view-pipeline-dag" data-view="pipeline-dag">
      <.form_refusal :if={@backlog_error} label="Backlog invalid" data-state="backlog-invalid">
        {@backlog_error}
      </.form_refusal>

      <div
        :if={!@backlog_error && @backlog_links == [] && @ad_hoc_links == []}
        class="empty-state"
        data-state="empty-backlog"
      >
        <p>No features in the backlog.</p>
      </div>

      <div
        :if={!@backlog_error && (@backlog_links != [] or @ad_hoc_links != [])}
        class="dag-canvas"
        data-state="chain"
      >
        <div class="dag-canvas-header">
          <div>
            <div class="dag-canvas-title">Pipeline Chain</div>
            <div class="dag-canvas-sub" data-state="sequential-run">
              every run releases one feature at a time, in ascending number order —
              each link shows the branch it stacks on
            </div>
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

        <div :if={@backlog_links != []} class="dag-chain" data-chain="backlog">
          <div
            :for={link <- @backlog_links}
            class="dag-node"
            data-dag-node={link.feature.id}
            data-node-origin="backlog"
            data-chain-position={link.position}
            data-chain-base={link.base}
            data-status={status_class(node_status(@view, link.feature.id))}
            phx-click="select_feature"
            phx-value-id={link.feature.id}
          >
            <div class="dag-node-head">
              <span
                class="dag-release-badge"
                data-release-order={link.position}
                title="release order — this run runs one feature at a time"
              >
                {pad_ordinal(link.position)}
              </span>
              <span class="dag-node-id">{link.feature.id}</span>
              <.status_pill status={node_status(@view, link.feature.id)} />
            </div>
            <div class="dag-node-slug">{link.feature.slug}</div>
            <div class="dag-node-base" data-chain-base-label>stacks on {link.base}</div>
            <.phase_strip
              phases={node_phases(@view, link.feature.id)}
              status={node_status(@view, link.feature.id)}
              chunk={node_chunk(@view, link.feature.id)}
              remediation={node_remediation(@view, link.feature.id)}
            />
            <div class="dag-node-spend">${format_money(node_spend(@view, link.feature.id))}</div>
          </div>
        </div>

        <div class="dag-legend">
          <div
            :for={status <- statuses()}
            class="dag-legend-item"
            data-legend-status={status}
          >
            <span class="legend-swatch" data-status={status}></span> {label(String.to_existing_atom(status))}
          </div>
          <div
            :if={@ad_hoc_links != []}
            class="dag-legend-item dag-legend-ad-hoc"
            data-legend-origin="ad-hoc"
          >
            <span class="legend-swatch legend-swatch-ad-hoc"></span> Ad-hoc (not in backlog)
          </div>
        </div>
      </div>

      <div :if={@ad_hoc_links != []} class="dag-ad-hoc-lane" data-state="ad-hoc-lane">
        <div class="dag-chain" data-chain="ad-hoc">
          <div
            :for={link <- @ad_hoc_links}
            class="dag-node"
            data-dag-node={link.feature.id}
            data-node-origin="ad-hoc"
            data-status={status_class(node_status(@view, link.feature.id))}
            phx-click="select_feature"
            phx-value-id={link.feature.id}
          >
            <div class="dag-node-head">
              <span class="dag-node-id">{link.feature.id}</span>
              <span class="dag-adhoc-badge" data-adhoc-badge>ad-hoc</span>
              <.status_pill status={node_status(@view, link.feature.id)} />
            </div>
            <div class="dag-node-slug">{link.feature.slug}</div>
            <div class="dag-node-base" data-chain-base-label>stacks on {link.base}</div>
            <.phase_strip
              phases={node_phases(@view, link.feature.id)}
              status={node_status(@view, link.feature.id)}
              remediation={node_remediation(@view, link.feature.id)}
            />
            <div class="dag-node-spend">${format_money(node_spend(@view, link.feature.id))}</div>
          </div>
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

  # A backlog chain link's base is the previous link's branch
  # (`feature/<id>-<slug>`, `Worktree`'s naming convention); an Ad-hoc link
  # always stacks on `pr_base` (FR-028) — it never joins the backlog chain.
  defp links(features, pr_base: pr_base) do
    features
    |> Enum.with_index(1)
    |> Enum.map_reduce(pr_base, fn {feature, position}, base ->
      {%{feature: feature, position: position, base: base}, branch(feature)}
    end)
    |> elem(0)
  end

  defp branch(feature), do: "feature/#{feature.id}-#{feature.slug}"

  # Every id present in the view's per-feature map that has no breakdown file
  # in ANY package — built as pseudo-`Feature` structs (id/slug only) so
  # `links/2` can treat both chains identically. Ordered by id: structurally
  # exactly 0 or 1 ad-hoc features are ever live in a given run (FR-026), so
  # this is a stable, deterministic tie-break rather than a real ordering
  # decision.
  defp ad_hoc_chain(assigns) do
    assigns.view.per_feature
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(assigns.known_backlog_ids, &1))
    |> Enum.sort()
    |> Enum.map(&%{id: &1, slug: get_in(assigns.view.per_feature, [&1, :slug])})
  end

  defp node_status(view, id), do: get_in(view.per_feature, [id, :status]) || :pending
  defp node_spend(view, id), do: get_in(view.per_feature, [id, :spend]) || 0.0
  defp node_phases(view, id), do: get_in(view.per_feature, [id, :phases]) || %{}
  defp node_chunk(view, id), do: get_in(view.per_feature, [id, :chunk])

  defp node_remediation(view, id), do: get_in(view.per_feature, [id, :remediation])

  # Every id that has a breakdown file in ANY package, not just the drawn one.
  # A feature is ad-hoc because `run_spec/2` created it with no breakdown file
  # at all — never merely because the wave picker is currently pointed
  # somewhere else. Tolerant per package: one unparseable package must not
  # blank the lane's exclusion set and turn every live feature into a false
  # ad-hoc node.
  defp known_backlog_ids(repo, []), do: package_ids(repo, nil)

  defp known_backlog_ids(repo, packages) do
    Enum.reduce(packages, MapSet.new(), fn slug, acc ->
      MapSet.union(acc, package_ids(repo, slug))
    end)
  end

  defp package_ids(repo, slug) do
    repo |> load_features(slug) |> MapSet.new(& &1.id)
  rescue
    _ -> MapSet.new()
  end
end
