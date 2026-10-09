defmodule Autonomous.Web.ConfigDiff do
  @moduledoc """
  Pure pending-change model behind Configuration's unsaved-changes bar
  (033, data-model §4). Fields are `"model_<phase>"`, `"pr_base"`,
  `"pr_remote"` — the set `LiveConfig.apply/1` accepts (039: `budget_usd` is
  retired). `diff/2` compares the applied configuration with the edited form.
  """

  @type fields :: %{String.t() => term()}
  @type changes :: %{String.t() => {old :: term(), new :: term()}}

  @doc "Fields of `edited` that differ from `applied`, as `{old, new}`; equal fields are omitted."
  @spec diff(fields(), fields()) :: changes()
  def diff(applied, edited) do
    for {field, new} <- edited,
        {:ok, old} <- [Map.fetch(applied, field)],
        old != new,
        into: %{} do
      {field, {old, new}}
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
end
