defmodule SpeckitOrchestrator.Web.RunsLive do
  @moduledoc """
  US2 — Run History (`/runs`, 018 contracts/console-runs.md): every prior run
  for the configured repository, most recent first, undestroyed by later runs
  (FR-021, FR-023). Calls `SpeckitOrchestrator.run_history/1` and
  `SpeckitOrchestrator.store_capacity/0` only — no query logic of its own
  (FR-030c).

  Filters (outcome, feature) are submitted as facade options, so the ordering
  and filtering both come from the facade, never a client-side sort. A
  refusing `store_capacity/0` renders a banner naming the shortfall and
  reclaimable amount (FR-031b). A damaged run row (a decode failure the store
  reported rather than dropped) renders distinctly instead of crashing the
  view.
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.ConsoleProjection

  @outcome_options [:all_done, :escalated, :halted, :failed, :mixed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Runs",
       current_path: "/runs",
       filters: %{outcome: nil, feature: nil},
       outcome_options: @outcome_options
     )
     |> refresh()}
  end

  @impl true
  def handle_info({:console, _kind, _payload}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    {:ok, runs} = SpeckitOrchestrator.run_history(facade_opts(socket.assigns.filters))
    {:ok, capacity} = SpeckitOrchestrator.store_capacity()
    assign(socket, runs: runs, capacity: capacity)
  end

  defp facade_opts(filters) do
    []
    |> maybe_put(:outcome, filters.outcome)
    |> maybe_put(:feature, filters.feature)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  @impl true
  def handle_event("filter", %{"outcome" => outcome, "feature" => feature}, socket) do
    filters = %{outcome: safe_outcome(outcome), feature: blank_to_nil(feature)}
    {:noreply, socket |> assign(filters: filters) |> refresh()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(filters: %{outcome: nil, feature: nil}) |> refresh()}
  end

  defp safe_outcome(""), do: nil

  defp safe_outcome(outcome) do
    atom = String.to_existing_atom(outcome)
    if atom in @outcome_options, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  # ---- render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-runs" data-view="runs">
      <div class="escalations-intro">
        <div class="escalations-title">Run history</div>
        <div class="escalations-sub">
          Every run recorded for this repository, most recent first — starting a
          new run never removes or alters an earlier one.
        </div>
      </div>

      <div
        :if={@capacity.status == :refusing}
        class="field-error"
        data-banner="capacity-refusing"
      >
        Store capacity refusing new runs — short {format_bytes(@capacity.shortfall_bytes)}
        ({format_bytes(@capacity.reclaimable_bytes)} reclaimable via a prune).
      </div>

      <form id="runs-filters-form" phx-change="filter" class="runs-filters" data-form="filters">
        <label class="field-label-inline">
          Outcome
          <select name="outcome" class="resume-select" data-field="outcome">
            <option value="">Any</option>
            <option :for={o <- @outcome_options} value={o} selected={o == @filters.outcome}>
              {o}
            </option>
          </select>
        </label>
        <label class="field-label-inline">
          Feature
          <input
            type="text"
            name="feature"
            value={@filters.feature || ""}
            class="resume-select"
            placeholder="feature id"
            phx-debounce="300"
            data-field="feature"
          />
        </label>
        <button
          :if={@filters.outcome || @filters.feature}
          type="button"
          phx-click="clear_filters"
          class="btn-secondary"
        >
          Clear filters
        </button>
      </form>

      <div :if={@runs == []} class="empty-state" data-state="no-runs">
        <p class="empty-state-title">No runs recorded</p>
        <p>Start one from <a href="/trigger">Trigger Run</a>.</p>
      </div>

      <table :if={@runs != []} class="backlog-table" data-table="runs">
        <thead>
          <tr>
            <th>Run</th>
            <th>State</th>
            <th>Outcome</th>
            <th>Started</th>
            <th>Duration</th>
            <th>Spend</th>
            <th>Features</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={run <- @runs} data-run-row={run.run_id} data-damaged={damaged?(run)}>
            <%= if damaged?(run) do %>
              <td>{run.run_id}</td>
              <td colspan="6" class="field-error" data-cell="damaged">
                Damaged record ({inspect(run.reason)})
              </td>
            <% else %>
              <td>
                <a href={"/runs/#{run.run_id}"} data-link="run-detail">{run.run_id}</a>
                <span :if={not run.record_complete?} class="badge badge-warn" data-marker="incomplete">
                  incomplete
                </span>
                <span :if={run.superseded_by} class="badge badge-neutral" data-marker="superseded">
                  superseded by {run.superseded_by}
                </span>
              </td>
              <td>{run.state}</td>
              <td>{run.outcome || "—"}</td>
              <td>{format_datetime(run.started_at)}</td>
              <td>{format_elapsed(run.duration_ms)}</td>
              <td>${format_money(run.spend_usd)}</td>
              <td>
                <span :for={{id, status} <- run.feature_statuses} class="run-feature-chip">
                  {id} <.status_pill status={status} />
                </span>
              </td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp damaged?(run), do: Map.get(run, :damaged, false)

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_bytes(nil), do: "0 B"
  defp format_bytes(bytes) when bytes < 1_000_000, do: "#{div(bytes, 1000)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"
end
