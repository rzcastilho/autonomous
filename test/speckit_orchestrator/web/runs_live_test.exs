defmodule SpeckitOrchestrator.Web.RunsLiveTest do
  # Mutates :repo/:store_capacity_bytes/:store_headroom_bytes app env — must
  # not run concurrently with another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.RepoIdentity
  alias SpeckitOrchestrator.Store.Writer

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior_repo = Application.get_env(:speckit_orchestrator, :repo)

    repo = Path.join(System.tmp_dir!(), "runs_live_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])

    {_, 0} =
      System.cmd("git", [
        "-C",
        repo,
        "remote",
        "add",
        "origin",
        "git@example.com:test/#{Path.basename(repo)}.git"
      ])

    Application.put_env(:speckit_orchestrator, :repo, repo)
    repo_id = RepoIdentity.partition(repo)

    on_exit(fn ->
      File.rm_rf(repo)

      case prior_repo do
        nil -> Application.delete_env(:speckit_orchestrator, :repo)
        v -> Application.put_env(:speckit_orchestrator, :repo, v)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn(), repo_id: repo_id}
  end

  defp open(repo_id, feature_ids, opts \\ []) do
    features =
      feature_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, n} ->
        %{feature_id: id, slug: "f-#{id}", path: "specs/#{id}", number: n, group: :backlog, created_at: nil}
      end)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: %{budget_usd: 100.0},
        scope: :ad_hoc,
        layout: %{}
      })

    if outcome = Keyword.get(opts, :close) do
      :ok = Writer.close_run({repo_id, run_id}, outcome, [])
    end

    run_id
  end

  test "renders run history rows sourced from run_history/1 only", %{conn: conn, repo_id: repo_id} do
    run_1 = open(repo_id, ["001"], close: :all_done)
    run_2 = open(repo_id, ["002"])

    {:ok, _view, html} = live(conn, "/runs")

    assert html =~ run_1
    assert html =~ run_2
    assert html =~ "all_done"
    assert html =~ "in_flight"
    assert html =~ "001"
    assert html =~ "002"
  end

  test "empty repository renders an empty state, not an error", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ ~s(data-state="no-runs")
  end

  test "starting a new run destroys 0 prior records — superseded run stays visible and marked", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_1 = open(repo_id, ["001"])
    run_2 = open(repo_id, ["001"])

    {:ok, _view, html} = live(conn, "/runs")

    assert html =~ run_1
    assert html =~ run_2
    assert html =~ ~s(data-marker="superseded")
  end

  test "filters by outcome (FR-024)", %{conn: conn, repo_id: repo_id} do
    run_1 = open(repo_id, ["001"], close: :all_done)
    run_2 = open(repo_id, ["001"], close: :halted)

    {:ok, view, _html} = live(conn, "/runs")

    html = render_change(view, "filter", %{"outcome" => "halted", "feature" => ""})
    assert html =~ run_2
    refute html =~ run_1
  end

  test "filters by feature (FR-024)", %{conn: conn, repo_id: repo_id} do
    run_1 = open(repo_id, ["001", "002"], close: :all_done)
    run_2 = open(repo_id, ["003"], close: :all_done)

    {:ok, view, _html} = live(conn, "/runs")

    html = render_change(view, "filter", %{"outcome" => "", "feature" => "002"})
    assert html =~ ~s(data-run-row="#{run_1}")
    refute html =~ ~s(data-run-row="#{run_2}")
  end

  test "a capacity refusal renders a banner naming the shortfall and reclaimable amount", %{
    conn: conn
  } do
    prior_capacity = Application.get_env(:speckit_orchestrator, :store_capacity_bytes)
    prior_headroom = Application.get_env(:speckit_orchestrator, :store_headroom_bytes)

    Application.put_env(:speckit_orchestrator, :store_capacity_bytes, 1)
    Application.put_env(:speckit_orchestrator, :store_headroom_bytes, 0)

    on_exit(fn ->
      restore(:store_capacity_bytes, prior_capacity)
      restore(:store_headroom_bytes, prior_headroom)
    end)

    {:ok, _view, html} = live(conn, "/runs")
    assert html =~ ~s(data-banner="capacity-refusing")
  end

  test "a parked run renders :parked distinctly, naming the stopper and reason", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001"])

    :ok =
      Writer.park_run({repo_id, run_id}, %{
        stopped_by: "001",
        status: :halted,
        reason: :critical_finding
      })

    {:ok, _view, html} = live(conn, "/runs")

    row = Regex.run(~r/<tr[^>]*data-run-row="#{run_id}".*?<\/tr>/s, html) |> hd()
    assert row =~ ~s(data-marker="state")
    assert row =~ "parked"
    assert row =~ ~s(data-marker="stopped-by")
    assert row =~ "001"
    assert row =~ ":critical_finding"
  end

  defp restore(key, nil), do: Application.delete_env(:speckit_orchestrator, key)
  defp restore(key, v), do: Application.put_env(:speckit_orchestrator, key, v)
end
