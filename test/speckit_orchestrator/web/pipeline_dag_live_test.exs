defmodule SpeckitOrchestrator.Web.PipelineDagLiveTest do
  # Overrides global Config app env (repo/breakdown_dir) and may start the
  # real named Coordinator — must not run concurrently with another test
  # claiming that name or mutating Config.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Checkpoint, Coordinator, Feature, Layout, RepoIdentity, RunManifest}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)
  @cyclic_dir Path.expand("../../fixtures/breakdown_cyclic", __DIR__)

  setup do
    prior = %{
      repo: Application.get_env(:speckit_orchestrator, :repo),
      breakdown_dir: Application.get_env(:speckit_orchestrator, :breakdown_dir),
      transcript_root: Application.get_env(:speckit_orchestrator, :transcript_root)
    }

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)

      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    # :transcript_root defaults to one shared tmp path for the whole test env
    # (config/config.exs) — clear any manifest a previous test's real
    # Coordinator (default :manifest seam) left there, so tests asserting on
    # last-known-status overlay (specs/009-crash-recovery) see a clean slot.
    RunManifest.clear()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_transcripts_at(dir) do
    Application.put_env(:speckit_orchestrator, :transcript_root, dir)
  end

  defp point_backlog_at(dir) do
    Application.put_env(:speckit_orchestrator, :repo, dir)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "")
  end

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # A real git repo (with `origin`) carrying the same 001/002 breakdown files
  # as @valid_dir, so RepoIdentity.resolve/1 succeeds and the manifest overlay
  # (U2 segment match) actually engages — @valid_dir itself is a plain
  # fixture dir, not a git checkout.
  defp real_repo_with_backlog do
    repo = Path.join(System.tmp_dir!(), "dag_repo_#{System.unique_integer([:positive])}")
    dest = Path.join(repo, "specs/autonomous/breakdown/core")
    File.mkdir_p!(dest)

    for name <- ["001-core-ledger.md", "002-categories.md", "003-budgets.md"] do
      File.cp!(Path.join(@valid_dir, name), Path.join(dest, name))
    end

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp layout_for(repo) do
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core"})
    layout
  end

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "slug-#{id}", path: "#{id}.md", prereqs: prereqs}

  # Isolates one node's own markup (up to the next node's opening tag) so
  # `data-status` assertions can't match a sibling node's pill by accident.
  defp extract_node(html, id) do
    case String.split(html, ~s(data-dag-node="#{id}")) do
      [_before, after_id] -> after_id |> String.split("data-dag-node=") |> List.first()
      _ -> ""
    end
  end

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
    assert html =~ "<svg"
    assert html =~ "<path"
    assert html =~ ~s(data-dag-edge="001:002")
    assert html =~ ~s(data-dag-edge="002:003")

    for status <- ~w(pending blocked running escalated halted failed done) do
      assert html =~ ~s(data-legend-status="#{status}")
    end
  end

  test "with 2 breakdown packages the DAG defaults to the first wave and the picker switches waves",
       %{conn: conn} do
    src = Path.expand("../../fixtures/breakdown_packages", __DIR__)
    repo = Path.join(System.tmp_dir!(), "dag_waves_#{System.unique_integer([:positive])}")
    dest = Path.join(repo, "specs/autonomous/breakdown")
    File.mkdir_p!(dest)
    File.cp_r!(src, dest)
    on_exit(fn -> File.rm_rf(repo) end)
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, view, html} = live(conn, "/dag")

    # Two packages → the wave picker renders, defaulting to the first
    # alphabetical wave (alpha) since there is no matching-segment manifest.
    assert html =~ ~s(data-form="wave-picker")
    assert html =~ "widget"
    refute html =~ "gadget"

    html =
      view
      |> element(~s(form[data-form="wave-picker"]))
      |> render_change(%{"slug" => "beta"})

    assert html =~ "gadget"
    refute html =~ "widget"
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

  test "an ad-hoc feature (absent from the backlog) renders as a node in a dedicated ad-hoc lane, reflecting live status/spend",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/dag")

    assert html =~ ~s(data-state="ad-hoc-lane")
    assert html =~ ~s(data-dag-node="099")
    assert html =~ ~s(data-status="pending")

    send(view.pid, {:console, :feature_updated, %{id: "099", feature: %{status: :done}}})
    html = render(view)

    assert html =~ ~s(data-dag-node="099")
    assert html =~ ~s(data-status="done")
  end

  test "when the live run's features are a subset of the backlog, no ad-hoc lane is rendered and existing backlog assertions still hold",
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

    refute html =~ ~s(data-state="ad-hoc-lane")

    for id <- ~w(001 002 003 004 005 006 007) do
      assert html =~ ~s(data-dag-node="#{id}")
    end

    assert html =~ ~s(data-dag-edge="001:002")
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

  test "after a restart with no live Coordinator, nodes reflect the last known status from the run manifest instead of defaulting to pending",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)
    point_transcripts_at(Path.join(System.tmp_dir!(), "dag_manifest_#{System.unique_integer()}"))

    :ok =
      RunManifest.write(%{
        features: [feat("001"), feat("002", ["001"])],
        statuses: %{"001" => :halted, "002" => :pending},
        context: %{},
        spend: 3.5,
        updated_at: 1,
        layout: layout_for(repo)
      })

    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-dag-node="001")
    node_001 = html |> extract_node("001")
    assert node_001 =~ ~s(data-status="halted")

    node_002 = html |> extract_node("002")
    assert node_002 =~ ~s(data-status="pending")

    # A feature absent from the manifest (never released) still falls back
    # to pending, not some other stale value.
    node_003 = html |> extract_node("003")
    assert node_003 =~ ~s(data-status="pending")
  end

  test "after a restart, a halted node's phase strip shows completed phases up to last_phase and the diverting phase highlighted",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    layout = layout_for(repo)
    point_backlog_at(repo)
    point_transcripts_at(Path.join(System.tmp_dir!(), "dag_manifest_#{System.unique_integer()}"))

    :ok =
      RunManifest.write(%{
        features: [feat("001")],
        statuses: %{"001" => :halted},
        context: %{},
        spend: 1.0,
        updated_at: 1,
        layout: layout
      })

    :ok =
      Checkpoint.write(%{
        feature_id: "001",
        last_phase: :analyze,
        status: :halted,
        reason: :critical_finding,
        session_id: "s1",
        slug: "slug-001",
        path: "001.md",
        layout: layout
      })

    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/dag")

    node_001 = html |> extract_node("001")

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, node_001)
      assert cell =~ "phase-cell-completed"
    end

    [analyze_cell] = Regex.run(~r/<span[^>]*data-phase="analyze"[^>]*>/, node_001)
    assert analyze_cell =~ "phase-cell-halted"

    for phase <- ~w(implement converge) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, node_001)
      assert cell =~ "phase-cell-pending"
    end
  end

  test "a nonexistent breakdown dir (single-spec-only project) renders as an empty backlog, not an error",
       %{conn: conn} do
    point_backlog_at(Path.join(System.tmp_dir!(), "no_breakdown_here_#{System.unique_integer()}"))

    {:ok, _view, html} = live(conn, "/dag")

    refute html =~ ~s(data-state="dag-invalid")
    assert html =~ ~s(data-state="empty-backlog")
  end

  test "a nonexistent breakdown dir still shows live ad-hoc features in the ad-hoc lane",
       %{conn: conn} do
    point_backlog_at(Path.join(System.tmp_dir!(), "no_breakdown_here_#{System.unique_integer()}"))

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    refute html =~ ~s(data-state="dag-invalid")
    assert html =~ ~s(data-state="ad-hoc-lane")
    assert html =~ ~s(data-dag-node="099")
  end

  test "clicking an ad-hoc node opens the same feature drawer as a backlog node, showing its detail",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/dag")
    refute html =~ "feature-drawer"

    html = render_click(view, "select_feature", %{"id" => "099"})

    assert html =~ ~s(id="feature-drawer")
    assert html =~ ~s(data-feature-id="099")
    assert html =~ "drawer-phase-timeline"
    assert html =~ "ELAPSED"
    assert html =~ "SPEND"
  end

  test "an ad-hoc feature that becomes escalated exposes the same resume/open-escalation drawer actions as a backlog feature",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/dag")

    send(view.pid, {:console, :feature_updated, %{id: "099", feature: %{status: :escalated}}})
    render(view)

    html = render_click(view, "select_feature", %{"id" => "099"})

    assert html =~ ~s(data-feature-id="099")
    assert html =~ ~s(data-action="drawer-resume")
    assert html =~ ~s(data-action="drawer-open-escalation")
  end

  test "backlog nodes carry data-node-origin=\"backlog\" and ad-hoc nodes carry data-node-origin=\"ad-hoc\" plus a visible marker, with a distinct legend entry",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-dag-node="001" data-node-origin="backlog")
    assert html =~ ~s(data-dag-node="099" data-node-origin="ad-hoc")
    assert html =~ "data-adhoc-badge"
    assert html =~ ~s(data-legend-origin="ad-hoc")
  end

  test "when the live run's features are a subset of the backlog, no ad-hoc marker or legend entry is rendered",
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

    refute html =~ "data-adhoc-badge"
    refute html =~ ~s(data-legend-origin="ad-hoc")
    assert html =~ ~s(data-dag-node="001" data-node-origin="backlog")
  end
end
