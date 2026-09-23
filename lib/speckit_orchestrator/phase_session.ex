defmodule SpeckitOrchestrator.PhaseSession do
  @moduledoc """
  Deadline-bounded fold of one harness session's event stream.

  `PhaseResult.reduce/1` is the pure fold; this is the edge around it that
  owns the **wall clock**. It exists because no layer above the action can
  end a session cleanly:

    * jido_action's execution timeout killed the action's Task from outside.
      The SDK transport (`ExternalRuntimeTransport.Transport.Subprocess`) is
      linked to the process pulling the stream but does not trap exits, so
      its `terminate/2` — the only thing that kills the `claude` OS process —
      never ran, and the CLI kept editing the worktree as an orphan.
    * `AgentServer.call`'s timeout only makes the *caller* give up; the
      action, and the CLI under it, run on regardless.

  Here the stream is pulled in a linked Task and the parent waits up to
  `deadline_ms`. On expiry the SDK processes linked to that Task are stopped
  through `GenServer.stop/3` — so their `terminate/2` runs and the subprocess
  is killed — the Task is given a short grace to fold whatever the cut stream
  yields (session id, cost so far, tool events), and the result is marked
  `PhaseResult.deadline_exceeded/2`.

  The deadline is the governing guard: every `AgentServer.call` that drives a
  session sizes its own timeout with `call_timeout/1` (deadline + grace), so
  the outer call can never fire first and leave the session running.
  """

  require Logger

  alias SpeckitOrchestrator.PhaseResult

  # Time granted, after the deadline, for the SDK processes to stop and the
  # cut stream to fold; and how much longer than the deadline an
  # `AgentServer.call` waits before treating the session as lost. The call
  # grace also covers everything an action does around the fold — request
  # build, artifact probes, gate classification, cost recording.
  @shutdown_grace_ms :timer.seconds(10)
  @call_grace_ms :timer.minutes(2)

  @doc """
  Fold `stream` into a `%PhaseResult{}` within `deadline_ms` of wall-clock
  time. A stream that ends in time folds exactly as `PhaseResult.reduce/1`
  would; one that does not is cut (see the moduledoc) and folds to a
  `PhaseResult.deadline_exceeded?/1` result.
  """
  @spec reduce(Enumerable.t(), pos_integer()) :: PhaseResult.t()
  def reduce(stream, deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0 do
    task = Task.async(fn -> PhaseResult.reduce(stream) end)

    case Task.yield(task, deadline_ms) do
      {:ok, %PhaseResult{} = result} ->
        result

      {:exit, reason} ->
        %PhaseResult{status: :error, error: {:stream_exit, reason}}

      nil ->
        Logger.warning(
          "harness session exceeded its #{div(deadline_ms, 60_000)} min deadline — " <>
            "shutting the CLI down"
        )

        cut(task, deadline_ms)
    end
  end

  @doc """
  The `AgentServer.call/3` timeout for a session run under `deadline_ms`:
  strictly larger, so the in-action deadline always fires first.
  """
  @spec call_timeout(pos_integer()) :: pos_integer()
  def call_timeout(deadline_ms) when is_integer(deadline_ms) and deadline_ms > 0,
    do: deadline_ms + @call_grace_ms

  @doc """
  The fixed grace `call_timeout/1` adds on top of a session's own deadline —
  shared with `Workers.Bound.wait_ms/3` (026), which uses the same grace when
  bounding how long a drain waits for a worker's in-flight session.
  """
  @spec call_grace_ms() :: pos_integer()
  def call_grace_ms, do: @call_grace_ms

  # ---- deadline cut -------------------------------------------------------

  defp cut(%Task{pid: pid} = task, deadline_ms) do
    stop_linked_servers(pid)

    partial =
      case Task.yield(task, @shutdown_grace_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, %PhaseResult{} = result} -> result
        _ -> nil
      end

    PhaseResult.deadline_exceeded(partial, deadline_ms)
  end

  # The SDK starts its transport with `start_link` from the process pulling
  # the stream, so the Task's link set is exactly the session's process tree
  # (plus us): stopping each member through `GenServer.stop` runs its
  # `terminate/2`, which is where the subprocess kill lives. No attempt is made
  # to tell GenServers from other linked processes first — process-dictionary
  # heuristics are unreliable (an `Agent` records its fun, not `init/1`), and
  # a non-OTP process merely costs the bounded stop timeout once, at a
  # deadline that is already tens of minutes long.
  defp stop_linked_servers(task_pid) do
    task_pid
    |> linked_pids()
    |> Enum.each(&stop_server/1)
  end

  defp linked_pids(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> links |> Enum.filter(&is_pid/1) |> List.delete(self())
      nil -> []
    end
  end

  # `:normal`, never `:shutdown`: the exit reason travels the link chain
  # (transport → stream Task → this process) and anything but `:normal` would
  # take the action down with the session. `terminate/2` runs either way —
  # it is the same call `ExternalRuntimeTransport.Transport.close/1` makes.
  defp stop_server(pid) do
    GenServer.stop(pid, :normal, @shutdown_grace_ms)
  catch
    :exit, _reason -> :ok
  end
end
