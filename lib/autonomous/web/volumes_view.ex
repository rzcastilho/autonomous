defmodule Autonomous.Web.VolumesView do
  @moduledoc """
  Pure view state for the Configuration page's declared-volumes group
  (feature 041, data-model.md "Configuration view state"). `:hidden` renders
  nothing, so an instance without a declaration keeps a byte-identical page.
  Never calls `inspect/1`.
  """

  alias Autonomous.AppliedVolumes.Volume

  @type usage :: :measuring | {:ok, non_neg_integer()} | {:unknown, String.t()}
  @type row :: %{
          name: String.t(),
          path: String.t(),
          env: [{String.t(), String.t()}],
          path_dirs: [String.t()],
          usage: usage()
        }
  @type state :: :hidden | {:refused, String.t()} | {:rows, String.t() | nil, [row()]}

  @doc "`applied` is `AppliedVolumes.current/0`; `usage` maps volume name to its measurement."
  @spec state(
          {:ok, [Volume.t()], String.t() | nil} | {:error, String.t()},
          %{optional(String.t()) => usage()}
        ) :: state()
  def state({:error, reason}, _usage), do: {:refused, reason}
  def state({:ok, [], _declaration}, _usage), do: :hidden

  def state({:ok, volumes, declaration}, usage) do
    rows =
      Enum.map(volumes, fn %Volume{} = v ->
        %{
          name: v.name,
          path: v.path,
          env: v.env,
          path_dirs: v.path_dirs,
          usage: Map.get(usage, v.name, :measuring)
        }
      end)

    {:rows, declaration, rows}
  end

  @doc "The `data-volume-usage` attribute value."
  @spec usage_state(usage()) :: String.t()
  def usage_state(:measuring), do: "measuring"
  def usage_state({:ok, _bytes}), do: "known"
  def usage_state({:unknown, _reason}), do: "unknown"

  @doc "The usage cell text: human size + exact KiB, or `unknown (<reason>)`."
  @spec usage_text(usage()) :: String.t()
  def usage_text(:measuring), do: "measuring"
  def usage_text({:unknown, reason}), do: "unknown (#{reason})"

  def usage_text({:ok, bytes}) do
    "#{human_size(bytes)} (#{div(bytes, 1024)} KiB)"
  end

  @doc "`VAR=value` labels, in declaration order."
  @spec env_labels([{String.t(), String.t()}]) :: [String.t()]
  def env_labels(env), do: Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp human_size(bytes) do
    units = ["KiB", "MiB", "GiB", "TiB"]
    {value, unit} = scale(bytes / 1024, units)
    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  defp scale(value, [unit]), do: {value, unit}
  defp scale(value, [unit | _]) when value < 1024, do: {value, unit}
  defp scale(value, [_ | rest]), do: scale(value / 1024, rest)
end
