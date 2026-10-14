defmodule Autonomous.SdkProxyTest do
  use ExUnit.Case, async: false

  alias Autonomous.{FakeSdk, SdkProxy}

  setup do
    prev = Application.get_env(:autonomous, :sdk_proxy_inner)
    Application.put_env(:autonomous, :sdk_proxy_inner, FakeSdk)

    on_exit(fn ->
      FakeSdk.reset()

      if prev,
        do: Application.put_env(:autonomous, :sdk_proxy_inner, prev),
        else: Application.delete_env(:autonomous, :sdk_proxy_inner)
    end)
  end

  defp options(env), do: %ClaudeAgentSDK.Options{env: env}

  test "prepare/1 pops both markers so the CLI never sees them (FR-026)" do
    env = %{
      "KEEP" => "1",
      SdkProxy.env_key() => SdkProxy.encode(self()),
      SdkProxy.conversation_key() => SdkProxy.encode(self())
    }

    assert %{env: %{"KEEP" => "1"} = e} = SdkProxy.prepare(options(env))
    assert map_size(e) == 1
  end

  test "frames are forwarded unchanged and send/2ed to the recorder" do
    frames = FakeSdk.default_frames("s1")
    FakeSdk.configure(frames: frames)
    env = %{SdkProxy.conversation_key() => SdkProxy.encode(self())}

    assert Enum.to_list(SdkProxy.query("p", options(env))) == frames
    for f <- frames, do: assert_received({:frame, ^f})

    Enum.to_list(SdkProxy.resume("sid", "p", options(env)))
    assert_received {:frame, _}

    refute Map.has_key?(FakeSdk.last_options().env, SdkProxy.conversation_key())
  end

  test "no marker ⇒ stream returned untouched, nothing sent" do
    FakeSdk.configure(frames: FakeSdk.default_frames("s1"))
    assert length(Enum.to_list(SdkProxy.query("p", options(%{})))) == 5
    refute_received {:frame, _}
  end

  test "a dead recorder pid neither raises nor delays" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    FakeSdk.configure(frames: FakeSdk.default_frames("s1"))
    env = %{SdkProxy.conversation_key() => SdkProxy.encode(pid)}

    {us, frames} = :timer.tc(fn -> Enum.to_list(SdkProxy.query("p", options(env))) end)
    assert length(frames) == 5
    assert us < 500_000
  end

  test "the tap never awaits a recorder that does not read its mailbox" do
    stuck = spawn(fn -> Process.sleep(:infinity) end)
    FakeSdk.configure(frames: FakeSdk.default_frames("s1"))
    env = %{SdkProxy.conversation_key() => SdkProxy.encode(stuck)}
    assert length(Enum.to_list(SdkProxy.query("p", options(env)))) == 5
    Process.exit(stuck, :kill)
  end

  test "a garbage marker is ignored" do
    FakeSdk.configure(frames: FakeSdk.default_frames("s1"))
    env = %{SdkProxy.conversation_key() => "not a pid"}
    assert length(Enum.to_list(SdkProxy.query("p", options(env)))) == 5
  end

  describe "callback/2 (feature 043)" do
    import ExUnit.CaptureLog

    test "logs the line and sends {:stderr, line} to the recorder" do
      cb = SdkProxy.callback(nil, self())
      log = capture_log(fn -> assert cb.("boom") == :ok end)
      assert log =~ "CLI stderr: boom"
      assert_received {:stderr, "boom"}
    end

    test "still forwards untrusted-workspace lines to the collector" do
      collector = Autonomous.WorkspaceTrust.Collector.start()
      cb = SdkProxy.callback(collector, self())

      line = "Error: this workspace has not been trusted: /work/tree"
      capture_log(fn -> cb.(line) end)
      assert_received {:stderr, ^line}
      assert Autonomous.WorkspaceTrust.Collector.collect(collector) == [line]
    end

    test "nil or dead recorder is a no-op" do
      cb = SdkProxy.callback(nil, nil)
      capture_log(fn -> assert cb.("a") == :ok end)

      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}
      cb = SdkProxy.callback(nil, pid)
      capture_log(fn -> assert cb.("a") == :ok end)
    end

    test "callback/1 is unchanged and prepare/1 wires the recorder from the marker" do
      capture_log(fn -> assert SdkProxy.callback(nil).("x") == :ok end)
      refute_received {:stderr, _}

      env = %{SdkProxy.conversation_key() => SdkProxy.encode(self()), "KEEP" => "1"}
      %{env: e, stderr: cb} = SdkProxy.prepare(%ClaudeAgentSDK.Options{env: env})
      assert e == %{"KEEP" => "1"}
      capture_log(fn -> cb.("via prepare") end)
      assert_received {:stderr, "via prepare"}
    end
  end
end
