defmodule SpeckitOrchestrator.Web.MissionControlLive do
  @moduledoc """
  US1 — Mission Control (`/`), the MVP slice
  (`specs/008-control-plane/tasks.md` T023-T030): status-count strip, backlog
  table (id, slug, status, seven-phase progress, elapsed, spend), cost gauge
  (rendered by the shared status bar — `SpeckitOrchestrator.Web.Layouts`), and
  a bounded live telemetry feed, all updating without reload. Clicking a row
  opens the feature drawer.

  Seeds from `ConsoleReadModel.merge/3` on mount, then updates from
  `ConsoleProjection`'s PubSub broadcasts (`{:console, :feature_updated | :feed
  | :reconciled | :run_finished, ...}`) — no message carries authority on its
  own; `:reconciled` supersedes drift (FR-033/SC-005).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{ConsoleProjection, ConsoleReadModel, Coordinator, Ledger}

  @status_order [:pending, :blocked, :running, :escalated, :halted, :failed, :done]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    {:ok,
     socket
     |> assign(page_title: "Mission Control", current_path: "/", selected_feature_id: nil)
     |> seed()}
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

  # ---- live updates (FR-010, FR-033/SC-005) --------------------------------

  @impl true
  def handle_info({:console, :feature_updated, %{id: id, feature: feature}}, socket) do
    view = socket.assigns.view
    default = %{status: :pending, elapsed_ms: nil, slug: nil, prereqs: []}
    merged = Map.merge(Map.get(view.per_feature, id, default), feature || %{})
    {:noreply, assign(socket, view: %{view | per_feature: Map.put(view.per_feature, id, merged)})}
  end

  def handle_info({:console, :feed, entry}, socket) do
    view = socket.assigns.view
    {:noreply, assign(socket, view: %{view | feed: Enum.take([entry | view.feed], 200)})}
  end

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
    assigns = assign(assigns, :status_counts, status_counts(assigns.view))

    ~H"""
    <div class="view-mission-control" data-view="mission-control">
      <div :if={not @view.active?} class="empty-state" data-state="no-active-run">
        <p>No active run.</p>
        <p>Start one from <a href="/trigger">Trigger Run</a>.</p>
      </div>

      <div :if={@view.active? and @view.finished?} class="run-finished" data-state="finished">
        <h2>Run complete</h2>
        <dl class="run-report">
          <dt>Done</dt>
          <dd>{length(@view.report[:done] || [])}</dd>
          <dt>Escalated</dt>
          <dd>{length(@view.report[:escalated] || [])}</dd>
          <dt>Halted</dt>
          <dd>{length(@view.report[:halted] || [])}</dd>
          <dt>Failed</dt>
          <dd>{length(@view.report[:failed] || [])}</dd>
          <dt>Blocked</dt>
          <dd>{length(@view.report[:blocked] || [])}</dd>
          <dt>Spend</dt>
          <dd>${format_money(@view.report[:spend])}</dd>
        </dl>
      </div>

      <div :if={@view.active? and not @view.finished?} class="run-live" data-state="live">
        <div class="mission-grid">
          <div class="mission-main">
            <div class="status-count-strip">
              <div
                :for={{status, count} <- @status_counts}
                class="status-count-cell"
                data-status={status}
              >
                <.status_pill status={status} /> <span class="count">{count}</span>
              </div>
            </div>

            <table class="backlog-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Slug</th>
                  <th>Status</th>
                  <th>Progress</th>
                  <th>Elapsed</th>
                  <th>Spend</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{id, f} <- Enum.sort_by(@view.per_feature, fn {id, _} -> id end)}
                  phx-click="select_feature"
                  phx-value-id={id}
                  data-feature-row={id}
                >
                  <td>{id}</td>
                  <td>{f.slug}</td>
                  <td><.status_pill status={f.status} /></td>
                  <td><.phase_strip phases={f.phases} status={f.status} /></td>
                  <td>{format_elapsed(f.elapsed_ms)}</td>
                  <td>${format_money(f.spend)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="mission-feed">
            <div class="mission-feed-header">Telemetry</div>
            <ul class="telemetry-feed">
              <li
                :for={entry <- @view.feed}
                class={"feed-entry feed-#{entry.severity}"}
                data-feature-id={entry.feature_id}
              >
                <span class="feed-time">{Calendar.strftime(entry.at, "%H:%M:%S")}</span>
                <span class="feed-text">{entry.text}</span>
              </li>
            </ul>
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

  defp status_counts(view) do
    frequencies = view.per_feature |> Map.values() |> Enum.frequencies_by(& &1.status)
    Enum.map(@status_order, &{&1, Map.get(frequencies, &1, 0)})
  end
end
