defmodule SpeckitOrchestrator.Workers.Bound do
  @moduledoc """
  Pure drain-wait arithmetic (data-model.md § Drain bound).

  How long a drainer should wait for one worker to reach its next boundary
  and exit, given the session deadline the worker last published into its
  registry entry. No process, no clock read — `now` is passed in so this stays
  a pure function under `Workers.drain/1`.
  """

  alias SpeckitOrchestrator.{Config, PhaseSession}

  # Covers the drained exit's own tail — worktree commit + agent stop — after
  # the session itself has already ended and been given `call_grace_ms` to be
  # noticed.
  @finalize_margin_ms :timer.seconds(30)

  @doc """
  Milliseconds a drainer should wait for a worker whose current session ends
  at `deadline_at` (or has not started one yet — `nil` ⇒ the full
  `Config.phase_timeout/0`, counted from `now`).

      remaining = max(0, deadline_at - now)   # nil deadline_at ⇒ Config.phase_timeout()
      wait_ms   = remaining + call_grace_ms + finalize_margin_ms

  Several workers being drained at once is a caller concern (the max across
  their individual bounds) — not this function's.

  `opts`:

    * `:call_grace_ms` — defaults to `PhaseSession.call_grace_ms/0`.
    * `:finalize_margin_ms` — defaults to a fixed 30s.
  """
  @spec wait_ms(DateTime.t() | nil, DateTime.t(), keyword()) :: non_neg_integer()
  def wait_ms(deadline_at, now, opts \\ []) do
    call_grace_ms = Keyword.get(opts, :call_grace_ms, PhaseSession.call_grace_ms())
    finalize_margin_ms = Keyword.get(opts, :finalize_margin_ms, @finalize_margin_ms)

    remaining_ms(deadline_at, now) + call_grace_ms + finalize_margin_ms
  end

  defp remaining_ms(nil, _now), do: Config.phase_timeout()

  defp remaining_ms(%DateTime{} = deadline_at, %DateTime{} = now),
    do: max(0, DateTime.diff(deadline_at, now, :millisecond))
end
