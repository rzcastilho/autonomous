defmodule Autonomous.Web.ConfigLiveTest do
  # Mutates global app env (:models, :max_concurrency, :pr_*) and the
  # app-supervised default-named Ledger's budget — must not run concurrently
  # with another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, Coordinator, Feature, Ledger}

  @endpoint Autonomous.Web.Endpoint

  setup do
    prior = %{
      models: Config.models(),
      pr_base: Application.get_env(:autonomous, :pr_base),
      pr_remote: Application.get_env(:autonomous, :pr_remote),
      budget_usd: Ledger.snapshot().budget,
      containment_profile: Application.get_env(:autonomous, :containment_profile)
    }

    on_exit(fn ->
      Application.put_env(:autonomous, :models, prior.models)
      restore(:pr_base, prior.pr_base)
      restore(:pr_remote, prior.pr_remote)
      restore(:containment_profile, prior.containment_profile)
      Ledger.set_budget(prior.budget_usd)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp restore(key, nil), do: Application.delete_env(:autonomous, key)
  defp restore(key, value), do: Application.put_env(:autonomous, key, value)

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
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    }

    Map.merge(base, overrides)
  end

  test "renders current model routing/budget/PR settings", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ ~s(data-form="config")
    assert html =~ "opus"
    assert html =~ "sonnet"
    assert html =~ Config.pr_base()
    assert html =~ Config.pr_remote()
  end

  # 031: the served repository and the instance node are shown read-only.
  test "shows the served repository and instance node as read-only identifiers", %{conn: conn} do
    {:ok, view, html} = live(conn, "/config")

    assert html =~ "data-instance-repo"
    assert html =~ Path.expand(Config.repo())
    assert html =~ "data-instance-node"
    assert html =~ Atom.to_string(node())
    refute has_element?(view, "[data-instance] input")
  end

  # 019: no concurrency slider or PR-workflow toggle renders anymore — every
  # run is already the one stacked sequential shape.
  test "renders no concurrency slider or PR-workflow toggle", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    refute html =~ ~s(name="max_concurrency")
    refute html =~ ~s(name="pr_workflow")
    refute html =~ "config-concurrency"
  end

  test "submits edits and reflects them post-apply with a toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    params = submit_params(%{"budget_usd" => "42.5"})
    html = render_submit(view, "apply", params)

    assert html =~ "Configuration applied"
    assert Ledger.snapshot().budget == 42.5
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

  test "submits PR base/remote edits and reflects them post-apply", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    params = submit_params(%{"pr_base" => "release", "pr_remote" => "upstream"})
    html = render_submit(view, "apply", params)

    assert html =~ "release"
    assert html =~ "upstream"
    assert Config.pr_base() == "release"
    assert Config.pr_remote() == "upstream"
  end

  # ---- 030: containment profile visibility (US3, contracts/operator-surfaces.md)

  test "shows the containment_profile default row only when the default is permissive", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/config")
    refute html =~ "containment_profile default:"

    Application.put_env(:autonomous, :containment_profile, :permissive)
    {:ok, _view, html} = live(conn, "/config")
    assert html =~ "containment_profile default: permissive"
  end

  test "shows the live run's containment_profile row only when that run is permissive", %{
    conn: conn
  } do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [%Feature{id: "cfg1", number: 1, slug: "cfg1", path: "cfg1.md"}],
        runner: fn _feature, _notify -> :ok end,
        owner: self(),
        context: %{containment_profile: "permissive"}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/config")

    assert html =~ "containment_profile (live run): permissive"
  end
end
