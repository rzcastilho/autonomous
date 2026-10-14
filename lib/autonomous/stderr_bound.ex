defmodule Autonomous.StderrBound do
  @moduledoc """
  Head/tail bound on the CLI error stream a conversation records (feature 043,
  R4). Pure.

  The first `head` lines are emitted on arrival; later lines are held in a
  rolling tail of at most `tail` lines, counting evictions as dropped. At close
  `flush/1` returns how many lines were dropped and the held tail in arrival
  order. Invariant: emitted + held + dropped = lines pushed, and a session of
  at most `head + tail` lines drops nothing.
  """

  defstruct [:head_cap, :tail_cap, emitted: 0, tail: :queue.new(), held: 0, dropped: 0]

  @type t :: %__MODULE__{
          head_cap: pos_integer(),
          tail_cap: pos_integer(),
          emitted: non_neg_integer(),
          tail: :queue.queue(String.t()),
          held: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(head, tail) when is_integer(head) and head > 0 and is_integer(tail) and tail > 0,
    do: %__MODULE__{head_cap: head, tail_cap: tail}

  @spec push(t(), String.t()) :: {:emit, String.t(), t()} | {:held, t()}
  def push(%__MODULE__{emitted: e, head_cap: h} = b, line) when e < h,
    do: {:emit, line, %{b | emitted: e + 1}}

  def push(%__MODULE__{held: n, tail_cap: t} = b, line) when n < t,
    do: {:held, %{b | tail: :queue.in(line, b.tail), held: n + 1}}

  def push(%__MODULE__{} = b, line) do
    {_evicted, rest} = :queue.out(b.tail)
    {:held, %{b | tail: :queue.in(line, rest), dropped: b.dropped + 1}}
  end

  @doc "`{dropped_count, held_lines_in_arrival_order}`; called once, at close."
  @spec flush(t()) :: {non_neg_integer(), [String.t()]}
  def flush(%__MODULE__{} = b), do: {b.dropped, :queue.to_list(b.tail)}
end
