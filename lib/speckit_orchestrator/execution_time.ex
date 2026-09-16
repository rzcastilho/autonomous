defmodule SpeckitOrchestrator.ExecutionTime do
  @moduledoc """
  Pure window algebra for "how long did at least one execution run"
  (`specs/024-elapsed-execution-time/contracts/execution-time.md`). No
  Mnesia, Phoenix, Coordinator, `:telemetry`, or clock dependency — `now` is
  always a parameter (Principle I, FR-012).

  A `window` is one span of wall-clock time, in milliseconds since the Unix
  epoch, during which a step for a feature was running. `to: nil` means
  still running. `elapsed_ms/2` closes open windows at an injected `now`,
  merges overlapping-or-touching windows, and sums — the same operation
  answers cold (recorded attempts only), live (recorded ∪ observed spans),
  and diverted (recorded attempts including the one it diverted on) without
  a special case for any of them (FR-001, FR-002, SC-006).
  """

  @type ms :: non_neg_integer()
  @type window :: %{key: term(), from: ms(), to: ms() | nil}

  # ---- 2.1 from_attempts/1 ---------------------------------------------------

  @doc """
  One window per element of a feature's recorded `phase_attempts` with both
  `:started_at` and `:ended_at` present as `%DateTime{}` and
  `ended_at >= started_at`. Every `phase` atom qualifies — no allow-list.
  An attempt missing either timestamp, with a non-`DateTime` timestamp, or
  with a reversed pair, yields no window and never raises. Non-list input
  yields `[]`.
  """
  @spec from_attempts([map()]) :: [window()]
  def from_attempts(attempts) when is_list(attempts) do
    attempts
    |> Enum.flat_map(&window_from_attempt/1)
    |> normalize()
  end

  def from_attempts(_attempts), do: []

  defp window_from_attempt(attempt) do
    with %DateTime{} = started_at <- Map.get(attempt, :started_at),
         %DateTime{} = ended_at <- Map.get(attempt, :ended_at),
         from <- DateTime.to_unix(started_at, :millisecond),
         to <- DateTime.to_unix(ended_at, :millisecond),
         true <- to >= from do
      [%{key: {:attempt, Map.get(attempt, :phase), Map.get(attempt, :ordinal)}, from: from, to: to}]
    else
      _ -> []
    end
  end

  # ---- 2.2 open/3, close/3, close_all/2 --------------------------------------

  @doc """
  Removes any window with the same `key` and `to: nil`, then adds
  `%{key: key, from: from, to: nil}`. Returns a `normalize/1`d list.
  """
  @spec open([window()], key :: term(), from :: ms()) :: [window()]
  def open(windows, key, from) do
    windows
    |> Enum.reject(&(&1.key == key and is_nil(&1.to)))
    |> then(&[%{key: key, from: from, to: nil} | &1])
    |> normalize()
  end

  @doc """
  Sets `to = max(to, from)` on the window with the same `key` and
  `to: nil`; when there is none, the list is returned unchanged (a stop
  whose start was never observed contributes nothing). Returns a
  `normalize/1`d list.
  """
  @spec close([window()], key :: term(), to :: ms()) :: [window()]
  def close(windows, key, to) do
    windows
    |> Enum.map(fn
      %{key: ^key, to: nil} = w -> %{w | to: max(to, w.from)}
      w -> w
    end)
    |> normalize()
  end

  @doc """
  Applies `close/3` to every open window, at the same `to`.
  """
  @spec close_all([window()], to :: ms()) :: [window()]
  def close_all(windows, to) do
    windows
    |> Enum.map(fn
      %{to: nil} = w -> %{w | to: max(to, w.from)}
      w -> w
    end)
    |> normalize()
  end

  # ---- 2.3 normalize/1 -------------------------------------------------------

  @doc """
  Deduplicates by `{key, from}` (a closed window beats an open one; among
  closed ones the larger `to` wins), then sorts by `{from, to}` with `nil`
  `to` last among equals. Idempotent.
  """
  @spec normalize([window()]) :: [window()]
  def normalize(windows) do
    windows
    |> Enum.group_by(&{&1.key, &1.from})
    |> Enum.map(fn {_key_from, group} -> Enum.reduce(group, &pick_winner/2) end)
    |> Enum.sort_by(&sort_key/1)
  end

  defp pick_winner(a, b) do
    cond do
      is_nil(a.to) and is_nil(b.to) -> a
      is_nil(a.to) -> b
      is_nil(b.to) -> a
      true -> if a.to >= b.to, do: a, else: b
    end
  end

  defp sort_key(%{from: from, to: nil}), do: {from, :infinity}
  defp sort_key(%{from: from, to: to}), do: {from, to}

  # ---- 2.4 elapsed_ms/2 -------------------------------------------------------

  @doc """
  `nil` for `[]`. Otherwise each open window is closed at
  `max(now, from)`, intervals are sorted by `from` and merged while
  `next.from <= current.to` (overlapping or touching), and the merged
  lengths are summed. A `DateTime` `now` is converted with
  `DateTime.to_unix(_, :millisecond)`.
  """
  @spec elapsed_ms([window()], now :: ms() | DateTime.t()) :: non_neg_integer() | nil
  def elapsed_ms([], _now), do: nil

  def elapsed_ms(windows, %DateTime{} = now) do
    elapsed_ms(windows, DateTime.to_unix(now, :millisecond))
  end

  def elapsed_ms(windows, now) when is_integer(now) do
    windows
    |> Enum.map(fn %{from: from, to: to} -> {from, close_at(to, from, now)} end)
    |> Enum.sort_by(fn {from, _to} -> from end)
    |> merge_intervals()
    |> Enum.reduce(0, fn {from, to}, acc -> acc + (to - from) end)
  end

  defp close_at(nil, from, now), do: max(now, from)
  defp close_at(to, _from, _now), do: to

  defp merge_intervals([]), do: []

  defp merge_intervals([first | rest]) do
    Enum.reduce(rest, [first], fn {from, to}, [{cur_from, cur_to} | acc_rest] ->
      if from <= cur_to do
        [{cur_from, max(cur_to, to)} | acc_rest]
      else
        [{from, to}, {cur_from, cur_to} | acc_rest]
      end
    end)
    |> Enum.reverse()
  end

  # ---- 2.5 native_to_ms/1 -----------------------------------------------------

  @doc """
  Converts a `:telemetry.span/3` native-unit measurement
  (`system_time`/`duration`) to milliseconds. The only place the telemetry
  time unit is named.
  """
  @spec native_to_ms(integer()) :: integer()
  def native_to_ms(value), do: System.convert_time_unit(value, :native, :millisecond)
end
