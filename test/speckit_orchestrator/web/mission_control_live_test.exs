defmodule SpeckitOrchestrator.Web.MissionControlLiveTest do
  # Starts the real named Coordinator (see layout_test.exs for the same
  # rationale) — must not run concurrently with another test claiming that
  # name. StoreCase (018) clears every store table before each test, so an
  # earlier test's in-flight run for this repo never leaks into this test's
  # "no live Coordinator" assertions (the store is one node-global instance
  # for the whole suite).
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{
    Config,
    ConsoleProjection,
    Coordinator,
    Feature,
    Layout,
    RepoIdentity,
    RunContext
  }

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # `number` defaults to a monotonic counter, so list-literal order (left to
  # right, evaluated at call time) is release order — e.g. `[feat("a"),
  # feat("b")]` gives "a" the lower number, same relative order the old
  # `prereqs` argument used to express before 019 retired prerequisites.
  defp feat(id, number \\ nil),
    do: %Feature{
      id: id,
      number: number || System.unique_integer([:positive, :monotonic]),
      slug: "slug-#{id}",
      path: "#{id}.md"
    }

  defp start_coordinator(features) do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: features,
        runner: fn _feature, _notify -> :ok end,
        owner: self()
      )

    pid
  end

  test "mount seeds the status-count strip and backlog table from Coordinator.status/0 + ConsoleProjection.read/0",
       %{conn: conn} do
    pid = start_coordinator([feat("mc1"), feat("mc2")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # mc1 is lowest-ordered so it releases immediately (no-op runner never
    # notifies) -> :running; one-at-a-time is structural, so mc2 stays
    # :pending regardless of anything about mc1.
    assert %{status: :running} = Coordinator.status(pid).per_feature["mc1"]
    assert %{status: :pending} = Coordinator.status(pid).per_feature["mc2"]

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-feature-row="mc1")
    assert html =~ ~s(data-feature-row="mc2")
    assert html =~ "slug-mc1"
    assert html =~ "slug-mc2"

    [pending_cell] =
      Regex.run(~r/<div class="status-count-cell" data-status="pending">.*?<\/div>/s, html)

    assert pending_cell =~ ">1<"

    [running_cell] =
      Regex.run(~r/<div class="status-count-cell" data-status="running">.*?<\/div>/s, html)

    assert running_cell =~ ">1<"
  end

  test "a :feature_updated broadcast updates a row's phase without reload, and :feed prepends a feed entry",
       %{conn: conn} do
    pid = start_coordinator([feat("mc3")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    feature_slice = %{
      current_phase: :plan,
      phases: %{
        specify: %{state: :completed, outcome: :ok, cost: 0.5, model: "sonnet"},
        plan: %{state: :active, outcome: nil, cost: nil, model: "opus"}
      },
      spend: 0.5
    }

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feature_updated, %{id: "mc3", feature: feature_slice}}
    )

    html = render(view)
    row = Regex.run(~r/<tr[^>]*data-feature-row="mc3".*?<\/tr>/s, html) |> hd()
    assert row =~ ~s(data-phase="plan")
    assert row =~ "phase-cell-active"
    assert row =~ "$0.50"

    entry = %{
      feature_id: "mc3",
      phase: :plan,
      severity: :info,
      text: "MC-TEST-FEED-ENTRY",
      at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feed, entry}
    )

    html = render(view)
    [feed_section] = Regex.run(~r/<ul class="telemetry-feed">.*?<\/ul>/s, html)
    [first_li | _] = Regex.run(~r/<li.*?<\/li>/s, feed_section, capture: :all) |> List.wrap()
    assert first_li =~ "MC-TEST-FEED-ENTRY"
  end

  test "a scope-narrowing-refused broadcast renders in the activity feed with no feature row affected",
       %{conn: conn} do
    pid = start_coordinator([feat("mc-scope")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html_before} = live(conn, "/")
    row_before = Regex.run(~r/<tr[^>]*data-feature-row="mc-scope".*?<\/tr>/s, html_before) |> hd()

    entry = %{
      feature_id: nil,
      phase: nil,
      severity: :warn,
      text: "scope narrowing refused — would drop 002, 003",
      at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feed, entry}
    )

    html = render(view)
    [feed_section] = Regex.run(~r/<ul class="telemetry-feed">.*?<\/ul>/s, html)
    [first_li | _] = Regex.run(~r/<li.*?<\/li>/s, feed_section, capture: :all) |> List.wrap()
    assert first_li =~ "scope narrowing refused"
    assert first_li =~ "002, 003"

    row_after = Regex.run(~r/<tr[^>]*data-feature-row="mc-scope".*?<\/tr>/s, html) |> hd()
    assert row_after == row_before
  end

  test "status bar reflects run title/mode, cost gauge, and armed/tripped indicator", %{
    conn: conn
  } do
    pid = start_coordinator([feat("mc4")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Active run"
    assert html =~ "cost-gauge"
    assert html =~ "armed"
  end

  test "renders the explicit no-active-run empty state when Coordinator is absent", %{conn: conn} do
    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-state="no-active-run")
    assert html =~ "No active run"
  end

  test "after a restart with no live Coordinator, shows last-known status from the store's in-flight run via the recovered-run banner",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    features = [feat("mc5"), feat("mc6")]
    run_key = open_store_run(features)
    :ok = Writer.record_feature_terminal(run_key, "mc5", :halted, "test fixture", [])

    {:ok, _view, html} = live(conn, "/")

    refute html =~ ~s(data-state="no-active-run")
    assert html =~ ~s(data-state="recovered-run")
    assert html =~ "SpeckitOrchestrator.resume_run/1"
    assert html =~ ~s(data-feature-row="mc5")
    assert html =~ ~s(data-feature-row="mc6")

    [halted_cell] =
      Regex.run(~r/<div class="status-count-cell" data-status="halted">.*?<\/div>/s, html)

    assert halted_cell =~ ">1<"
  end

  test "after a restart, a halted feature's row shows its phase progress from the checkpoint, and clicking it opens a drawer with the same timeline",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("mc7")])

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("mc7", :analyze),
        checkpoint: %{
          phase: :analyze,
          last_completed_phase: :analyze,
          status: :halted,
          reason: :critical_finding,
          session_id: "s1"
        }
      })

    :ok = Writer.record_feature_terminal(run_key, "mc7", :halted, :critical_finding, [])

    {:ok, view, html} = live(conn, "/")

    row = Regex.run(~r/<tr[^>]*data-feature-row="mc7".*?<\/tr>/s, html) |> hd()

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-completed"
    end

    [analyze_cell] = Regex.run(~r/<span[^>]*data-phase="analyze"[^>]*>/, row)
    assert analyze_cell =~ "phase-cell-halted"

    html = render_click(view, "select_feature", %{"id" => "mc7"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)
    assert drawer =~ ~s(data-phase="analyze" data-phase-state="halted")
    assert drawer =~ "/transcripts?run_id="
    assert drawer =~ "feature=mc7&amp;phase=analyze"
  end

  test "a done feature's drawer links to the PR recorded when it was published",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("mc8")])
    url = "https://github.com/acme/ledgerlite/pull/8"

    :ok = Writer.record_feature_terminal(run_key, "mc8", :done, nil, [])
    :ok = Writer.record_pr_url(run_key, "mc8", url)

    {:ok, view, _html} = live(conn, "/")

    html = render_click(view, "select_feature", %{"id" => "mc8"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)

    assert drawer =~ ~s(data-action="drawer-view-pr")
    assert drawer =~ ~s(href="#{url}")
    refute drawer =~ ~s(data-action="drawer-no-pr")
  end

  test "a PR opened mid-run reaches an already-mounted console without waiting for a reconcile tick",
       %{conn: conn} do
    pid = start_coordinator([feat("mc10")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    url = "https://github.com/acme/ledgerlite/pull/10"

    :telemetry.execute([:speckit, :publish, :opened], %{}, %{feature_id: "mc10", url: url})
    # The projection folds and broadcasts off its own mailbox — this round-trip
    # guarantees it has done so before we render.
    :sys.get_state(ConsoleProjection)

    html = render_click(view, "select_feature", %{"id" => "mc10"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)

    assert drawer =~ ~s(href="#{url}")
  end

  test "a done feature whose publish never produced a URL gets a label, not a dead button",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("mc9")])
    :ok = Writer.record_feature_terminal(run_key, "mc9", :done, nil, [])

    {:ok, view, _html} = live(conn, "/")

    html = render_click(view, "select_feature", %{"id" => "mc9"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)

    assert drawer =~ ~s(data-action="drawer-no-pr")
    refute drawer =~ ~s(data-action="drawer-view-pr")
  end

  # ---- 016 T039: resume lists the whole restored run (FR-022) ---------------

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
        settings: RunContext.to_map(%RunContext{budget_usd: 100.0}),
        scope: :ad_hoc,
        layout: layout
      })

    {repo_id, run_id}
  end

  test "after a resume, every feature in the restored run is listed, including ones still pending behind it",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    features = [feat("010"), feat("011"), feat("012")]
    run_key = open_store_run(features)

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("010", :analyze),
        checkpoint: %{
          phase: :analyze,
          last_completed_phase: :analyze,
          status: :halted,
          reason: "test fixture",
          session_id: "s1"
        }
      })

    :ok = Writer.record_feature_terminal(run_key, "010", :halted, "test fixture", [])

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("010",
               runner: fn feature, notify -> send(me, {:started, feature.id, notify}) end,
               owner: me
             )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # target dispatched, never notified — 011/012 stay :pending the whole
    # time this test observes the render (one-at-a-time is structural).
    assert_receive {:started, "010", _notify}, 1_000

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-feature-row="010")
    assert html =~ ~s(data-feature-row="011")
    assert html =~ ~s(data-feature-row="012")

    [pending_cell] =
      Regex.run(~r/<div class="status-count-cell" data-status="pending">.*?<\/div>/s, html)

    assert pending_cell =~ ">2<"
  end

  # ---- 019 US4: parked-run banner (contracts/parked-run.md § 6) ------------

  test "a parked run renders the banner naming the stopper and both continue/end actions",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("020"), feat("021")])
    :ok = Writer.record_feature_terminal(run_key, "020", :halted, :critical_finding, [])

    :ok =
      Writer.park_run(run_key, %{
        stopped_by: "020",
        status: :halted,
        reason: :critical_finding
      })

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-state="parked")
    assert html =~ "020"
    assert html =~ ":critical_finding"
    assert html =~ ~s(data-action="continue-run")
    assert html =~ ~s(data-action="end-run")
  end

  test "no banner renders when the run is in flight, not parked", %{conn: conn} do
    refute Process.whereis(Coordinator)

    open_store_run([feat("030")])

    {:ok, _view, html} = live(conn, "/")

    refute html =~ ~s(data-state="parked")
  end
end
