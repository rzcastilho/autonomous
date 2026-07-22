defmodule SpeckitOrchestrator.Web.TranscriptsLiveTest do
  # Mutates transcript_root app env — must not run concurrently with another
  # test claiming that global.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.Config

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior = Application.get_env(:speckit_orchestrator, :transcript_root)
    root = Path.join(System.tmp_dir!(), "tr_live_#{System.unique_integer([:positive])}")
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      case prior do
        nil -> Application.delete_env(:speckit_orchestrator, :transcript_root)
        v -> Application.put_env(:speckit_orchestrator, :transcript_root, v)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp write_transcript(feature_id, n, phase, body) do
    dir = Path.join(Config.transcript_root(), feature_id)
    File.mkdir_p!(dir)
    padded = n |> Integer.to_string() |> String.pad_leading(2, "0")
    File.write!(Path.join(dir, "#{padded}-#{phase}.md"), body)
  end

  test "selecting a feature+phase with an existing transcript renders its body + source path", %{
    conn: conn
  } do
    write_transcript("t1", 3, "plan", "# plan\n\nsome durable transcript body")

    {:ok, view, html} = live(conn, "/transcripts?feature=t1&phase=plan")

    assert html =~ "some durable transcript body"
    assert html =~ Config.transcript_root()
    assert html =~ ~s(data-state="found")

    html = render_change(view, "select", %{"feature" => "t1", "phase" => "plan"})
    assert html =~ "some durable transcript body"
  end

  test "selecting a phase the feature hasn't reached shows an explicit not-yet-written state", %{
    conn: conn
  } do
    write_transcript("t2", 1, "specify", "# specify\n\ndone")

    {:ok, view, html} = live(conn, "/transcripts?feature=t2&phase=specify")
    assert html =~ ~s(data-state="found")

    html = render_change(view, "select", %{"feature" => "t2", "phase" => "converge"})

    assert html =~ ~s(data-state="not-yet-written")
    assert html =~ "has not been reached yet"
    refute html =~ "some durable transcript body"
  end

  test "renders the no-transcripts empty state when nothing has been written yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/transcripts")

    assert html =~ ~s(data-state="no-transcripts")
  end
end
