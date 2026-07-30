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
  those forms in every LiveView that opens this drawer. For a `:done` feature
  it surfaces the PR opened for its branch, when one was — see `pr_url/1`.
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
        <.phase_strip
          :if={@feature}
          phases={@feature[:phases] || %{}}
          status={@feature[:status] || :pending}
        />
        <ol class="drawer-phase-timeline">
          <li
            :for={{phase, ordinal} <- Enum.with_index(Pipeline.phases(), 1)}
            class="timeline-cell"
            data-phase={phase}
            data-phase-state={phase_state(@feature, phase)}
          >
            <div class="timeline-marker">
              <span class="timeline-dot">{timeline_glyph(phase_state(@feature, phase), ordinal)}</span>
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
          Open transcripts
        </a>

        <div :if={diverted?(@feature)} class="drawer-diverted-actions">
          <a
            href={"/escalations#escalation-#{@feature_id}"}
            class="btn-primary drawer-action"
            data-action="drawer-resume"
          >
            resume/2 from checkpoint
          </a>
          <a
            href={"/escalations#escalation-#{@feature_id}"}
            class="btn-secondary drawer-action"
            data-action="drawer-open-escalation"
          >
            Open escalation · answer &amp; override
          </a>
        </div>

        <.record_block :if={pr_url(@feature)} label="Pull request">
          <a
            href={pr_url(@feature)}
            target="_blank"
            rel="noopener noreferrer"
            class="record-block-link"
            data-action="drawer-view-pr"
          >
            {pr_label(pr_url(@feature))}
          </a>
        </.record_block>

        <.record_block
          :if={done?(@feature) && is_nil(pr_url(@feature))}
          label="Pull request"
        >
          <span class="record-block-value" data-action="drawer-no-pr">
            No PR recorded · branch pushed
          </span>
        </.record_block>
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

  defp phase_state(feature, phase), do: phase_cell_state(phase_cell(feature, phase), feature && feature[:status])

  # §V: "✓ done, ● active, ! escalated, ✕ failed, ordinal pending" — `halted`
  # is not named in the doc's timeline enumeration; it shares `!` with
  # `escalated` as the nearer family (stopped pending an operator, not a
  # hard execution failure like `failed`).
  defp timeline_glyph("completed", _ordinal), do: "✓"
  defp timeline_glyph("active", _ordinal), do: "●"
  defp timeline_glyph("escalated", _ordinal), do: "!"
  defp timeline_glyph("halted", _ordinal), do: "!"
  defp timeline_glyph("failed", _ordinal), do: "✕"
  defp timeline_glyph(_pending, ordinal), do: pad_ordinal(ordinal)

  defp timeline_meta(nil), do: ""

  defp timeline_meta(%{cost: cost}) when is_number(cost) and cost > 0,
    do: "$#{format_money(cost)}"

  defp timeline_meta(%{state: state}), do: to_string(state)

  defp diverted?(nil), do: false
  defp diverted?(feature), do: feature[:status] in [:escalated, :halted, :failed]

  defp done?(nil), do: false
  defp done?(feature), do: feature[:status] == :done

  # The URL `gh pr create` returned, recorded on publish (019, FR-018). A
  # `:done` feature can legitimately have none — publishing is best-effort and
  # never fails the run, and a feature completed before the URL was persisted
  # has nothing to link to either — so this is a link only when there is a real
  # destination, and a plain label otherwise. It was previously always a
  # non-interactive `<div>`, which read as a button that did nothing.
  defp pr_url(nil), do: nil
  defp pr_url(feature), do: feature[:pr_url]

  # `gh pr create` returns `…/pull/<n>`; show the number rather than the whole
  # URL, falling back to the URL itself for anything that doesn't end in one.
  defp pr_label(url) do
    case Regex.run(~r{/pull/(\d+)/?$}, url) do
      [_, number] -> "##{number}"
      nil -> url
    end
  end

  # Run-scoped attempt reference (018, contracts/console-runs.md Navigation):
  # `TranscriptsLive` resolves the latest attempt for this feature/phase
  # within the current run rather than reading a `?feature=<scope>/<id>` file
  # path directly.
  defp transcript_href(feature_id, feature) do
    run_id = SpeckitOrchestrator.current_run_id()

    case {run_id, feature && feature[:current_phase]} do
      {nil, nil} -> "/transcripts?feature=#{feature_id}"
      {nil, phase} -> "/transcripts?feature=#{feature_id}&phase=#{phase}"
      {run_id, nil} -> "/transcripts?run_id=#{run_id}&feature=#{feature_id}"
      {run_id, phase} -> "/transcripts?run_id=#{run_id}&feature=#{feature_id}&phase=#{phase}"
    end
  end
end
