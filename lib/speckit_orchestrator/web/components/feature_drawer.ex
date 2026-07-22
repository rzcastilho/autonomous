defmodule SpeckitOrchestrator.Web.FeatureDrawerComponent do
  @moduledoc """
  Slide-in feature drawer (FR-011..013): per-phase timeline, elapsed, spend,
  prerequisites for one feature. Opened from the Mission Control table row and
  the DAG node (`contracts/routes.md`) — one component, two entry points —
  dismissible without obstructing the underlying view.

  A plain function component (not a `LiveComponent`): it holds no state of its
  own, and `phx-click` on `@on_close` bubbles to whichever parent LiveView
  rendered it, same as every other shared component in `CoreComponents`. For a
  diverted feature (`:escalated`/`:halted`/`:failed`) it surfaces a link into
  Escalations (where the actual resume/full-restart forms live — T046-T050)
  and a link to the feature's current-phase transcript (FR-012, US3
  Acceptance Scenario 5, T052) — quick entry points rather than duplicating
  those forms in every LiveView that opens this drawer.
  """

  use Phoenix.Component

  import SpeckitOrchestrator.Web.CoreComponents

  alias SpeckitOrchestrator.Pipeline

  attr(:feature_id, :string, required: true)
  attr(:feature, :map, default: nil, doc: "the FeatureView slice, or nil if not (yet) known")
  attr(:on_close, :string, default: "close_drawer")

  def feature_drawer(assigns) do
    ~H"""
    <div class="feature-drawer-backdrop" phx-click={@on_close}></div>
    <aside
      class="feature-drawer"
      id="feature-drawer"
      data-feature-id={@feature_id}
      role="dialog"
      aria-label={"Feature #{@feature_id} detail"}
    >
      <div class="drawer-header">
        <div class="drawer-header-main">
          <div class="drawer-title-row">
            <span class="drawer-id">{@feature_id}</span>
            <.status_pill :if={@feature} status={@feature[:status] || :pending} />
          </div>
          <div class="drawer-slug">{(@feature && @feature[:slug]) || "—"}</div>
          <div class="drawer-branch">feature/{@feature_id}-{(@feature && @feature[:slug]) || "…"}</div>
        </div>
        <button type="button" class="drawer-close" phx-click={@on_close} aria-label="Close">
          &times;
        </button>
      </div>

      <div class="drawer-stats">
        <div class="drawer-stat">
          <div class="drawer-stat-label">ELAPSED</div>
          <div class="drawer-stat-value">{format_elapsed(@feature && @feature[:elapsed_ms])}</div>
        </div>
        <div class="drawer-stat">
          <div class="drawer-stat-label">SPEND</div>
          <div class="drawer-stat-value">${format_money(@feature && @feature[:spend])}</div>
        </div>
        <div class="drawer-stat">
          <div class="drawer-stat-label">PREREQS</div>
          <div class="drawer-stat-value drawer-prereqs">
            <span :if={prereqs(@feature) == []}>none</span>
            <span :for={p <- prereqs(@feature)} class="drawer-prereq">{p}</span>
          </div>
        </div>
      </div>

      <div class="drawer-timeline-section">
        <div class="drawer-section-label">PHASE PIPELINE</div>
        <ol class="drawer-phase-timeline">
          <li
            :for={phase <- Pipeline.phases()}
            class="timeline-cell"
            data-phase={phase}
            data-phase-state={phase_cell_state(phase_cell(@feature, phase), @feature && @feature[:status])}
          >
            <div class="timeline-marker">
              <span class="timeline-dot">{timeline_glyph(phase_cell(@feature, phase))}</span>
              <span class="timeline-line"></span>
            </div>
            <div class="timeline-body">
              <div class="timeline-head">
                <span class="timeline-phase-name">{phase}</span>
                <span class="timeline-meta">{timeline_meta(phase_cell(@feature, phase))}</span>
              </div>
              <div :if={phase_cell(@feature, phase)[:outcome]} class="timeline-note">
                {inspect(phase_cell(@feature, phase).outcome)}
              </div>
            </div>
          </li>
        </ol>
      </div>

      <div class="drawer-actions" data-drawer-actions>
        <a
          href={transcript_href(@feature_id, @feature)}
          class="btn-secondary drawer-action"
          data-action="drawer-transcript"
        >
          &#8801; Open transcripts
        </a>

        <div :if={diverted?(@feature)} class="drawer-diverted-actions">
          <a
            href={"/escalations#escalation-#{@feature_id}"}
            class="btn-primary drawer-action"
            data-action="drawer-resume"
          >
            &#9654; Resume from checkpoint
          </a>
          <a
            href={"/escalations#escalation-#{@feature_id}"}
            class="btn-secondary drawer-action"
            data-action="drawer-open-escalation"
          >
            &#9888; Open escalation · answer &amp; override
          </a>
        </div>

        <div :if={done?(@feature)} class="drawer-pr" data-action="drawer-view-pr">
          &#8991; View PR · branch pushed
        </div>
      </div>
    </aside>
    """
  end

  defp prereqs(nil), do: []
  defp prereqs(feature), do: feature[:prereqs] || []

  defp phase_cell(nil, _phase), do: nil
  defp phase_cell(feature, phase), do: get_in(feature, [:phases, phase])

  defp phase_cell_state(nil, _status), do: "pending"
  defp phase_cell_state(%{state: :completed}, _status), do: "completed"

  defp phase_cell_state(%{state: :active}, status) when status in [:escalated, :halted, :failed],
    do: to_string(status)

  defp phase_cell_state(%{state: :active}, _status), do: "active"
  defp phase_cell_state(_cell, _status), do: "pending"

  defp timeline_glyph(%{state: :completed}), do: "✓"
  defp timeline_glyph(%{state: :active}), do: "●"
  defp timeline_glyph(_cell), do: "○"

  defp timeline_meta(nil), do: ""
  defp timeline_meta(%{cost: cost}) when is_number(cost) and cost > 0, do: "$#{format_money(cost)}"
  defp timeline_meta(%{state: state}), do: to_string(state)

  defp diverted?(nil), do: false
  defp diverted?(feature), do: feature[:status] in [:escalated, :halted, :failed]

  defp done?(nil), do: false
  defp done?(feature), do: feature[:status] == :done

  defp transcript_href(feature_id, feature) do
    case feature && feature[:current_phase] do
      nil -> "/transcripts?feature=#{feature_id}"
      phase -> "/transcripts?feature=#{feature_id}&phase=#{phase}"
    end
  end
end
