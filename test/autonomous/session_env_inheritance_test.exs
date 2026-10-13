defmodule Autonomous.SessionEnvInheritanceTest do
  @moduledoc """
  Feature 041, FR-014: variables and the `PATH` prefix set on the container reach
  every agent session by inheritance. The launch env must neither set nor clear
  them; a `jido_claude`/`claude_agent_sdk` bump that starts clearing the
  environment fails here.
  """
  # Mutates the process environment.
  use ExUnit.Case, async: false

  alias Autonomous.{Feature, PhaseRequest, SdkProxy}
  alias CliSubprocessCore.Command, as: CoreCommand

  @declared "CARGO_TARGET_DIR"
  @prefixed_path "/var/lib/autonomous/volumes/rust/cargo/bin:" <> (System.get_env("PATH") || "/usr/bin")

  setup do
    previous = %{@declared => System.get_env(@declared), "PATH" => System.get_env("PATH")}
    System.put_env(@declared, "/var/lib/autonomous/volumes/cargo-target")
    System.put_env("PATH", @prefixed_path)

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)
  end

  defp feature do
    %Feature{id: "001", number: 1, slug: "core-ledger", path: "/abs/docs/breakdown/001-core-ledger.md"}
  end

  # Every request builder a session goes through: phase, implement chunk,
  # remediation / auto-remediation, PR describe.
  defp requests do
    [
      PhaseRequest.build(feature(), :plan),
      PhaseRequest.build(feature(), :implement),
      PhaseRequest.build_remediation(feature(), "sonnet", prompt: "fix it"),
      PhaseRequest.build(feature(), :describe)
    ]
  end

  defp launch_env(request) do
    options =
      %ClaudeAgentSDK.Options{env: request.metadata["claude"][:env], cwd: request.cwd}
      |> SdkProxy.prepare()

    ClaudeAgentSDK.Process.__env_vars__(options)
  end

  test "no request builder sets or overrides the declared variable or PATH" do
    for request <- requests() do
      env = request.metadata["claude"][:env]
      refute Map.has_key?(env, @declared)
      refute Map.has_key?(env, "PATH")
    end
  end

  test "the SDK launch env passes the prefixed PATH through and leaves the variable to inheritance" do
    for request <- requests() do
      env = launch_env(request)
      assert env["PATH"] == @prefixed_path
      refute Map.has_key?(env, @declared)
    end
  end

  test "the subprocess command does not clear the inherited environment" do
    for request <- requests() do
      command = CoreCommand.new("claude", ["--version"], cwd: request.cwd, env: launch_env(request))
      assert command.clear_env? == false
    end
  end

  test "the SDK and adapter never ask for a cleared environment" do
    for dir <- ["deps/claude_agent_sdk/lib", "deps/jido_claude/lib"] do
      hits =
        Path.wildcard(Path.join([dir, "**", "*.ex"]))
        |> Enum.filter(&(File.read!(&1) =~ "clear_env"))

      assert hits == [], "#{dir} now references clear_env: #{inspect(hits)}"
    end
  end
end
