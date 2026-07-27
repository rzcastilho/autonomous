defmodule SpeckitOrchestrator.Severity do
  @moduledoc """
  Pure ordered finding-severity vocabulary (FR-001a).

  `:low < :medium < :high < :critical`, with `"blocker"` a case-insensitive
  synonym for `:critical` (preserved from `AnalyzeResult`'s existing
  `@critical_severities`). Anything else parses to `:unknown`, which matches
  no threshold — including `:low` (research R3): an unrecognized severity is
  reported, never invented into a rank.

  No IO, no CLI, no harness, no Jido — fed only model-authored JSON.
  """

  @type severity :: :low | :medium | :high | :critical
  @type parsed :: severity() | :unknown

  @order [:low, :medium, :high, :critical]
  @critical_synonyms ~w(critical blocker)
  @plain_severities ~w(low medium high)

  @doc "The four recognized severities, in ascending order."
  @spec values() :: [severity()]
  def values, do: @order

  @doc "1-indexed rank of a recognized severity; `nil` for `:unknown`."
  @spec rank(parsed()) :: 1..4 | nil
  def rank(severity) do
    case Enum.find_index(@order, &(&1 == severity)) do
      nil -> nil
      index -> index + 1
    end
  end

  @doc """
  Parse a severity value. Case-insensitive; `"blocker"` normalizes to
  `:critical`. Never raises, never `String.to_atom/1` — `:error` for anything
  unrecognized.
  """
  @spec parse(String.t() | atom()) :: {:ok, severity()} | :error
  def parse(value) when is_atom(value) and value in @order, do: {:ok, value}

  def parse(value) when is_binary(value) do
    downcased = String.downcase(value)

    cond do
      downcased in @critical_synonyms -> {:ok, :critical}
      downcased in @plain_severities -> {:ok, String.to_existing_atom(downcased)}
      true -> :error
    end
  end

  def parse(_value), do: :error

  @doc "Read a finding's `\"severity\"` key; `:unknown` when absent or unparseable."
  @spec parse_finding(map()) :: parsed()
  def parse_finding(%{"severity" => severity}) do
    case parse(severity) do
      {:ok, parsed} -> parsed
      :error -> :unknown
    end
  end

  def parse_finding(_finding), do: :unknown

  @doc """
  Inclusive-floor threshold test: `rank(severity) >= rank(threshold)`.
  Reflexive (`at_or_above?(:high, :high) == true`). Always `false` for
  `:unknown` — a documented clause, not a fallthrough.
  """
  @spec at_or_above?(parsed(), severity()) :: boolean()
  def at_or_above?(severity, threshold) do
    case rank(severity) do
      nil -> false
      s -> s >= rank(threshold)
    end
  end

  @doc """
  Highest recognized severity in `enumerable`. `:unknown` entries are ignored
  when at least one recognized severity is present; `:unknown` if every entry
  is unrecognized; `nil` for an empty enumerable.
  """
  @spec max(Enumerable.t()) :: parsed() | nil
  def max(enumerable) do
    list = Enum.to_list(enumerable)

    case Enum.reject(list, &(rank(&1) == nil)) do
      [] -> if list == [], do: nil, else: :unknown
      known -> Enum.max_by(known, &rank/1)
    end
  end
end
