defmodule Autonomous.Web.ConversationLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Conversation, ConversationIdentity, FakeSdk, PhaseResult}
  alias Jido.Harness.RunRequest

  @endpoint Autonomous.Web.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    on_exit(&FakeSdk.reset/0)
    request = RunRequest.new!(%{prompt: "do it", model: "opus"})
    {:ok, conn: build_conn(), root: root, request: request}
  end

  defp open_session(root, request, opts \\ []) do
    identity = %ConversationIdentity{
      repo_id: "o:repo",
      run_id: "r000001",
      feature_id: Keyword.get(opts, :feature_id, "001"),
      phase: :clarify,
      ordinal: 1,
      kind: :phase,
      transcript_root: root
    }

    {:ok, handle, _req} = Conversation.open(identity, request)
    on_exit(fn -> if Process.alive?(handle.pid), do: Conversation.close(handle, nil) end)
    handle
  end

  defp text_frame(text, n \\ 1),
    do:
      FakeSdk.frame(:assistant, %{
        "message" => %{"id" => "m#{n}", "content" => [%{"type" => "text", "text" => text}]}
      })

  defp call_frame(id),
    do:
      FakeSdk.frame(:assistant, %{
        "message" => %{
          "id" => "mc#{id}",
          "content" => [
            %{"type" => "tool_use", "id" => id, "name" => "Bash", "input" => %{"command" => "ls"}}
          ]
        }
      })

  defp result_frame(id, out),
    do:
      FakeSdk.frame(:user, %{
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => id, "content" => out, "is_error" => false}
          ]
        }
      })

  defp feed(handle, frames) do
    for f <- frames, do: send(handle.pid, {:frame, f})
    # a synchronous call drains the recorder mailbox behind the frames
    Conversation.catch_up(handle.conversation_id)
  end

  test "/live with nothing in flight shows the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/live")
    assert html =~ "No agent session in flight"
  end

  test "/live follows the in-flight session and streams entries in order", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [text_frame("first thought"), call_frame("t1"), result_frame("t1", "a.txt")])

    {:ok, view, html} = live(conn, "/live")
    assert html =~ handle.conversation_id
    assert html =~ "first thought"
    assert html =~ "a.txt"

    feed(handle, [text_frame("second thought", 2)])
    html = render(view)
    assert html =~ "second thought"

    # arrival order
    {a, _} = :binary.match(html, "first thought")
    {b, _} = :binary.match(html, "second thought")
    assert a < b
  end

  test "tool call and result are separate rows; the result carries the call's name", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [call_frame("t1"), result_frame("t1", "out")])

    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
    assert has_element?(view, ~s([data-kind="tool_call"]))
    assert has_element?(view, ~s([data-kind="tool_result"] .conv-tool), "Bash")
  end

  test "a long result is truncated and expand replaces the row in place", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    big = Enum.map_join(1..120, "\n", &"row-#{&1}")
    feed(handle, [call_frame("t1"), result_frame("t1", big)])

    {:ok, view, html} = live(conn, "/live/#{handle.conversation_id}")
    assert html =~ "lines / "
    refute html =~ "row-120"

    view |> element("button[data-expand]") |> render_click()
    assert render(view) =~ "row-120"
    refute has_element?(view, "button[data-expand]")
  end

  test "ending shows the outcome chip, stops the live dot, and does not navigate", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [text_frame("working")])
    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
    assert has_element?(view, ~s(.transcript-live[data-live="true"]))

    Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})

    html = render(view)
    assert has_element?(view, ~s(.transcript-live[data-live="false"]))
    assert html =~ "completed"
    assert has_element?(view, ~s([data-kind="end"] .status-chip[data-status="done"]))
    assert html =~ "working"
  end

  test "an unfinished tool call is tagged when the session ends", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [call_frame("t9")])
    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

    Conversation.close(handle, %PhaseResult{status: :error, error: :deadline_exceeded})
    render(view)
    assert has_element?(view, ~s([data-kind="tool_call"][data-unfinished="true"]))
  end

  test "follow mode offers the next session but never navigates away", %{
    conn: conn,
    root: root,
    request: req
  } do
    first = open_session(root, req)
    {:ok, view, _} = live(conn, "/live")
    assert render(view) =~ first.conversation_id

    Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
    second = open_session(root, req, feature_id: "002")
    html = render(view)

    assert html =~ first.conversation_id
    assert has_element?(view, "[data-next-session] a", second.conversation_id)
  end

  test "a pinned id that is not live and has no record says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/live/clarify-1-nope")
    assert html =~ "Conversation clarify-1-nope is not live and has no saved record"
  end

  test "joining mid-session shows earlier entries then the tail without duplicates", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, for(n <- 1..5, do: text_frame("early-#{n}", n)))

    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
    feed(handle, for(n <- 6..8, do: text_frame("late-#{n}", n)))

    html = render(view)

    for n <- 1..5, do: assert(count(html, "early-#{n}") == 1)
    for n <- 6..8, do: assert(count(html, "late-#{n}") == 1)
  end

  test "more than 500 entries shows the catch-up notice", %{conn: conn, root: root, request: req} do
    handle = open_session(root, req)
    feed(handle, for(n <- 1..520, do: text_frame("e-#{n}", n)))

    {:ok, _view, html} = live(conn, "/live/#{handle.conversation_id}")

    assert html =~
             "Showing the most recent 500 entries; earlier entries are in the full conversation once the session ends."
  end

  test "SC-006: what the view shows matches the saved file entry for entry", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, for(n <- 1..5, do: text_frame("early-#{n}", n)))
    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
    feed(handle, for(n <- 6..9, do: text_frame("late-#{n}", n)))

    ref = Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})
    html = render(view)

    {:ok, entries, :eof} =
      Autonomous.ConversationFile.page(Path.join(root, ref.path), 0, 500)

    texts = for %{kind: :assistant_text, body: %{"text" => t}} <- entries, do: t
    assert length(texts) == 9

    shown =
      Regex.scan(~r/(?:early|late)-\d+/, html) |> List.flatten()

    assert shown == texts
  end

  test "a reconnect re-runs catch-up and never duplicates, even if broadcasts replay", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, for(n <- 1..3, do: text_frame("first-#{n}", n)))
    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

    {:ok, [_ | _] = window, _last, _} = Conversation.catch_up(handle.conversation_id)
    replay = List.last(window)
    send(view.pid, {:conversation, handle.conversation_id, :entry, replay})
    feed(handle, [text_frame("fourth", 4)])

    # a fresh LiveView process (what a reconnect is) catches up from the window
    {:ok, view2, _} = live(conn, "/live/#{handle.conversation_id}")

    for v <- [view, view2] do
      html = render(v)
      for n <- 1..3, do: assert(count(html, "first-#{n}") == 1)
      assert count(html, "fourth") == 1
    end
  end

  test "a remount after the recorder died says so instead of crashing", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [text_frame("x")])
    id = handle.conversation_id
    ref = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    {:ok, _view, html} = live(conn, "/live/#{id}")
    assert html =~ "Conversation #{id} is not live and has no saved record"
  end

  describe "follow next sessions toggle" do
    test "the rows carry the scroll-follow hook and the follow flag", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{first.conversation_id}")

      assert has_element?(
               view,
               ~s(#conversation-rows[phx-hook="FollowTail"][data-follow="false"])
             )

      view |> element(".conv-follow input") |> render_click()
      assert has_element?(view, ~s(#conversation-rows[data-follow="true"]))
    end

    test "is off by default on /live and on with ?follow=1", %{conn: conn} do
      {:ok, view, _} = live(conn, "/live")
      assert has_element?(view, ~s(.conv-follow input[data-follow="false"]))

      {:ok, view, _} = live(build_conn(), "/live?follow=1")
      assert has_element?(view, ~s(.conv-follow input[data-follow="true"]))
    end

    test "on: the end of the session moves to the next one already open", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{first.conversation_id}?follow=1")

      second = open_session(root, req, feature_id: "002")
      # still reading the first, live: no move
      assert render(view) =~ first.conversation_id

      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      assert_patch(view, "/live/#{second.conversation_id}?follow=1")
      assert render(view) =~ second.conversation_id
    end

    test "on: a session opening after the end moves the view", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live?follow=1")
      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      render(view)

      second = open_session(root, req, feature_id: "002")
      assert_patch(view, "/live/#{second.conversation_id}?follow=1")
    end

    test "turning it on after the end jumps to the offered next session", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live")
      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      second = open_session(root, req, feature_id: "002")
      assert has_element?(view, "[data-next-session] a", second.conversation_id)

      view |> element(".conv-follow input") |> render_click()
      assert_patch(view, "/live/#{second.conversation_id}?follow=1")
    end

    test "turning it off keeps the session and drops the URL flag", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{first.conversation_id}?follow=1")

      view |> element(".conv-follow input") |> render_click()
      assert_patch(view, "/live/#{first.conversation_id}")
      assert has_element?(view, ~s(.conv-follow input[data-follow="false"]))
    end
  end

  describe "embedded panel (Mission Control)" do
    test "follows by default and switches sessions in place", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      feed(first, [text_frame("first session words")])

      {:ok, view, html} = live_isolated(conn, Autonomous.Web.ConversationPanelLive)
      assert html =~ "first session words"
      assert has_element?(view, ~s(.conv-follow input[data-follow="true"]))
      assert has_element?(view, ~s(a.conv-open-full[href="/live/#{first.conversation_id}"]))

      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      second = open_session(root, req, feature_id: "002")
      feed(second, [text_frame("second session words", 2)])

      html = render(view)
      assert html =~ second.conversation_id
      assert html =~ "second session words"
      refute html =~ "first session words"
    end

    test "with follow off it keeps the ended session and offers the link", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live_isolated(conn, Autonomous.Web.ConversationPanelLive)
      view |> element(".conv-follow input") |> render_click()

      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      second = open_session(root, req, feature_id: "002")

      assert render(view) =~ first.conversation_id
      assert has_element?(view, "[data-next-session] a", second.conversation_id)
    end
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1
end
