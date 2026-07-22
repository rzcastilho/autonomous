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
        <fieldset class="config-models">
          <legend>Model routing</legend>
          <label :for={phase <- Pipeline.phases()}>
            {phase}
            <select name={"model_#{phase}"}>
              <option value="opus" selected={@models[phase] == "opus"}>opus</option>
              <option value="sonnet" selected={@models[phase] == "sonnet"}>sonnet</option>
            </select>
          </label>
          <p :if={@errors[:models]} class="field-error" data-error="models">{@errors[:models]}</p>
        </fieldset>

        <fieldset class="config-budget">
          <legend>Budget</legend>
          <label>
            Budget (USD)
            <input type="text" name="budget_usd" value={@budget_usd} />
          </label>
          <p :if={@errors[:budget_usd]} class="field-error" data-error="budget_usd">
            {@errors[:budget_usd]}
          </p>
        </fieldset>

        <fieldset class="config-concurrency">
          <legend>Concurrency</legend>
          <label>
            Max concurrency
            <input type="text" name="max_concurrency" value={@max_concurrency} />
          </label>
          <p :if={@errors[:max_concurrency]} class="field-error" data-error="max_concurrency">
            {@errors[:max_concurrency]}
          </p>
          <p data-effective-concurrency={@effective_concurrency}>
            effective concurrency: {@effective_concurrency}
          </p>
        </fieldset>

        <fieldset class="config-pr">
          <legend>PR workflow</legend>
          <label>
            <input type="checkbox" name="pr_workflow" value="true" checked={@pr_workflow?} />
            Stacked PR workflow
          </label>
          <label>
            PR base
            <input type="text" name="pr_base" value={@pr_base} />
          </label>
          <label>
            PR remote
            <input type="text" name="pr_remote" value={@pr_remote} />
          </label>
        </fieldset>

        <button type="submit" data-action="apply-config">Apply</button>
      </form>
    </div>
    """
  end
end
