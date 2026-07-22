defmodule SpeckitOrchestrator.Web.ConfigLiveTest do
  # Mutates global app env (:models, :max_concurrency, :pr_*) and the
  # app-supervised default-named Ledger's budget — must not run concurrently
  # with another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Config, Ledger}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior = %{
      models: Config.models(),
      max_concurrency: Application.get_env(:speckit_orchestrator, :max_concurrency),
      pr_workflow: Application.get_env(:speckit_orchestrator, :pr_workflow),
      pr_base: Application.get_env(:speckit_orchestrator, :pr_base),
      pr_remote: Application.get_env(:speckit_orchestrator, :pr_remote),
      budget_usd: Ledger.snapshot().budget
    }

    on_exit(fn ->
      Application.put_env(:speckit_orchestrator, :models, prior.models)
      restore(:max_concurrency, prior.max_concurrency)
      restore(:pr_workflow, prior.pr_workflow)
      restore(:pr_base, prior.pr_base)
      restore(:pr_remote, prior.pr_remote)
      Ledger.set_budget(prior.budget_usd)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp restore(key, nil), do: Application.delete_env(:speckit_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:speckit_orchestrator, key, value)

  defp submit_params(overrides) do
    base = %{
      "model_specify" => Config.model_for(:specify),
      "model_clarify" => Config.model_for(:clarify),
      "model_plan" => Config.model_for(:plan),
      "model_tasks" => Config.model_for(:tasks),
      "model_analyze" => Config.model_for(:analyze),
      "model_implement" => Config.model_for(:implement),
      "model_converge" => Config.model_for(:converge),
      "budget_usd" => to_string(Ledger.snapshot().budget),
      "max_concurrency" => to_string(Config.max_concurrency()),
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    }

    Map.merge(base, overrides)
  end

  test "renders current model routing/budget/concurrency/PR settings", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ ~s(data-form="config")
    assert html =~ "opus"
    assert html =~ "sonnet"
    assert html =~ to_string(Config.max_concurrency())
    assert html =~ Config.pr_base()
    assert html =~ Config.pr_remote()
  end

  test "submits edits and reflects them post-apply with a toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    params = submit_params(%{"budget_usd" => "42.5", "max_concurrency" => "7"})
    html = render_submit(view, "apply", params)

    assert html =~ "Configuration applied"
    assert Ledger.snapshot().budget == 42.5
    assert Application.get_env(:speckit_orchestrator, :max_concurrency) == 7
    assert html =~ ~s(value="42.5")
  end

  test "invalid input surfaces a field error and applies nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")
    before = Ledger.snapshot().budget

    params = submit_params(%{"budget_usd" => "-5"})
    html = render_submit(view, "apply", params)

    assert html =~ ~s(data-error="budget_usd")
    assert Ledger.snapshot().budget == before
  end

  test "enabling stacked PR workflow forces displayed effective concurrency to 1 and shows PR base/remote",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    params =
      submit_params(%{
        "pr_workflow" => "true",
        "pr_base" => "release",
        "pr_remote" => "upstream",
        "max_concurrency" => "6"
      })

    html = render_submit(view, "apply", params)

    assert html =~ ~s(data-effective-concurrency="1")
    assert html =~ "release"
    assert html =~ "upstream"
    assert Config.pr_workflow?() == true
  end
end
