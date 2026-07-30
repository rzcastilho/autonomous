defmodule SpeckitOrchestrator.Web.LayoutTest do
  # Starts the real named Coordinator to exercise the Escalations badge and
  # status bar's active-run branch — must not run concurrently with another
  # test that also claims that name. StoreCase (018) clears every store table
  # before each test, so an earlier test's in-flight run never leaks into
  # this test's "no active run" assertions (the crash-recovery overlay).
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{
    Config,
    Coordinator,
    Feature,
    Layout,
    Pipeline,
    RepoIdentity,
    Store.Writer
  }

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp feat(id),
    do: %Feature{id: id, number: String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

  defp open_store_run(features) do
    repo_id = RepoIdentity.partition(Config.repo())
    {:ok, segment} = RepoIdentity.resolve(Config.repo())
    {:ok, layout} = Layout.build(Config.repo(), segment, :ad_hoc)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features:
          Enum.map(
            features,
            &%{
              feature_id: &1.id,
              slug: &1.slug,
              path: &1.path,
              number: &1.number,
              group: &1.group,
              created_at: &1.created_at
            }
          ),
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    {repo_id, run_id}
  end

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

  # A parked run's Coordinator stays alive awaiting the operator's
  # continue_run/end_run decision (contracts/parked-run.md) — the topbar must
  # say so instead of showing "● live"/"Active run" over a run that has
  # actually stopped, which used to contradict Mission Control's own parked
  # banner and "Run complete" report rendered on the very same page.
  test "status bar renders a parked chip, not live, when the run is parked", %{conn: conn} do
    run_key = open_store_run([feat("001")])
    :ok = Writer.record_feature_terminal(run_key, "001", :halted, :critical_finding, [])

    :ok =
      Writer.park_run(run_key, %{
        stopped_by: "001",
        status: :halted,
        reason: :critical_finding
      })

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    [topbar] = Regex.run(~r/<header class="console-topbar".*?<\/header>/s, html)

    assert topbar =~ "Parked run"
    assert topbar =~ "run-state-parked"
    refute topbar =~ "● live"
    assert topbar =~ ~s(data-parked=)
  end

  # 019, T025: there is exactly one run shape — the status bar names no mode
  # and no cap, active or idle. It used to read global Config for both, so a
  # run started with a per-run `:pr_workflow` opt (or a later live-config
  # edit) made the bar describe a run other than the one actually running;
  # now there is nothing left to describe.
  test "status bar renders no mode label and no cap while a run is active", %{conn: conn} do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    refute html =~ "stacked_pr"
    refute html =~ "parallel_waves"
    refute html =~ "run-meta"
    refute html =~ ~s(cap )
  end

  test "status bar renders no mode label and no cap when no run is active", %{conn: conn} do
    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "No active run"
    refute html =~ "stacked_pr"
    refute html =~ "parallel_waves"
    refute html =~ "run-meta"
  end

  test "lifecycle labels and phase order come from the shared status transport / Pipeline.phases/0" do
    for status <- Feature.terminal_statuses() ++ [:pending, :blocked, :running] do
      assert is_binary(SpeckitOrchestrator.Web.CoreComponents.label(status)),
             "missing label for #{status}"
    end

    assert SpeckitOrchestrator.Web.CoreComponents.status_class(:never_started) == "blocked"

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

  test "the same status renders with the identical data-status transport across Mission Control and Escalations",
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

    swatch = ~s(data-status="escalated")

    # 019: an escalated feature with nothing else in flight stops the chain
    # (Release.next/3 rule 2) — the run finishes immediately, so Mission
    # Control renders its aggregate "Run complete" summary rather than the
    # live per-feature table. Escalations isn't gated on `finished?`.
    #
    # Pipeline DAG is excluded here: its dependency-depth layout
    # (`PipelineDagLayout`) still reads the retired `Feature.prereqs` field
    # and is pending its 019 US2 rewrite to a linear chain view (T037) —
    # tracked separately, not re-verified by this shared-palette check.
    {:ok, _mc_view, mc_html} = live(conn, "/")
    {:ok, _esc_view, esc_html} = live(conn, "/escalations")

    assert mc_html =~ ~s(data-state="finished")
    assert esc_html =~ swatch
  end
end
