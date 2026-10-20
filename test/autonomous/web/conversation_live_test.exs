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

  test "a tool call and its result are one block; the result is nested in the call", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    feed(handle, [call_frame("t1"), result_frame("t1", "out")])

    {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
    assert has_element?(view, ~s([data-kind="tool_call"] .conv-call-line), "Bash(ls)")
    assert has_element?(view, ~s([data-kind="tool_call"] .conv-result), "out")
    refute has_element?(view, ~s([data-kind="tool_result"]))
  end

  describe "block markup (042)" do
    test "call is one summary line, no JSON by default; prompt and thinking are folded", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)

      feed(handle, [
        FakeSdk.frame(:assistant, %{
          "message" => %{
            "id" => "mt",
            "content" => [%{"type" => "thinking", "thinking" => "pondering\nmore"}]
          }
        }),
        call_frame("t1"),
        result_frame("t1", "out")
      ])

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(
               view,
               "details.conv-call:not([open]) summary.conv-call-line",
               "Bash(ls)"
             )

      assert has_element?(view, "details.conv-thinking:not([open]) .conv-first", "pondering")
      assert has_element?(view, ~s|.conv-row[data-class="context"] details:not([open])|)
      refute has_element?(view, ".conv-flag")
    end

    test "an error result carries the is_error flag without a status colour", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)

      err =
        FakeSdk.frame(:user, %{
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "t1",
                "content" => "boom",
                "is_error" => true
              }
            ]
          }
        })

      feed(handle, [call_frame("t1"), err])
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(view, ".conv-result .conv-flag", "is_error: true")
      refute has_element?(view, ".conv-flag[data-status]")
    end
  end

  test "a long result shows five lines; expand replaces the call block in place", %{
    conn: conn,
    root: root,
    request: req
  } do
    handle = open_session(root, req)
    big = Enum.map_join(1..120, "\n", &"row-#{&1}")
    feed(handle, [call_frame("t1"), result_frame("t1", big)])

    {:ok, view, html} = live(conn, "/live/#{handle.conversation_id}")
    assert html =~ "row-5"
    refute html =~ "row-6\n"
    refute html =~ "row-120"
    assert has_element?(view, "button[data-expand]", "+115 lines")

    view |> element("button[data-expand]") |> render_click()
    assert render(view) =~ "row-120"
    refute has_element?(view, "button[data-expand]")
    assert count(render(view), "data-kind=\"tool_call\"") == 1
  end

  describe "synthetic error result (043)" do
    test "the marker carries the error text and the status line reads result error", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [text_frame("working"), ClaudeAgentSDK.Message.error_result("CLI exited 1")])
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(
               view,
               ".conv-marker",
               "result · error_during_execution — CLI exited 1"
             )

      assert has_element?(view, "[data-activity]", "result error — CLI exited 1")
    end

    test "no message reads no reason given, and the footer is never a clean finish", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [ClaudeAgentSDK.Message.error_result("")])
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})
      render(view)

      assert has_element?(view, ".conv-marker", "no reason given")
      refute has_element?(view, ~s([data-activity] [data-status="done"]))
      assert has_element?(view, ~s([data-activity] [data-status="failed"]))
      assert has_element?(view, "[data-activity]", "completed · result error")
    end
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

  describe "follow conversations toggle" do
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

    test "the toolbar holds the live badge, the toggle and the ids; the badge shows the end", %{
      conn: conn,
      root: root,
      request: req
    } do
      first = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{first.conversation_id}")

      assert has_element?(
               view,
               ~s([data-conv-toolbar] [data-live-badge][data-live="true"]),
               "live session"
             )

      assert has_element?(
               view,
               ~s([data-conv-toolbar] .conv-follow input[aria-label="follow conversations"])
             )

      assert has_element?(
               view,
               "[data-conv-toolbar] .conv-follow .option-name",
               "follow conversations"
             )

      assert has_element?(
               view,
               "[data-conv-toolbar] [data-conversation-header]",
               first.conversation_id
             )

      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      assert has_element?(view, ~s([data-live-badge][data-live="false"]), "session ended")
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
      refute html =~ "first session words"
      refute has_element?(view, ".conv-follow")
      assert has_element?(view, "[data-live-badge]")
      assert has_element?(
               view,
               ~s(a.btn-secondary.btn-compact.conv-open-full[href="/live/#{first.conversation_id}"])
             )

      Conversation.close(first, %PhaseResult{status: :ok, final_text: "x"})
      second = open_session(root, req, feature_id: "002")
      feed(second, [text_frame("second session words", 2)])

      html = render(view)
      assert html =~ second.conversation_id
      refute html =~ first.conversation_id
      refute html =~ "second session words"
    end

    test "has no rows, toggles, notices or next-session link; /live keeps them", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [text_frame("some words")])

      {:ok, view, _} = live_isolated(conn, Autonomous.Web.ConversationPanelLive)

      for sel <- [
            ".conv-follow",
            "input[data-follow]",
            ".conv-frames",
            "input[data-frames]",
            "#conversation-rows",
            ".conv-row",
            ~s([data-notice="truncated"]),
            "[data-next-session]"
          ] do
        refute has_element?(view, sel), sel
      end

      assert has_element?(view, "[data-live-badge]")
      assert has_element?(view, "[data-conversation-header]")
      assert has_element?(view, "section[data-conv-status]")

      {:ok, full, _} = live(conn, "/live/#{handle.conversation_id}")
      assert has_element?(full, ".conv-follow")
      assert has_element?(full, ".conv-frames")
      assert has_element?(full, "#conversation-rows")
      refute has_element?(full, ".conv-open-full")
    end

    test "the status footer still updates as entries arrive", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live_isolated(conn, Autonomous.Web.ConversationPanelLive)
      before_html = view |> element("section[data-conv-status]") |> render()

      feed(handle, [text_frame("a"), call_frame("t1")])
      refute view |> element("section[data-conv-status]") |> render() == before_html
    end

    test "no session shows the empty state and no open-full-view link", %{conn: conn} do
      {:ok, view, _} = live_isolated(conn, Autonomous.Web.ConversationPanelLive)
      assert has_element?(view, ~s([data-state="nothing-in-flight"]))
      refute has_element?(view, ".conv-open-full")
    end
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  describe "status line (042)" do
    defp sys_frame(sub, extra), do: FakeSdk.frame(:system, Map.put(extra, "subtype", sub))

    defp rate_frame(status),
      do:
        FakeSdk.frame(:rate_limit_event, %{
          "rate_limit_info" => %{
            "status" => status,
            "rateLimitType" => "five_hour",
            "resetsAt" => 1_760_400_000
          }
        })

    defp text_of(view, sel) do
      view
      |> element(sel)
      |> render()
      |> String.replace(~r/<[^>]*>/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end

    test "signal entries are not rows; they drive the status line", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      feed(handle, [
        sys_frame("status", %{"status" => "requesting"}),
        sys_frame("thinking_tokens", %{"estimated_tokens" => 1200}),
        sys_frame("hook_started", %{"hook_id" => "h", "hook_name" => "Pre"}),
        sys_frame("hook_response", %{"hook_id" => "h", "outcome" => "success", "exit_code" => 0}),
        FakeSdk.frame(:tool_progress, %{"tool_name" => "Bash", "elapsed_time_seconds" => 30}),
        rate_frame("allowed")
      ])

      html = render(view)
      refute html =~ ~s(data-class="raw")
      assert has_element?(view, ~s(section[role="region"][aria-label="session status"]))
      assert text_of(view, "[data-activity]") =~ "running Bash · 30s"
      refute has_element?(view, "[data-rate-limit]")
    end

    test "SC-006: an entry shows in the status line on the next render, without a tick", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      feed(handle, [sys_frame("status", %{"status" => "requesting"})])
      assert has_element?(view, "[data-activity]", "requesting")

      feed(handle, [sys_frame("thinking_tokens", %{"estimated_tokens" => 1200})])
      assert has_element?(view, "[data-activity]", "thinking · ~1.2k tok")
    end

    test "counters, background work, rate limit, cost and duration update from broadcasts", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      feed(handle, [text_frame("x", 1), call_frame("t1"), call_frame("t2")])
      assert has_element?(view, "[data-tools]", "tools 2")
      assert has_element?(view, "[data-turns]", "turns 1")

      feed(handle, [sys_frame("task_started", %{"task_id" => "k"})])
      assert has_element?(view, "[data-tasks]", "bg 1")
      feed(handle, [sys_frame("task_notification", %{"task_id" => "k", "status" => "completed"})])
      refute has_element?(view, "[data-tasks]")

      feed(handle, [rate_frame("limited")])
      assert has_element?(view, "[data-rate-limit]", "rate limit · five_hour")
      feed(handle, [rate_frame("allowed")])
      refute has_element?(view, "[data-rate-limit]")

      refute has_element?(view, "[data-cost]")
      refute has_element?(view, "[data-duration]")

      feed(handle, [
        FakeSdk.frame(:result, %{
          "subtype" => "success",
          "num_turns" => 2,
          "total_cost_usd" => 0.77,
          "duration_ms" => 716_000
        })
      ])

      assert has_element?(view, "[data-cost]", "$0.77")
      assert has_element?(view, "[data-duration]", "11m 56s")
      assert has_element?(view, "[data-turns]", "turns 2")
    end

    test "announcements: only the outcome and a rate-limit onset", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      feed(handle, [sys_frame("status", %{"status" => "requesting"}), call_frame("t1")])
      assert text_of(view, "[data-announce]") == ""

      feed(handle, [rate_frame("limited")])
      assert text_of(view, "[data-announce]") == "rate limited · five_hour"

      Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})
      assert text_of(view, "[data-announce]") == "completed"
    end

    test "joining a session past the 500-entry window seeds exact counters from the file", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, for(n <- 1..600, do: call_frame("c#{n}")))

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      assert has_element?(view, "[data-tools]", "tools 600")
      refute text_of(view, "[data-tools]") =~ "≥"

      feed(handle, [call_frame("c601")])
      assert has_element?(view, "[data-tools]", "tools 601")
    end

    test "when the file cannot be read, counters are lower bounds", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, for(n <- 1..600, do: call_frame("c#{n}")))
      {:ok, path} = Conversation.file_path(handle.conversation_id)
      File.rm!(path)

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      assert text_of(view, "[data-tools]") =~ "tools ≥ "
      assert text_of(view, "[data-turns]") =~ "turns ≥ "
    end

    test "a short session is exact from the window even without the file", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [call_frame("c1")])
      {:ok, path} = Conversation.file_path(handle.conversation_id)
      File.rm!(path)

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      assert has_element?(view, "[data-tools]", "tools 1")
      refute text_of(view, "[data-tools]") =~ "≥"
    end

    test ":tick advances the elapsed clock while live and stops at the end", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(view, "[data-elapsed]")
      send(view.pid, :tick)
      assert has_element?(view, "[data-elapsed]")

      Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})
      frozen = text_of(view, "[data-elapsed]")
      send(view.pid, :tick)
      Process.sleep(1_100)
      assert text_of(view, "[data-elapsed]") == frozen
      assert has_element?(view, ~s([data-activity] [data-status="done"]))
    end
  end

  describe "frames toggle and header (042)" do
    defp init_frame do
      sys_frame("init", %{
        "model" => "claude-opus-4-8",
        "claude_code_version" => "2.1.100",
        "session_id" => "sess-1"
      })
    end

    test "signals are hidden by default and appear as folded raw rows with the toggle", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [init_frame(), text_frame("hello")])

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      assert has_element?(view, ~s(input[data-frames="default"]))
      refute has_element?(view, ~s(.conv-row[data-class="raw"]))

      view |> element(".conv-frames input") |> render_click()
      assert_patch(view, "/live/#{handle.conversation_id}?frames=all")
      assert has_element?(view, ~s(input[data-frames="all"]))
      assert has_element?(view, ~s(.conv-row[data-class="raw"] .conv-first), "system")

      view |> element(".conv-frames input") |> render_click()
      assert_patch(view, "/live/#{handle.conversation_id}")
      refute has_element?(view, ~s(.conv-row[data-class="raw"]))
    end

    test "?frames=all is honoured and combines with follow", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      feed(handle, [init_frame()])

      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}?follow=1&frames=all")
      assert has_element?(view, ~s(input[data-frames="all"]))
      assert has_element?(view, ~s(.conv-row[data-class="raw"]))

      view |> element(".conv-follow input") |> render_click()
      assert_patch(view, "/live/#{handle.conversation_id}?frames=all")
    end

    test "header shows alias, resolved model and cli version once init arrives", %{
      conn: conn,
      root: root,
      request: req
    } do
      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(view, "[data-header-model]")
      refute has_element?(view, "[data-header-resolved]")
      refute has_element?(view, "[data-header-cli]")

      feed(handle, [init_frame()])
      render(view)
      assert has_element?(view, "[data-header-resolved]", "claude-opus-4-8")
      assert has_element?(view, "[data-header-cli]", "cli 2.1.100")
    end
  end

  describe "stderr rows and token figure (043)" do
    defp usage_frame(event),
      do: FakeSdk.frame(:stream_event, %{"event" => event})

    defp start_event(id, input),
      do:
        usage_frame(%{
          "type" => "message_start",
          "message" => %{
            "id" => id,
            "usage" => %{"input_tokens" => input, "output_tokens" => 1}
          }
        })

    defp delta_event(out),
      do: usage_frame(%{"type" => "message_delta", "usage" => %{"output_tokens" => out}})

    defp stderr!(handle, lines) do
      for l <- lines, do: send(handle.pid, {:stderr, l})
      Conversation.catch_up(handle.conversation_id)
    end

    test "stderr is a quiet row by default, repeats collapse, the tail follows the last frame",
         %{conn: conn, root: root, request: req} do
      handle = open_session(root, req)
      stderr!(handle, ["warn", "warn", "warn", "error: retrying"])
      feed(handle, [text_frame("working")])
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")

      assert has_element?(view, ".conv-stderr", "warn")
      assert has_element?(view, "[data-repeat]", "×3")
      assert has_element?(view, ".conv-stderr", "error: retrying")
      assert count(render(view), ~s(data-class="stderr")) == 2

      stderr!(handle, ["late line"])
      assert has_element?(view, ".conv-stderr", "late line")

      # frames=all leaves stderr rows as they were
      view |> element("[data-frames]") |> render_click()
      assert count(render(view), ~s(data-class="stderr")) == 3
    end

    test "a dropped-count notice reads as a row between head and tail",
         %{conn: conn, root: root, request: req} do
      prev = Application.fetch_env(:autonomous, :conversation_stderr_head)
      Application.put_env(:autonomous, :conversation_stderr_head, 1)
      Application.put_env(:autonomous, :conversation_stderr_tail, 1)

      on_exit(fn ->
        Application.delete_env(:autonomous, :conversation_stderr_tail)

        case prev do
          {:ok, v} -> Application.put_env(:autonomous, :conversation_stderr_head, v)
          :error -> Application.delete_env(:autonomous, :conversation_stderr_head)
        end
      end)

      handle = open_session(root, req)
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      stderr!(handle, ["a", "b", "c", "d"])
      Conversation.close(handle, %PhaseResult{status: :ok, session_id: "s1", final_text: "x"})
      render(view)

      assert has_element?(view, ".conv-marker", "stderr · 2 lines dropped")
      assert has_element?(view, ".conv-stderr", "d")
    end

    test "the status line shows tokens as usage arrives, absent before any",
         %{conn: conn, root: root, request: req} do
      handle = open_session(root, req)
      feed(handle, [text_frame("hi")])
      {:ok, view, _} = live(conn, "/live/#{handle.conversation_id}")
      refute has_element?(view, "[data-tokens]")

      feed(handle, [start_event("m1", 12_000), delta_event(3_000)])
      assert has_element?(view, "[data-tokens]", "in 12.0k · out 3.0k")

      feed(handle, [delta_event(3_100), start_event("m2", 100), delta_event(50)])
      assert has_element?(view, "[data-tokens]", "in 12.1k · out 3.1k")
      refute has_element?(view, "[data-cost]")
    end
  end
end
