defmodule SpeckitOrchestrator.AnalyzeResult do
  @moduledoc """
  Deterministic parser for the `analyze` phase.

  The analyze phase runs read-only and the prompt (see `priv/prompts/analyze.md`)
  instructs the model to end its transcript with a single JSON object of the
  form:

      {"summary": "...", "findings": [{"severity": "critical", "title": "...",
       "detail": "..."}]}

  `parse/1` recovers that JSON from a possibly-noisy transcript (fenced blocks,
  JSON mid-transcript, trailing prose) and classifies it. **Malformed or absent
  JSON is a failure, never a silent pass** — the caller treats `{:error, _}` as a
  failed analyze phase.

  A finding with `severity` in `#{inspect(~w(critical blocker))}`
  (case-insensitive) sets `critical?: true`, which drives the analyze gate
  (`Pipeline.next(:analyze, :ok, %{critical?: true})` → `:halted`).
  """

  alias SpeckitOrchestrator.AnalyzeResult

  @critical_severities ~w(critical blocker)

  defstruct summary: nil, findings: [], critical?: false, raw: %{}

  @type finding :: %{String.t() => term()}
  @type t :: %__MODULE__{
          summary: String.t() | nil,
          findings: [finding()],
          critical?: boolean(),
          raw: map()
        }

  @doc """
  Parse an analyze transcript into `{:ok, %AnalyzeResult{}}` or
  `{:error, reason}`.

  `reason` is `:no_analyze_json` when no JSON object carrying a `"findings"` list
  can be recovered, or `{:invalid_findings, term}` when the recovered object's
  `"findings"` is not a list.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(transcript) when is_binary(transcript) do
    case recover_json(transcript) do
      {:ok, %{"findings" => findings} = obj} when is_list(findings) ->
        {:ok,
         %AnalyzeResult{
           summary: Map.get(obj, "summary"),
           findings: findings,
           critical?: Enum.any?(findings, &critical_finding?/1),
           raw: obj
         }}

      {:ok, %{"findings" => other}} ->
        {:error, {:invalid_findings, other}}

      {:ok, _no_findings_key} ->
        {:error, :no_analyze_json}

      :error ->
        {:error, :no_analyze_json}
    end
  end

  @doc "True when the parsed result carries a Critical/blocker finding."
  @spec critical?(t()) :: boolean()
  def critical?(%AnalyzeResult{critical?: c}), do: c

  defp critical_finding?(%{"severity" => sev}) when is_binary(sev),
    do: String.downcase(sev) in @critical_severities

  defp critical_finding?(_), do: false

  # ---- JSON recovery ------------------------------------------------------

  # Prefer the last decodable object that carries a `"findings"` key; else the
  # last decodable object at all (so a non-list `"findings"` surfaces as an
  # invalid-findings error rather than :no_analyze_json).
  @spec recover_json(String.t()) :: {:ok, map()} | :error
  defp recover_json(transcript) do
    decoded =
      (fenced_blocks(transcript) ++ brace_objects(transcript))
      |> Enum.map(&Jason.decode/1)
      |> Enum.flat_map(fn
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end)

    with_findings = Enum.filter(decoded, &Map.has_key?(&1, "findings"))

    cond do
      with_findings != [] ->
        {:ok, List.last(with_findings)}

      # Recover a truncated/unbalanced findings object (a common model failure:
      # the transcript ends before the closing `}`/`]`, so balanced extraction
      # finds nothing) before falling back to any findings-less object.
      match?({:ok, _}, salvage(transcript)) ->
        salvage(transcript)

      decoded != [] ->
        {:ok, List.last(decoded)}

      true ->
        :error
    end
  end

  # ---- salvage of truncated / unbalanced JSON -----------------------------

  # Take the last object that opens `{ "summary"` (the analyze schema's root),
  # string-aware-balance its unclosed `{`/`[`, and decode. Returns a map only if
  # it decodes AND carries a `"findings"` list — never a partial guess.
  @spec salvage(String.t()) :: {:ok, map()} | :error
  defp salvage(transcript) do
    case last_root_start(transcript) do
      nil ->
        :error

      start ->
        frag = binary_part(transcript, start, byte_size(transcript) - start)

        case Jason.decode(balance_close(frag)) do
          {:ok, %{"findings" => f} = obj} when is_list(f) -> {:ok, obj}
          _ -> :error
        end
    end
  end

  @root_re ~r/\{\s*"summary"/

  defp last_root_start(transcript) do
    case Regex.scan(@root_re, transcript, return: :index) do
      [] -> nil
      matches -> matches |> List.last() |> hd() |> elem(0)
    end
  end

  # Append the closers needed to balance the fragment, closing an unterminated
  # trailing string first. String-aware so braces/brackets inside string values
  # are not counted.
  defp balance_close(frag) do
    {stack, in_str?, _esc?} =
      frag |> String.to_charlist() |> Enum.reduce({[], false, false}, &balance_step/2)

    string_close = if in_str?, do: "\"", else: ""
    closers = stack |> Enum.map(&closer_for/1) |> List.to_string()
    frag <> string_close <> closers
  end

  # state = {stack (openers, head = innermost), in_string?, escaped?}
  defp balance_step(_c, {stack, true, true}), do: {stack, true, false}
  defp balance_step(?\\, {stack, true, false}), do: {stack, true, true}
  defp balance_step(?", {stack, true, false}), do: {stack, false, false}
  defp balance_step(_c, {stack, true, false}), do: {stack, true, false}
  defp balance_step(?", {stack, false, _}), do: {stack, true, false}
  defp balance_step(?{, {stack, false, _}), do: {[?{ | stack], false, false}
  defp balance_step(?[, {stack, false, _}), do: {[?[ | stack], false, false}
  defp balance_step(?}, {[?{ | stack], false, _}), do: {stack, false, false}
  defp balance_step(?], {[?[ | stack], false, _}), do: {stack, false, false}
  defp balance_step(_c, {stack, false, esc}), do: {stack, false, esc}

  defp closer_for(?{), do: ?}
  defp closer_for(?[), do: ?]

  @fence_re ~r/```(?:json)?\s*(\{.*?\})\s*```/s

  defp fenced_blocks(transcript) do
    @fence_re
    |> Regex.scan(transcript, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  # Every top-level balanced `{...}` substring, in order of appearance. Naive
  # brace counting (adequate for the simple analyze JSON; fenced blocks are the
  # primary recovery path anyway).
  defp brace_objects(transcript) do
    do_scan(String.to_charlist(transcript), 0, [], [])
  end

  # chars, depth, current-object (reversed charlist), acc (objects, reversed)
  defp do_scan([], _depth, _cur, acc), do: Enum.reverse(acc)

  defp do_scan([?{ | rest], 0, _cur, acc), do: do_scan(rest, 1, [?{], acc)
  defp do_scan([?{ | rest], depth, cur, acc), do: do_scan(rest, depth + 1, [?{ | cur], acc)

  defp do_scan([?} | rest], 1, cur, acc) do
    obj = [?} | cur] |> Enum.reverse() |> List.to_string()
    do_scan(rest, 0, [], [obj | acc])
  end

  defp do_scan([?} | rest], depth, cur, acc) when depth > 1,
    do: do_scan(rest, depth - 1, [?} | cur], acc)

  defp do_scan([_c | rest], 0, cur, acc), do: do_scan(rest, 0, cur, acc)
  defp do_scan([c | rest], depth, cur, acc), do: do_scan(rest, depth, [c | cur], acc)
end
