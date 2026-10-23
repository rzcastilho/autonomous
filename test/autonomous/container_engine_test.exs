defmodule Autonomous.ContainerEngineTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ContainerEngine, StubEngineCli}

  describe "advertised?/1 and requested?/1 (feature 046)" do
    test "advertised? needs the container marker and the engine marker, both \"1\"" do
      on = %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_CONTAINER_ENGINE" => "1"}
      assert ContainerEngine.advertised?(on)
      refute ContainerEngine.advertised?(Map.delete(on, "AUTONOMOUS_CONTAINER"))
      refute ContainerEngine.advertised?(Map.delete(on, "AUTONOMOUS_CONTAINER_ENGINE"))
      refute ContainerEngine.advertised?(%{on | "AUTONOMOUS_CONTAINER_ENGINE" => "0"})
      refute ContainerEngine.advertised?(%{})
    end

    test "requested? needs the container marker and the REQUESTED marker" do
      on = %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_CONTAINER_ENGINE_REQUESTED" => "1"}
      assert ContainerEngine.requested?(on)
      refute ContainerEngine.requested?(Map.delete(on, "AUTONOMOUS_CONTAINER"))
      refute ContainerEngine.requested?(%{"AUTONOMOUS_CONTAINER" => "1"})
      refute ContainerEngine.requested?(%{})
    end

    test "an advertisement without a request, or the reverse, does not cross over" do
      only_adv = %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_CONTAINER_ENGINE" => "1"}
      refute ContainerEngine.requested?(only_adv)

      only_req = %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_CONTAINER_ENGINE_REQUESTED" => "1"}
      refute ContainerEngine.advertised?(only_req)
    end
  end

  describe "prompt_note/1" do
    test "\"\" when not advertised" do
      assert ContainerEngine.prompt_note(false) == ""
    end

    test "starts with a blank line and states the endpoint, staging and cleanup rules" do
      note = ContainerEngine.prompt_note(true)
      assert String.starts_with?(note, "\n\n")
      assert note =~ "DOCKER_HOST"
      assert note =~ "docker compose"
      assert note =~ "under the feature worktree"
      assert note =~ "removed when this phase ends"
      assert note =~ "Images\n  and build cache are kept"
    end
  end

  describe "probe/1" do
    test "ok: the trimmed server version, from `docker version --format`" do
      cli = StubEngineCli.new(fn _ -> {:ok, "29.9.2\n"} end)
      assert {:ok, "29.9.2"} = ContainerEngine.probe(cli: cli)
      assert [["version", "--format", "{{.Server.Version}}"]] = StubEngineCli.calls(cli)
    end

    test "error: the last line of the client's output is the cause" do
      cli =
        StubEngineCli.new(fn _ ->
          {:error,
           {:exit, 1, "Client: ok\nCannot connect to the Docker daemon at tcp://127.0.0.1:2375\n"}}
        end)

      assert {:error, "Cannot connect to the Docker daemon at tcp://127.0.0.1:2375"} =
               ContainerEngine.probe(cli: cli)
    end

    test "an answer without a version is an error, not an available engine" do
      cli = StubEngineCli.new(fn _ -> {:ok, "  \n"} end)
      assert {:error, "the engine answered without a version"} = ContainerEngine.probe(cli: cli)
    end

    test "timeout from the client (status 124) is named with the bound" do
      cli = StubEngineCli.new(fn _ -> {:error, {:exit, 124, "timed out"}} end)
      assert {:error, "the engine did not answer within 5s"} = ContainerEngine.probe(cli: cli)
    end

    test "a hung CLI is abandoned at the bound and reported as a timeout" do
      cli = StubEngineCli.new(fn _ -> Process.sleep(:infinity) end)

      assert {:error, "the engine did not answer within 1s"} =
               ContainerEngine.probe(cli: cli, timeout_ms: 1_000)
    end

    @tag capture_log: true
    test "a crashing CLI is an error, never a raise" do
      cli = StubEngineCli.new(fn _ -> raise "boom" end)
      assert {:error, "the engine probe crashed"} = ContainerEngine.probe(cli: cli)
    end
  end
end
