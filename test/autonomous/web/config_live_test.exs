defmodule Autonomous.Web.ConfigLiveTest do
  # Mutates global app env (:models, :max_concurrency, :pr_*) and the
  # app-supervised default-named Ledger's budget — must not run concurrently
  # with another test claiming those globals.
  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, Coordinator, Feature, Ledger, RepoIdentity}

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

  test "budget input renders plain decimals, never scientific notation", %{conn: conn} do
    Ledger.set_budget(2000.0)
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ ~s(value="2000.00")
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
    assert html =~ ~s(value="42.50")
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

  # ---- 037: agent root row ------------------------------------------------

  defp committed_pack_repo(contract) do
    repo = Path.join(System.tmp_dir!(), "cfg_pack_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, _} = Autonomous.TargetPack.install(repo)
    hook = Path.join(repo, ".claude/hooks/scope_guard.py")

    File.write!(
      hook,
      String.replace(File.read!(hook), "PACK_CONTRACT = 5", "PACK_CONTRACT = #{contract}")
    )

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "t@e.com"],
          ["config", "user.name", "T"],
          ["add", "-A"],
          ["commit", "-q", "-m", "pack"]
        ],
        do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

    repo
  end

  defp advertise_agent_root(repo) do
    prior =
      {Application.get_env(:autonomous, :repo), System.get_env("AUTONOMOUS_CONTAINER"),
       System.get_env("AUTONOMOUS_AGENT_ROOT")}

    Application.put_env(:autonomous, :repo, repo)
    System.put_env("AUTONOMOUS_CONTAINER", "1")
    System.put_env("AUTONOMOUS_AGENT_ROOT", "1")

    on_exit(fn ->
      {r, c, a} = prior
      restore(:repo, r)

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

  test "agent root: advertised with a current pack shows the available row", %{conn: conn} do
    advertise_agent_root(committed_pack_repo(5))
    {:ok, _view, html} = live(conn, "/config")
    assert html =~ "available — strict allows sudo apt-get/apt install"
    refute html =~ "data-agent-root-warning"
  end

  test "agent root: advertised with an old pack adds the warning", %{conn: conn} do
    advertise_agent_root(committed_pack_repo(4))
    {:ok, _view, html} = live(conn, "/config")
    assert html =~ "available — strict allows sudo apt-get/apt install"
    assert html =~ "committed pack is contract 4; re-run TargetPack.install/2 and commit"
  end

  # ---- 033 US5: dirty tracking, cent-precise budget, sticky bar -----------

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
    |> form("#config-form", %{"model_plan" => "opus", "budget_usd" => "12.34"})
    |> render_change()

    # model_plan may already be opus in config; budget alone is a guaranteed change
    assert has_element?(view, ~s(#config-form[data-dirty="true"]))
    assert render(view) =~ "unsaved"

    render_click(view, "reset", %{})
    refute has_element?(view, ~s(#config-form[data-dirty="true"]))
    refute has_element?(view, "[data-unsaved]")
  end

  test "budget is a cent-precise number input authority with no inline script", %{conn: conn} do
    {:ok, view, html} = live(conn, "/config")

    assert has_element?(
             view,
             ~s(input[type="number"][name="budget_usd"][step="0.01"].console-input)
           )

    refute html =~ "oninput"
  end

  test "a budget with more than two decimals is refused and the form stays dirty", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")
    before = Ledger.snapshot().budget

    params = submit_params(%{"budget_usd" => "12.345"})
    view |> form("#config-form", params) |> render_change()
    html = render_submit(view, "apply", params)

    assert html =~ ~s(data-error="budget_usd")
    assert has_element?(view, ~s(#config-form[data-dirty="true"]))
    assert Ledger.snapshot().budget == before
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
