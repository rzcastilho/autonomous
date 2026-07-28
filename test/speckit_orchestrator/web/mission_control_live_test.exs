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

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "slug-#{id}", path: "#{id}.md", prereqs: prereqs}

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
    pid = start_coordinator([feat("mc1"), feat("mc2", ["mc1"])])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # mc1 has no prereqs so it releases immediately (cap 2, no-op runner never
    # notifies) -> :running; mc2's prereq isn't :done yet -> stays :pending.
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

    features = [feat("mc5"), feat("mc6", ["mc5"])]
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
            &%{feature_id: &1.id, slug: &1.slug, path: &1.path, prereqs: &1.prereqs}
          ),
        settings:
          RunContext.to_map(%RunContext{
            pr_workflow: false,
            max_concurrency: 2,
            budget_usd: 100.0
          }),
        scope: :ad_hoc,
        layout: layout
      })

    {repo_id, run_id}
  end

  test "after a resume, every feature in the restored run is listed, including ones still waiting on prerequisites",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    features = [feat("mc10"), feat("mc11", ["mc10"]), feat("mc12", ["mc11"])]
    run_key = open_store_run(features)

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt("mc10", :analyze),
        checkpoint: %{
          phase: :analyze,
          last_completed_phase: :analyze,
          status: :halted,
          reason: "test fixture",
          session_id: "s1"
        }
      })

    :ok = Writer.record_feature_terminal(run_key, "mc10", :halted, "test fixture", [])

    me = self()

    assert {:ok, pid} =
             SpeckitOrchestrator.resume("mc10",
               runner: fn feature, notify -> send(me, {:started, feature.id, notify}) end,
               owner: me
             )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # target dispatched, never notified — 011/012 stay :pending on their
    # prereq the whole time this test observes the render.
    assert_receive {:started, "mc10", _notify}, 1_000

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-feature-row="mc10")
    assert html =~ ~s(data-feature-row="mc11")
    assert html =~ ~s(data-feature-row="mc12")

    [pending_cell] =
      Regex.run(~r/<div class="status-count-cell" data-status="pending">.*?<\/div>/s, html)

    assert pending_cell =~ ">2<"
  end
end
