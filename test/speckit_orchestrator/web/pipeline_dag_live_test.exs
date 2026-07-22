defmodule SpeckitOrchestrator.Web.PipelineDagLiveTest do
  # Overrides global Config app env (repo/breakdown_dir) and may start the
  # real named Coordinator — must not run concurrently with another test
  # claiming that name or mutating Config.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Coordinator, Feature}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)
  @cyclic_dir Path.expand("../../fixtures/breakdown_cyclic", __DIR__)

  setup do
    prior = %{
      repo: Application.get_env(:speckit_orchestrator, :repo),
      breakdown_dir: Application.get_env(:speckit_orchestrator, :breakdown_dir)
    }

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)

      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_backlog_at(dir) do
    Application.put_env(:speckit_orchestrator, :repo, dir)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "")
  end

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "slug-#{id}", path: "#{id}.md", prereqs: prereqs}

  test "renders a node per feature with id/slug/status/spend, edges from prereqs to dependents, and the shared-palette legend",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("002", ["001"])],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-view="pipeline-dag")

    for id <- ~w(001 002 003 004 005 006 007) do
      assert html =~ ~s(data-dag-node="#{id}")
    end

    assert html =~ "core-ledger"
    assert html =~ ~s(data-dag-edge="001:002")
    assert html =~ ~s(data-dag-edge="002:003")

    for status <- ~w(pending blocked running escalated halted failed done) do
      assert html =~ ~s(data-legend-status="#{status}")
    end
  end

  test "clicking a node opens the same FeatureDrawerComponent as Mission Control", %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/dag")
    refute html =~ "feature-drawer"

    html = render_click(view, "select_feature", %{"id" => "001"})

    assert html =~ ~s(id="feature-drawer")
    assert html =~ ~s(data-feature-id="001")
  end

  test "an invalid DAG (cycle) renders the dag-invalid state instead of a broken layout", %{
    conn: conn
  } do
    point_backlog_at(@cyclic_dir)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-state="dag-invalid")
    assert html =~ "cycle"
    refute html =~ ~s(data-state="dag")
  end
end
