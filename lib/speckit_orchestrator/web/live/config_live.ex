defmodule SpeckitOrchestrator.Web.ConfigLive do
  @moduledoc """
  US6 — Configuration (`/config`): per-phase model routing, budget, and PR
  base/remote, applying forward-only to the live run
  (`specs/008-control-plane/tasks.md` T068-T070). 019: every run is a
  stacked sequential run — there is no concurrency or PR-workflow toggle
  left to configure.

  Renders `Config.*` + `Ledger.snapshot/1`; submits through
  `LiveConfig.apply/1`. On success it broadcasts a `:reconciled` message on
  `ConsoleProjection.topic()` (the same shape the projection's own reconcile
  tick sends) so the status bar/gauge and every other mounted LiveView pick up
  the change immediately rather than waiting up to 2s (FR-030), and toasts the
  change (FR-005).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{
    Config,
    ConsoleProjection,
    Coordinator,
    Ledger,
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

  defp refresh(socket) do
    assign(socket,
      models: Config.models(),
      budget_usd: Ledger.snapshot().budget,
      pr_base: Config.pr_base(),
      pr_remote: Config.pr_remote()
    )
  end

  # ---- apply (T068 dispatch, T070 display) -----------------------------

  @impl true
  def handle_event("apply", params, socket) do
    case LiveConfig.apply(build_change(params)) do
      {:ok, change} ->
        broadcast_reconcile()

        {:noreply,
         socket
         |> assign(errors: %{})
         |> put_flash(:info, "Configuration applied: #{applied_summary(change)}")
         |> refresh()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  defp build_change(params) do
    %{
      models: model_changes(params),
      budget_usd: parse_number(params["budget_usd"]),
      pr_base: params["pr_base"] || "",
      pr_remote: params["pr_remote"] || ""
    }
  end

  defp model_changes(params) do
    Map.new(Pipeline.phases(), fn phase ->
      {phase, params["model_#{phase}"] || Config.model_for(phase)}
    end)
  end

  # Echoes the actual call and its arguments (FR-011) rather than a generic
  # "applied" message — an operator confirming a change wants to see the
  # values that took effect, not a rubber stamp.
  defp applied_summary(change) do
    "budget_usd=#{change.budget_usd} pr_base=#{change.pr_base} pr_remote=#{change.pr_remote}"
  end

  defp parse_number(nil), do: 0.0

  defp parse_number(s) do
    case Float.parse(s) do
      {n, _rest} -> n
      :error -> :invalid
    end
  end

  # Mirrors ConsoleProjection's own :reconcile tick so an applied config
  # change is reflected everywhere within the same render cycle instead of
  # waiting up to the 2s tick (FR-030, SC-005).
  defp broadcast_reconcile do
    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: coordinator_status(), ledger: Ledger.snapshot()}}
    )
  end

  defp coordinator_status do
    if Process.whereis(Coordinator), do: Coordinator.status(Coordinator)
  end

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-config" data-view="config">
      <form id="config-form" phx-submit="apply" data-form="config">
        <fieldset class="config-models form-panel">
          <legend>Per-phase model routing</legend>
          <div :for={{phase, idx} <- Enum.with_index(Pipeline.phases(), 1)} class="model-row">
            <span class="model-row-index">{pad_ordinal(idx)}</span>
            <span class="model-row-phase">{phase}</span>
            <div class="model-row-options">
              <label class={[
                "model-option",
                @models[phase] == "opus" && "model-option-active"
              ]}>
                <input
                  type="radio"
                  name={"model_#{phase}"}
                  value="opus"
                  checked={@models[phase] == "opus"}
                  class="model-option-input"
                /> opus
              </label>
              <label class={[
                "model-option",
                @models[phase] == "sonnet" && "model-option-active"
              ]}>
                <input
                  type="radio"
                  name={"model_#{phase}"}
                  value="sonnet"
                  checked={@models[phase] == "sonnet"}
                  class="model-option-input"
                /> sonnet
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
              <span class="range-row-title">Cost breaker budget</span>
              <span class="range-row-value" id="budget-range-value">
                ${format_money(@budget_usd)}
              </span>
            </div>
            <input
              type="range"
              name="budget_usd"
              min="0"
              max="500"
              step="0.5"
              value={@budget_usd}
              class="range-input"
              oninput="document.getElementById('budget-range-value').textContent = '$' + parseFloat(this.value).toFixed(2)"
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
              <input type="text" name="pr_base" value={@pr_base} />
            </label>
            <label>
              PR_REMOTE
              <input type="text" name="pr_remote" value={@pr_remote} />
            </label>
          </div>
        </fieldset>

        <button type="submit" class="btn-primary" data-action="apply-config">Apply</button>
      </form>
    </div>
    """
  end
end
