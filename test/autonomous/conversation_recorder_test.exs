defmodule Autonomous.ConversationRecorderTest do
  use ExUnit.Case, async: false

  alias Autonomous.{
    Conversation,
    ConversationEntry,
    ConversationFile,
    ConversationIdentity,
    FakeSdk,
    PhaseResult
  }

  alias Autonomous.Store.Records.ConversationRef
  alias Jido.Harness.RunRequest

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    on_exit(&FakeSdk.reset/0)

    identity = %ConversationIdentity{
      repo_id: "o:repo",
      run_id: "r000001",
      feature_id: "001",
      phase: :clarify,
      ordinal: 1,
      kind: :phase,
      transcript_root: root
    }

    request =
      RunRequest.new!(%{
        prompt: "do the thing",
        model: "opus",
        metadata: %{"claude" => %{env: %{"A" => "b"}}}
      })

    %{identity: identity, request: request, root: root}
  end

  defp frame(text) do
    FakeSdk.frame(:assistant, %{
      "message" => %{"id" => "m", "content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp ok_result(sid \\ "sess-1"), do: %PhaseResult{status: :ok, session_id: sid, final_text: "x"}

  defp wait_for_entries(handle, n) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      {:ok, entries, _, _} = Conversation.catch_up(handle.conversation_id)

      if length(entries) >= n,
        do: {:halt, entries},
        else:
          (
            Process.sleep(5)
            {:cont, nil}
          )
    end)
  end

  test "open adds the marker, writes start + prompt; close writes one :end and returns a captured ref",
       %{identity: identity, request: request, root: root} do
    assert {:ok, handle, req} = Conversation.open(identity, request)
    marker = req.metadata["claude"].env["AUTONOMOUS_CONVERSATION"]
    assert is_binary(marker)
    assert req.metadata["claude"].env["A"] == "b"
    assert %{req | metadata: request.metadata} == request

    send(handle.pid, {:frame, frame("hello")})
    wait_for_entries(handle, 3)

    assert [%{conversation_id: id}] = Conversation.in_flight("o:repo")
    assert id == handle.conversation_id

    assert %ConversationRef{
             status: :captured,
             reason: nil,
             entries: 4,
             outcome: :completed,
             session_id: "sess-1"
           } =
             ref = Conversation.close(handle, ok_result())

    assert Conversation.in_flight("o:repo") == []
    refute Process.alive?(handle.pid)

    path = ConversationFile.resolve(root, ref.path)
    assert {:ok, entries, :eof} = ConversationFile.page(path, 0, 100)
    assert Enum.map(entries, & &1.kind) == [:start, :prompt, :assistant_text, :end]
    assert Enum.map(entries, & &1.seq) == [0, 1, 2, 3]
    assert File.stat!(path).size == ref.bytes
    assert List.last(entries).body["outcome"] == "completed"
  end

  test "catch_up / entry serve the window; unknown id is :not_live / :not_found", %{
    identity: identity,
    request: request
  } do
    {:ok, handle, _} = Conversation.open(identity, request)
    send(handle.pid, {:frame, frame("a")})
    wait_for_entries(handle, 3)

    assert {:ok, [_, _, %ConversationEntry{seq: 2}], 2, false} =
             Conversation.catch_up(handle.conversation_id)

    assert {:ok, %{seq: 1, kind: :prompt}} = Conversation.entry(handle.conversation_id, 1)
    assert Conversation.entry(handle.conversation_id, 99) == :not_found

    Conversation.close(handle, ok_result())
    assert Conversation.catch_up(handle.conversation_id) == :not_live
    assert Conversation.entry("nope", 0) == :not_found
  end

  test "SC-006: subscribe → catch_up → apply seq > last_seq has no gap or dupe vs the saved file",
       %{identity: identity, request: request, root: root} do
    {:ok, handle, _} = Conversation.open(identity, request)
    id = handle.conversation_id

    for i <- 1..20, do: send(handle.pid, {:frame, frame("pre #{i}")})
    Conversation.subscribe(id)
    {:ok, window, last_seq, _} = Conversation.catch_up(id)
    for i <- 1..20, do: send(handle.pid, {:frame, frame("post #{i}")})

    ref = Conversation.close(handle, ok_result())

    live =
      Stream.repeatedly(fn ->
        receive do
          {:conversation, ^id, :entry, e} -> e
          {:conversation, ^id, :ended, _} -> :ended
        after
          500 -> :timeout
        end
      end)
      |> Enum.take_while(&match?(%ConversationEntry{}, &1))
      |> Enum.filter(&(&1.seq > last_seq))

    seen = window ++ live
    {:ok, saved, :eof} = ConversationFile.page(ConversationFile.resolve(root, ref.path), 0, 1000)
    assert Enum.map(seen, & &1.seq) == Enum.map(saved, & &1.seq) |> Enum.take(length(seen))
    assert Enum.map(seen, & &1.seq) == Enum.to_list(0..(length(seen) - 1))
    # the :end entry is written after the last broadcast frame we collected
    assert length(saved) - length(seen) <= 1
  end

  test "SC-008: every masked env value is absent from the window, broadcast and file",
       %{identity: identity, request: request, root: root} do
    secrets = %{
      "GH_TOKEN" => "ghp_supersecret1234",
      "CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat-secretsecret"
    }

    Enum.each(secrets, fn {k, v} -> System.put_env(k, v) end)
    on_exit(fn -> Enum.each(secrets, fn {k, _} -> System.delete_env(k) end) end)

    {:ok, handle, _} = Conversation.open(identity, request)
    id = handle.conversation_id
    Conversation.subscribe(id)

    echo = Enum.join(Map.values(secrets), " | ")

    send(
      handle.pid,
      {:frame,
       FakeSdk.frame(:user, %{
         "message" => %{
           "content" => [
             %{
               "type" => "tool_result",
               "tool_use_id" => "t",
               "content" => echo,
               "is_error" => false
             }
           ]
         }
       })}
    )

    ref = Conversation.close(handle, ok_result())

    assert_receive {:conversation, ^id, :entry, %{kind: :tool_result} = e}
    refute inspect(e) =~ "supersecret"
    refute inspect(e) =~ "secretsecret"
    assert e.body["output"] =~ "[masked:GH_TOKEN]"

    contents = File.read!(ConversationFile.resolve(root, ref.path))
    for v <- Map.values(secrets), do: refute(contents =~ v)
    assert contents =~ "[masked:CLAUDE_CODE_OAUTH_TOKEN]"
  end

  test "killing the recorder yields a :partial ref and never raises", %{
    identity: identity,
    request: request,
    root: root
  } do
    {:ok, handle, _} = Conversation.open(identity, request)
    send(handle.pid, {:frame, frame("x")})
    wait_for_entries(handle, 3)
    ref = Process.monitor(handle.pid)
    Process.exit(handle.pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}

    assert %ConversationRef{status: :partial, reason: :recorder_down, outcome: :completed} =
             closed = Conversation.close(handle, ok_result())

    assert closed.path =~ "conversations/r000001/001/"
    # the file holds what was written, with no :end entry
    {:ok, entries, :eof} =
      ConversationFile.page(ConversationFile.resolve(root, closed.path), 0, 100)

    refute Enum.any?(entries, &(&1.kind == :end))
  end

  test "unwritable transcript root → :not_captured and the request is unchanged", %{
    identity: identity,
    request: request,
    root: root
  } do
    blocker = Path.join(root, "blocker")
    File.write!(blocker, "a file, not a dir")
    identity = %{identity | transcript_root: blocker}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:not_captured,
                %ConversationRef{status: :not_captured, reason: {:open_failed, _}} = ref, req} =
                 Conversation.open(identity, request)

        assert req == request
        assert Conversation.close({:not_captured, ref}, ok_result()) == ref
      end)

    assert log =~ "not fully captured"
  end

  test "bad identity and nil identity do not capture", %{request: request} do
    assert {:not_captured, %ConversationRef{reason: {:open_failed, {:bad_identity, :run_id}}},
            ^request} =
             Conversation.open(
               %ConversationIdentity{
                 run_id: "",
                 feature_id: "1",
                 phase: :a,
                 ordinal: 1,
                 transcript_root: "/x"
               },
               request
             )

    assert {:not_captured, nil, ^request} = Conversation.open(nil, request)
  end

  test "a file write error marks :partial while window and broadcast continue", %{
    identity: identity,
    request: request
  } do
    {:ok, handle, _} = Conversation.open(identity, request)
    id = handle.conversation_id
    Conversation.subscribe(id)
    # sabotage: close the file device under the recorder
    %{handle: %{io: io}} = :sys.get_state(handle.pid)
    File.close(io)

    send(handle.pid, {:frame, frame("after failure")})
    assert_receive {:conversation, ^id, :entry, %{kind: :assistant_text}}
    assert {:ok, entries, _, _} = Conversation.catch_up(id)
    assert Enum.any?(entries, &(&1.kind == :assistant_text))

    assert %ConversationRef{status: :partial, reason: {:write_failed, _}} =
             Conversation.close(handle, ok_result())
  end

  test "two overlapping sessions never cross entries", %{identity: identity, request: request} do
    {:ok, a, _} = Conversation.open(identity, request)
    {:ok, b, _} = Conversation.open(%{identity | feature_id: "002"}, request)
    send(a.pid, {:frame, frame("from A")})
    send(b.pid, {:frame, frame("from B")})
    ea = wait_for_entries(a, 3)
    eb = wait_for_entries(b, 3)
    assert Enum.any?(ea, &(&1.body["text"] == "from A"))
    refute Enum.any?(ea, &(&1.body["text"] == "from B"))
    assert Enum.any?(eb, &(&1.body["text"] == "from B"))
    assert a.conversation_id != b.conversation_id
    Conversation.close(a, ok_result())
    Conversation.close(b, ok_result())
  end

  test "a viewer that joins later (console restart) still gets the window", %{
    identity: identity,
    request: request
  } do
    {:ok, handle, _} = Conversation.open(identity, request)
    send(handle.pid, {:frame, frame("early")})
    wait_for_entries(handle, 3)

    task = Task.async(fn -> Conversation.catch_up(handle.conversation_id) end)
    assert {:ok, entries, _, _} = Task.await(task)
    assert Enum.any?(entries, &(&1.body["text"] == "early"))
    Conversation.close(handle, ok_result())
  end

  describe "stderr capture (feature 043)" do
    defp put_env!(key, value) do
      prev = Application.fetch_env(:autonomous, key)
      Application.put_env(:autonomous, key, value)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:autonomous, key, v)
          :error -> Application.delete_env(:autonomous, key)
        end
      end)
    end

    defp saved(root, ref) do
      {:ok, entries, :eof} =
        ConversationFile.page(ConversationFile.resolve(root, ref.path), 0, 100_000)

      entries
    end

    test "stderr lines interleave with frames in mailbox order",
         %{identity: identity, request: request, root: root} do
      {:ok, handle, _} = Conversation.open(identity, request)
      send(handle.pid, {:stderr, "warn one"})
      send(handle.pid, {:frame, frame("hello")})
      send(handle.pid, {:stderr, "warn two"})
      ref = Conversation.close(handle, ok_result())

      entries = saved(root, ref)

      assert Enum.map(entries, & &1.kind) ==
               [:start, :prompt, :stderr, :assistant_text, :stderr, :end]

      assert Enum.map(Enum.filter(entries, &(&1.kind == :stderr)), & &1.body["line"]) ==
               ["warn one", "warn two"]
    end

    test "credentials are masked in stderr lines and in a synthetic result's error",
         %{identity: identity, request: request, root: root} do
      System.put_env("GH_TOKEN", "ghp_supersecret1234")
      on_exit(fn -> System.delete_env("GH_TOKEN") end)

      {:ok, handle, _} = Conversation.open(identity, request)
      send(handle.pid, {:stderr, "auth failed ghp_supersecret1234"})

      send(
        handle.pid,
        {:frame, ClaudeAgentSDK.Message.error_result("exit with ghp_supersecret1234")}
      )

      ref = Conversation.close(handle, ok_result())
      contents = File.read!(ConversationFile.resolve(root, ref.path))
      refute contents =~ "supersecret"
      assert contents =~ "[masked:GH_TOKEN]"
    end

    test "a burst past head + tail records head, one notice, tail, then :end",
         %{identity: identity, request: request, root: root} do
      put_env!(:conversation_stderr_head, 2)
      put_env!(:conversation_stderr_tail, 3)

      {:ok, handle, _} = Conversation.open(identity, request)
      for i <- 1..10, do: send(handle.pid, {:stderr, "l#{i}"})
      ref = Conversation.close(handle, ok_result())

      entries = saved(root, ref)
      stderr = Enum.filter(entries, &(&1.kind == :stderr))

      assert Enum.map(stderr, & &1.body) == [
               %{"line" => "l1"},
               %{"line" => "l2"},
               %{"notice" => "dropped", "dropped" => 5},
               %{"line" => "l8"},
               %{"line" => "l9"},
               %{"line" => "l10"}
             ]

      assert List.last(entries).kind == :end
      assert ref.status == :captured
    end

    test "at or under the cap there is no notice",
         %{identity: identity, request: request, root: root} do
      put_env!(:conversation_stderr_head, 2)
      put_env!(:conversation_stderr_tail, 3)

      {:ok, handle, _} = Conversation.open(identity, request)
      for i <- 1..5, do: send(handle.pid, {:stderr, "l#{i}"})
      ref = Conversation.close(handle, ok_result())

      stderr = root |> saved(ref) |> Enum.filter(&(&1.kind == :stderr))
      assert length(stderr) == 5
      refute Enum.any?(stderr, &Map.has_key?(&1.body, "notice"))
    end

    test "a startup failure with stderr only (no frames) is recorded",
         %{identity: identity, request: request, root: root} do
      {:ok, handle, _} = Conversation.open(identity, request)
      send(handle.pid, {:stderr, "Error: cannot read ~/.claude.json"})
      ref = Conversation.close(handle, ok_result())

      assert Enum.map(saved(root, ref), & &1.kind) == [:start, :prompt, :stderr, :end]
    end

    test "a stderr message sent after close is a harmless no-op",
         %{identity: identity, request: request} do
      {:ok, handle, _} = Conversation.open(identity, request)
      Conversation.close(handle, ok_result())
      assert send(handle.pid, {:stderr, "late"}) == {:stderr, "late"}
    end

    test "a fault while processing stderr degrades capture, never crashes",
         %{identity: identity, request: request} do
      {:ok, handle, _} = Conversation.open(identity, request)
      send(handle.pid, {:stderr, :not_a_binary})
      assert Process.alive?(handle.pid)
      ref = Conversation.close(handle, ok_result())
      assert ref.status == :partial
    end

    test "SC-006: a 100,000-line flood keeps 2,000 lines + one notice, frames and end intact",
         %{identity: identity, request: request, root: root} do
      {:ok, handle, _} = Conversation.open(identity, request)
      pid = handle.pid

      sender =
        Task.async(fn ->
          for i <- 1..100_000 do
            if rem(i, 25_000) == 0, do: send(pid, {:frame, frame("f#{i}")})
            send(pid, {:stderr, "line #{i}"})
          end

          :sent
        end)

      assert Task.await(sender, 30_000) == :sent
      {us, ref} = :timer.tc(fn -> Conversation.close(handle, ok_result()) end)
      assert us < 30_000_000
      assert ref.status == :captured

      entries = saved(root, ref)
      stderr = Enum.filter(entries, &(&1.kind == :stderr))
      lines = for %{body: %{"line" => l}} <- stderr, do: l
      assert length(lines) == 2000
      assert hd(lines) == "line 1"
      assert Enum.at(lines, 999) == "line 1000"
      assert Enum.at(lines, 1000) == "line 99001"
      assert List.last(lines) == "line 100000"

      assert [%{body: %{"dropped" => 98_000}}] =
               Enum.filter(stderr, &Map.has_key?(&1.body, "notice"))

      assert List.last(entries).kind == :end
      assert Enum.count(entries, &(&1.kind == :assistant_text)) == 4
    end
  end

  test "close/2 returns the pre-043 ConversationRef shape after usage, stderr and an error result",
       %{identity: identity, request: request} do
    {:ok, handle, _} = Conversation.open(identity, request)

    send(
      handle.pid,
      {:frame,
       FakeSdk.frame(:stream_event, %{
         "event" => %{"type" => "message_delta", "usage" => %{"output_tokens" => 5}}
       })}
    )

    send(handle.pid, {:stderr, "x"})
    send(handle.pid, {:frame, ClaudeAgentSDK.Message.error_result("CLI exited 1")})
    ref = Conversation.close(handle, ok_result())

    assert Map.keys(ref) |> Enum.sort() ==
             Map.keys(%ConversationRef{}) |> Enum.sort()

    assert ref.status in [:captured, :partial, :not_captured]
  end
end
