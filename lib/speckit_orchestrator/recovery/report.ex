defmodule SpeckitOrchestrator.Recovery.Report do
  @moduledoc """
  The read-only reconciled whole-run picture the operator reviews before
  continuing (FR-015). See
  `specs/014-recovery-reconciliation/contracts/recovery-report.md` and
  data-model.md "Entity: Reconciled run report".
  """

  alias SpeckitOrchestrator.Recovery.Reconcile

  @enforce_keys [:features, :conflicts, :next_runnable, :spend, :run_shape]
  defstruct features: [],
            conflicts: [],
            next_runnable: [],
            spend: 0,
            run_shape: :ad_hoc,
            discrepancies: []

  @typedoc "Per-feature before/after picture. `recorded: nil` — the record never named this feature (016 US3)."
  @type feature_row :: %{
          id: String.t(),
          slug: String.t(),
          recorded: atom() | nil,
          reconciled: Reconcile.result(),
          resume_phase: atom() | nil,
          corrected?: boolean()
        }

  @typedoc "A feature held gate-like for human resolution, with its reason."
  @type conflict_row :: %{id: String.t(), reason: atom()}

  @typedoc "016 US3 — a rebuild proposal row this report could not silently reconcile."
  @type discrepancy_row :: %{kind: atom(), id: String.t(), detail: term()}

  @type t :: %__MODULE__{
          features: [feature_row()],
          conflicts: [conflict_row()],
          next_runnable: [String.t()],
          spend: number(),
          run_shape: Reconcile.run_shape(),
          discrepancies: [discrepancy_row()]
        }

  @doc """
  Render the reconciled whole-run picture as the plain-text table shown in
  `contracts/recovery-report.md` ("Reconciled report") — `Feature | Recorded |
  Reconciled | Note` columns plus a `Spend:` / `Next runnable:` footer.
  `CONFLICT` rows carry their reason so the operator can resolve them
  (Principle V). Pure — takes the report, returns a string.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = report) do
    conflict_reasons = Map.new(report.conflicts, &{&1.id, &1.reason})
    discrepancy_notes = discrepancy_notes(report.discrepancies)

    rows =
      Enum.map(report.features, fn row ->
        [
          row.id,
          recorded_label(row.recorded),
          reconciled_label(row.reconciled),
          note(row, report.next_runnable, conflict_reasons, discrepancy_notes)
        ]
      end)

    [
      table([["Feature", "Recorded", "Reconciled", "Note"] | rows]),
      discrepancy_footer(report.discrepancies),
      "Spend: $#{fmt_spend(report.spend)} (preserved)   Next runnable: #{inspect(report.next_runnable)}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # ---- helpers --------------------------------------------------------------

  defp recorded_label(nil), do: "—"
  defp recorded_label(status), do: to_string(status)

  defp reconciled_label(:done), do: "done"
  defp reconciled_label(:pending), do: "pending"
  defp reconciled_label(:escalated), do: "escalated"
  defp reconciled_label(:halted), do: "halted"
  defp reconciled_label(:failed), do: "failed"
  defp reconciled_label({:resume, phase}), do: "running (resume: #{phase})"
  defp reconciled_label({:conflict, reason}), do: "conflict:#{reason}"
  # A 016 US3 "absent from backlog" row carries its raw recorded status
  # through unreconciled (e.g. `:running`) — not a shape `Reconcile.result/0`
  # ever produces, so it falls through here.
  defp reconciled_label(other) when is_atom(other), do: to_string(other)

  defp note(%{id: id} = row, next_runnable, conflict_reasons, discrepancy_notes) do
    cond do
      Map.has_key?(conflict_reasons, id) ->
        "CONFLICT — #{Map.fetch!(conflict_reasons, id)}; human resolve"

      row.reconciled in [:escalated, :halted] ->
        "held (human gate)"

      Map.has_key?(discrepancy_notes, id) ->
        Map.fetch!(discrepancy_notes, id)

      id in next_runnable ->
        "next runnable"

      row.corrected? ->
        "corrected"

      true ->
        ""
    end
  end

  # 016 US3: `:unreconcilable` is already surfaced via `conflict_reasons`
  # (report.conflicts is built from it) and `:prereq_missing` never reaches
  # a built report (propose/3 refuses first) — only these two kinds need a
  # dedicated Note.
  defp discrepancy_notes(discrepancies) do
    discrepancies
    |> Enum.filter(&(&1.kind in [:absent_from_backlog, :absent_from_record]))
    |> Map.new(&{&1.id, discrepancy_note_text(&1.kind)})
  end

  defp discrepancy_note_text(:absent_from_backlog),
    do: "restored from record (absent from backlog)"

  defp discrepancy_note_text(:absent_from_record),
    do: "restored from backlog (absent from record)"

  defp discrepancy_footer([]), do: ""

  defp discrepancy_footer(discrepancies) do
    line = Enum.map_join(discrepancies, ", ", &"#{&1.id} #{&1.kind}")
    "Discrepancies: #{line}"
  end

  defp fmt_spend(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt_spend(n), do: to_string(n)

  # Simple monospace table: pad each column to its widest cell.
  defp table(rows) do
    widths =
      rows
      |> Enum.zip()
      |> Enum.map(fn col ->
        col |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
      end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
    end)
  end
end
