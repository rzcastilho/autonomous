defmodule Autonomous.SessionExit do
  @moduledoc """
  Pure classification of a harness session that died instead of finishing
  (feature 034).

  `PhaseSession` hands over the exit term of the fold process plus whether the
  stream ever yielded an event. This module says *what kind* of death it was
  and extracts the CLI's own words for the operator.

  It knows nothing about the SDK's structs: the single contract it relies on
  is that the CLI's message lives under a `:stderr` key somewhere in the exit
  term (recorded in `docs/harness-contract.md`). Total — never raises.
  """

  @max_excerpt 2_000

  @type kind :: :start_failed | :ended_early
  @type t :: %{kind: kind(), excerpt: String.t()}

  @doc """
  `started?` is true when the stream yielded at least one event before the
  death: `:ended_early`; otherwise `:start_failed`.
  """
  @spec classify(term(), boolean()) :: t()
  def classify(reason, started?) do
    %{kind: if(started?, do: :ended_early, else: :start_failed), excerpt: excerpt(reason)}
  end

  defp excerpt(reason) do
    text =
      case find_stderr(reason) do
        {:ok, bin} -> bin
        :error -> safe_inspect(reason)
      end

    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_excerpt)
    |> case do
      "" -> "no output captured"
      s -> s
    end
  end

  defp safe_inspect(term) do
    inspect(term, limit: 50, printable_limit: @max_excerpt)
  rescue
    _ -> "unprintable exit reason"
  end

  # Depth-first, first `stderr: <binary>` wins.
  defp find_stderr(%_{} = struct), do: struct |> Map.from_struct() |> find_stderr()

  defp find_stderr(map) when is_map(map) do
    case Map.fetch(map, :stderr) do
      {:ok, bin} when is_binary(bin) -> {:ok, bin}
      _ -> map |> Map.values() |> find_in_list()
    end
  end

  defp find_stderr(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> find_in_list()
  defp find_stderr(list) when is_list(list), do: find_in_list(list)
  defp find_stderr(_), do: :error

  defp find_in_list(list), do: walk(list)

  # Tolerates improper lists.
  defp walk([{:stderr, bin} | _]) when is_binary(bin), do: {:ok, bin}

  defp walk([head | tail]) do
    case find_stderr(head) do
      {:ok, _} = found -> found
      :error -> walk(tail)
    end
  end

  defp walk(_), do: :error
end
