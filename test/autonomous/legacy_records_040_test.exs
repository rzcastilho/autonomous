defmodule Autonomous.LegacyRecords040Test do
  @moduledoc """
  040 (T050, SC-007): an attempt recorded before the conversation feature
  (`conversations: nil`, the shape the v7 → v8 migration leaves) still opens on
  Transcripts with its final-text transcript, and Run Detail says it was not
  recorded — nothing errors and nothing is invented.
  """

  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Layout, RepoIdentity}

  @endpoint Autonomous.Web.Endpoint

  setup do
    prior_repo = Application.get_env(:autonomous, :repo)
    repo = Path.join(System.tmp_dir!(), "legacy040_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])

    {_, 0} =
      System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@example.com:t/x.git"])

    Application.put_env(:autonomous, :repo, repo)

    on_exit(fn ->
      File.rm_rf(repo)

      case prior_repo do
        nil -> Application.delete_env(:autonomous, :repo)
        v -> Application.put_env(:autonomous, :repo, v)
      end
    end)

    repo_id = RepoIdentity.partition(repo)
    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, :ad_hoc)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: "001",
            slug: "old",
            path: "001.md",
            number: 1,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: layout
      })

    now = DateTime.utc_now()

    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: %{
          feature_id: "001",
          phase: :plan,
          ordinal: 1,
          step: 1,
          label: "plan",
          started_at: now,
          ended_at: now,
          duration_ms: 0,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.0,
          cost_kind: :estimate,
          conversations: nil
        },
        transcript: "pre-040 final text"
      })

    {:ok, conn: build_conn(), run_id: run_id}
  end

  test "Transcripts opens the pre-040 attempt with its final text and a note", %{
    conn: conn,
    run_id: run_id
  } do
    {:ok, _view, html} = live(conn, "/transcripts?run_id=#{run_id}&feature=001&attempt=0")
    assert html =~ "pre-040 final text"
    assert html =~ "recorded before feature 040"
  end

  test "Run Detail marks the attempt as not recorded", %{conn: conn, run_id: run_id} do
    {:ok, _view, html} = live(conn, "/runs/#{run_id}")
    assert html =~ "not recorded (pre-040)"
  end
end
