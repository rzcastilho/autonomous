defmodule Autonomous.CredentialMask do
  @moduledoc """
  Masks exact credential values in conversation entries (feature 040, R9).

  The owned list is explicit (`names/0`). `pairs/1` reads the environment once
  at the edge; `mask/2` is pure — it replaces every exact occurrence of each
  value with `[masked:NAME]`, longest value first, recursively over every string
  (map keys and values) of the term. Applied by the recorder only, never to the
  request, so the agent is unaffected.
  """

  @names ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GH_TOKEN GITHUB_TOKEN)
  @min_length 8

  @type pairs :: [{name :: String.t(), value :: String.t()}]

  @doc "Names of the environment variables whose values are masked."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  `{name, value}` pairs for the set variables whose value is at least
  #{@min_length} characters, longest value first. `env_fun` defaults to
  `System.get_env/1`.
  """
  @spec pairs((String.t() -> String.t() | nil)) :: pairs()
  def pairs(env_fun \\ &System.get_env/1) do
    @names
    |> Enum.map(&{&1, env_fun.(&1)})
    |> Enum.filter(fn {_n, v} -> is_binary(v) and String.length(v) >= @min_length end)
    |> Enum.sort_by(fn {_n, v} -> -byte_size(v) end)
  end

  @doc "Replace every exact credential value in `term`, recursively."
  @spec mask(term(), pairs()) :: term()
  def mask(term, []), do: term
  def mask(term, pairs), do: do_mask(term, pairs)

  defp do_mask(s, pairs) when is_binary(s) do
    Enum.reduce(pairs, s, fn {name, value}, acc ->
      String.replace(acc, value, "[masked:#{name}]")
    end)
  end

  defp do_mask(%_{} = struct, pairs),
    do: struct |> Map.from_struct() |> do_mask(pairs) |> then(&struct(struct.__struct__, &1))

  defp do_mask(map, pairs) when is_map(map),
    do: Map.new(map, fn {k, v} -> {do_mask(k, pairs), do_mask(v, pairs)} end)

  defp do_mask(list, pairs) when is_list(list), do: Enum.map(list, &do_mask(&1, pairs))
  defp do_mask(other, _pairs), do: other
end
