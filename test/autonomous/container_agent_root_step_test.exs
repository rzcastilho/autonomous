defmodule Autonomous.ContainerAgentRootStepTest do
  @moduledoc "Runs the real `container-entrypoint.sh agent-root` step with a stub `sudo` (feature 037)."
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../scripts/container-entrypoint.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "agent_root_step_#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, bin: bin}
  end

  defp stub_sudo(ctx, exit_code) do
    file = Path.join(ctx.bin, "sudo")
    File.write!(file, "#!/bin/sh\nexit #{exit_code}\n")
    File.chmod!(file, 0o755)
  end

  # PATH holds only the stub dir plus a private shim dir with the few tools the
  # script needs, so a host `sudo` can never leak into the run.
  defp capture(ctx, env \\ %{}) do
    err = Path.join(Path.dirname(ctx.bin), "stderr")

    shims = Path.join(Path.dirname(ctx.bin), "shims")
    File.mkdir_p!(shims)

    for tool <- ~w(sh id env cat printf) do
      case System.find_executable(tool) do
        nil -> :ok
        path -> File.ln_s(path, Path.join(shims, tool))
      end
    end

    path = Enum.join([ctx.bin, shims], ":")
    envs = Map.to_list(Map.merge(%{"PATH" => path}, env))

    {out, code} =
      System.cmd("/bin/sh", ["-c", ~s(exec /bin/sh "$0" agent-root 2>"$1"), @entrypoint, err],
        env: envs
      )

    {out, File.read!(err), code}
  end

  test "no sudo: prints =0, silent", ctx do
    assert {"AUTONOMOUS_AGENT_ROOT=0\n", "", 0} = capture(ctx)
  end

  test "sudo -n true succeeds: prints =1 and the available line", ctx do
    stub_sudo(ctx, 0)
    assert {"AUTONOMOUS_AGENT_ROOT=1\n", err, 0} = capture(ctx)
    assert err =~ "agent root: available"
  end

  test "sudo -n true fails: prints =0 and warns with the uid", ctx do
    stub_sudo(ctx, 1)
    assert {"AUTONOMOUS_AGENT_ROOT=0\n", err, 0} = capture(ctx)
    assert err =~ "'sudo -n true' failed for uid"
    assert err =~ "not advertised"
  end

  test "an inherited AUTONOMOUS_AGENT_ROOT=1 is never honoured", ctx do
    assert {"AUTONOMOUS_AGENT_ROOT=0\n", "", 0} = capture(ctx, %{"AUTONOMOUS_AGENT_ROOT" => "1"})
  end
end
