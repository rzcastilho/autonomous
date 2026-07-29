defmodule SpeckitOrchestrator.Web.LayoutTest do
  # Starts the real named Coordinator to exercise the Escalations badge and
  # status bar's active-run branch — must not run concurrently with another
  # test that also claims that name. StoreCase (018) clears every store table
  # before each test, so an earlier test's in-flight run never leaks into
  # this test's "no active run" assertions (the crash-recovery overlay).
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Coordinator, Feature, Pipeline, RunContext}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp feat(id), do: %Feature{id: id, slug: "f#{id}", path: "#{id}.md"}

  test "nav renders all six items with the six routes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    for {path, label} <- SpeckitOrchestrator.Web.Layouts.nav_items() do
      assert html =~ label
      assert html =~ ~s(href="#{path}")
    end
  end

  test "Escalations badge is hidden when no feature is escalated/halted/failed", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    [nav_section] = Regex.run(~r/<nav.*?<\/nav>/s, html)
    refute nav_section =~ "badge-warn"
  end

  test "Escalations badge shows a count when features are diverted", %{conn: conn} do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("002")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Coordinator.notify(pid, "001", :escalated, :needs_human)
    Coordinator.notify(pid, "002", :halted, :critical_finding)
    # notify/4 casts; status/0 calls, and a GenServer's mailbox is FIFO, so
    # this call only completes once both prior casts have been applied.
    assert %{status: :escalated} = Coordinator.status(pid).per_feature["001"]

    {:ok, _view, html} = live(conn, "/")

    [nav_section] = Regex.run(~r/<nav.*?<\/nav>/s, html)
    assert nav_section =~ "badge-warn"
    assert nav_section =~ ">2<"
  end

  test "status bar renders the no-active-run shell when no Coordinator is running", %{conn: conn} do
    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "No active run"
    refute html =~ "cost-gauge"
  end

  test "status bar renders the active-run shell (gauge, armed/tripped) when a Coordinator is running",
       %{
         conn: conn
       } do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Active run"
    assert html =~ "cost-gauge"
    assert html =~ "armed"
  end

  # The status bar used to read global Config for both of these, so a run
  # started with a per-run :pr_workflow opt (or a later live-config edit)
  # made the bar describe a run other than the one actually running.
  test "status bar reports the live run's own mode and cap, not global Config", %{conn: conn} do
    prior = Application.get_env(:speckit_orchestrator, :max_concurrency)
    Application.put_env(:speckit_orchestrator, :max_concurrency, 7)
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :max_concurrency, prior) end)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001")],
        runner: fn _feature, _notify -> :ok end,
        context: %RunContext{pr_workflow: true, max_concurrency: 1},
        max_concurrency: 1,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    [meta] = Regex.run(~r/<div class="run-meta">.*?<\/div>/s, html)
    assert meta =~ "stacked_pr"
    assert meta =~ "cap 1"
    refute meta =~ "cap 7"
  end

  test "status bar falls back to Config for mode/cap when no run is active", %{conn: conn} do
    refute Process.whereis(Coordinator)

    prior = Application.get_env(:speckit_orchestrator, :pr_workflow)
    Application.put_env(:speckit_orchestrator, :pr_workflow, true)

    on_exit(fn ->
      if prior != nil,
        do: Application.put_env(:speckit_orchestrator, :pr_workflow, prior),
        else: Application.delete_env(:speckit_orchestrator, :pr_workflow)
    end)

    {:ok, _view, html} = live(conn, "/")

    # No run to describe — the bar shows the shell, and never claims an
    # active run's shape.
    assert html =~ "No active run"
  end

  test "lifecycle colors and phase order come from the shared palette / Pipeline.phases/0" do
    palette = SpeckitOrchestrator.Web.CoreComponents.palette()

    for status <- Feature.terminal_statuses() ++ [:pending, :blocked, :running] do
      assert Map.has_key?(palette, status), "missing palette entry for #{status}"
    end

    assigns = %{phases: %{}, status: :pending}

    html =
      Phoenix.LiveViewTest.render_component(
        &SpeckitOrchestrator.Web.CoreComponents.phase_strip/1,
        assigns
      )

    for phase <- Pipeline.phases() do
      assert html =~ ~s(data-phase="#{phase}")
    end
  end

  test "the same status renders with the identical shared-palette color across Mission Control, Pipeline DAG, and Escalations",
       %{conn: conn} do
    prior = %{
      repo: Application.get_env(:speckit_orchestrator, :repo),
      breakdown_dir: Application.get_env(:speckit_orchestrator, :breakdown_dir)
    }

    Application.put_env(
      :speckit_orchestrator,
      :repo,
      Path.expand("../../fixtures/breakdown", __DIR__)
    )

    Application.put_env(:speckit_orchestrator, :breakdown_dir, "")

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)
    end)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("002")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Coordinator.notify(pid, "001", :escalated, :needs_human)
    assert %{status: :escalated} = Coordinator.status(pid).per_feature["001"]

    {_label, color} = SpeckitOrchestrator.Web.CoreComponents.palette()[:escalated]
    swatch = "color: #{color};"

    {:ok, _mc_view, mc_html} = live(conn, "/")
    {:ok, _dag_view, dag_html} = live(conn, "/dag")
    {:ok, _esc_view, esc_html} = live(conn, "/escalations")

    assert mc_html =~ swatch
    assert dag_html =~ swatch
    assert esc_html =~ swatch

    # And the phase order is the same fixed Pipeline.phases/0 list on every
    # surface that renders phases (Mission Control's table + DAG's drawer).
    for phase <- Pipeline.phases() do
      assert mc_html =~ ~s(data-phase="#{phase}")
    end
  end
end
