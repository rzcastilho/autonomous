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

  describe "cleanup/1 (feature 046)" do
    test "not advertised: :skipped with zero CLI calls" do
      cli = StubEngineCli.new(&empty/1)
      assert :skipped = ContainerEngine.cleanup(cli: cli, advertised?: false)
      assert [] = StubEngineCli.calls(cli)
    end

    test "empty listings: :clean, in the contract's command order, never touching images or cache" do
      cli = StubEngineCli.new(&empty/1)
      assert :clean = ContainerEngine.cleanup(cli: cli, advertised?: true)

      assert [
               ["ps", "-aq"],
               ["network", "prune", "-f"],
               ["volume", "prune", "-af"],
               ["ps", "-aq"],
               ["network", "ls", "-q", "--filter", "type=custom"],
               ["volume", "ls", "-q"]
             ] = StubEngineCli.calls(cli)
    end

    test "containers found: rm -f -v <ids> comes after the listing, before the prunes" do
      {:ok, state} = Agent.start_link(fn -> :before end)

      cli =
        StubEngineCli.new(fn
          ["ps", "-aq"] ->
            {:ok, if(Agent.get(state, & &1) == :before, do: "aaa\nbbb\n", else: "")}

          ["rm", "-f", "-v", "aaa", "bbb"] ->
            Agent.update(state, fn _ -> :after end)
            {:ok, ""}

          args ->
            empty(args)
        end)

      assert :clean = ContainerEngine.cleanup(cli: cli, advertised?: true)

      assert [
               ["ps", "-aq"],
               ["rm", "-f", "-v", "aaa", "bbb"],
               ["network", "prune", "-f"],
               ["volume", "prune", "-af"] | _verify
             ] = StubEngineCli.calls(cli)
    end

    test "never sends image/builder/system prune or rmi" do
      cli =
        StubEngineCli.new(fn args ->
          if args == ["ps", "-aq"], do: {:ok, "x"}, else: {:ok, ""}
        end)

      ContainerEngine.cleanup(cli: cli, advertised?: true)

      for args <- StubEngineCli.calls(cli) do
        refute hd(args) in ["image", "builder", "system", "rmi"]
      end
    end

    test "verification finds leftovers: {:residue, counts, cause}" do
      cli =
        StubEngineCli.new(fn
          ["ps", "-aq"] -> {:ok, ""}
          ["network", "ls" | _] -> {:ok, "n1\nn2\n"}
          ["volume", "ls" | _] -> {:ok, "v1\n"}
          args -> empty(args)
        end)

      assert {:residue, %{containers: 0, networks: 2, volumes: 1},
              {:exit, :verify, 0, "resources remain after the sweep"}} =
               ContainerEngine.cleanup(cli: cli, advertised?: true)
    end

    test "a non-zero exit names its step; later steps still run" do
      for {step, failing} <- [
            list: ["ps", "-aq"],
            rm: ["rm", "-f", "-v", "c1"],
            network_prune: ["network", "prune", "-f"],
            volume_prune: ["volume", "prune", "-af"]
          ] do
        cli =
          StubEngineCli.new(fn
            args when args == failing -> {:error, {:exit, 1, "boom #{step}"}}
            ["ps", "-aq"] -> {:ok, "c1\n"}
            args -> empty(args)
          end)

        # `ps -aq` keeps listing c1, so the verification also reports a container
        # unless `ps` itself is the failing command.
        assert {:residue, _residue, {:exit, ^step, 1, "boom " <> _}} =
                 ContainerEngine.cleanup(cli: cli, advertised?: true)
      end
    end

    test "an unrunnable verification listing counts as unknown (-1)" do
      cli =
        StubEngineCli.new(fn
          ["volume", "ls" | _] -> {:error, {:exit, 1, "nope"}}
          args -> empty(args)
        end)

      assert {:residue, %{volumes: -1}, {:exit, :verify, 0, _}} =
               ContainerEngine.cleanup(cli: cli, advertised?: true)
    end

    test "a hung CLI is cut at the bound: :timeout with unknown counts" do
      cli = StubEngineCli.new(fn _ -> Process.sleep(:infinity) end)

      assert {:residue, %{containers: -1, networks: -1, volumes: -1}, :timeout} =
               ContainerEngine.cleanup(cli: cli, advertised?: true, timeout_ms: 200)
    end

    @tag capture_log: true
    test "a crashing CLI is a residue, never a raise" do
      cli = StubEngineCli.new(fn _ -> raise "boom" end)

      assert {:residue, %{containers: -1}, {:crash, _}} =
               ContainerEngine.cleanup(cli: cli, advertised?: true)
    end
  end

  describe "after_boundary/3 (feature 046)" do
    import ExUnit.CaptureLog

    @feature %Autonomous.Feature{id: "007", number: 7, slug: "x", path: "p"}

    setup do
      id = "engine-cleanup-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        id,
        [:speckit, :engine, :cleanup],
        fn _e, meas, meta, _ -> send(test, {:cleanup, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "not advertised: :ok, no log, no telemetry, zero CLI calls" do
      cli = StubEngineCli.new(&empty/1)

      log =
        capture_log([level: :debug], fn ->
          assert :ok =
                   ContainerEngine.after_boundary(@feature, :plan, cli: cli, advertised?: false)
        end)

      assert log == ""
      refute_received {:cleanup, _, _}
      assert [] = StubEngineCli.calls(cli)
    end

    test "clean: no error log, telemetry with result :clean" do
      cli = StubEngineCli.new(&empty/1)

      log =
        capture_log([level: :debug], fn ->
          assert :ok =
                   ContainerEngine.after_boundary(@feature, :plan, cli: cli, advertised?: true)
        end)

      refute log =~ "left"

      assert_received {:cleanup, %{duration: d},
                       %{feature_id: "007", phase: :plan, result: :clean}}

      assert is_integer(d)
    end

    test "residue: error log names feature, phase and counts; telemetry carries them" do
      cli =
        StubEngineCli.new(fn
          ["volume", "ls" | _] -> {:ok, "v1\nv2\n"}
          args -> empty(args)
        end)

      log =
        capture_log(fn ->
          assert :ok =
                   ContainerEngine.after_boundary(@feature, :implement,
                     cli: cli,
                     advertised?: true
                   )
        end)

      assert log =~ "feature 007 (implement) left 0 containers, 0 networks, 2 volumes"
      assert log =~ "images and build cache are kept"

      assert_received {:cleanup, _,
                       %{phase: :implement, result: :residue, residue: %{volumes: 2}}}
    end

    test "unknown counts render as \"unknown\"" do
      cli = StubEngineCli.new(fn _ -> Process.sleep(:infinity) end)

      log =
        capture_log(fn ->
          ContainerEngine.after_boundary(@feature, :analyze,
            cli: cli,
            advertised?: true,
            timeout_ms: 100
          )
        end)

      assert log =~ "left unknown containers, unknown networks, unknown volumes (timed out)"
    end
  end

  defp empty(["ps", "-aq"]), do: {:ok, ""}
  defp empty(["rm" | _]), do: {:ok, ""}
  defp empty(["network", "prune" | _]), do: {:ok, ""}
  defp empty(["volume", "prune" | _]), do: {:ok, ""}
  defp empty(["network", "ls" | _]), do: {:ok, ""}
  defp empty(["volume", "ls" | _]), do: {:ok, ""}
end
