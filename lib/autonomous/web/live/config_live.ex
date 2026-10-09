defmodule Autonomous.Web.ConfigLive do
  @moduledoc """
  US6 — Configuration (`/config`): per-phase model routing and PR
  base/remote, applying forward-only to the live run
  (`specs/008-control-plane/tasks.md` T068-T070). 019: every run is a
  stacked sequential run — there is no concurrency or PR-workflow toggle
  left to configure. 031: also shows, read-only, the repository this instance
  serves and its node name (real identifiers, not editable settings).

  Renders `Config.*`; submits through
  `LiveConfig.apply/1`. On success it broadcasts a `:reconciled` message on
  `ConsoleProjection.topic()` (the same shape the projection's own reconcile
  tick sends) so the status bar and every other mounted LiveView pick up
  the change immediately rather than waiting up to 2s (FR-030), and toasts the
  change (FR-005).

  033 US5: the form tracks `edited` against `applied` (`ConfigDiff`), shows an
  unsaved count with sticky Apply/Reset, and echoes the actual
  `LiveConfig.apply/1` call on success. 039: no budget — cost is
  informational, so there is nothing to configure.
  """

  use Autonomous.Web, :live_view

  alias Autonomous.Web.{AgentRootView, ConfigDiff}

  alias Autonomous.{
    AgentRoot,
    Config,
    ConsoleProjection,
    LiveConfig,
    Pipeline
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Configuration", current_path: "/config", errors: %{})
     |> refresh()}
  end

  # Re-reads the applied configuration; the form starts (and, after a
  # successful apply or Reset, returns) clean — `edited == applied`.
  defp refresh(socket) do
    applied = applied_fields()

    socket
    |> assign(
      applied: applied,
      served_repo: Path.expand(Config.repo()),
      instance_node: Atom.to_string(node()),
      agent_root: AgentRootView.state(AgentRoot.advertised?())
    )
    |> put_edited(applied)
  end

  defp applied_fields do
    models =
      Map.new(Pipeline.phases(), fn phase -> {"model_#{phase}", Config.model_for(phase)} end)

    Map.merge(models, %{
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    })
  end

  defp put_edited(socket, edited) do
    changes = ConfigDiff.diff(socket.assigns.applied, edited)
    assign(socket, edited: edited, changes: changes, dirty: ConfigDiff.dirty?(changes))
  end

  # ---- edit / reset / apply ---------------------------------------------

  @impl true
  def handle_event("edit", params, socket) do
    {:noreply, put_edited(socket, edited_from(params, socket.assigns.edited))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(errors: %{}) |> put_edited(socket.assigns.applied)}
  end

  def handle_event("apply", params, socket) do
    edited = edited_from(params, socket.assigns.edited)
    socket = put_edited(socket, edited)
    changes = socket.assigns.changes

    case LiveConfig.apply(build_change(edited)) do
      {:ok, _change} ->
        broadcast_reconcile()
        lines = ["Configuration applied" | ConfigDiff.apply_echo(changes, active_run_id())]

        {:noreply,
         socket
         |> assign(errors: %{})
         |> put_flash(:info, Enum.join(lines, "\n"))
         |> refresh()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  defp edited_from(params, prior) do
    Map.new(prior, fn {field, old} -> {field, params[field] || old} end)
  end

  defp build_change(edited) do
    %{
      models: Map.new(Pipeline.phases(), fn phase -> {phase, edited["model_#{phase}"]} end),
      pr_base: edited["pr_base"] || "",
      pr_remote: edited["pr_remote"] || ""
    }
  end

  # Mirrors ConsoleProjection's own :reconcile tick so an applied config
  # change is reflected everywhere within the same render cycle instead of
  # waiting up to the 2s tick (FR-030, SC-005).
  defp broadcast_reconcile do
    Phoenix.PubSub.broadcast(
      Autonomous.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled,
       %{
         coordinator: coordinator_status(),
         delayed?: false
       }}
    )
  end

  defp coordinator_status, do: ConsoleProjection.coordinator_or_last_known()

  # Same notion of "a run is in flight" as Trigger Run's confirmation.
  defp active_run_id do
    live? = match?(%{finished?: false}, coordinator_status())
    if live? or Autonomous.workers() != [], do: Autonomous.current_run_id()
  end

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-config" data-view="config">
      <form
        id="config-form"
        phx-submit="apply"
        phx-change="edit"
        data-form="config"
        data-dirty={@dirty && "true"}
      >
        <fieldset class="config-models form-panel">
          <legend class="sr-only">Per-phase model routing</legend>
          <div class="config-toggle-title config-section-title">Per-phase model routing</div>
          <div :for={{phase, idx} <- Enum.with_index(Pipeline.phases(), 1)} class="model-row">
            <span class="model-row-index">{pad_ordinal(idx)}</span>
            <span class="model-row-phase">{phase}</span>
            <div class="model-row-options">
              <label
                :for={model <- ["opus", "sonnet"]}
                class={[
                  "model-option",
                  @edited["model_#{phase}"] == model && "model-option-active"
                ]}
              >
                <input
                  type="radio"
                  name={"model_#{phase}"}
                  value={model}
                  checked={@edited["model_#{phase}"] == model}
                  class="model-option-input"
                /> {model}
              </label>
            </div>
          </div>
          <.form_refusal :if={@errors[:models]} label="Models refused" data-error="models">
            {@errors[:models]}
          </.form_refusal>
        </fieldset>

        <fieldset class="config-pr form-panel">
          <legend class="sr-only">PR workflow</legend>
          <div class="config-toggle-row">
            <div>
              <div class="config-toggle-title">Stacked PR workflow</div>
              <div class="config-toggle-sub">
                Every run — one feature at a time, one PR per feature, stacked bottom-up.
              </div>
            </div>
          </div>
          <div class="config-pr-fields">
            <label>
              PR_BASE
              <input type="text" name="pr_base" value={@edited["pr_base"]} class="console-input" />
              <.form_refusal :if={@errors[:pr_base]} label="PR_BASE refused" data-error="pr_base">
                {@errors[:pr_base]}
              </.form_refusal>
            </label>
            <label>
              PR_REMOTE
              <input
                type="text"
                name="pr_remote"
                value={@edited["pr_remote"]}
                class="console-input"
              />
              <.form_refusal
                :if={@errors[:pr_remote]}
                label="PR_REMOTE refused"
                data-error="pr_remote"
              >
                {@errors[:pr_remote]}
              </.form_refusal>
            </label>
          </div>
        </fieldset>

        <fieldset class="config-pr form-panel" data-instance>
          <legend class="sr-only">Instance</legend>
          <.record_block label="instance">
            <dl class="record-block-fields">
              <dt>served repository</dt>
              <dd class="config-instance-id" data-instance-repo>{@served_repo}</dd>
              <dt>instance node</dt>
              <dd class="config-instance-id" data-instance-node>{@instance_node}</dd>
              <dt :if={@agent_root != :hidden}>agent root</dt>
              <dd :if={@agent_root != :hidden} class="config-instance-id" data-agent-root>
                {AgentRootView.summary()}
              </dd>
            </dl>
          </.record_block>
        </fieldset>

        <div class="config-actionbar" data-actionbar>
          <span :if={@dirty} class="config-unsaved" data-unsaved>{map_size(@changes)} unsaved</span>
          <button
            type="button"
            class="btn-secondary"
            phx-click="reset"
            disabled={not @dirty}
            data-action="reset-config"
          >
            Reset
          </button>
          <button type="submit" class="btn-primary" data-action="apply-config">Apply</button>
        </div>
      </form>
    </div>
    """
  end
end
