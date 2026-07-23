defmodule SpeckitOrchestrator.Web.MissionControlLiveTest do
  # Starts the real named Coordinator (see layout_test.exs for the same
  # rationale) — must not run concurrently with another test claiming that
  # name.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Checkpoint, ConsoleProjection, Coordinator, Feature, RunManifest}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior_transcript_root = Application.get_env(:speckit_orchestrator, :transcript_root)

    on_exit(fn ->
      case prior_transcript_root do
        nil -> Application.delete_env(:speckit_orchestrator, :transcript_root)
        v -> Application.put_env(:speckit_orchestrator, :transcript_root, v)
      end
    end)

    # :transcript_root is pinned to one shared tmp path for the whole test env
    # (config/config.exs) — any earlier test's real Coordinator (default
    # :manifest seam) may have left a run manifest there. Clear it so this
    # test's "no live Coordinator" assertions see a clean slot, not another
    # test's leftover state (specs/009-crash-recovery overlay).
    RunManifest.clear()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_transcripts_at(dir) do
    Application.put_env(:speckit_orchestrator, :transcript_root, dir)
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

  test "after a restart with no live Coordinator, shows last-known status from the run manifest via the recovered-run banner",
       %{conn: conn} do
    refute Process.whereis(Coordinator)

    :ok =
      RunManifest.write(%{
        features: [feat("mc5"), feat("mc6", ["mc5"])],
        statuses: %{"mc5" => :halted, "mc6" => :pending},
        context: %{},
        spend: 2.0,
        updated_at: 1
      })

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
    point_transcripts_at(Path.join(System.tmp_dir!(), "mc_checkpoint_#{System.unique_integer()}"))
    refute Process.whereis(Coordinator)

    :ok =
      RunManifest.write(%{
        features: [feat("mc7")],
        statuses: %{"mc7" => :halted},
        context: %{},
        spend: 1.0,
        updated_at: 1
      })

    :ok =
      Checkpoint.write(%{
        feature_id: "mc7",
        last_phase: :analyze,
        status: :halted,
        reason: :critical_finding,
        session_id: "s1",
        slug: "slug-mc7",
        path: "mc7.md"
      })

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
    assert drawer =~ "/transcripts?feature=mc7&amp;phase=analyze"
  end
end
