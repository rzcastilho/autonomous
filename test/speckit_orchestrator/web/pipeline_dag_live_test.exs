defmodule SpeckitOrchestrator.Web.PipelineDagLiveTest do
  # Overrides global Config app env (repo/breakdown_dir) and may start the
  # real named Coordinator — must not run concurrently with another test
  # claiming that name or mutating Config. StoreCase (018) clears every store
  # table before each test, so an earlier test's in-flight run never leaks
  # into this test's "no live Coordinator" assertions.
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Coordinator, Feature, Layout, RepoIdentity, RunContext}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)
  @duplicate_dir Path.expand("../../fixtures/breakdown_duplicate", __DIR__)

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

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # A real git repo (with `origin`) carrying the same 001/002/003 breakdown
  # files as @valid_dir, so RepoIdentity.resolve/1 succeeds and the manifest
  # overlay (U2 segment match) actually engages — @valid_dir itself is a
  # plain fixture dir, not a git checkout.
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

  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || String.to_integer(id),
      slug: "slug-#{id}",
      path: "#{id}.md"
    }

  defp ad_hoc_feat(id),
    do: %Feature{
      id: id,
      number: String.to_integer(id),
      slug: "slug-#{id}",
      path: "#{id}.md",
      group: :ad_hoc,
      created_at: DateTime.utc_now()
    }

  # Isolates one node's own markup (up to the next node's opening tag) so
  # `data-status` assertions can't match a sibling node's pill by accident.
  defp extract_node(html, id) do
    case String.split(html, ~s(data-dag-node="#{id}")) do
      [_before, after_id] -> after_id |> String.split("data-dag-node=") |> List.first()
      _ -> ""
    end
  end

  test "renders a chain node per feature with id/slug/status/spend/base-branch, in ascending number order, and the shared-palette legend",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), feat("002")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-view="pipeline-dag")
    assert html =~ ~s(data-state="chain")

    for id <- ~w(001 002 003 004 005 006 007) do
      assert html =~ ~s(data-dag-node="#{id}")
    end

    assert html =~ "core-ledger"

    # Ascending number order, one link at a time: 001 stacks on pr_base
    # ("main"), 002 on 001's branch, etc. (FR-018, Worktree's
    # feature/NNN-slug convention).
    node_001 = extract_node(html, "001")
    assert node_001 =~ "stacks on main"

    node_002 = extract_node(html, "002")
    assert node_002 =~ "stacks on feature/001-core-ledger"

    for status <- ~w(pending blocked running escalated halted failed done) do
      assert html =~ ~s(data-legend-status="#{status}")
    end
  end

  test "with 2 breakdown packages the chain defaults to the first wave and the picker switches waves",
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

  # Mirrors the real ../ledgerlite shape: two packages whose ids do NOT overlap
  # (001-mvp holds 001-007, 002-addons holds 008-011). The shipped
  # breakdown_packages fixture numbers both packages "001", so it cannot show
  # this class of bug at all.
  defp repo_with_disjoint_packages do
    repo = Path.join(System.tmp_dir!(), "dag_disjoint_#{System.unique_integer([:positive])}")
    root = Path.join(repo, "specs/autonomous/breakdown")
    File.mkdir_p!(Path.join(root, "first-wave"))
    File.mkdir_p!(Path.join(root, "second-wave"))

    File.write!(
      Path.join(root, "first-wave/001-alpha.md"),
      "# 001 — Alpha\n\n## Prerequisites\n\nNone\n"
    )

    File.write!(
      Path.join(root, "second-wave/008-beta.md"),
      "# 008 — Beta\n\n## Prerequisites\n\nNone\n"
    )

    on_exit(fn -> File.rm_rf(repo) end)
    Application.put_env(:speckit_orchestrator, :repo, repo)
    repo
  end

  describe "ad-hoc lane across breakdown packages" do
    # A feature belonging to another package has a breakdown file, so it is not
    # ad-hoc. Switching the wave picker away from the running package used to
    # relabel every one of its features as ad-hoc, because the lane's exclusion
    # set was the drawn package alone.
    test "a running package's features are not shown as ad-hoc when viewing another package",
         %{conn: conn} do
      repo_with_disjoint_packages()

      {:ok, pid} =
        Coordinator.start_link(
          name: Coordinator,
          features: [feat("001")],
          runner: fn _feature, _notify -> :ok end,
          owner: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, view, html} = live(conn, "/dag")
      # Defaults to the first package alphabetically — 001 is a normal node.
      assert html =~ ~s(data-dag-node="001")
      refute html =~ ~s(data-node-origin="ad-hoc")

      html =
        view
        |> element(~s(form[data-form="wave-picker"]))
        |> render_change(%{"slug" => "second-wave"})

      assert html =~ ~s(data-dag-node="008")
      refute html =~ ~s(data-node-origin="ad-hoc")
      refute html =~ ~s(data-state="ad-hoc-lane")
    end

    test "a feature in no package at all is still shown as ad-hoc", %{conn: conn} do
      repo_with_disjoint_packages()

      {:ok, pid} =
        Coordinator.start_link(
          name: Coordinator,
          features: [feat("001"), feat("999")],
          runner: fn _feature, _notify -> :ok end,
          owner: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, _view, html} = live(conn, "/dag")

      assert html =~ ~s(data-state="ad-hoc-lane")
      assert html =~ ~s(data-node-origin="ad-hoc")
      lane = extract_node(html, "999")
      assert lane =~ "ad-hoc"
    end
  end

  describe "live status is scoped to the run's own wave" do
    # Feature ids are per-package: `001` in alpha and `001` in beta are
    # different features that collide in the run's per-feature map, which is
    # keyed by id alone. Switching the picker to an idle wave used to redraw
    # the running wave's status/phases under the idle wave's nodes.
    defp repo_with_colliding_packages do
      src = Path.expand("../../fixtures/breakdown_packages", __DIR__)
      repo = Path.join(System.tmp_dir!(), "dag_collide_#{System.unique_integer([:positive])}")
      dest = Path.join(repo, "specs/autonomous/breakdown")
      File.mkdir_p!(dest)
      File.cp_r!(src, dest)

      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
      on_exit(fn -> File.rm_rf(repo) end)
      Application.put_env(:speckit_orchestrator, :repo, repo)
      repo
    end

    test "an idle wave's same-numbered node is drawn cold, not with the running wave's status",
         %{conn: conn} do
      repo = repo_with_colliding_packages()

      run_key = open_store_run(repo, [feat("001")], {:breakdown, "alpha"})
      :ok = Writer.record_feature_terminal(run_key, "001", :halted, "test fixture", [])

      refute Process.whereis(Coordinator)

      {:ok, view, html} = live(conn, "/dag")

      # The run's own wave draws its real status.
      assert html =~ "widget"
      assert extract_node(html, "001") =~ ~s(data-status="halted")

      html =
        view
        |> element(~s(form[data-form="wave-picker"]))
        |> render_change(%{"slug" => "beta"})

      # Same id, different wave, nothing running there.
      assert html =~ "gadget"
      node = extract_node(html, "001")
      assert node =~ ~s(<span class="status-chip" data-status="pending">)
      refute node =~ ~s(<span class="status-chip" data-status="halted">)
    end

    test "the drawer for an idle wave's node does not show the running wave's feature",
         %{conn: conn} do
      repo = repo_with_colliding_packages()

      run_key = open_store_run(repo, [feat("001")], {:breakdown, "alpha"})
      :ok = Writer.record_feature_terminal(run_key, "001", :halted, "test fixture", [])

      {:ok, view, _html} = live(conn, "/dag")

      html =
        view
        |> element(~s(form[data-form="wave-picker"]))
        |> render_change(%{"slug" => "beta"})

      refute extract_node(html, "001") =~ ~s(<span class="status-chip" data-status="halted">)

      html = view |> element(~s([data-dag-node="001"])) |> render_click()

      assert html =~ ~s(id="feature-drawer")
      drawer = html |> String.split(~s(id="feature-drawer")) |> List.last()
      # The alpha run's 001 (slug-001, :halted) must not leak into beta's drawer.
      refute drawer =~ "slug-001"
      refute drawer =~ ~s(<span class="status-chip" data-status="halted">)
    end
  end

  describe "release-order badges (019: every run is sequential, structurally)" do
    test "every node is numbered with its release position, no cap variant left to compare against",
         %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, pid} =
        Coordinator.start_link(
          name: Coordinator,
          features: [feat("001"), feat("002")],
          runner: fn _feature, _notify -> :ok end,
          owner: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, _view, html} = live(conn, "/dag")

      assert html =~ ~s(data-state="sequential-run")
      assert html =~ "one feature at a time"

      # The fixture backlog linearizes to 001..007 — one badge per node, no gaps.
      for {id, position} <- Enum.with_index(~w(001 002 003 004 005 006 007), 1) do
        node = extract_node(html, id)
        assert node =~ ~s(data-release-order="#{position}")
        assert node =~ ~s(data-chain-position="#{position}")
      end
    end

    test "no live run still renders badges from the static backlog order", %{conn: conn} do
      point_backlog_at(@valid_dir)
      refute Process.whereis(Coordinator)

      {:ok, _view, html} = live(conn, "/dag")

      assert html =~ ~s(data-release-order="1")
      assert html =~ ~s(data-state="sequential-run")
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

  test "an ad-hoc feature (absent from the backlog) renders as a node in a dedicated ad-hoc lane, reflecting live status/spend",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), ad_hoc_feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/dag")

    assert html =~ ~s(data-state="ad-hoc-lane")
    assert html =~ ~s(data-dag-node="099")
    assert html =~ ~s(data-status="pending")

    ad_hoc_099 = extract_node(html, "099")
    assert ad_hoc_099 =~ "stacks on main"

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
        features: [feat("001"), feat("002")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    refute html =~ ~s(data-state="ad-hoc-lane")

    for id <- ~w(001 002 003 004 005 006 007) do
      assert html =~ ~s(data-dag-node="#{id}")
    end
  end

  test "a backlog with numerically-equal duplicate numbers renders the backlog-invalid state instead of a broken chain",
       %{conn: conn} do
    point_backlog_at(@duplicate_dir)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-state="backlog-invalid")
    assert html =~ "duplicate"
    refute html =~ ~s(data-state="chain")
  end

  defp open_store_run(repo, features, scope \\ {:breakdown, "core"}) do
    repo_id = RepoIdentity.partition(repo)
    layout = layout_for(repo)

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
        settings: RunContext.to_map(%RunContext{}),
        scope: scope,
        layout: layout
      })

    {repo_id, run_id}
  end

  defp minimal_attempt(feature_id, phase) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: 1,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :error,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  test "after a restart with no live Coordinator, nodes reflect the last known status from the store's in-flight run instead of defaulting to pending",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    run_key = open_store_run(repo, [feat("001"), feat("002")])
    :ok = Writer.record_feature_terminal(run_key, "001", :halted, "test fixture", [])

    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/dag")

    assert html =~ ~s(data-dag-node="001")
    node_001 = html |> extract_node("001")
    assert node_001 =~ ~s(data-status="halted")

    node_002 = html |> extract_node("002")
    assert node_002 =~ ~s(data-status="pending")

    # A feature absent from the run record (never released) still falls back
    # to pending, not some other stale value.
    node_003 = html |> extract_node("003")
    assert node_003 =~ ~s(data-status="pending")
  end

  test "after a restart, a halted node's phase strip shows completed phases up to last_phase and the diverting phase highlighted",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    run_key = open_store_run(repo, [feat("001")])

    for phase <- [:specify, :clarify, :plan, :tasks] do
      :ok = Writer.record_phase_attempt(run_key, %{attempt: minimal_attempt("001", phase)})
    end

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("001", :analyze),
        checkpoint: %{
          phase: :analyze,
          last_completed_phase: :analyze,
          status: :halted,
          reason: :critical_finding,
          session_id: "s1"
        }
      })

    :ok = Writer.record_feature_terminal(run_key, "001", :halted, :critical_finding, [])

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

  # ---- 023 console-restart-hydration (US1: finished features keep their
  # history across a restart) -------------------------------------------------

  test "a :done pre-restart feature's node carries the same completed phase cells and spend as its Mission Control row (US1-4)",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    run_key = open_store_run(repo, [feat("001")])
    :ok = Writer.record_feature_started(run_key, "001")

    for phase <- [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge] do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: minimal_attempt("001", phase),
          cost: %{amount_usd: 2.0, kind: :actual}
        })
    end

    :ok = Writer.record_feature_terminal(run_key, "001", :done, nil, [])

    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/dag")

    node_001 = html |> extract_node("001")

    for phase <- ~w(specify clarify plan tasks analyze implement converge) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, node_001)
      assert cell =~ "phase-cell-completed"
    end

    assert node_001 =~ "$14.00"
  end

  # ---- 024 elapsed-execution-time (US1-3: the node drawer's ELAPSED equals
  # the Mission Control row's for the same record) ---------------------------

  defp attempt_at(feature_id, phase, ordinal, started_at, duration_ms) do
    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: ordinal,
      step: 1,
      label: Atom.to_string(phase),
      started_at: started_at,
      ended_at: DateTime.add(started_at, duration_ms, :millisecond),
      duration_ms: duration_ms,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 2.0,
      cost_kind: :actual,
      session_id: "s1",
      error: nil
    }
  end

  defp drawer_elapsed(drawer) do
    [_, value] =
      Regex.run(~r/ELAPSED<\/div>\s*<div class="drawer-stat-value">(.*?)<\/div>/s, drawer)

    value
  end

  test "a :done feature's node drawer ELAPSED equals the Mission Control row's for the same record (US1-3)",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    run_key = open_store_run(repo, [feat("001")])
    :ok = Writer.record_feature_started(run_key, "001")

    base = ~U[2026-01-01 00:00:00Z]

    [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]
    |> Enum.with_index()
    |> Enum.each(fn {phase, i} ->
      started_at = DateTime.add(base, i * 3 * 60 * 60, :second)

      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("001", phase, 1, started_at, 60_000),
          cost: %{amount_usd: 2.0, kind: :actual}
        })
    end)

    :ok = Writer.record_feature_terminal(run_key, "001", :done, nil, [])

    refute Process.whereis(Coordinator)

    {:ok, _mc_view, mc_html} = live(conn, "/")
    mc_row = Regex.run(~r/<tr[^>]*data-feature-row="001".*?<\/tr>/s, mc_html) |> hd()
    [mc_elapsed] = Regex.run(~r/\d+m \d+s/, mc_row)

    {:ok, dag_view, _dag_html} = live(conn, "/dag")
    dag_html = render_click(dag_view, "select_feature", %{"id" => "001"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, dag_html)

    assert drawer_elapsed(drawer) == mc_elapsed
  end

  defp drawer_elapsed_seconds(drawer) do
    [minutes_str, seconds_str] =
      Regex.run(~r/(\d+)m (\d+)s/, drawer_elapsed(drawer), capture: :all_but_first)

    String.to_integer(minutes_str) * 60 + String.to_integer(seconds_str)
  end

  # Both tests below use an id ("902"/"903") outside the fixture backlog
  # (rendered in the ad-hoc lane) on purpose: the real telemetry events they
  # emit fold into the node-global `ConsoleProjection` for the rest of the
  # suite's lifetime — reusing "001" here would leak an open :clarify window
  # into every later test that asserts on that id's phase strip.
  test "a live phase's window grows the drawer's ELAPSED on the next reconcile tick, same as Mission Control (US2)",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    run_key = open_store_run(repo, [feat("902")])

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("902", :specify, 1, ~U[2026-01-01 00:00:00Z], 10_000),
        cost: %{amount_usd: 2.0, kind: :actual}
      })

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("902")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: System.system_time()},
      %{feature_id: "902", phase: :clarify, model: "sonnet", step: 2}
    )

    {:ok, view, _html} = live(conn, "/dag")
    dag_html = render_click(view, "select_feature", %{"id" => "902"})
    [drawer_once] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, dag_html)
    elapsed_once = drawer_elapsed_seconds(drawer_once)
    assert elapsed_once >= 10

    Process.sleep(1_200)

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      SpeckitOrchestrator.ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: Coordinator.status(pid), ledger: nil}}
    )

    html_later = render(view)
    [drawer_later] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html_later)
    elapsed_later = drawer_elapsed_seconds(drawer_later)

    assert elapsed_later >= elapsed_once
    assert elapsed_later <= elapsed_once + 5
  end

  test "once a live phase stops, the drawer's ELAPSED stays the same across further reconcile ticks, same as Mission Control (US2-3)",
       %{conn: conn} do
    repo = real_repo_with_backlog()
    point_backlog_at(repo)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("903")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: 0},
      %{feature_id: "903", phase: :specify, model: "sonnet", step: 1}
    )

    :telemetry.execute(
      [:speckit, :phase, :stop],
      %{duration: System.convert_time_unit(5_000, :millisecond, :native)},
      %{feature_id: "903", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
    )

    {:ok, view, _html} = live(conn, "/dag")
    dag_html = render_click(view, "select_feature", %{"id" => "903"})
    [drawer_once] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, dag_html)
    elapsed_once = drawer_elapsed_seconds(drawer_once)
    assert elapsed_once == 5

    Process.sleep(1_100)

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      SpeckitOrchestrator.ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: Coordinator.status(pid), ledger: nil}}
    )

    html_later = render(view)
    [drawer_later] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html_later)
    elapsed_later = drawer_elapsed_seconds(drawer_later)

    assert elapsed_later == elapsed_once
  end

  test "a nonexistent breakdown dir (single-spec-only project) renders as an empty backlog, not an error",
       %{conn: conn} do
    point_backlog_at(Path.join(System.tmp_dir!(), "no_breakdown_here_#{System.unique_integer()}"))

    {:ok, _view, html} = live(conn, "/dag")

    refute html =~ ~s(data-state="backlog-invalid")
    assert html =~ ~s(data-state="empty-backlog")
  end

  test "a nonexistent breakdown dir still shows live ad-hoc features in the ad-hoc lane",
       %{conn: conn} do
    point_backlog_at(Path.join(System.tmp_dir!(), "no_breakdown_here_#{System.unique_integer()}"))

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [ad_hoc_feat("099")],
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/dag")

    refute html =~ ~s(data-state="backlog-invalid")
    assert html =~ ~s(data-state="ad-hoc-lane")
    assert html =~ ~s(data-dag-node="099")
  end

  test "clicking an ad-hoc node opens the same feature drawer as a backlog node, showing its detail",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: [feat("001"), ad_hoc_feat("099")],
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
        features: [feat("001"), ad_hoc_feat("099")],
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
        features: [feat("001"), ad_hoc_feat("099")],
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
        features: [feat("001"), feat("002")],
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
