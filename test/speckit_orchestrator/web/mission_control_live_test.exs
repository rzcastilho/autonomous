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

  defp start_coordinator(features, statuses) do
    {:ok, pid} =
      Coordinator.start_link(
        name: Coordinator,
        features: features,
        statuses: statuses,
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

    for phase <- [:specify, :clarify, :plan, :tasks] do
      :ok = Writer.record_phase_attempt(run_key, %{attempt: minimal_attempt("mc7", phase)})
    end

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

  # ---- 023 console-restart-hydration (US1: finished features keep their
  # history across a restart) -------------------------------------------------

  @all_phases ~w(specify clarify plan tasks analyze implement converge)a

  defp record_done_feature(run_key, feature_id) do
    :ok = Writer.record_feature_started(run_key, feature_id)

    for phase <- @all_phases do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: minimal_attempt(feature_id, phase),
          cost: %{amount_usd: 2.0, kind: :actual}
        })
    end

    :ok = Writer.record_feature_terminal(run_key, feature_id, :done, nil, [])
  end

  defp assert_full_completed_strip(row) do
    for phase <- @all_phases do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-completed"
    end
  end

  test "with no live Coordinator, a :done feature recorded through all seven phases renders a full completed strip, correct spend, and non-'—' elapsed (US1-5)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("h1"), feat("h2")])
    record_done_feature(run_key, "h1")
    record_done_feature(run_key, "h2")

    {:ok, _view, html} = live(conn, "/")

    for id <- ["h1", "h2"] do
      row = Regex.run(~r/<tr[^>]*data-feature-row="#{id}".*?<\/tr>/s, html) |> hd()
      assert_full_completed_strip(row)
      assert row =~ "$14.00"
      refute row =~ ">—<"
    end
  end

  test "identically with a live Coordinator resumed over the same store, a :done feature keeps its full completed strip, spend, and elapsed (US1-1)",
       %{conn: conn} do
    run_key = open_store_run([feat("h3"), feat("h4"), feat("h5")])
    record_done_feature(run_key, "h3")
    record_done_feature(run_key, "h4")

    pid =
      start_coordinator([feat("h3", 1), feat("h4", 2), feat("h5", 3)], %{
        "h3" => :done,
        "h4" => :done,
        "h5" => :pending
      })

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")

    for id <- ["h3", "h4"] do
      row = Regex.run(~r/<tr[^>]*data-feature-row="#{id}".*?<\/tr>/s, html) |> hd()
      assert_full_completed_strip(row)
      assert row =~ "$14.00"
      refute row =~ ">—<"
    end
  end

  test "a feature that finished in-session shows the same elapsed on every later reconcile tick (US1-2, SC-005)",
       %{conn: conn} do
    run_key = open_store_run([feat("h6"), feat("h7")])
    record_done_feature(run_key, "h6")

    pid = start_coordinator([feat("h6", 1), feat("h7", 2)], %{"h6" => :done, "h7" => :pending})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="h6".*?<\/tr>/s, html) |> hd()
    [elapsed_once] = Regex.run(~r/\d+m \d+s/, row)

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: Coordinator.status(pid), ledger: nil}}
    )

    html_later = render(view)
    row_later = Regex.run(~r/<tr[^>]*data-feature-row="h6".*?<\/tr>/s, html_later) |> hd()
    [elapsed_later] = Regex.run(~r/\d+m \d+s/, row_later)

    assert elapsed_later == elapsed_once
  end

  # ---- 024 elapsed-execution-time (US1: elapsed is execution time, not
  # calendar time) -------------------------------------------------------

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

  # Seven attempts, ~5m43s each (summing to exactly 40m 0s), one per phase,
  # spread three hours apart — 40 minutes of execution across a 20-hour
  # calendar span.
  @seven_attempt_durations_ms [343_000, 343_000, 343_000, 343_000, 343_000, 343_000, 342_000]

  defp record_forty_minutes_over_twenty_hours(run_key, feature_id) do
    :ok = Writer.record_feature_started(run_key, feature_id)
    base = ~U[2026-01-01 00:00:00Z]

    @all_phases
    |> Enum.zip(@seven_attempt_durations_ms)
    |> Enum.with_index()
    |> Enum.each(fn {{phase, duration_ms}, i} ->
      started_at = DateTime.add(base, i * 3 * 60 * 60, :second)

      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at(feature_id, phase, 1, started_at, duration_ms),
          cost: %{amount_usd: 2.0, kind: :actual}
        })
    end)

    :ok = Writer.record_feature_terminal(run_key, feature_id, :done, nil, [])
  end

  test "a finished feature's seven attempts covering 40 minutes across a 20-hour span read 40m 0s, not 1200m 0s, with no live Coordinator (US1-1)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("e1")])
    record_forty_minutes_over_twenty_hours(run_key, "e1")

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="e1".*?<\/tr>/s, html) |> hd()

    assert row =~ "40m 0s"
    refute row =~ "1200m 0s"
  end

  test "identically, with a live Coordinator resumed over the same store (US1-1)",
       %{conn: conn} do
    run_key = open_store_run([feat("e2"), feat("e2b")])
    record_forty_minutes_over_twenty_hours(run_key, "e2")

    pid =
      start_coordinator([feat("e2", 1), feat("e2b", 2)], %{"e2" => :done, "e2b" => :pending})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="e2".*?<\/tr>/s, html) |> hd()

    assert row =~ "40m 0s"
    refute row =~ "1200m 0s"
  end

  test "an implement roll-up's chunk attempts add nothing on top of the roll-up's own window (US1-4, SC-006)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    base = ~U[2026-01-01 00:00:00Z]

    run_key = open_store_run([feat("e3"), feat("e4")])

    :ok = Writer.record_feature_started(run_key, "e3")

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e3", :implement, 1, base, 60_000),
        cost: %{amount_usd: 2.0, kind: :actual}
      })

    :ok = Writer.record_feature_terminal(run_key, "e3", :done, nil, [])

    :ok = Writer.record_feature_started(run_key, "e4")

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e4", :implement, 1, base, 60_000),
        cost: %{amount_usd: 2.0, kind: :actual}
      })

    for {offset, i} <- Enum.with_index([0, 20_000, 40_000]) do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("e4", :implement_chunk, i + 1, DateTime.add(base, offset, :millisecond), 20_000)
        })
    end

    :ok = Writer.record_feature_terminal(run_key, "e4", :done, nil, [])

    {:ok, _view, html} = live(conn, "/")
    row_without = Regex.run(~r/<tr[^>]*data-feature-row="e3".*?<\/tr>/s, html) |> hd()
    row_with = Regex.run(~r/<tr[^>]*data-feature-row="e4".*?<\/tr>/s, html) |> hd()

    [elapsed_without] = Regex.run(~r/\d+m \d+s/, row_without)
    [elapsed_with] = Regex.run(~r/\d+m \d+s/, row_with)

    assert elapsed_without == elapsed_with
  end

  test "a final analyze record's superseded runs and corrections add nothing on top of its own window (US1-5, SC-006)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    base = ~U[2026-01-01 00:00:00Z]

    run_key = open_store_run([feat("e5"), feat("e6")])

    :ok = Writer.record_feature_started(run_key, "e5")

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e5", :analyze, 3, base, 100_000),
        cost: %{amount_usd: 2.0, kind: :actual}
      })

    :ok = Writer.record_feature_terminal(run_key, "e5", :done, nil, [])

    :ok = Writer.record_feature_started(run_key, "e6")

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e6", :analyze, 1, base, 20_000)
      })

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e6", :auto_remediation, 1, DateTime.add(base, 20_000, :millisecond), 20_000)
      })

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e6", :analyze, 2, DateTime.add(base, 40_000, :millisecond), 20_000)
      })

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e6", :auto_remediation, 2, DateTime.add(base, 60_000, :millisecond), 20_000)
      })

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("e6", :analyze, 3, base, 100_000),
        cost: %{amount_usd: 2.0, kind: :actual}
      })

    :ok = Writer.record_feature_terminal(run_key, "e6", :done, nil, [])

    {:ok, _view, html} = live(conn, "/")
    row_without = Regex.run(~r/<tr[^>]*data-feature-row="e5".*?<\/tr>/s, html) |> hd()
    row_with = Regex.run(~r/<tr[^>]*data-feature-row="e6".*?<\/tr>/s, html) |> hd()

    [elapsed_without] = Regex.run(~r/\d+m \d+s/, row_without)
    [elapsed_with] = Regex.run(~r/\d+m \d+s/, row_with)

    assert elapsed_without == elapsed_with
  end

  test "a live Coordinator's since-release elapsed_ms never leaks into ELAPSED for a feature with no attempts and no live phase (FR-009)",
       %{conn: conn} do
    pid = start_coordinator([feat("e7")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # The no-op runner releases "e7" immediately but never emits phase
    # telemetry, so the Coordinator's per-feature elapsed_ms (a since-release
    # monotonic counter) grows while the projection's windows stay empty.
    assert %{status: :running} = Coordinator.status(pid).per_feature["e7"]

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="e7".*?<\/tr>/s, html) |> hd()

    assert row =~ ">—<"
  end

  test "other features' live telemetry does not change a finished row (US1-2)",
       %{conn: conn} do
    run_key = open_store_run([feat("h8"), feat("h9")])
    record_done_feature(run_key, "h8")

    pid = start_coordinator([feat("h8", 1), feat("h9", 2)], %{"h8" => :done, "h9" => :pending})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/")
    row_before = Regex.run(~r/<tr[^>]*data-feature-row="h8".*?<\/tr>/s, html) |> hd()

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feature_updated,
       %{
         id: "h9",
         feature: %{
           current_phase: :specify,
           phases: %{specify: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}},
           spend: 0.1
         }
       }}
    )

    html_after = render(view)
    row_after = Regex.run(~r/<tr[^>]*data-feature-row="h8".*?<\/tr>/s, html_after) |> hd()

    assert row_after == row_before
  end

  # ---- 023 console-restart-hydration (US2: the resumed feature shows its
  # whole history) -------------------------------------------------------

  defp record_phase(run_key, feature_id, phase, checkpoint \\ nil) do
    payload = %{
      attempt: %{minimal_attempt(feature_id, phase) | cost_usd: 2.0},
      cost: %{amount_usd: 2.0, kind: :actual}
    }

    payload = if checkpoint, do: Map.put(payload, :checkpoint, checkpoint), else: payload
    :ok = Writer.record_phase_attempt(run_key, payload)
  end

  test "a feature resumed at phase five with four pre-restart phases recorded renders cells 1-4 completed, cell 5 active, and elapsed from the recorded start (US2-1)",
       %{conn: conn} do
    run_key = open_store_run([feat("u1")])
    :ok = Writer.record_feature_started(run_key, "u1")

    for phase <- [:specify, :clarify, :plan] do
      record_phase(run_key, "u1", phase)
    end

    record_phase(run_key, "u1", :tasks, %{
      phase: :tasks,
      last_completed_phase: :tasks,
      status: :running,
      reason: nil,
      session_id: "s1"
    })

    pid = start_coordinator([feat("u1", 1)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: System.system_time()},
      %{feature_id: "u1", phase: :analyze, model: "sonnet", step: 5}
    )

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="u1".*?<\/tr>/s, html) |> hd()

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-completed"
    end

    [analyze_cell] = Regex.run(~r/<span[^>]*data-phase="analyze"[^>]*>/, row)
    assert analyze_cell =~ "phase-cell-active"
    refute row =~ ">—<"
  end

  test "a feature resumed from plan with tasks/analyze recorded before the restart renders plan active and tasks/analyze pending (US2-5)",
       %{conn: conn} do
    run_key = open_store_run([feat("u2")])
    :ok = Writer.record_feature_started(run_key, "u2")

    for phase <- [:specify, :clarify] do
      record_phase(run_key, "u2", phase)
    end

    record_phase(run_key, "u2", :plan, %{
      phase: :plan,
      last_completed_phase: :plan,
      status: :running,
      reason: nil,
      session_id: "s1"
    })

    # Stale attempts from before the resume-from-earlier-phase reset — the
    # checkpoint above already put current_phase back at :plan.
    for phase <- [:tasks, :analyze] do
      record_phase(run_key, "u2", phase)
    end

    pid = start_coordinator([feat("u2", 1)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: System.system_time()},
      %{feature_id: "u2", phase: :plan, model: "sonnet", step: 3}
    )

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="u2".*?<\/tr>/s, html) |> hd()

    for phase <- ~w(specify clarify) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-completed"
    end

    [plan_cell] = Regex.run(~r/<span[^>]*data-phase="plan"[^>]*>/, row)
    assert plan_cell =~ "phase-cell-active"

    for phase <- ~w(tasks analyze) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-pending"
    end
  end

  test "a :feature_updated broadcast carrying only since-boot phases leaves pre-restart cells completed and spend non-decreasing (US2-2, SC-004)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("u3")])
    :ok = Writer.record_feature_started(run_key, "u3")

    for phase <- [:specify, :clarify, :plan] do
      record_phase(run_key, "u3", phase)
    end

    record_phase(run_key, "u3", :tasks, %{
      phase: :tasks,
      last_completed_phase: :tasks,
      status: :running,
      reason: nil,
      session_id: "s1"
    })

    {:ok, view, html} = live(conn, "/")
    row_before = Regex.run(~r/<tr[^>]*data-feature-row="u3".*?<\/tr>/s, html) |> hd()
    assert row_before =~ "$8.00"

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feature_updated,
       %{
         id: "u3",
         feature: %{
           current_phase: :analyze,
           phases: %{analyze: %{state: :active, outcome: nil, cost: nil, model: "sonnet"}},
           spend: 0.0
         }
       }}
    )

    html_after = render(view)
    row_after = Regex.run(~r/<tr[^>]*data-feature-row="u3".*?<\/tr>/s, html_after) |> hd()

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row_after)
      assert cell =~ "phase-cell-completed"
    end

    [analyze_cell] = Regex.run(~r/<span[^>]*data-phase="analyze"[^>]*>/, row_after)
    assert analyze_cell =~ "phase-cell-active"
    assert row_after =~ "$8.00"
  end

  test "the drawer shows cost and model together for each completed pre-restart phase (US2-4)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("u4")])
    :ok = Writer.record_feature_started(run_key, "u4")

    for phase <- [:specify, :clarify, :plan] do
      record_phase(run_key, "u4", phase)
    end

    record_phase(run_key, "u4", :tasks, %{
      phase: :tasks,
      last_completed_phase: :tasks,
      status: :running,
      reason: nil,
      session_id: "s1"
    })

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "select_feature", %{"id" => "u4"})

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<li[^>]*data-phase="#{phase}".*?<\/li>/s, html)
      assert cell =~ "$2.00 · sonnet"
    end
  end

  # ---- 023 console-restart-hydration (US3: diverted features keep their
  # marker and their receipt) ---------------------------------------------

  defp record_halted_feature(run_key, feature_id) do
    :ok = Writer.record_feature_started(run_key, feature_id)

    for phase <- [:specify, :clarify, :plan, :tasks] do
      record_phase(run_key, feature_id, phase)
    end

    record_phase(run_key, feature_id, :analyze, %{
      phase: :analyze,
      last_completed_phase: :analyze,
      status: :halted,
      reason: :critical_finding,
      session_id: "s1"
    })

    :ok = Writer.record_feature_terminal(run_key, feature_id, :halted, :critical_finding, [])
  end

  defp assert_halted_row(row) do
    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<span[^>]*data-phase="#{phase}"[^>]*>/, row)
      assert cell =~ "phase-cell-completed"
    end

    [analyze_cell] = Regex.run(~r/<span[^>]*data-phase="analyze"[^>]*>/, row)
    assert analyze_cell =~ "phase-cell-halted"

    assert row =~ "$10.00"
    refute row =~ ">—<"
  end

  test "a feature halted at analyze before the restart renders the halted marker with recorded cost/model, earlier cells completed, and non-empty spend/elapsed, cold (US3-1)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("u5")])
    record_halted_feature(run_key, "u5")

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="u5".*?<\/tr>/s, html) |> hd()

    assert_halted_row(row)
  end

  test "the same halted feature's per-feature hydration is identical with a resumed Coordinator over the same store (US3-2)",
       %{conn: conn} do
    run_key = open_store_run([feat("u6")])
    record_halted_feature(run_key, "u6")

    # Release.next/3 stops the whole chain the instant any feature is a
    # non-done terminal (rule 2, structural — regardless of order), so a
    # Coordinator that knows about a halted feature always reports
    # finished? true and the backlog table (gated on `not finished?`) never
    # renders. Hydration itself is unaffected by that UI gate — the drawer
    # reads straight from `@view.per_feature`, so it is where this asserts.
    pid = start_coordinator([feat("u6", 1)], %{"u6" => :halted})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "select_feature", %{"id" => "u6"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)

    assert drawer =~ ~s(data-phase="analyze" data-phase-state="halted")

    for phase <- ~w(specify clarify plan tasks) do
      [cell] = Regex.run(~r/<li[^>]*data-phase="#{phase}".*?<\/li>/s, drawer)
      assert cell =~ ~s(data-phase-state="completed")
    end

    refute drawer =~ "$0.00"
  end

  test "an escalated feature's recorded pr_url survives a live update whose slice carries pr_url: nil (US3-3, FR-011)",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    run_key = open_store_run([feat("u8")])
    url = "https://github.com/acme/ledgerlite/pull/8"

    :ok = Writer.record_feature_terminal(run_key, "u8", :escalated, "test fixture", [])
    :ok = Writer.record_pr_url(run_key, "u8", url)

    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :feature_updated, %{id: "u8", feature: %{pr_url: nil}}}
    )

    html = render_click(view, "select_feature", %{"id" => "u8"})
    [drawer] = Regex.run(~r/<aside class="feature-drawer".*?<\/aside>/s, html)

    assert drawer =~ ~s(href="#{url}")
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

  # ---- 024 elapsed-execution-time (US2: a running feature's elapsed grows
  # only while a phase runs) -----------------------------------------------

  defp elapsed_seconds(row) do
    [minutes_str, seconds_str] = Regex.run(~r/(\d+)m (\d+)s/, row, capture: :all_but_first)
    String.to_integer(minutes_str) * 60 + String.to_integer(seconds_str)
  end

  test "a live phase's window grows the row's elapsed on the next reconcile tick (US2-1, US2-2, SC-004)",
       %{conn: conn} do
    base = ~U[2026-01-01 00:00:00Z]
    run_key = open_store_run([feat("g1")])

    for {phase, i} <- Enum.with_index([:specify, :clarify, :plan, :tasks]) do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("g1", phase, 1, DateTime.add(base, i * 60, :second), 10_000),
          cost: %{amount_usd: 1.0, kind: :actual}
        })
    end

    pid = start_coordinator([feat("g1", 1)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: System.system_time()},
      %{feature_id: "g1", phase: :analyze, model: "sonnet", step: 5}
    )

    {:ok, view, html} = live(conn, "/")
    row_once = Regex.run(~r/<tr[^>]*data-feature-row="g1".*?<\/tr>/s, html) |> hd()
    refute row_once =~ ">—<"
    elapsed_once = elapsed_seconds(row_once)
    # Four recorded 10s phases already sum to 40s before any live time.
    assert elapsed_once >= 40

    Process.sleep(1_200)

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: Coordinator.status(pid), ledger: nil}}
    )

    html_later = render(view)
    row_later = Regex.run(~r/<tr[^>]*data-feature-row="g1".*?<\/tr>/s, html_later) |> hd()
    elapsed_later = elapsed_seconds(row_later)

    assert elapsed_later >= elapsed_once
    assert elapsed_later <= elapsed_once + 5
  end

  test "once a live phase stops, elapsed stays the same across further reconcile ticks (US2-3, FR-006)",
       %{conn: conn} do
    _run_key = open_store_run([feat("g2")])
    pid = start_coordinator([feat("g2", 1)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: 0},
      %{feature_id: "g2", phase: :specify, model: "sonnet", step: 1}
    )

    :telemetry.execute(
      [:speckit, :phase, :stop],
      %{duration: System.convert_time_unit(5_000, :millisecond, :native)},
      %{feature_id: "g2", phase: :specify, model: "sonnet", step: 1, outcome: :ok, cost: 0.5}
    )

    {:ok, view, html} = live(conn, "/")
    row_once = Regex.run(~r/<tr[^>]*data-feature-row="g2".*?<\/tr>/s, html) |> hd()
    elapsed_once = elapsed_seconds(row_once)
    assert elapsed_once == 5

    Process.sleep(1_100)

    Phoenix.PubSub.broadcast(
      SpeckitOrchestrator.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled, %{coordinator: Coordinator.status(pid), ledger: nil}}
    )

    html_later = render(view)
    row_later = Regex.run(~r/<tr[^>]*data-feature-row="g2".*?<\/tr>/s, html_later) |> hd()
    elapsed_later = elapsed_seconds(row_later)

    assert elapsed_later == elapsed_once
  end

  test "a feature resumed from plan with stale tasks/analyze attempts counts those windows too (US2-4)",
       %{conn: conn} do
    base = ~U[2026-01-01 00:00:00Z]
    run_key = open_store_run([feat("g3")])
    :ok = Writer.record_feature_started(run_key, "g3")

    for {phase, i} <- Enum.with_index([:specify, :clarify]) do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("g3", phase, 1, DateTime.add(base, i * 60, :second), 10_000),
          cost: %{amount_usd: 1.0, kind: :actual}
        })
    end

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("g3", :plan, 1, DateTime.add(base, 120, :second), 10_000),
        checkpoint: %{
          phase: :plan,
          last_completed_phase: :plan,
          status: :running,
          reason: nil,
          session_id: "s1"
        },
        cost: %{amount_usd: 1.0, kind: :actual}
      })

    # Stale attempts from before a resume-from-an-earlier-phase reset — the
    # checkpoint above already puts current_phase back at :plan, so these
    # phase cells render pending (US2-5), but their windows still count
    # toward elapsed.
    for {phase, i} <- Enum.with_index([:tasks, :analyze]) do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("g3", phase, 1, DateTime.add(base, 180 + i * 60, :second), 10_000),
          cost: %{amount_usd: 1.0, kind: :actual}
        })
    end

    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="g3".*?<\/tr>/s, html) |> hd()

    [tasks_cell] = Regex.run(~r/<span[^>]*data-phase="tasks"[^>]*>/, row)
    assert tasks_cell =~ "phase-cell-pending"

    assert elapsed_seconds(row) == 50
  end

  # ---- 024 elapsed-execution-time (US3: diverted and unstarted features
  # read correctly) ---------------------------------------------------------

  test "a feature halted at analyze after four completed phases reads all five attempts' union, cold and live (US3-1)",
       %{conn: conn} do
    base = ~U[2026-01-01 00:00:00Z]
    run_key = open_store_run([feat("g4")])

    for {phase, i} <- Enum.with_index([:specify, :clarify, :plan, :tasks]) do
      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt_at("g4", phase, 1, DateTime.add(base, i * 60, :second), 10_000),
          cost: %{amount_usd: 1.0, kind: :actual}
        })
    end

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: attempt_at("g4", :analyze, 1, DateTime.add(base, 240, :second), 10_000),
        checkpoint: %{
          phase: :analyze,
          last_completed_phase: :analyze,
          status: :halted,
          reason: "test fixture",
          session_id: "s1"
        },
        cost: %{amount_usd: 1.0, kind: :actual}
      })

    :ok = Writer.record_feature_terminal(run_key, "g4", :halted, "test fixture", [])

    refute Process.whereis(Coordinator)
    {:ok, _view, cold_html} = live(conn, "/")
    cold_row = Regex.run(~r/<tr[^>]*data-feature-row="g4".*?<\/tr>/s, cold_html) |> hd()
    assert elapsed_seconds(cold_row) == 50

    # Live: reproduce the same five disjoint 10s phase windows purely
    # through telemetry on a freshly-live feature (no store record at all,
    # the diverting :analyze phase closed by its own :exception) — the same
    # window algebra drives both paths, so it reads the same union (FR-004).
    pid = start_coordinator([feat("g4live", 1)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for {phase, i} <- Enum.with_index([:specify, :clarify, :plan, :tasks, :analyze]) do
      start_native = System.convert_time_unit(i * 60_000, :millisecond, :native)
      duration_native = System.convert_time_unit(10_000, :millisecond, :native)

      :telemetry.execute(
        [:speckit, :phase, :start],
        %{system_time: start_native},
        %{feature_id: "g4live", phase: phase, model: "sonnet", step: 1}
      )

      if phase == :analyze do
        :telemetry.execute(
          [:speckit, :phase, :exception],
          %{duration: duration_native},
          %{feature_id: "g4live", phase: phase, model: "sonnet", step: 1, kind: :error, reason: :needs_human}
        )
      else
        :telemetry.execute(
          [:speckit, :phase, :stop],
          %{duration: duration_native},
          %{feature_id: "g4live", phase: phase, model: "sonnet", step: 1, outcome: :ok, cost: 1.0}
        )
      end
    end

    {:ok, _view, live_html} = live(conn, "/")
    live_row = Regex.run(~r/<tr[^>]*data-feature-row="g4live".*?<\/tr>/s, live_html) |> hd()
    assert elapsed_seconds(live_row) == 50
  end

  test "a feature with no recorded attempt and no live phase reads — (US3-2)",
       %{conn: conn} do
    pid = start_coordinator([feat("g5")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="g5".*?<\/tr>/s, html) |> hd()

    assert row =~ ">—<"
  end

  test "a feature whose only activity is a live start reads the seconds since it (US3-3)",
       %{conn: conn} do
    pid = start_coordinator([feat("g6")])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    :telemetry.execute(
      [:speckit, :phase, :start],
      %{system_time: System.system_time()},
      %{feature_id: "g6", phase: :specify, model: "sonnet", step: 1}
    )

    {:ok, _view, html} = live(conn, "/")
    row = Regex.run(~r/<tr[^>]*data-feature-row="g6".*?<\/tr>/s, html) |> hd()

    refute row =~ ">—<"
    assert elapsed_seconds(row) >= 0
  end

  # ---- 029 US4: awaiting pill (contracts/operator-surfaces.md Every status surface) ----

  test "an awaiting feature shows the round/waited/left pill and its row links to Escalations",
       %{conn: conn} do
    repo_id = RepoIdentity.partition(Config.repo())

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: "701",
            slug: "slug-701",
            path: "701.md",
            number: 701,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    run_key = {repo_id, run_id}

    {:ok, _seq} =
      Writer.record_feature_awaiting(run_key, "701", %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n\nWhich timezone?",
        questions: {:freeform, "Which timezone?"},
        answer_timeout_s: 1_800
      })

    pid = start_coordinator([feat("701", 701)])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    send(pid, {:feature_awaiting, "701"})
    :sys.get_state(pid)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-status="awaiting_answers")
    assert html =~ "round 1/3"
    assert html =~ "waited"
    assert html =~ "left"
    assert html =~ "/escalations#awaiting-701"
  end
end
