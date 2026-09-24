defmodule SpeckitOrchestrator.Report do
  @moduledoc """
  Render a `Coordinator` snapshot as a plain-text table for the `iex` operator
  surface. Pure — takes the snapshot map, returns a string.
  """

  alias SpeckitOrchestrator.PublishOutcome

  @doc "Format a `Coordinator.status/0` snapshot as a table."
  @spec format_status(map()) :: String.t()
  def format_status(snapshot) do
    rows =
      snapshot
      |> Map.get(:per_feature, %{})
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, info} ->
        [id, spec_number(Map.get(info, :spec_number)), to_string(info.status), elapsed(info.elapsed_ms)]
      end)

    [
      table([["FEATURE", "SPEC", "STATUS", "ELAPSED"] | rows]),
      "",
      "totals: #{format_totals(Map.get(snapshot, :totals, %{}))}",
      "spend:  $#{fmt_spend(Map.get(snapshot, :spend, 0.0))}" <>
        breaker(Map.get(snapshot, :breaker_tripped, false)),
      advanced_line(snapshot),
      awaiting_line(snapshot),
      clarify_line(snapshot),
      stopped_line(snapshot),
      run_state(snapshot)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ---- helpers ------------------------------------------------------------

  # `number` (the FEATURE column) and `spec_number` are distinct fields
  # (022) — the wave-local identity and the repo-monotonic spec directory
  # number — rendered under their own labels, "not allocated" before the
  # feature has started (Constitution Principle VII: machine values, no
  # borrowed number).
  defp spec_number(n) when is_integer(n), do: String.pad_leading(Integer.to_string(n), 3, "0")
  defp spec_number(_), do: "not allocated"

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

  # Feature 021: absent entirely when no feature advanced under *proceed*, so
  # the :escalate-path report is byte-identical to today's (SC-002).
  defp advanced_line(snapshot) do
    case Map.get(snapshot, :report) do
      %{advanced_with_findings: [_ | _] = ids} ->
        "advanced: #{Enum.join(ids, ", ")}   (proceeded past unresolved findings)"

      _ ->
        nil
    end
  end

  # FR-017: names the feature that broke the chain and why, when the run
  # parked rather than drained clean.
  defp stopped_line(snapshot) do
    case Map.get(snapshot, :report) do
      %{stopped_by: %{feature_id: id, status: status, reason: reason}} ->
        "stopped: #{id} (#{status}) — #{format_reason(reason)}"

      _ ->
        nil
    end
  end

  # `{:empty_checkpoint, phase}` (net two) reads distinctly from
  # `{:missing_artifact, phase, artifact}` — same phase, different failure:
  # the phase committed no change at all, vs. it wrote something that isn't
  # the named artifact. A publish-failed/branch-drift reason (027) renders via
  # `PublishOutcome.describe/1`. Every other reason renders as before (FR-013).
  #
  # 029: every non-answer exit from `:awaiting_answers` reaches this as a
  # `{:needs_human, sub}` tuple (research.md R5); plain `:needs_human` (mode
  # off, or the pre-029 clarify escalation) is untouched by these clauses and
  # falls through to the catch-all exactly as before (SC-003). Public (not
  # `defp`) so a test can assert every variant directly.
  @doc "Render a terminal/escalation reason as it appears in the status table and reports."
  @spec format_reason(term()) :: String.t()
  def format_reason({:needs_human, :rounds_exhausted}),
    do: "needs human — clarify rounds exhausted"

  def format_reason({:needs_human, :answer_timeout}), do: "needs human — answer timeout"

  def format_reason({:needs_human, :breaker}),
    do: "needs human — breaker tripped while awaiting answers"

  def format_reason({:needs_human, :drained}),
    do: "needs human — drained while awaiting answers"

  def format_reason({:needs_human, :restart}),
    do: "needs human — orchestrator restarted while awaiting answers"

  def format_reason({:empty_checkpoint, phase}), do: "#{phase} committed no change"
  def format_reason(reason), do: PublishOutcome.describe(reason) || inspect(reason)

  defp run_state(%{finished?: true}), do: "state:  finished"
  defp run_state(_), do: "state:  running"

  # 029, contracts/facade-api.md Status, research.md R14: absent entirely when
  # nothing awaits (mode off, or on but nothing waiting), so mode-off output
  # is byte-identical (FR-002). Structurally at most one entry (one-at-a-time
  # run), but this renders any number the same way.
  defp awaiting_line(snapshot) do
    case Map.get(snapshot, :awaiting, %{}) do
      empty when map_size(empty) == 0 ->
        nil

      awaiting ->
        awaiting
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map_join("\n", &format_awaiting/1)
    end
  end

  defp format_awaiting({id, %{round: round, max_rounds: max_rounds} = info}) do
    "awaiting: #{id} round #{round}/#{max_rounds} waited " <>
      "#{duration(elapsed_seconds(info))} #{duration(remaining_seconds(info))} left"
  end

  defp elapsed_seconds(%{started_at: started_at}),
    do: DateTime.diff(DateTime.utc_now(), started_at)

  defp remaining_seconds(%{deadline_at: deadline_at}),
    do: max(DateTime.diff(deadline_at, DateTime.utc_now()), 0)

  defp duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp duration(seconds), do: "#{div(seconds, 60)}m"

  # 029, data-model.md Coordinator report, research.md R15: absent (not an
  # empty "clarify:" line) whenever no feature ever opened a round — the
  # same byte-identical-when-off discipline as `advanced_line/1`.
  defp clarify_line(snapshot) do
    case Map.get(snapshot, :report) do
      %{clarify_rounds: rounds} when map_size(rounds) > 0 ->
        "clarify: " <>
          (rounds
           |> Enum.sort_by(fn {id, _} -> id end)
           |> Enum.map_join("  ", fn {id, rs} -> "#{id}=#{length(rs)}" end))

      _ ->
        nil
    end
  end

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
