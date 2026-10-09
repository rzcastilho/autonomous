defmodule Autonomous.ConsoleDelay do
  @moduledoc """
  Pure miss-streak policy for the console's Coordinator refresh
  (`specs/038-console-projection-resilience/data-model.md` §3): when a stale
  status becomes a visible "delayed" notice, what is broadcast on a miss, and
  when a warning is logged. No process, clock, or logger dependency — `now_ms`
  is injected.
  """

  @delayed_after 2
  @warn_interval_ms 60_000

  @type probe_result :: {:ok, map()} | :none | {:error, term()}

  @doc "Next consecutive-miss count after one probe."
  @spec step(non_neg_integer(), probe_result()) :: non_neg_integer()
  def step(_misses, {:ok, _status}), do: 0
  def step(_misses, :none), do: 0
  def step(misses, {:error, _reason}), do: misses + 1

  @doc "Whether the miss streak is long enough to show the delayed notice."
  @spec delayed?(non_neg_integer()) :: boolean()
  def delayed?(misses), do: misses >= @delayed_after

  @doc "What a probe result broadcasts, given the already-stepped miss count."
  @spec broadcast?(non_neg_integer(), probe_result()) :: :reconciled | :delayed | :silent
  def broadcast?(_misses, {:ok, _status}), do: :reconciled
  def broadcast?(_misses, :none), do: :reconciled
  def broadcast?(misses, {:error, _reason}), do: if(delayed?(misses), do: :delayed, else: :silent)

  @doc """
  Logging decision for one probe: `misses_before` is the count prior to this
  probe, `misses` the stepped count, `warned_at` the monotonic ms of the last
  warning (or `nil`).
  """
  @spec log?(non_neg_integer(), non_neg_integer(), integer() | nil, integer()) ::
          :warn | :recovered | :quiet
  def log?(misses_before, misses, warned_at, now_ms)

  def log?(_before, 1, _warned_at, _now_ms), do: :warn
  def log?(before, 0, _warned_at, _now_ms) when before > 0, do: :recovered

  def log?(_before, misses, warned_at, now_ms) when misses > 1 do
    if is_nil(warned_at) or now_ms - warned_at >= @warn_interval_ms, do: :warn, else: :quiet
  end

  def log?(_before, _misses, _warned_at, _now_ms), do: :quiet
end
