defmodule Autonomous.ContainerEngine.Cli do
  @moduledoc """
  The `docker` command-line boundary for the container-engine sidecar (feature 046).

  `Autonomous.ContainerEngine` talks to the engine only through this behaviour, so
  its probe and end-of-phase cleanup are unit-tested with a stub module (injected
  via `Config.container_engine_cli/0`). The default implementation shells out to
  the `docker` client, which finds the engine through the inherited `DOCKER_HOST`.
  """

  @typedoc "Exit status and combined stdout/stderr of a failed command."
  @type failure :: {:exit, status :: integer(), output :: String.t()}

  @callback run(args :: [String.t()], timeout_ms :: pos_integer()) ::
              {:ok, stdout :: String.t()} | {:error, failure()}

  @behaviour __MODULE__

  @doc """
  Run `docker <args>`, bounded by `timeout_ms`. A command that overruns the bound
  is abandoned and reported as exit status 124 (the `timeout(1)` convention); a
  missing client is exit status 127.
  """
  @impl true
  @spec run([String.t()], pos_integer()) :: {:ok, String.t()} | {:error, failure()}
  def run(args, timeout_ms) when is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> exec(args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, 1, "docker did not run: #{inspect(reason)}"}}
      nil -> {:error, {:exit, 124, "timed out after #{timeout_ms}ms"}}
    end
  end

  defp exec(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {:exit, status, out}}
    end
  rescue
    e in ErlangError -> {:error, {:exit, 127, "docker not runnable: #{Exception.message(e)}"}}
  end
end
