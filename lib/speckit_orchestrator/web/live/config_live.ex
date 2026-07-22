defmodule SpeckitOrchestrator.Web.ConfigLive do
  @moduledoc """
  US6 — Configuration (`/config`): per-phase model routing, budget, max
  concurrency, and PR-workflow mode, applying forward-only to the live run
  (`specs/008-control-plane/tasks.md` T068-T070).

  Renders `Config.*` + `Ledger.snapshot/1`; submits through
  `LiveConfig.apply/1`. On success it broadcasts a `:reconciled` message on
  `ConsoleProjection.topic()` (the same shape the projection's own reconcile
  tick sends) so the status bar/gauge and every other mounted LiveView pick up
  the change immediately rather than waiting up to 2s (FR-030), and toasts the
  change (FR-005). PR workflow forces the displayed effective concurrency to 1
  (FR-031).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{Config, ConsoleProjection, Coordinator, Ledger, LiveConfig, Pipeline}

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
      max_concurrency: Config.max_concurrency(),
      pr_workflow?: Config.pr_workflow?(),
      pr_base: Config.pr_base(),
      pr_remote: Config.pr_remote()
    )
  end

  # ---- apply (T068 dispatch, T070 display) -----------------------------

  @impl true
  def handle_event("apply", params, socket) do
    case LiveConfig.apply(build_change(params)) do
      {:ok, _change} ->
        broadcast_reconcile()

        {:noreply,
         socket
         |> assign(errors: %{})
         |> put_flash(:info, "Configuration applied")
         |> refresh()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  defp build_change(params) do
    %{
      models: model_changes(params),
      budget_usd: parse_number(params["budget_usd"]),
      max_concurrency: parse_int(params["max_concurrency"]),
      pr_workflow: params["pr_workflow"] == "true",
      pr_base: params["pr_base"] || "",
      pr_remote: params["pr_remote"] || ""
    }
  end

  defp model_changes(params) do
    Map.new(Pipeline.phases(), fn phase ->
      {phase, params["model_#{phase}"] || Config.model_for(phase)}
    end)
  end

  defp parse_number(nil), do: 0.0

  defp parse_number(s) do
    case Float.parse(s) do
      {n, _rest} -> n
      :error -> :invalid
    end
  end

  defp parse_int(nil), do: 0

  defp parse_int(s) do
    case Integer.parse(s) do
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

  defp effective_concurrency(true, _max_concurrency), do: 1
  defp effective_concurrency(false, max_concurrency), do: max_concurrency

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :effective_concurrency,
        effective_concurrency(assigns.pr_workflow?, assigns.max_concurrency)
      )

    ~H"""
    <div class="view-config" data-view="config">
      <form id="config-form" phx-submit="apply" data-form="config">
        <fieldset class="config-models form-panel">
          <legend>Per-phase model routing</legend>
          <div :for={{phase, idx} <- Enum.with_index(Pipeline.phases(), 1)} class="model-row">
            <span class="model-row-index">{idx}</span>
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
          <p :if={@errors[:models]} class="field-error" data-error="models">{@errors[:models]}</p>
        </fieldset>

        <div class="config-grid">
          <fieldset class="config-budget form-panel">
            <legend class="sr-only">Budget</legend>
            <div class="range-row-head">
              <span class="range-row-title">Cost breaker budget</span>
              <span class="range-row-value" id="budget-range-value">${@budget_usd}</span>
            </div>
            <input
              type="range"
              name="budget_usd"
              min="0"
              max="500"
              step="0.5"
              value={@budget_usd}
              class="range-input"
              oninput="document.getElementById('budget-range-value').textContent = '$' + this.value"
            />
            <p :if={@errors[:budget_usd]} class="field-error" data-error="budget_usd">
              {@errors[:budget_usd]}
            </p>
          </fieldset>

          <fieldset class="config-concurrency form-panel">
            <legend class="sr-only">Concurrency</legend>
            <div class="range-row-head">
              <span class="range-row-title">Max concurrency</span>
              <span class="range-row-value" id="concurrency-range-value">{@max_concurrency}</span>
            </div>
            <input
              type="range"
              name="max_concurrency"
              min="1"
              max="12"
              step="1"
              value={@max_concurrency}
              class="range-input"
              oninput="document.getElementById('concurrency-range-value').textContent = this.value"
            />
            <p :if={@errors[:max_concurrency]} class="field-error" data-error="max_concurrency">
              {@errors[:max_concurrency]}
            </p>
            <p class="range-row-hint" data-effective-concurrency={@effective_concurrency}>
              effective concurrency: {@effective_concurrency}
            </p>
          </fieldset>
        </div>

        <fieldset class="config-pr form-panel">
          <legend class="sr-only">PR workflow</legend>
          <div class="config-toggle-row">
            <div>
              <div class="config-toggle-title">Stacked PR workflow</div>
              <div class="config-toggle-sub">Forces cap 1 · one PR per feature · stacked bottom-up.</div>
            </div>
            <label class="pr-toggle">
              <input
                type="checkbox"
                name="pr_workflow"
                value="true"
                checked={@pr_workflow?}
                class="switch-input"
              />
              <span class="switch-track switch-track-lg"><span class="switch-knob"></span></span>
            </label>
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
