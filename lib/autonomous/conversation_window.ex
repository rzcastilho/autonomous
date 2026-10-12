defmodule Autonomous.ConversationWindow do
  @moduledoc """
  Bounded ring of the most recent conversation entries (feature 040, R4) —
  the catch-up window a late viewer reads. Pure; owned by the recorder.
  """

  @default_cap 500

  defstruct queue: :queue.new(), size: 0, cap: @default_cap, last_seq: nil, dropped: 0

  @type t :: %__MODULE__{
          queue: :queue.queue(),
          size: non_neg_integer(),
          cap: pos_integer(),
          last_seq: non_neg_integer() | nil,
          dropped: non_neg_integer()
        }

  @spec new(pos_integer()) :: t()
  def new(cap \\ @default_cap) when is_integer(cap) and cap > 0, do: %__MODULE__{cap: cap}

  @doc "Append `entry` (a map with `:seq`), evicting the oldest at the cap."
  @spec push(t(), %{seq: non_neg_integer()}) :: t()
  def push(%__MODULE__{} = w, %{seq: seq} = entry) do
    q = :queue.in(entry, w.queue)

    if w.size >= w.cap do
      {_, q} = :queue.out(q)
      %{w | queue: q, last_seq: seq, dropped: w.dropped + 1}
    else
      %{w | queue: q, size: w.size + 1, last_seq: seq}
    end
  end

  @doc "`{entries oldest-first, last_seq | nil, truncated?}`."
  @spec snapshot(t()) :: {[map()], non_neg_integer() | nil, boolean()}
  def snapshot(%__MODULE__{} = w), do: {:queue.to_list(w.queue), w.last_seq, w.dropped > 0}

  @doc "The windowed entry with `seq`, or `:not_in_window`."
  @spec fetch(t(), non_neg_integer()) :: {:ok, map()} | :not_in_window
  def fetch(%__MODULE__{} = w, seq) do
    case Enum.find(:queue.to_list(w.queue), &(&1.seq == seq)) do
      nil -> :not_in_window
      entry -> {:ok, entry}
    end
  end
end
