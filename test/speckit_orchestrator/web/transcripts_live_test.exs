defmodule SpeckitOrchestrator.Web.TranscriptsLiveTest do
  # Mutates :repo app env and touches the store — must not run concurrently
  # with another test claiming those globals. StoreCase (018) clears every
  # store table before each test.
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Layout, RepoIdentity}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior_repo = Application.get_env(:speckit_orchestrator, :repo)
    repo = Path.join(System.tmp_dir!(), "tr_live_repo_#{System.unique_integer([:positive])}")
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

    on_exit(fn ->
      File.rm_rf(repo)

      case prior_repo do
        nil -> Application.delete_env(:speckit_orchestrator, :repo)
        v -> Application.put_env(:speckit_orchestrator, :repo, v)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn(), repo: repo}
  end

  defp minimal_attempt(feature_id, phase, ordinal \\ 1) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: ordinal,
      step: ordinal,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # `entries`: `[{feature_id, phase, transcript_body_or_nil}]` — opens one
  # store run and records one phase attempt per entry, so the picker sees a
  # coherent run to browse (018).
  defp seed_run(repo, entries) do
    repo_id = RepoIdentity.partition(repo)
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    feature_ids = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features:
          Enum.map(
            feature_ids,
            &%{feature_id: &1, slug: "slug-#{&1}", path: "#{&1}.md", prereqs: []}
          ),
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    Enum.each(entries, fn {feature_id, phase, body} ->
      :ok =
        Writer.record_phase_attempt({repo_id, run_id}, %{
          attempt: minimal_attempt(feature_id, phase),
          transcript: body
        })
    end)

    run_id
  end

  test "selecting a feature+phase with an existing transcript renders its body", %{
    conn: conn,
    repo: repo
  } do
    run_id = seed_run(repo, [{"t1", :plan, "# plan\n\nsome durable transcript body"}])

    {:ok, view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t1&phase=plan")

    assert html =~ "some durable transcript body"
    assert html =~ ~s(data-state="found")

    html = render_click(view, "select_attempt", %{"index" => "0"})
    assert html =~ "some durable transcript body"
  end

  test "selecting an attempt with no recorded transcript body shows an explicit not-found state",
       %{conn: conn, repo: repo} do
    run_id = seed_run(repo, [{"t2", :specify, nil}])

    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t2&phase=specify")

    assert html =~ ~s(data-state="not-yet-written")
    assert html =~ "No transcript recorded for this attempt"
    refute html =~ "some durable transcript body"
  end

  test "switching feature via the sidebar defaults to that feature's latest attempt", %{
    conn: conn,
    repo: repo
  } do
    run_id =
      seed_run(repo, [
        {"t3", :specify, "# specify\n\nt3 body"},
        {"t4", :plan, "# plan\n\nt4 body"}
      ])

    {:ok, view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t3")
    assert html =~ "t3 body"

    html = render_click(view, "select_feature", %{"id" => "t4"})
    assert html =~ "t4 body"
    refute html =~ "t3 body"
  end

  test "renders the no-transcripts empty state when nothing has been written yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/transcripts")

    assert html =~ ~s(data-state="no-transcripts")
  end

  test "with no run_id and nothing in flight, falls back to the repo's most recent completed run",
       %{conn: conn, repo: repo} do
    repo_id = RepoIdentity.partition(repo)
    run_id = seed_run(repo, [{"t5", :specify, "# specify\n\nt5 body"}])
    :ok = Writer.close_run({repo_id, run_id}, :all_done, [])

    {:ok, _view, html} = live(conn, "/transcripts")

    assert html =~ "t5 body"
    assert html =~ "run #{run_id}"
  end

  test "an explicit ?attempt= index selects that attempt directly", %{conn: conn, repo: repo} do
    repo_id = RepoIdentity.partition(repo)
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [%{feature_id: "t6", slug: "slug-t6", path: "t6.md", prereqs: []}],
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: minimal_attempt("t6", :specify, 1),
        transcript: "first attempt body"
      })

    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: minimal_attempt("t6", :specify, 2),
        transcript: "second attempt body"
      })

    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t6&attempt=0")

    assert html =~ "first attempt body"
    refute html =~ "second attempt body"
  end

  test "an out-of-range ?attempt= index falls back to the latest attempt", %{
    conn: conn,
    repo: repo
  } do
    run_id = seed_run(repo, [{"t7", :specify, "# specify\n\nt7 body"}])

    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t7&attempt=99")

    assert html =~ "t7 body"
  end

  test "a garbage ?phase= value is ignored, falling back to the latest attempt", %{
    conn: conn,
    repo: repo
  } do
    run_id = seed_run(repo, [{"t8", :specify, "# specify\n\nt8 body"}])

    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t8&phase=not-a-phase")

    assert html =~ "t8 body"
  end

  test "a feature with no recorded attempts shows the no-attempts state, not a crash", %{
    conn: conn,
    repo: repo
  } do
    repo_id = RepoIdentity.partition(repo)
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [%{feature_id: "t9", slug: "slug-t9", path: "t9.md", prereqs: []}],
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=t9")

    assert html =~ "No attempts recorded yet for t9"
  end

  test "a repo with no in-flight or past run has nothing to browse" do
    bare = Path.join(System.tmp_dir!(), "tr_live_bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "-q", bare])
    on_exit(fn -> File.rm_rf(bare) end)

    Application.put_env(:speckit_orchestrator, :repo, bare)

    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/transcripts")
    assert html =~ ~s(data-state="no-transcripts")
  end
end
