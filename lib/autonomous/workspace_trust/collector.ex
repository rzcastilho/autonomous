defmodule Autonomous.WorkspaceTrust.Collector do
  @moduledoc """
  Per-session collector for CLI stderr lines that matter to the
  untrusted-workspace gate (feature 036).

  A small process under `Autonomous.SessionSup`, started by a session-driving
  site before the harness request is issued, read and stopped after
  `PhaseSession.reduce/2` returns (any outcome). It never shares a mailbox with
  `AgentServer`. A push to a collector that is gone is dropped.
  """

  @doc "Start a collector; returns its pid."
  @spec start() :: pid()
  def start do
    {:ok, pid} = Task.Supervisor.start_child(Autonomous.SessionSup, fn -> loop([]) end)
    pid
  end

  @doc "Append a line. Fire and forget; dropped if the collector is gone."
  @spec push(pid() | nil, String.t()) :: :ok
  def push(nil, _line), do: :ok

  def push(pid, line) when is_pid(pid) do
    send(pid, {:push, line})
    :ok
  end

  @doc "Lines collected so far, in arrival order. `[]` if the collector is gone."
  @spec lines(pid() | nil) :: [String.t()]
  def lines(nil), do: []

  def lines(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, {:lines, self(), ref})

    receive do
      {^ref, lines} ->
        Process.demonitor(ref, [:flush])
        lines

      {:DOWN, ^ref, :process, _, _} ->
        []
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        []
    end
  end

  @doc "Stop the collector. Safe on a collector that already exited."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  @doc "Read the collected lines, then stop the collector."
  @spec collect(pid() | nil) :: [String.t()]
  def collect(pid) do
    lines = lines(pid)
    stop(pid)
    lines
  end

  defp loop(acc) do
    receive do
      {:push, line} -> loop([line | acc])
      {:lines, from, ref} -> send(from, {ref, Enum.reverse(acc)}) && loop(acc)
      :stop -> :ok
    end
  end
end
