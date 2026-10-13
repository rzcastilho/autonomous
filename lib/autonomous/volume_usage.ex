defmodule Autonomous.VolumeUsage do
  @moduledoc """
  Space used under a mounted volume path (feature 041, FR-023). Boundary IO:
  `du -sk -x` under a `Task` with a timeout, so a huge volume never blocks the
  Configuration page. An unmeasurable path is `{:unknown, reason}` — never a
  misleading `{:ok, 0}`.
  """

  @default_timeout_ms 30_000

  @type result :: {:ok, non_neg_integer()} | {:unknown, String.t()}

  @doc """
  Bytes used under `path`. `opts[:command]` (`(path -> {output, status})`) is
  the injection seam for tests.
  """
  @spec measure(Path.t(), pos_integer(), keyword()) :: result()
  def measure(path, timeout_ms \\ @default_timeout_ms, opts \\ []) do
    runner = Keyword.get(opts, :command, &du/1)

    if File.dir?(path) do
      task = Task.async(fn -> runner.(path) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> parse(output)
        {:ok, {output, _status}} -> {:unknown, "du failed: #{first_line(output)}"}
        {:exit, reason} -> {:unknown, "du failed: #{Exception.format_exit(reason)}"}
        nil -> {:unknown, "timed out"}
      end
    else
      {:unknown, "not mounted"}
    end
  end

  defp du(path) do
    System.cmd("du", ["-sk", "-x", path], stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), 127}
  end

  defp parse(output) do
    case Integer.parse(String.trim_leading(output)) do
      {kib, _rest} -> {:ok, kib * 1024}
      :error -> {:unknown, "du failed: #{first_line(output)}"}
    end
  end

  defp first_line(output), do: output |> String.split("\n", parts: 2) |> hd() |> String.trim()
end
