defmodule Autonomous.ContainerEngineStepTest do
  @moduledoc "Runs the real `container-entrypoint.sh container-engine` step with a stub `docker` (feature 046)."
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../scripts/container-entrypoint.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "engine_step_#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, bin: bin, log: Path.join(base, "docker.log")}
  end

  # A stub `docker`: `version` answers (or fails), `ps -aq` lists `ids`, `rm` /
  # `network prune` / `volume prune` succeed or fail per `sweep`. Every call is logged.
  defp stub_docker(ctx, opts) do
    version = Keyword.get(opts, :version, "29.9.2")
    ids = Keyword.get(opts, :ids, "")
    sweep_exit = Keyword.get(opts, :sweep_exit, 0)
    file = Path.join(ctx.bin, "docker")

    version_clause =
      if version,
        do: ~s(echo "#{version}"; exit 0),
        else: ~s(echo "Cannot connect to the Docker daemon" >&2; exit 1)

    File.write!(file, """
    #!/bin/sh
    echo "args=$*" >> "#{ctx.log}"
    case "$1" in
      version) #{version_clause} ;;
      ps) echo "#{ids}"; exit 0 ;;
      rm | network | volume) exit #{sweep_exit} ;;
    esac
    exit 0
    """)

    File.chmod!(file, 0o755)
  end

  defp calls(ctx), do: if(File.exists?(ctx.log), do: File.read!(ctx.log), else: "")

  # PATH holds only the stub dir plus a private shim dir with the few tools the step
  # needs, so a host `docker` can never leak into the run.
  defp capture(ctx, env \\ %{}) do
    err = Path.join(ctx.base, "stderr")
    shims = Path.join(ctx.base, "shims")
    File.mkdir_p!(shims)

    for tool <- ~w(sh id env cat printf date sleep tail head) do
      case System.find_executable(tool) do
        nil -> :ok
        path -> File.ln_s(path, Path.join(shims, tool))
      end
    end

    path = Enum.join([ctx.bin, shims], ":")
    envs = Map.to_list(Map.merge(%{"PATH" => path}, env))

    {out, code} =
      System.cmd(
        "/bin/sh",
        ["-c", ~s(exec /bin/sh "$0" container-engine 2>"$1"), @entrypoint, err],
        env: envs
      )

    {out, File.read!(err), code}
  end

  @requested %{"AUTONOMOUS_CONTAINER_ENGINE_REQUESTED" => "1"}

  test "not requested: prints =0 VERSION=, is silent and makes zero docker calls", ctx do
    stub_docker(ctx, [])
    assert {"AUTONOMOUS_CONTAINER_ENGINE=0 VERSION=\n", "", 0} = capture(ctx)
    assert calls(ctx) == ""
  end

  test "requested and reachable: advertises with the version and sweeps the engine", ctx do
    stub_docker(ctx, ids: "c1 c2")
    assert {"AUTONOMOUS_CONTAINER_ENGINE=1 VERSION=29.9.2\n", err, 0} = capture(ctx, @requested)
    assert err =~ "container engine: available (engine 29.9.2"

    log = calls(ctx)
    assert log =~ "args=version --format {{.Server.Version}}"
    assert log =~ "args=rm -f -v c1 c2"
    assert log =~ "args=network prune -f"
    assert log =~ "args=volume prune -af"
    refute log =~ "image prune"
    refute log =~ "system prune"
  end

  test "requested, reachable, nothing to remove: no rm call", ctx do
    stub_docker(ctx, ids: "")
    assert {"AUTONOMOUS_CONTAINER_ENGINE=1" <> _, _, 0} = capture(ctx, @requested)
    refute calls(ctx) =~ "args=rm "
  end

  test "a failing sweep only warns; the engine is still advertised", ctx do
    stub_docker(ctx, ids: "c1", sweep_exit: 1)
    assert {"AUTONOMOUS_CONTAINER_ENGINE=1 VERSION=29.9.2\n", err, 0} = capture(ctx, @requested)
    assert err =~ "warning: could not sweep leftover engine containers"
  end

  test "requested but unreachable: exits 78 after the bound, naming the cause", ctx do
    stub_docker(ctx, version: nil)
    env = Map.put(@requested, "AUTONOMOUS_ENGINE_TIMEOUT", "1")
    assert {"", err, 78} = capture(ctx, env)
    assert err =~ "did not answer within 1s"
    assert err =~ "Cannot connect to the Docker daemon"
  end

  test "requested but no docker client on PATH: exits 78 naming the remedy", ctx do
    assert {"", err, 78} = capture(ctx, @requested)
    assert err =~ "no docker client"
    assert err =~ "build --docker"
  end

  test "an inherited AUTONOMOUS_CONTAINER_ENGINE=1 is never honoured", ctx do
    stub_docker(ctx, [])

    assert {"AUTONOMOUS_CONTAINER_ENGINE=0 VERSION=\n", "", 0} =
             capture(ctx, %{
               "AUTONOMOUS_CONTAINER_ENGINE" => "1",
               "AUTONOMOUS_CONTAINER_ENGINE_VERSION" => "9.9.9"
             })

    assert calls(ctx) == ""
  end

  test "stdout carries only the hook line (all step output goes to stderr)", ctx do
    stub_docker(ctx, ids: "c1")
    {out, _err, 0} = capture(ctx, @requested)
    assert out |> String.split("\n", trim: true) |> length() == 1
  end
end
