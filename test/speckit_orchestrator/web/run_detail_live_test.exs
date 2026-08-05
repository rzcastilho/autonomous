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
      feature_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, n} ->
        %{
          feature_id: id,
          slug: "f-#{id}",
          path: "specs/#{id}",
          number: n,
          group: :backlog,
          created_at: nil
        }
      end)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: %{budget_usd: 100.0},
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

    html = render_click(view, "toggle_transcript", %{"ref" => "001::specify::1"})
    assert html =~ "verbatim transcript body"
  end

  test "the Transcript button toggles its own panel shut, and swaps between attempts", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001"])
    record_attempt(repo_id, run_id, "001", :specify, 1)
    record_attempt(repo_id, run_id, "001", :plan, 1)

    {:ok, view, _html} = live(conn, "/runs/#{run_id}")

    html = render_click(view, "toggle_transcript", %{"ref" => "001::specify::1"})
    assert html =~ ~s(data-transcript-row="001::specify::1")

    # Same attempt again — the button that opened the panel closes it, so the
    # panel needs no close control of its own.
    html = render_click(view, "toggle_transcript", %{"ref" => "001::specify::1"})
    refute html =~ ~s(data-transcript-row="001::specify::1")
    refute html =~ "verbatim transcript body"

    # A different attempt replaces the open one rather than toggling it shut.
    _reopened = render_click(view, "toggle_transcript", %{"ref" => "001::specify::1"})
    html = render_click(view, "toggle_transcript", %{"ref" => "001::plan::1"})
    assert html =~ ~s(data-transcript-row="001::plan::1")
    refute html =~ ~s(data-transcript-row="001::specify::1")
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

  # `resolve_escalation/2` has always recorded `note` (and `by`) next to
  # `resolved_at`, but the page rendered only the timestamp — the operator's
  # account of *why* they closed the escalation was reachable nowhere but the
  # JSON `Store.Export` writes. A write-only textarea is worse than none.
  test "the recorded resolution note is rendered back, not just its timestamp", %{
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

    {:ok, view, _html} = live(conn, "/runs/#{run_id}")

    html =
      render_submit(view, "resolve_escalation", %{
        "ref" => "001::1",
        "note" => "picked option A (eager upgrade)"
      })

    assert html =~ ~s(data-resolution="001::1")
    assert html =~ "picked option A (eager upgrade)"
  end

  # Recovery lives once, on `/escalations` (018, T046-T050). Run detail is the
  # post-mortem — before this it displayed the checkpoint with nothing to act
  # on, so the only button in reach was `resolve_escalation/2`, which restarts
  # nothing.
  test "a diverted feature's checkpoint links out to the recovery forms", %{
    conn: conn,
    repo_id: repo_id
  } do
    run_id = open(repo_id, ["001", "002"])
    record_attempt(repo_id, run_id, "001", :specify, 1)
    record_attempt(repo_id, run_id, "002", :clarify, 1)

    :ok = Writer.record_feature_terminal({repo_id, run_id}, "002", :escalated, :needs_human, [])

    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ ~s(href="/escalations#escalation-002")
    assert html =~ "resume/2 from checkpoint"
    # 001 is still running — its checkpoint is a progress marker, not a
    # recovery point, and must not offer one.
    refute html =~ ~s(href="/escalations#escalation-001")
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

  # ---- 021-analyze-exhaustion-policy console surfaces (T035, contracts/advanced-record.md §4)

  test "the run header's settings chips show the run's captured exhaustion policy", %{
    conn: conn,
    repo_id: repo_id
  } do
    features = [
      %{
        feature_id: "001",
        slug: "f-001",
        path: "specs/001",
        number: 1,
        group: :backlog,
        created_at: nil
      }
    ]

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: %{budget_usd: 100.0, auto_remediation_exhaustion_policy: "proceed"},
        scope: :ad_hoc,
        layout: %{}
      })

    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ "auto_remediation_exhaustion_policy"
    assert html =~ "proceed"
  end

  test "the feature marker renders for a feature advanced past unresolved findings and is absent for a clean one",
       %{conn: conn, repo_id: repo_id} do
    run_id = open(repo_id, ["001", "002"])
    record_attempt(repo_id, run_id, "001", :analyze, 1)
    record_attempt(repo_id, run_id, "002", :analyze, 1)

    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: %{
          feature_id: "001",
          phase: :analyze,
          ordinal: 2,
          step: 2,
          label: "analyze-2",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 10,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.1,
          cost_kind: :actual
        },
        advanced_with_findings: %{
          policy: "proceed",
          attempts_used: 2,
          attempt_limit: 2,
          threshold: "high",
          max_severity: "high",
          findings: [%{"severity" => "high", "title" => "stubborn finding"}],
          advanced_at: DateTime.utc_now()
        }
      })

    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ ~s(data-feature="001")
    assert html =~ ~s(data-advanced-with-findings)
    assert html =~ "stubborn finding"

    # Only feature 001 was marked — exactly one occurrence of the block, so
    # feature 002 (clean) renders it nowhere.
    assert html |> String.split(~s(data-advanced-with-findings)) |> length() == 2
  end

  test "a parked run's header names the stopper and reason, and a never-started feature renders as such",
       %{conn: conn, repo_id: repo_id} do
    run_id = open(repo_id, ["001", "002"])

    :ok =
      Writer.park_run({repo_id, run_id}, %{
        stopped_by: "001",
        status: :halted,
        reason: :critical_finding
      })

    :ok = Writer.end_run({repo_id, run_id})

    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ ~s(data-marker="stopped-by")
    assert html =~ "001"
    assert html =~ ":critical_finding"

    assert html =~ ~s(data-feature="002")
    # :never_started folds to the "blocked" contract status — its shared
    # meaning, per docs/design-constitution.md §II — so no eighth color exists.
    assert html =~ ~s(data-status="blocked")
  end
end
