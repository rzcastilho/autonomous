defmodule SpeckitOrchestrator.Web.TranscriptsLiveTest do
  # Mutates :repo/:autonomous_root app env — must not run concurrently with
  # another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.RepoIdentity

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior_repo = Application.get_env(:speckit_orchestrator, :repo)
    prior_root = Application.get_env(:speckit_orchestrator, :autonomous_root)

    repo = Path.join(System.tmp_dir!(), "tr_live_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "tr_live_#{System.unique_integer([:positive])}")
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
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)
    {:ok, segment} = RepoIdentity.resolve(repo)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(root)

      case prior_repo do
        nil -> Application.delete_env(:speckit_orchestrator, :repo)
        v -> Application.put_env(:speckit_orchestrator, :repo, v)
      end

      case prior_root do
        nil -> Application.delete_env(:speckit_orchestrator, :autonomous_root)
        v -> Application.put_env(:speckit_orchestrator, :autonomous_root, v)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn(), segment: segment, root: root}
  end

  # `key` is "<scope>/<feature_id>" — the picker's identity under the new
  # <segment>/<scope>/<feature_id> grammar (012).
  defp write_transcript(root, segment, key, n, phase, body) do
    dir = Path.join([root, "transcripts", segment, key])
    File.mkdir_p!(dir)
    padded = n |> Integer.to_string() |> String.pad_leading(2, "0")
    File.write!(Path.join(dir, "#{padded}-#{phase}.md"), body)
  end

  test "selecting a feature+phase with an existing transcript renders its body + source path", %{
    conn: conn,
    segment: segment,
    root: root
  } do
    write_transcript(root, segment, "core/t1", 3, "plan", "# plan\n\nsome durable transcript body")

    {:ok, view, html} = live(conn, "/transcripts?feature=core/t1&phase=plan")

    assert html =~ "some durable transcript body"
    assert html =~ Path.join([root, "transcripts", segment])
    assert html =~ ~s(data-state="found")

    html = render_change(view, "select", %{"feature" => "core/t1", "phase" => "plan"})
    assert html =~ "some durable transcript body"
  end

  test "selecting a phase the feature hasn't reached shows an explicit not-yet-written state", %{
    conn: conn,
    segment: segment,
    root: root
  } do
    write_transcript(root, segment, "ad-hoc/t2", 1, "specify", "# specify\n\ndone")

    {:ok, view, html} = live(conn, "/transcripts?feature=ad-hoc/t2&phase=specify")
    assert html =~ ~s(data-state="found")

    html = render_change(view, "select", %{"feature" => "ad-hoc/t2", "phase" => "converge"})

    assert html =~ ~s(data-state="not-yet-written")
    assert html =~ "has not been reached yet"
    refute html =~ "some durable transcript body"
  end

  test "renders the no-transcripts empty state when nothing has been written yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/transcripts")

    assert html =~ ~s(data-state="no-transcripts")
  end

  test "a repo with no origin has nothing to browse (no segment to key the machine-global root by)" do
    bare = Path.join(System.tmp_dir!(), "tr_live_bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "-q", bare])
    on_exit(fn -> File.rm_rf(bare) end)

    Application.put_env(:speckit_orchestrator, :repo, bare)

    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/transcripts")
    assert html =~ ~s(data-state="no-transcripts")
  end
end
