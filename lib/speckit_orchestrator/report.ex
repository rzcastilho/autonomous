defmodule SpeckitOrchestrator.Report do
  @moduledoc """
  Render a `Coordinator` snapshot as a plain-text table for the `iex` operator
  surface. Pure — takes the snapshot map, returns a string.
  """

  @doc "Format a `Coordinator.status/0` snapshot as a table."
  @spec format_status(map()) :: String.t()
  def format_status(snapshot) do
    rows =
      snapshot
      |> Map.get(:per_feature, %{})
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, info} ->
        [id, to_string(info.status), elapsed(info.elapsed_ms)]
      end)

    [
      table([["FEATURE", "STATUS", "ELAPSED"] | rows]),
      "",
      "totals: #{format_totals(Map.get(snapshot, :totals, %{}))}",
      "spend:  $#{fmt_spend(Map.get(snapshot, :spend, 0.0))}" <>
        breaker(Map.get(snapshot, :breaker_tripped, false)),
      run_state(snapshot)
    ]
    |> Enum.join("\n")
  end

  # ---- helpers ------------------------------------------------------------

  defp elapsed(nil), do: "-"
  defp elapsed(ms) when ms < 1000, do: "#{ms}ms"
  defp elapsed(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_totals(totals) when map_size(totals) == 0, do: "(none)"

  defp format_totals(totals) do
    totals
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("  ", fn {status, n} -> "#{status}=#{n}" end)
  end

  defp fmt_spend(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt_spend(n), do: to_string(n)

  defp breaker(true), do: "  [BREAKER TRIPPED]"
  defp breaker(false), do: ""

  defp run_state(%{finished?: true}), do: "state:  finished"
  defp run_state(_), do: "state:  running"

  # Simple monospace table: pad each column to its widest cell.
  defp table(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn col -> col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
    end)
  end
end
