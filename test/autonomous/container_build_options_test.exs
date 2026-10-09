defmodule Autonomous.ContainerBuildOptionsTest do
  @moduledoc "Runs the real `scripts/autonomous build` against a stub `docker` (feature 037, build-options.md)."
  use ExUnit.Case, async: true

  @wrapper Path.expand("../../scripts/autonomous", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "build_opts_#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    home = Path.join(base, "home")
    log = Path.join(base, "docker.log")
    File.mkdir_p!(bin)
    File.mkdir_p!(home)

    stub = Path.join(bin, "docker")

    File.write!(stub, """
    #!/bin/sh
    if [ "$1 $2 $3" = "compose version --short" ]; then echo 2.30.0; exit 0; fi
    echo "args=$*" >> "#{log}"
    echo "EXTRA_APT_PACKAGES=[$EXTRA_APT_PACKAGES]" >> "#{log}"
    echo "WITH_AGENT_ROOT=[$WITH_AGENT_ROOT]" >> "#{log}"
    exit 0
    """)

    File.chmod!(stub, 0o755)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, bin: bin, home: home, log: log}
  end

  defp run(ctx, args) do
    env = [
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"HOME", ctx.home}
    ]

    System.cmd("sh", [@wrapper | args], env: env, stderr_to_stdout: true)
  end

  defp calls(ctx), do: if(File.exists?(ctx.log), do: File.read!(ctx.log), else: "")

  test "an invalid package name exits 2 before any docker build call", ctx do
    assert {out, 2} = run(ctx, ["build", "--apt", "pkg-config ; rm -rf /"])
    assert out =~ "autonomous: invalid package name ';'"
    assert calls(ctx) == ""
  end

  test "repeated --apt accumulates into one build arg", ctx do
    assert {_, 0} = run(ctx, ["build", "--apt", "a-b libc6-dev", "--apt", "c++"])
    assert calls(ctx) =~ "EXTRA_APT_PACKAGES=[a-b libc6-dev c++]"
    assert calls(ctx) =~ "build dev"
  end

  test "comma separation and --apt=value form", ctx do
    assert {_, 0} = run(ctx, ["build", "--apt", "a-b,libc6-dev", "--apt=pkg-config:amd64"])
    assert calls(ctx) =~ "EXTRA_APT_PACKAGES=[a-b libc6-dev pkg-config:amd64]"
  end

  test "an empty list passes an empty build arg", ctx do
    assert {_, 0} = run(ctx, ["build", "--apt", ""])
    assert calls(ctx) =~ "EXTRA_APT_PACKAGES=[]"
  end

  test "no --apt passes an empty build arg", ctx do
    assert {_, 0} = run(ctx, ["build"])
    assert calls(ctx) =~ "EXTRA_APT_PACKAGES=[]"
  end

  test "--apt on a non-build command is an unknown option", ctx do
    assert {out, 2} = run(ctx, ["stop", "--apt", "pkg-config"])
    assert out =~ "unknown option '--apt'"
    assert calls(ctx) == ""
  end

  test "usage lists --apt", ctx do
    assert {out, 2} = run(ctx, ["help"])
    assert out =~ "--apt"
  end

  test "--agent-root passes WITH_AGENT_ROOT=1; default is 0", ctx do
    assert {_, 0} = run(ctx, ["build", "--agent-root"])
    assert calls(ctx) =~ "WITH_AGENT_ROOT=[1]"
    File.rm!(ctx.log)
    assert {_, 0} = run(ctx, ["build"])
    assert calls(ctx) =~ "WITH_AGENT_ROOT=[0]"
  end

  test "--agent-root on a non-build command is an unknown option", ctx do
    assert {out, 2} = run(ctx, ["stop", "--agent-root"])
    assert out =~ "unknown option '--agent-root'"
    assert calls(ctx) == ""
  end

  test "usage lists --agent-root", ctx do
    assert {out, 2} = run(ctx, ["help"])
    assert out =~ "--agent-root"
  end
end
