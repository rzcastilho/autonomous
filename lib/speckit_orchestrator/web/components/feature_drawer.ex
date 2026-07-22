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
    <aside
      class="feature-drawer"
      id="feature-drawer"
      data-feature-id={@feature_id}
      role="dialog"
      aria-label={"Feature #{@feature_id} detail"}
    >
      <button type="button" class="drawer-close" phx-click={@on_close} aria-label="Close">
        &times;
      </button>

      <h2 class="drawer-title">
        {@feature_id}
        <span :if={@feature && @feature[:slug]}>— {@feature.slug}</span>
      </h2>

      <.status_pill :if={@feature} status={@feature[:status] || :pending} />

      <dl class="drawer-meta">
        <dt>Elapsed</dt>
        <dd>{format_elapsed(@feature && @feature[:elapsed_ms])}</dd>
        <dt>Spend</dt>
        <dd>${format_money(@feature && @feature[:spend])}</dd>
        <dt>Prerequisites</dt>
        <dd class="drawer-prereqs">
          <span :if={prereqs(@feature) == []}>none</span>
          <span :for={p <- prereqs(@feature)} class="drawer-prereq">{p}</span>
        </dd>
      </dl>

      <ol class="drawer-phase-timeline">
        <li
          :for={phase <- Pipeline.phases()}
          class={"timeline-cell timeline-#{phase_cell_state(phase_cell(@feature, phase))}"}
          data-phase={phase}
        >
          <strong>{phase}</strong>
          <span :if={phase_cell(@feature, phase)} class="timeline-detail">
            {phase_cell(@feature, phase).state} — {inspect(phase_cell(@feature, phase).outcome)} — ${format_money(
              phase_cell(@feature, phase).cost
            )}
          </span>
        </li>
      </ol>

      <div :if={diverted?(@feature)} class="drawer-actions" data-drawer-actions>
        <a href={"/escalations##{@feature_id}"} data-action="drawer-resume">
          Resolve in Escalations
        </a>
        <a href={transcript_href(@feature_id, @feature)} data-action="drawer-transcript">
          View phase transcript
        </a>
      </div>
    </aside>
    """
  end

  defp prereqs(nil), do: []
  defp prereqs(feature), do: feature[:prereqs] || []

  defp phase_cell(nil, _phase), do: nil
  defp phase_cell(feature, phase), do: get_in(feature, [:phases, phase])

  defp phase_cell_state(nil), do: "pending"
  defp phase_cell_state(%{state: state}), do: to_string(state)

  defp diverted?(nil), do: false
  defp diverted?(feature), do: feature[:status] in [:escalated, :halted, :failed]

  defp transcript_href(feature_id, feature) do
    case feature && feature[:current_phase] do
      nil -> "/transcripts?feature=#{feature_id}"
      phase -> "/transcripts?feature=#{feature_id}&phase=#{phase}"
    end
  end
end
