defmodule Autonomous.CoordinatorProbe do
  @moduledoc """
  Exit-safe boundary around `Coordinator.status/1`
  (`specs/038-console-projection-resilience/contracts/console-projection-resilience.md` §1).

  A busy or wedged Coordinator makes a plain `GenServer.call` exit the caller.
  Console code must never inherit that exit, so every status read goes through
  here and comes back as a tagged result. Never raises or exits.
  """

  @doc """
  Ask `server` for its status, waiting at most `timeout` ms.

    * `{:ok, status}` — answered in time (map passed through untouched)
    * `:none` — no such live process
    * `{:error, :timeout}` — alive but did not answer in time
    * `{:error, :down}` — exited / died during the call
  """
  @spec status(GenServer.server(), timeout()) ::
          {:ok, map()} | :none | {:error, :timeout | :down}
  def status(server, timeout) do
    if alive?(server) do
      try do
        {:ok, GenServer.call(server, :status, timeout)}
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, {:noproc, _} -> :none
        :exit, _ -> {:error, :down}
      end
    else
      :none
    end
  end

  defp alive?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp alive?(server) when is_pid(server), do: node(server) != node() or Process.alive?(server)
  defp alive?(_server), do: true
end
