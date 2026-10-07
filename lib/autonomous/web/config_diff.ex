defmodule Autonomous.Web.ConfigDiff do
  @moduledoc """
  Pure pending-change model behind Configuration's unsaved-changes bar
  (033, data-model §4). Fields are `"model_<phase>"`, `"budget_usd"`,
  `"pr_base"`, `"pr_remote"` — the set `LiveConfig.apply/1` accepts. `diff/2`
  compares the applied configuration with the edited form after normalizing
  the budget to whole cents, so `"50.00"` against `50.0` is not a change.
  """

  @type fields :: %{String.t() => term()}
  @type changes :: %{String.t() => {old :: term(), new :: term()}}

  @doc "Budget as whole cents. Two decimals at most; more is refused, not rounded."
  @spec parse_cents(term()) :: {:ok, non_neg_integer()} | :invalid
  def parse_cents(value) when is_integer(value) and value >= 0, do: {:ok, value * 100}
  def parse_cents(value) when is_float(value) and value >= 0, do: {:ok, round(value * 100)}

  def parse_cents(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(?:\.(\d{1,2}))?$/, String.trim(value)) do
      [_, whole] -> {:ok, String.to_integer(whole) * 100}
      [_, whole, frac] -> {:ok, String.to_integer(whole) * 100 + cents(frac)}
      nil -> :invalid
    end
  end

  def parse_cents(_value), do: :invalid

  defp cents(<<_>> = tenths), do: String.to_integer(tenths) * 10
  defp cents(hundredths), do: String.to_integer(hundredths)

  @doc "Fields of `edited` that differ from `applied`, as `{old, new}`; equal fields are omitted."
  @spec diff(fields(), fields()) :: changes()
  def diff(applied, edited) do
    for {field, new} <- edited,
        {:ok, old} <- [Map.fetch(applied, field)],
        not same?(field, old, new),
        into: %{} do
      {field, {old, display(field, new)}}
    end
  end

  @spec dirty?(changes()) :: boolean()
  def dirty?(changes), do: changes != %{}

  @doc """
  Toast lines for an applied change. Line 1 echoes the call with the changed
  keys only; line 2 appears only while a run is in flight (FR-024).
  """
  @spec apply_echo(changes(), String.t() | nil) :: [String.t()]
  def apply_echo(changes, active_run_id) do
    args =
      changes
      |> Enum.sort_by(fn {field, _} -> field end)
      |> Enum.map_join(", ", fn {field, {_old, new}} -> "#{field}: #{inspect(new)}" end)

    call = "LiveConfig.apply(%{#{args}})"

    case active_run_id do
      nil -> [call]
      run_id -> [call, "applies forward-only to #{run_id} · not saved as default"]
    end
  end

  defp same?("budget_usd", old, new) do
    case {parse_cents(old), parse_cents(new)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _ -> false
    end
  end

  defp same?(_field, old, new), do: old == new

  defp display("budget_usd", new) do
    case parse_cents(new) do
      {:ok, cents} -> cents / 100
      :invalid -> new
    end
  end

  defp display(_field, new), do: new
end
