defmodule Autonomous.Web.ConfigLive do
  @moduledoc """
  US6 — Configuration (`/config`): per-phase model routing, budget, and PR
  base/remote, applying forward-only to the live run
  (`specs/008-control-plane/tasks.md` T068-T070). 019: every run is a
  stacked sequential run — there is no concurrency or PR-workflow toggle
  left to configure. 031: also shows, read-only, the repository this instance
  serves and its node name (real identifiers, not editable settings).

  Renders `Config.*` + `Ledger.snapshot/1`; submits through
  `LiveConfig.apply/1`. On success it broadcasts a `:reconciled` message on
  `ConsoleProjection.topic()` (the same shape the projection's own reconcile
  tick sends) so the status bar/gauge and every other mounted LiveView pick up
  the change immediately rather than waiting up to 2s (FR-030), and toasts the
  change (FR-005).

  033 US5: the form tracks `edited` against `applied` (`ConfigDiff`), shows an
  unsaved count with sticky Apply/Reset, takes the budget as a cent-precise
  number input, and echoes the actual `LiveConfig.apply/1` call on success.
  """

  use Autonomous.Web, :live_view

  alias Autonomous.Web.{AgentRootView, ConfigDiff}

  alias Autonomous.{
    AgentRoot,
    Config,
    Containment,
    ConsoleProjection,
    Ledger,
    LiveConfig,
    Pipeline,
    TargetPack
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
      containment_default: Atom.to_string(Config.containment_profile()),
      containment_live: live_containment_profile(),
      agent_root: agent_root_state()
    )
    |> put_edited(applied)
  end

  # 037: the committed pack is only probed when agent root is advertised.
  defp agent_root_state do
    if AgentRoot.advertised?(),
      do: AgentRootView.state(true, TargetPack.agent_root_warning(Config.repo())),
      else: AgentRootView.state(false, :ok)
  end

  defp applied_fields do
    models =
      Map.new(Pipeline.phases(), fn phase -> {"model_#{phase}", Config.model_for(phase)} end)

    Map.merge(models, %{
      "budget_usd" => Ledger.snapshot().budget,
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    })
  end

  defp put_edited(socket, edited) do
    changes = ConfigDiff.diff(socket.assigns.applied, edited)
    assign(socket, edited: edited, changes: changes, dirty: ConfigDiff.dirty?(changes))
  end

  # 030, contracts/operator-surfaces.md: `nil` unless the live run's profile
  # is permissive — `Coordinator`'s snapshot only ever carries the key then.
  defp live_containment_profile do
    case coordinator_status() do
      nil -> nil
      status -> Map.get(status, :containment_profile)
    end
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
        {:noreply, assign(socket, errors: refine_errors(errors, edited))}
    end
  end

  # The range slider mirrors the number input: whichever the operator touched
  # last supplies the budget (`_target` names the changed control).
  defp edited_from(params, prior) do
    budget =
      if params["_target"] == ["budget_range"],
        do: params["budget_range"],
        else: params["budget_usd"]

    prior
    |> Map.new(fn {field, old} ->
      {field, if(field == "budget_usd", do: budget || old, else: params[field] || old)}
    end)
  end

  defp build_change(edited) do
    %{
      models: Map.new(Pipeline.phases(), fn phase -> {phase, edited["model_#{phase}"]} end),
      budget_usd: budget_amount(edited["budget_usd"]),
      pr_base: edited["pr_base"] || "",
      pr_remote: edited["pr_remote"] || ""
    }
  end

  defp budget_amount(value) do
    case ConfigDiff.parse_cents(value) do
      {:ok, cents} -> cents / 100
      :invalid -> :invalid
    end
  end

  defp refine_errors(errors, edited) do
    if Map.has_key?(errors, :budget_usd) and
         ConfigDiff.parse_cents(edited["budget_usd"]) == :invalid,
       do:
         Map.put(
           errors,
           :budget_usd,
           "budget must be a non-negative amount with at most two decimals"
         ),
       else: errors
  end

  # `Float.to_string(2000.0)` is "2.0e3"; a number input needs plain decimals.
  defp budget_input_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp budget_input_value(value), do: value

  defp slider_value(edited, applied) do
    case ConfigDiff.parse_cents(edited["budget_usd"]) do
      {:ok, cents} -> cents / 100
      :invalid -> applied["budget_usd"]
    end
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
         ledger: ConsoleProjection.ledger_or_last_known(),
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

        <div class="config-grid">
          <fieldset class="config-budget form-panel">
            <legend class="sr-only">Budget</legend>
            <div class="range-row-head">
              <label for="budget-input" class="config-toggle-title">Cost breaker budget</label>
              <span class="range-row-value" id="budget-range-value">
                ${format_money(slider_value(@edited, @applied))}
              </span>
            </div>
            <input
              type="number"
              id="budget-input"
              name="budget_usd"
              min="0"
              step="0.01"
              value={budget_input_value(@edited["budget_usd"])}
              class="console-input"
              phx-debounce="300"
            />
            <input
              type="range"
              name="budget_range"
              min="0"
              max="500"
              step="0.5"
              value={budget_input_value(slider_value(@edited, @applied))}
              class="range-input"
              aria-label="Cost breaker budget slider"
            />
            <.form_refusal :if={@errors[:budget_usd]} label="Budget refused" data-error="budget_usd">
              {@errors[:budget_usd]}
            </.form_refusal>
          </fieldset>
        </div>

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

        <fieldset
          :if={Containment.permissive?(@containment_default) or Containment.permissive?(@containment_live)}
          class="config-pr form-panel"
          data-containment
        >
          <legend class="sr-only">Containment</legend>
          <div :if={Containment.permissive?(@containment_default)} class="config-toggle-row">
            <div class="config-toggle-title">
              containment_profile default: {@containment_default}
            </div>
          </div>
          <div :if={Containment.permissive?(@containment_live)} class="config-toggle-row">
            <div class="config-toggle-title">
              containment_profile (live run): {@containment_live}
            </div>
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
                <span :if={match?({:pack_outdated, _}, @agent_root)} data-agent-root-warning>
                  {AgentRootView.warning(@agent_root)}
                </span>
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
