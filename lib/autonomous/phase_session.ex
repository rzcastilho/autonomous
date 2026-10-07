defmodule Autonomous.PhaseSession do
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

  Here the stream is pulled in a Task and the parent waits up to
  `deadline_ms`. On expiry the SDK processes linked to that Task are stopped
  through `GenServer.stop/3` — so their `terminate/2` runs and the subprocess
  is killed — the Task is given a short grace to fold whatever the cut stream
  yields (session id, cost so far, tool events), and the result is marked
  `PhaseResult.deadline_exceeded/2`.

  **Session death (034).** The SDK `start_link`s its client inside the fold
  Task, so a client that dies abnormally (the CLI exited during initialize)
  takes the Task down through the link. Were the Task linked to the caller,
  that exit would kill the action silently — Jido's runner is unmonitored, its
  reply never sent — and the feature would sit `running` until the deadline.
  The Task is therefore started `async_nolink` under `Autonomous.SessionSup`:
  the death is a `Task.yield/2` `{:exit, reason}` value, folded into
  `{:session_died, kind, excerpt}` (`SessionExit`). A small watcher process
  keeps the old "the session dies with its action" guarantee: if the caller
  goes away first, the watcher stops the Task's linked servers through
  `GenServer.stop` so the CLI is killed, not orphaned.

  The deadline is the governing guard: every `AgentServer.call` that drives a
  session sizes its own timeout with `call_timeout/1` (deadline + grace), so
  the outer call can never fire first and leave the session running.
  """

  require Logger

  alias Autonomous.{PhaseResult, SessionExit}

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
    parent = self()
    marker = make_ref()

    task =
      Task.Supervisor.async_nolink(Autonomous.SessionSup, fn ->
        stream |> announce_events(parent, marker) |> PhaseResult.reduce()
      end)

    watch_caller(parent, task.pid)

    case Task.yield(task, deadline_ms) do
      {:ok, %PhaseResult{} = result} ->
        flush_seen(marker)
        result

      {:exit, reason} ->
        session_died(reason, marker)

      nil ->
        Logger.warning(
          "harness session exceeded its #{div(deadline_ms, 60_000)} min deadline — " <>
            "shutting the CLI down"
        )

        flush_seen(marker)
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

  # ---- session death (034) -----------------------------------------------

  # Runs inside the fold Task: tells the parent, once, that the stream has
  # yielded (so a later death is `:ended_early`, not `:start_failed`) and
  # again when a session id first shows up (so the dead session's id survives
  # for the transcript).
  defp announce_events(stream, parent, marker) do
    Stream.transform(stream, {false, nil}, fn event, {started?, sid} ->
      event_sid = event_session_id(event)
      new_sid = sid || event_sid

      if not started? or new_sid != sid do
        send(parent, {marker, :seen, new_sid})
      end

      {[event], {true, new_sid}}
    end)
  end

  defp event_session_id(%{session_id: sid}) when is_binary(sid), do: sid
  defp event_session_id(_), do: nil

  # `{started?, session_id}` from the markers the fold Task sent before dying.
  defp drain_seen(marker, acc \\ {false, nil}) do
    receive do
      {^marker, :seen, sid} -> drain_seen(marker, {true, sid || elem(acc, 1)})
    after
      0 -> acc
    end
  end

  defp flush_seen(marker), do: drain_seen(marker) && :ok

  defp session_died(reason, marker) do
    {started?, session_id} = drain_seen(marker)
    %{kind: kind, excerpt: excerpt} = SessionExit.classify(reason, started?)

    Logger.warning("harness session died (#{kind}): #{excerpt}")

    %PhaseResult{
      status: :error,
      session_id: session_id,
      error: {:session_died, kind, excerpt}
    }
  end

  # The fold Task is no longer linked to its caller, so nothing ties the CLI's
  # lifetime to the action's any more. This watcher does: if the caller exits
  # before the fold finishes, it stops the Task's linked servers (their
  # `terminate/2` kills the CLI), and as a last resort the Task itself.
  defp watch_caller(parent, task_pid) do
    spawn(fn ->
      parent_ref = Process.monitor(parent)
      task_ref = Process.monitor(task_pid)

      receive do
        {:DOWN, ^task_ref, :process, _, _} ->
          :ok

        {:DOWN, ^parent_ref, :process, _, _} ->
          stop_linked_servers(task_pid)

          receive do
            {:DOWN, ^task_ref, :process, _, _} -> :ok
          after
            @shutdown_grace_ms -> Process.exit(task_pid, :kill)
          end
      end
    end)

    :ok
  end

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
      {:links, links} ->
        links
        |> Enum.filter(&is_pid/1)
        |> List.delete(self())
        |> List.delete(Process.whereis(Autonomous.SessionSup))

      nil ->
        []
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
