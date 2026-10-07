defmodule Autonomous.Web.RunSettingsView do
  @moduledoc """
  Pure projection of a run's recorded settings (`RunContext.to_map/1`) into
  ordered `{key, value}` rows for a record block (033, data-model §1).

  Only keys in `RunContext.keys/0` are emitted, so a bookkeeping key
  (`__given__`, anything `__`-prefixed) can never reach the page.
  `containment_profile` is dropped: the CONTAINMENT block owns it. Never calls
  `inspect/1` (research R3).
  """

  alias Autonomous.RunContext

  @money_keys ~w(budget_usd)
  @dropped ~w(containment_profile)

  @allowed (for key <- RunContext.keys(), Atom.to_string(key) not in @dropped do
              Atom.to_string(key)
            end)

  @doc "One row per recorded setting, in `RunContext` key order; string key wins over atom key."
  @spec rows(map() | nil) :: [{String.t(), String.t()}]
  def rows(settings) when is_map(settings) do
    for key <- @allowed, {:ok, value} <- [fetch(settings, key)] do
      {key, row_value(key, value)}
    end
  end

  def rows(_other), do: []

  defp fetch(settings, key) do
    case Map.fetch(settings, key) do
      {:ok, _} = found -> found
      :error -> fetch_atom(settings, key)
    end
  end

  defp fetch_atom(settings, key) do
    Enum.find_value(settings, :error, fn
      {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: {:ok, v}
      _ -> nil
    end)
  end

  defp row_value(key, value) when key in @money_keys and is_number(value),
    do: "$" <> Autonomous.Web.CoreComponents.format_money(value)

  defp row_value(_key, value), do: format_value(value)

  @doc "Render a setting or amendment value as plain text — no quoting artefacts, no `inspect/1`."
  @spec format_value(term()) :: String.t()
  def format_value(value) when is_binary(value), do: value
  def format_value(nil), do: "—"
  def format_value(true), do: "true"
  def format_value(false), do: "false"
  def format_value(value) when is_atom(value), do: ":" <> Atom.to_string(value)
  def format_value(value) when is_integer(value), do: Integer.to_string(value)
  def format_value(value) when is_float(value), do: Float.to_string(value)
  def format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)

  def format_value(%{} = value) do
    value
    |> Map.drop([:__struct__])
    |> Enum.reject(fn {k, _} -> hidden_key?(k) end)
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  def format_value(value) when is_tuple(value),
    do: "{" <> (value |> Tuple.to_list() |> Enum.map_join(", ", &format_value/1)) <> "}"

  def format_value(_other), do: "—"

  defp hidden_key?(k) when is_atom(k) or is_binary(k), do: String.starts_with?(to_string(k), "__")
  defp hidden_key?(_k), do: false
end
