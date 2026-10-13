defmodule Autonomous.ContainerVolumePathTest do
  @moduledoc "Runs the entrypoint's `vm-handover` against a stub `mise` (feature 041, applied-volumes.md)."
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../scripts/container-entrypoint.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "vol_path_#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)

    # Like the real `mise exec`: puts its tool directory ahead of PATH, then runs
    # the command after `--`.
    File.write!(Path.join(bin, "mise"), """
    #!/bin/sh
    [ "$1" = exec ] && [ "$2" = -- ] || exit 64
    shift 2
    PATH="/mise/tools:$PATH"
    exec "$@"
    """)

    File.chmod!(Path.join(bin, "mise"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, bin: bin}
  end

  defp handover(ctx, extra_env) do
    env = [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}] ++ extra_env
    System.cmd("sh", [@entrypoint, "vm-handover", "sh", "-c", "echo $PATH"], env: env)
  end

  test "AUTONOMOUS_VOLUME_PATH is re-prepended inside mise exec", ctx do
    {out, 0} = handover(ctx, [{"AUTONOMOUS_VOLUME_PATH", "/v/a/bin:/v/b/bin"}])
    assert String.starts_with?(out, "/v/a/bin:/v/b/bin:/mise/tools:")
  end

  test "unset leaves mise's PATH untouched", ctx do
    {out, 0} = handover(ctx, [])
    assert String.starts_with?(out, "/mise/tools:")
    refute out =~ "/v/"
  end

  test "empty leaves mise's PATH untouched", ctx do
    {out, 0} = handover(ctx, [{"AUTONOMOUS_VOLUME_PATH", ""}])
    assert String.starts_with?(out, "/mise/tools:")
    refute String.starts_with?(out, ":")
  end

  test "the command line is passed through intact (spaces, quotes)", ctx do
    env = [
      {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
      {"AUTONOMOUS_VOLUME_PATH", "/v/a"}
    ]

    {out, 0} =
      System.cmd("sh", [@entrypoint, "vm-handover", "printf", "%s|", "a b", "c'd"], env: env)

    assert out == "a b|c'd|"
  end
end
