defmodule Autonomous.Web.ConfigLiveTest do
  # Mutates global app env (:models, :pr_*) — must not run concurrently with
  # another test claiming those globals.
  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, Coordinator, Feature, RepoIdentity}

  @endpoint Autonomous.Web.Endpoint

  setup do
    prior = %{
      models: Config.models(),
      pr_base: Application.get_env(:autonomous, :pr_base),
      pr_remote: Application.get_env(:autonomous, :pr_remote)
    }

    on_exit(fn ->
      Application.put_env(:autonomous, :models, prior.models)
      restore(:pr_base, prior.pr_base)
      restore(:pr_remote, prior.pr_remote)
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
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    }

    Map.merge(base, overrides)
  end

  test "039: renders no budget control — cost is informational", %{conn: conn} do
    {:ok, view, html} = live(conn, "/config")

    refute has_element?(view, ~s(input[name="budget_usd"]))
    refute has_element?(view, ~s(input[name="budget_range"]))
    refute html =~ ~r/budget|breaker/i
  end

  test "renders current model routing/PR settings", %{conn: conn} do
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

  test "submits PR base/remote edits and reflects them post-apply", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    params = submit_params(%{"pr_base" => "release", "pr_remote" => "upstream"})
    html = render_submit(view, "apply", params)

    assert html =~ "release"
    assert html =~ "upstream"
    assert Config.pr_base() == "release"
    assert Config.pr_remote() == "upstream"
  end

  # ---- 039: no containment section ------------------------------------------

  test "renders no containment section, even for a legacy live run context", %{conn: conn} do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [%Feature{id: "cfg1", number: 1, slug: "cfg1", path: "cfg1.md"}],
        runner: fn _feature, _notify -> :ok end,
        owner: self(),
        context: %{containment_profile: "permissive"}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/config")

    refute has_element?(view, "[data-containment]")
    refute html =~ ~r/containment|permissive/i
  end

  # ---- 037: agent root row ------------------------------------------------

  defp advertise_agent_root do
    prior = {System.get_env("AUTONOMOUS_CONTAINER"), System.get_env("AUTONOMOUS_AGENT_ROOT")}

    System.put_env("AUTONOMOUS_CONTAINER", "1")
    System.put_env("AUTONOMOUS_AGENT_ROOT", "1")

    on_exit(fn ->
      {c, a} = prior

      for {k, v} <- [{"AUTONOMOUS_CONTAINER", c}, {"AUTONOMOUS_AGENT_ROOT", a}] do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)
  end

  test "agent root: not advertised leaves the page without the row", %{conn: conn} do
    System.delete_env("AUTONOMOUS_AGENT_ROOT")
    {:ok, _view, html} = live(conn, "/config")
    refute html =~ "agent root"
    refute html =~ "data-agent-root"
  end

  test "agent root: advertised shows the available row — no pack warning (039)", %{conn: conn} do
    advertise_agent_root()
    {:ok, _view, html} = live(conn, "/config")
    assert html =~ "data-agent-root"
    assert html =~ "available — sessions may sudo apt-get/apt install missing packages"
    refute html =~ "data-agent-root-warning"
  end

  # ---- 033 US5: dirty tracking, sticky bar ---------------------------------

  test "form is clean on mount: data-dirty absent and no unsaved count", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    refute has_element?(view, ~s(#config-form[data-dirty="true"]))
    refute has_element?(view, "[data-unsaved]")
    assert has_element?(view, ~s([data-action="apply-config"]))
    assert has_element?(view, ~s([data-action="reset-config"]))
  end

  test "editing marks the form dirty and counts unsaved fields; reset clears it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    view
    |> form("#config-form", %{"model_plan" => "opus", "pr_base" => "dirty-x-branch"})
    |> render_change()

    # model_plan may already be opus in config; pr_base alone is a guaranteed change
    assert has_element?(view, ~s(#config-form[data-dirty="true"]))
    assert render(view) =~ "unsaved"

    render_click(view, "reset", %{})
    refute has_element?(view, ~s(#config-form[data-dirty="true"]))
    refute has_element?(view, "[data-unsaved]")
  end

  test "apply toast echoes the call with changed keys only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    html = render_submit(view, "apply", submit_params(%{"pr_base" => "release-x"}))

    assert html =~ ~s|LiveConfig.apply(%{pr_base: &quot;release-x&quot;})|
    refute html =~ "forward-only"
    refute has_element?(view, ~s(#config-form[data-dirty="true"]))
  end

  test "apply toast adds the forward-only line while a run is in flight", %{conn: conn} do
    {:ok, run_id} =
      Writer.open_run(RepoIdentity.partition(Config.repo()), %{
        features: [
          %{
            feature_id: "cfg2",
            slug: "cfg2",
            path: "specs/cfg2",
            number: 1,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [%Feature{id: "cfg2", number: 1, slug: "cfg2", path: "cfg2.md"}],
        runner: fn _feature, _notify -> :ok end,
        owner: self(),
        context: %{}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/config")
    html = render_submit(view, "apply", submit_params(%{"pr_remote" => "up-x"}))

    assert html =~ "LiveConfig.apply("
    assert html =~ "applies forward-only to #{run_id}"
    assert html =~ "not saved as default"
  end

  test "served repository and instance node sit in one record block", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    assert has_element?(view, ".record-block [data-instance-repo]")

    assert has_element?(view, ".record-block [data-instance-node]")
  end

  test "legends are screen-reader only; visible section titles use config-toggle-title", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/config")

    refute has_element?(view, "legend:not(.sr-only)")
    assert has_element?(view, ".config-toggle-title")
  end
end
