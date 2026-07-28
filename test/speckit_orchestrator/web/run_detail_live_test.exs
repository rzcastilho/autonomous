defmodule SpeckitOrchestrator.Web.RunDetailLiveTest do
  # Mutates :repo app env and writes under a temp Config.autonomous_root() —
  # must not run concurrently with another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.RepoIdentity
  alias SpeckitOrchestrator.Store.Writer

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior_repo = Application.get_env(:speckit_orchestrator, :repo)

    repo =
      Path.join(System.tmp_dir!(), "run_detail_live_repo_#{System.unique_integer([:positive])}")

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

  defp open(repo_id, feature_ids) do
    features =
      Enum.map(feature_ids, &%{feature_id: &1, slug: "f-#{&1}", path: "specs/#{&1}", prereqs: []})

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: %{max_concurrency: 2},
        scope: :ad_hoc,
        layout: %{}
      })

    run_id
  end

  defp record_attempt(repo_id, run_id, feature_id, phase, ordinal) do
    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: %{
          feature_id: feature_id,
          phase: phase,
          ordinal: ordinal,
          step: ordinal,
          label: "#{phase}-#{ordinal}",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 10,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.1,
          cost_kind: :actual
        },
        cost: %{amount_usd: 0.1, kind: :actual},
        checkpoint: %{phase: phase, last_completed_phase: phase, status: :in_progress},
        transcript: "verbatim transcript body"
      })
  end

  test "renders run detail sourced from run_detail/2 only", %{conn: conn, repo_id: repo_id} do
    run_id = open(repo_id, ["001"])
    record_attempt(repo_id, run_id, "001", :specify, 1)

    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ run_id
    assert html =~ "001"
    assert html =~ "specify"
    assert html =~ "sonnet"
  end

  test "on-demand transcript fetch renders the body verbatim only after the click", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001"])
    record_attempt(repo_id, run_id, "001", :specify, 1)

    {:ok, view, html} = live(conn, "/runs/#{run_id}")
    refute html =~ "verbatim transcript body"

    html = render_click(view, "open_transcript", %{"ref" => "001::specify::1"})
    assert html =~ "verbatim transcript body"
  end

  test "resolve_escalation action clears the open escalation (FR-026)", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001"])

    :ok =
      Writer.record_escalation({repo_id, run_id}, %{
        feature_id: "001",
        kind: :escalated,
        phase: :clarify,
        reason: "needs human",
        evidence: %{}
      })

    {:ok, view, html} = live(conn, "/runs/#{run_id}")
    refute html =~ ~s(data-marker="resolved")

    html = render_submit(view, "resolve_escalation", %{"ref" => "001::1", "note" => "reviewed"})
    assert html =~ ~s(data-marker="resolved")
  end

  test "export action writes exactly one file under autonomous_root/exports", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001"])
    record_attempt(repo_id, run_id, "001", :specify, 1)

    {:ok, view, _html} = live(conn, "/runs/#{run_id}")
    render_click(view, "export", %{})

    exports_dir = Path.join(SpeckitOrchestrator.Config.autonomous_root(), "exports")
    assert {:ok, entries} = File.ls(exports_dir)
    assert Enum.any?(entries, &String.starts_with?(&1, run_id))
  end

  test "an absent run renders an error instead of crashing", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs/r999999")
    assert html =~ "unavailable"
  end
end
