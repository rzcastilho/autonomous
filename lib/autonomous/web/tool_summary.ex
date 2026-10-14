defmodule Autonomous.Web.ToolSummary do
  @moduledoc """
  One-line `Tool(summary)` text for a tool call (feature 042). Pure.

  Known tools read a fixed input key; anything else uses the first string-valued
  input in sorted key order (maps carry no order), else the name alone. The
  summary is the first line, `…` when more lines follow, capped at 200 chars.
  """

  @max 200

  @spec summary(String.t() | nil, map() | nil) :: String.t()
  def summary(nil, input), do: summary("tool", input)

  def summary(name, input) when is_map(input) do
    case text(name, input) do
      nil -> name
      "" -> name
      text -> "#{name}(#{shorten(text)})"
    end
  end

  def summary(name, _input), do: name

  defp text("Bash", input), do: string(input["command"])
  defp text(n, input) when n in ["Read", "Write", "Edit"], do: string(input["file_path"])
  defp text("NotebookEdit", input), do: string(input["notebook_path"] || input["file_path"])
  defp text(n, input) when n in ["Grep", "Glob"], do: string(input["pattern"])
  defp text("Skill", input), do: string(input["skill"])

  defp text(_name, input) do
    input
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.find_value(fn
      {_k, v} when is_binary(v) -> v
      _ -> nil
    end)
  end

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil

  defp shorten(text) do
    case String.split(text, "\n", parts: 2) do
      [line] -> cap(line)
      [line, _rest] -> cap(line <> " …")
    end
  end

  defp cap(text), do: if(String.length(text) > @max, do: String.slice(text, 0, @max), else: text)
end
