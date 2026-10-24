defmodule Autonomous.ContainerEngineCliTest do
  @moduledoc "Runs the real `scripts/autonomous` against a stub `docker` (feature 046, contracts/wrapper-cli.md)."
  use ExUnit.Case, async: true

  alias Autonomous.StubDocker

  @wrapper Path.expand("../../scripts/autonomous", __DIR__)
  @segment "t-1a2b"
  @project "autonomous-#{@segment}"
  @files "-f compose.yaml -f compose.engine.yaml"

  defp setup_env(opts \\ []) do
    base = Path.join(System.tmp_dir!(), "engine_cli_#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    xdg = Path.join(base, "xdg")
    repo = Path.join(base, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(xdg)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])
    on_exit(fn -> File.rm_rf!(base) end)

    docker = StubDocker.install(base, opts)
    %{base: base, home: home, xdg: xdg, repo: repo, docker: docker}
  end

  defp run(ctx, args, extra_env \\ []) do
    env =
      [
        {"PATH", ctx.docker.bin <> ":" <> System.get_env("PATH")},
        {"HOME", ctx.home},
        {"XDG_CONFIG_HOME", ctx.xdg},
        {"AUTONOMOUS_START_TIMEOUT", "1"}
      ] ++ extra_env

    System.cmd("sh", [@wrapper | args], env: env, stderr_to_stdout: true)
  end

  defp argvs(ctx), do: StubDocker.argvs(ctx.docker)

  defp index(argvs, fragment), do: Enum.find_index(argvs, &String.contains?(&1, fragment))

  describe "build" do
    test "--docker passes WITH_DOCKER=1, adds the engine overlay and also builds the engine image" do
      ctx = setup_env()
      assert {_, 0} = run(ctx, ["build", "--docker"])

      assert argvs(ctx) == [
               "compose -p autonomous-bootstrap #{@files} build dev engine"
             ]

      assert StubDocker.calls(ctx.docker) =~ "env WITH_DOCKER=[1] SEGMENT=[bootstrap]"
    end

    test "--docker --release builds both agent images and the engine" do
      ctx = setup_env()
      assert {_, 0} = run(ctx, ["build", "--release", "--docker"])
      assert ["compose -p autonomous-bootstrap " <> rest] = argvs(ctx)
      assert rest =~ "build dev release engine"
    end

    test "without --docker the call is exactly the pre-046 one and WITH_DOCKER is unset" do
      ctx = setup_env()
      assert {_, 0} = run(ctx, ["build"])
      assert argvs(ctx) == ["compose -p autonomous-bootstrap -f compose.yaml build dev"]
      assert StubDocker.calls(ctx.docker) =~ "env WITH_DOCKER=[] SEGMENT=[]"
      refute StubDocker.calls(ctx.docker) =~ "engine"
    end

    test "Compose older than 2.24.4 refuses --docker with exit 3" do
      ctx = setup_env(compose_version: "2.20.0")
      assert {out, 3} = run(ctx, ["build", "--docker"])
      assert out =~ "2.24.4"
      assert argvs(ctx) == []
    end

    test "a development Compose version string (v2.36.0-desktop.1) is accepted" do
      ctx = setup_env(compose_version: "v2.36.0-desktop.1")
      assert {_, 0} = run(ctx, ["build", "--docker"])
    end
  end

  describe "option parsing" do
    test "--docker is an unknown option on commands other than build/shell/console/release" do
      for cmd <- ~w(stop port viewer remote volumes reset-cache) do
        ctx = setup_env()
        assert {out, 2} = run(ctx, [cmd, "--docker"])
        assert out =~ "unknown option '--docker'"
        assert argvs(ctx) == []
      end
    end

    test "--engine is an unknown option anywhere but reset-cache" do
      for cmd <- ~w(build shell console release stop port viewer) do
        ctx = setup_env()
        assert {out, 2} = run(ctx, [cmd, "--engine"])
        assert out =~ "unknown option '--engine'"
        assert argvs(ctx) == []
      end
    end

    test "usage lists --docker and --engine and the new exit codes' options" do
      ctx = setup_env()
      assert {out, 2} = run(ctx, ["help"])
      assert out =~ "--docker"
      assert out =~ "--engine"
    end
  end

  describe "console --docker start sequence" do
    defp console(ctx, extra \\ [], env \\ []),
      do: run(ctx, ["console", "--target", ctx.repo] ++ extra, env)

    test "preconditions, then the sidecar alone, then the agent, with the overlay only after the identity lookup" do
      ctx =
        setup_env(agent_exit: 78, agent_logs: "autonomous: the container engine did not answer")

      assert {_, 78} = console(ctx, ["--docker"])
      a = argvs(ctx)

      identity = index(a, " identity")
      refute Enum.at(a, identity) =~ "compose.engine.yaml"

      engine_image = index(a, "image inspect autonomous-engine:local")
      client = index(a, "run --rm --entrypoint sh autonomous-dev:local -c")

      sidecar =
        index(a, "#{@files} up -d --no-build --pull never --wait --wait-timeout 60 engine")

      agent = index(a, "#{@files} up -d --no-build --pull never console")

      assert engine_image && client && sidecar && agent
      assert engine_image < sidecar and client < sidecar and sidecar < agent

      assert Enum.at(a, client) =~
               "command -v docker && docker compose version && docker buildx version"
    end

    test "AUTONOMOUS_ENGINE_TIMEOUT is the --wait-timeout bound" do
      ctx = setup_env(agent_exit: 78)
      console(ctx, ["--docker"], [{"AUTONOMOUS_ENGINE_TIMEOUT", "7"}])
      assert Enum.any?(argvs(ctx), &(&1 =~ "--wait --wait-timeout 7 engine"))
    end

    test "the instance segment reaches Compose for the storage-volume label" do
      ctx = setup_env(agent_exit: 78)
      console(ctx, ["--docker"])
      assert StubDocker.calls(ctx.docker) =~ "SEGMENT=[#{@segment}]"
    end

    test "an image without the docker client is refused with 5 before any container or volume" do
      ctx = setup_env(client: 1)
      assert {out, 5} = console(ctx, ["--docker"])
      assert out =~ "no docker client"
      assert out =~ "build --docker"
      a = argvs(ctx)
      refute Enum.any?(a, &(&1 =~ " up "))
      refute Enum.any?(a, &(&1 =~ "volume create"))
    end

    test "a missing engine image is refused with 5 before any container or volume" do
      ctx = setup_env(missing_images: ["autonomous-engine:local"])
      assert {out, 5} = console(ctx, ["--docker"])
      assert out =~ "autonomous-engine:local not found"
      refute Enum.any?(argvs(ctx), &(&1 =~ " up "))
    end

    test "Compose older than 2.24.4 is refused with 3 before any docker call" do
      ctx = setup_env(compose_version: "2.20.0")
      assert {out, 3} = console(ctx, ["--docker"])
      assert out =~ "2.24.4"
      assert argvs(ctx) == []
    end

    test "a sidecar the host refuses to run privileged is removed and refused with 77" do
      ctx =
        setup_env(engine_up: {1, "Error response from daemon: privileged mode is forbidden"})

      assert {out, 77} = console(ctx, ["--docker"])
      assert out =~ "privileged container"
      assert out =~ "Docker Desktop"
      a = argvs(ctx)
      up = index(a, " up -d --no-build --pull never --wait")
      rm = index(a, "#{@files} rm -sf engine")
      assert up && rm && up < rm
      refute Enum.any?(a, &(&1 =~ "up -d --no-build --pull never console"))
    end

    test "'operation not permitted' in the engine logs also classifies as 77" do
      ctx =
        setup_env(
          engine_up: {1, "container autonomous-t-1a2b-engine-1 is unhealthy"},
          engine_logs: "rootlesskit: operation not permitted"
        )

      assert {_, 77} = console(ctx, ["--docker"])
    end

    test "an engine that never becomes healthy is removed and refused with 78, naming the log and the remedy" do
      ctx =
        setup_env(
          engine_up: {1, "container autonomous-t-1a2b-engine-1 is unhealthy"},
          engine_logs: "dockerd: no space left on device"
        )

      assert {out, 78} = console(ctx, ["--docker"])
      assert out =~ "no space left on device"
      assert out =~ "within 60s"
      assert out =~ "reset-cache --target"
      assert out =~ "--engine"
      assert out =~ "AUTONOMOUS_ENGINE_TIMEOUT"
      a = argvs(ctx)
      assert index(a, "#{@files} rm -sf engine")
      refute Enum.any?(a, &(&1 =~ "up -d --no-build --pull never console"))
    end

    test "the sidecar failing on a busy console port keeps today's exit 76" do
      ctx = setup_env(engine_up: {1, "Bind for 127.0.0.1:4000 failed: port is already allocated"})
      assert {out, 76} = console(ctx, ["--docker"], [])
      assert out =~ "already in use"
      assert index(argvs(ctx), "rm -sf engine")
    end

    test "the agent exiting 78 after start tears the project down WITHOUT -v and passes the code through" do
      ctx =
        setup_env(
          agent_exit: 78,
          agent_logs: "autonomous: the container engine did not answer within 60s"
        )

      assert {out, 78} = console(ctx, ["--docker"])
      assert out =~ "did not answer"
      downs = Enum.filter(argvs(ctx), &(&1 =~ " down"))
      assert [down] = downs
      assert down =~ "compose -p #{@project} #{@files} down"
      refute down =~ "-v"
    end

    test "release --docker uses the release image and service" do
      ctx = setup_env(agent_exit: 78)
      run(ctx, ["release", "--target", ctx.repo, "--docker"])
      a = argvs(ctx)
      assert index(a, "image inspect autonomous-release:local")
      assert index(a, "run --rm --entrypoint sh autonomous-release:local -c")
      assert index(a, "#{@files} up -d --no-build --pull never release")
    end

    test "--viewer with --docker swaps in the engine viewer overlay" do
      ctx = setup_env(agent_exit: 78)
      console(ctx, ["--docker", "--viewer"])
      up = Enum.find(argvs(ctx), &(&1 =~ "--wait-timeout"))
      assert up =~ "-f compose.engine.yaml -f compose.engine-viewer.yaml"
      refute Enum.any?(argvs(ctx), &(&1 =~ "compose.desktop-viewer.yaml" and &1 =~ " up "))
    end
  end

  describe "console without --docker is unchanged" do
    test "no engine image check, no client check, no overlay, no --wait, no sidecar teardown" do
      ctx = setup_env(agent_exit: 78)
      assert {_, 78} = console(ctx)
      a = argvs(ctx)

      assert Enum.any?(
               a,
               &(&1 ==
                   "compose -p #{@project} -f compose.yaml up -d --no-build --pull never console")
             )

      refute Enum.any?(a, &(&1 =~ "engine"))
      refute Enum.any?(a, &(&1 =~ "command -v docker"))
      refute Enum.any?(a, &(&1 =~ " down"))
      refute Enum.any?(a, &(&1 =~ "--wait"))
      refute StubDocker.calls(ctx.docker) =~ "WITH_DOCKER=[1]"
    end

    test "--viewer still adds the desktop viewer overlay" do
      ctx = setup_env(agent_exit: 78)
      console(ctx, ["--viewer"])

      assert Enum.any?(
               argvs(ctx),
               &(&1 =~ "-f compose.yaml -f compose.desktop-viewer.yaml up -d")
             )
    end
  end

  describe "shell --docker" do
    test "starts the sidecar, runs the session without exec, and removes the sidecar afterwards" do
      ctx = setup_env()
      assert {_, 0} = run(ctx, ["shell", "--target", ctx.repo, "--docker"])
      a = argvs(ctx)

      sidecar = index(a, "--wait --wait-timeout 60 engine")
      session = index(a, "#{@files} run --rm -T dev shell")
      removed = index(a, "#{@files} rm -sf engine")

      assert sidecar && session && removed
      assert sidecar < session and session < removed
      refute Enum.at(a, session) =~ "--service-ports"
    end

    test "a refused sidecar never reaches the session and is still removed" do
      ctx = setup_env(engine_up: {1, "privileged mode is forbidden"})
      assert {_, 77} = run(ctx, ["shell", "--target", ctx.repo, "--docker"])
      a = argvs(ctx)
      assert index(a, "rm -sf engine")
      refute index(a, " run --rm -T dev shell")
    end

    test "without --docker the session is the pre-046 foreground run with --service-ports" do
      ctx = setup_env()
      assert {_, 0} = run(ctx, ["shell", "--target", ctx.repo])
      a = argvs(ctx)

      assert index(
               a,
               "compose -p #{@project} -f compose.yaml run --rm --service-ports -T dev shell"
             )

      refute Enum.any?(a, &(&1 =~ "engine"))
    end
  end

  describe "port and viewer" do
    test "print the first published mapping across the project's containers" do
      ctx =
        setup_env(
          containers: ["cid-agent", "cid-engine"],
          published: %{"cid-engine" => "127.0.0.1:49153"}
        )

      assert {out, 0} = run(ctx, ["port", "--target", ctx.repo])
      assert out =~ "console  http://127.0.0.1:49153/"
    end

    test "a single container's output is unchanged" do
      ctx = setup_env(containers: ["cid-one"], published: %{"cid-one" => "127.0.0.1:50000"})
      assert {out, 0} = run(ctx, ["port", "--target", ctx.repo])
      assert out =~ "console  http://127.0.0.1:50000/"
    end

    test "viewer looks through every container too" do
      ctx =
        setup_env(
          containers: ["cid-agent", "cid-engine"],
          published: %{"cid-engine" => "127.0.0.1:6080"}
        )

      assert {out, 0} = run(ctx, ["viewer", "--target", ctx.repo])
      assert out =~ "viewer   http://127.0.0.1:6080/vnc.html"
    end

    test "no running container, and no published port, keep their messages" do
      ctx = setup_env(containers: [])
      assert {out, 1} = run(ctx, ["port", "--target", ctx.repo])
      assert out =~ "no running instance for"

      ctx = setup_env(containers: ["cid-agent"])
      assert {out, 1} = run(ctx, ["port", "--target", ctx.repo])
      assert out =~ "publishes no console port"
    end
  end

  describe "stop with the engine sidecar" do
    defp stop(ctx, extra \\ []), do: run(ctx, ["stop", "--target", ctx.repo] ++ extra)

    defp down_calls(ctx), do: Enum.filter(argvs(ctx), &String.contains?(&1, " down"))

    test "adds the engine overlay to down only when an engine container exists" do
      ctx = setup_env(engine_ps: ["autonomous-t-1a2b-engine-1"])
      assert {_, 0} = stop(ctx)
      assert down_calls(ctx) == ["compose -p #{@project} #{@files} down"]
      assert StubDocker.calls(ctx.docker) =~ "SEGMENT=[#{@segment}]"
      assert Enum.any?(argvs(ctx), &(&1 =~ "service=engine"))
    end

    test "no engine container: down is exactly the pre-046 call" do
      ctx = setup_env()
      assert {_, 0} = stop(ctx)
      assert down_calls(ctx) == ["compose -p #{@project} -f compose.yaml down"]
      refute Enum.any?(argvs(ctx), &(&1 =~ "compose.engine.yaml"))
    end

    test "stop --purge also removes the labelled engine storage volume, naming it" do
      ctx = setup_env(engine_ps: ["e"], engine_ls: ["autonomous-t-1a2b_autonomous-engine"])
      assert {out, 0} = stop(ctx, ["--purge"])
      assert out =~ "autonomous-t-1a2b_autonomous-engine removed"

      assert Enum.any?(
               argvs(ctx),
               &(&1 =~ "volume ls" and &1 =~ "label=dev.autonomous.kind=engine-storage" and
                   &1 =~ "label=dev.autonomous.segment=#{@segment}")
             )

      assert "volume rm autonomous-t-1a2b_autonomous-engine" in argvs(ctx)
      assert down_calls(ctx) == ["compose -p #{@project} #{@files} down -v"]
    end

    test "plain stop never removes the engine storage" do
      ctx = setup_env(engine_ps: ["e"], engine_ls: ["autonomous-t-1a2b_autonomous-engine"])
      assert {_, 0} = stop(ctx)
      refute Enum.any?(argvs(ctx), &String.starts_with?(&1, "volume rm"))
    end
  end

  describe "reset-cache --engine" do
    defp reset(ctx, extra), do: run(ctx, ["reset-cache", "--target", ctx.repo] ++ extra)

    test "refuses 75 while any project container exists" do
      ctx = setup_env(containers: ["autonomous-t-1a2b-console-1"])
      assert {out, 75} = reset(ctx, ["--engine"])
      assert out =~ "stop it first"
      refute Enum.any?(argvs(ctx), &String.starts_with?(&1, "volume rm"))
    end

    test "absent storage prints a message and exits 0" do
      ctx = setup_env()
      assert {out, 0} = reset(ctx, ["--engine"])
      assert out =~ "engine storage not present"
    end

    test "removes only the engine storage volume" do
      ctx = setup_env(engine_ls: ["autonomous-t-1a2b_autonomous-engine"])
      assert {out, 0} = reset(ctx, ["--engine"])
      assert out =~ "engine storage removed"

      assert ["volume rm autonomous-t-1a2b_autonomous-engine"] =
               Enum.filter(argvs(ctx), &String.starts_with?(&1, "volume rm"))
    end

    test "a removal failure exits 1" do
      ctx = setup_env(engine_ls: ["v"], volume_rm_exit: 1)
      assert {out, 1} = reset(ctx, ["--engine"])
      assert out =~ "could not remove volume v"
    end

    test "combines with --volume: both are handled, declared volumes via the declaration" do
      ctx = setup_env(engine_ls: ["autonomous-t-1a2b_autonomous-engine"])
      decl = Path.join([ctx.xdg, "autonomous", "targets", "t-1a2b", "volumes.toml"])
      File.mkdir_p!(Path.dirname(decl))

      File.write!(decl, """
      [[volume]]
      name = "cache"
      path = "/var/lib/autonomous/volumes/cache"
      """)

      assert {out, _rc} = reset(ctx, ["--engine", "--volume", "cache"])
      assert out =~ "engine storage removed"
      assert out =~ "cache not present"
    end

    test "without --engine the command is the pre-046 one (no engine-storage lookup)" do
      ctx = setup_env()
      assert {out, 0} = reset(ctx, [])
      assert out =~ "no declared volumes"
      refute Enum.any?(argvs(ctx), &(&1 =~ "engine-storage"))
    end
  end
end
