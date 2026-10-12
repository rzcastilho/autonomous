defmodule Autonomous.FakeSdk do
  @moduledoc """
  Scripted `:sdk_proxy_inner` for feature 040 tests (the SDK seam every session
  passes through). `configure/1` stores the script; `query/2` and `resume/3`
  return a stream of `%ClaudeAgentSDK.Message{}` frames.

  Options (`configure/1`): `:frames` (default `default_frames/1`), `:stall`
  (after the frames the stream blocks forever — a session that never ends),
  `:delay_ms` (sleep before each frame), `:last_options` is recorded for
  assertions via `last_options/0`.

  The `AUTONOMOUS_CONVERSATION` marker is stripped by `SdkProxy.prepare/1`
  *before* this module is called, so a missing tap shows up as a missing
  conversation (no recorder entries), not here.
  """

  alias ClaudeAgentSDK.Message

  @key :autonomous_fake_sdk

  def configure(opts), do: Application.put_env(:autonomous, @key, Map.new(opts))
  def reset, do: Application.delete_env(:autonomous, @key)
  def last_options, do: Application.get_env(:autonomous, :autonomous_fake_sdk_last)

  def query(_prompt, options), do: stream(options)
  def resume(_session_id, _prompt, options), do: stream(options)

  defp stream(options) do
    Application.put_env(:autonomous, :autonomous_fake_sdk_last, options)
    cfg = Application.get_env(:autonomous, @key, %{})
    frames = Map.get_lazy(cfg, :frames, fn -> default_frames("sess-fake") end)
    delay = Map.get(cfg, :delay_ms, 0)

    base =
      Stream.map(frames, fn f ->
        if delay > 0, do: Process.sleep(delay)
        f
      end)

    if Map.get(cfg, :stall, false) do
      Stream.concat(base, Stream.repeatedly(fn -> Process.sleep(:infinity) end))
    else
      base
    end
  end

  def frame(type, raw, subtype \\ nil),
    do: %Message{
      type: type,
      subtype: subtype,
      data: %{},
      raw: Map.put(raw, "type", Atom.to_string(type))
    }

  def default_frames(session_id) do
    [
      frame(
        :system,
        %{"subtype" => "init", "session_id" => session_id, "model" => "fake"},
        :init
      ),
      frame(:assistant, %{
        "session_id" => session_id,
        "message" => %{"id" => "msg_1", "content" => [%{"type" => "text", "text" => "working"}]}
      }),
      frame(:assistant, %{
        "session_id" => session_id,
        "message" => %{
          "id" => "msg_2",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "Bash",
              "input" => %{"command" => "ls"}
            }
          ]
        }
      }),
      frame(:user, %{
        "session_id" => session_id,
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_1",
              "content" => "a.txt",
              "is_error" => false
            }
          ]
        }
      }),
      frame(
        :result,
        %{
          "subtype" => "success",
          "session_id" => session_id,
          "result" => "done",
          "num_turns" => 2,
          "duration_ms" => 5,
          "total_cost_usd" => 0.01,
          "is_error" => false
        },
        :success
      )
    ]
  end
end
