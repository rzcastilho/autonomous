defmodule SpeckitOrchestrator.NeedsHuman do
  @moduledoc """
  The one `## NEEDS HUMAN` rule (feature 029, FR-018,
  contracts/needs-human-format.md). `RunFeaturePhase`'s clarify gate and
  `spec.md` scan, and `EscalationsLive`'s question panel, all call this
  module instead of keeping their own copy of the regex — moved verbatim,
  byte-identical on today's inputs (SC-003).

  `parse_questions/1` additionally understands the numbered `### Qn` format
  `priv/prompts/clarify.md` teaches the reviewer, falling back to freeform
  whenever the block doesn't parse cleanly (Principle II: salvage, don't
  invent a partial parse).
  """

  defmodule Question do
    @moduledoc "One parsed `### Qn` item (data-model.md)."

    defstruct [:id, :text, :context, :options, :recommended]

    @type t :: %__MODULE__{
            id: String.t(),
            text: String.t(),
            context: String.t() | nil,
            options: [String.t()],
            recommended: String.t() | nil
          }
  end

  # Line-anchored: prose that merely *mentions* the heading must not be
  # mistaken for it (moved from `RunFeaturePhase`/`EscalationsLive`).
  @marker ~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m

  @item_heading ~r/^###[ \t]+Q(\d+)[:.][ \t]*(.*)$/
  @field_start ~r/^\*\*(Context|Options|Recommended)\*\*:[ \t]*(.*)$/i

  @doc "The literal marker regex, exported so callers never redeclare it."
  @spec marker() :: Regex.t()
  def marker, do: @marker

  @doc """
  Rehydrate a `parse_questions/1` result that was round-tripped through
  storage as plain maps (`Store.Writer.normalize_questions/1`, Mnesia-safe —
  no `Question` struct dependency at the store boundary) back into
  `Question` structs, so callers like `InteractiveClarify.AnswerSet.build/2`
  see the same shape whether the parse is fresh or read back from a round row.
  """
  @spec rehydrate({:numbered, [map()]} | {:freeform, String.t()}) ::
          {:numbered, [Question.t()]} | {:freeform, String.t()}
  def rehydrate({:numbered, maps}), do: {:numbered, Enum.map(maps, &struct(Question, &1))}
  def rehydrate({:freeform, text}), do: {:freeform, text}

  @doc "Whether `text` carries a `## NEEDS HUMAN` heading on its own line."
  @spec present?(String.t() | nil) :: boolean()
  def present?(text), do: Regex.match?(@marker, text || "")

  @doc """
  The block after the heading, up to the next `^## ` heading or EOF, trimmed.
  `nil` when the marker is absent.
  """
  @spec extract(String.t() | nil) :: String.t() | nil
  def extract(text) do
    text = text || ""

    if present?(text) do
      case Regex.split(@marker, text, parts: 2) do
        [_before, after_marker] ->
          after_marker
          |> String.split(~r/^\#\#[ \t]/m, parts: 2)
          |> List.first()
          |> String.trim()

        _ ->
          nil
      end
    else
      nil
    end
  end

  @doc """
  Parse a `## NEEDS HUMAN` block body into either the numbered format or a
  freeform fallback. Never returns a partial parse — any malformed item,
  non-contiguous id, or stray text before `### Q1` falls the whole block back
  to `{:freeform, block}` (contracts/needs-human-format.md).
  """
  @spec parse_questions(String.t() | nil) ::
          {:numbered, [Question.t()]} | {:freeform, String.t()}
  def parse_questions(block) do
    block = block || ""

    if String.trim(block) == "" do
      {:freeform, ""}
    else
      case parse_numbered(block) do
        {:ok, questions} -> {:numbered, questions}
        :error -> {:freeform, block}
      end
    end
  end

  defp parse_numbered(block) do
    lines = String.split(block, "\n")

    headings =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _idx} -> Regex.match?(@item_heading, line) end)

    with false <- headings == [],
         :ok <- ensure_no_leading_text(lines, headings),
         :ok <- ensure_contiguous(headings) do
      build_questions(lines, headings)
    else
      true -> :error
      :error -> :error
    end
  end

  defp ensure_no_leading_text(_lines, [{_line, 0} | _rest]), do: :ok

  defp ensure_no_leading_text(lines, [{_line, first_idx} | _rest]) do
    leading = Enum.slice(lines, 0, first_idx)

    if Enum.all?(leading, &(String.trim(&1) == "")) do
      :ok
    else
      :error
    end
  end

  defp ensure_contiguous(headings) do
    ids = Enum.map(headings, fn {line, _idx} -> heading_id(line) end)

    if ids == Enum.to_list(1..length(ids)) do
      :ok
    else
      :error
    end
  end

  defp heading_id(line) do
    [_, id_str, _text] = Regex.run(@item_heading, line)
    String.to_integer(id_str)
  end

  defp build_questions(lines, headings) do
    total = length(lines)
    boundaries = Enum.map(headings, fn {_line, idx} -> idx end) ++ [total]

    headings
    |> Enum.zip(Enum.drop(boundaries, 1))
    |> Enum.reduce_while({:ok, []}, fn {{heading_line, start_idx}, end_idx}, {:ok, acc} ->
      body = Enum.slice(lines, (start_idx + 1)..(end_idx - 1)//1)

      case build_question(heading_line, body) do
        {:ok, question} -> {:cont, {:ok, [question | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, questions} -> {:ok, Enum.reverse(questions)}
      :error -> :error
    end
  end

  defp build_question(heading_line, body_lines) do
    [_, id_str, text] = Regex.run(@item_heading, heading_line)
    fields = parse_fields(body_lines)

    context = fields |> Map.get(:context) |> blank_to_nil()
    recommended = fields |> Map.get(:recommended) |> blank_to_nil()
    options = fields |> Map.get(:options) |> parse_options()

    if is_nil(recommended) and options == [] do
      :error
    else
      {:ok,
       %Question{
         id: "Q#{id_str}",
         text: String.trim(text),
         context: context,
         options: options,
         recommended: recommended
       }}
    end
  end

  defp parse_fields(lines) do
    {fields, _current} =
      Enum.reduce(lines, {%{}, nil}, fn line, {fields, current} ->
        case Regex.run(@field_start, line) do
          [_, name, rest] ->
            key = name |> String.downcase() |> String.to_existing_atom()
            {Map.update(fields, key, rest, &(&1 <> "\n" <> rest)), key}

          nil ->
            cond do
              String.trim(line) == "" -> {fields, current}
              is_nil(current) -> {fields, current}
              true -> {Map.update(fields, current, line, &(&1 <> "\n" <> line)), current}
            end
        end
      end)

    Map.new(fields, fn {k, v} -> {k, String.trim(v)} end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp parse_options(nil), do: []

  defp parse_options(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        []

      String.contains?(trimmed, "·") ->
        trimmed
        |> String.split("·")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      Enum.any?(String.split(trimmed, "\n"), &String.starts_with?(String.trim(&1), "- ")) ->
        trimmed
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> Enum.map(&String.trim_leading(&1, "- "))
        |> Enum.map(&String.trim/1)

      true ->
        [trimmed]
    end
  end
end
