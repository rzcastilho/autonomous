defmodule Autonomous.Web.ConversationRows do
  @moduledoc """
  Pure row model for the conversation views (feature 040). One row per
  `ConversationEntry`; the live view and the saved-conversation view render the
  same rows through the same component, so what an operator watched is what
  they later review.

  * A tool result is paired with its call by `tool_use_id` (the result row
    carries the call's tool name).
  * A call that has no result when the session's `:end` entry arrives is tagged
    `unfinished?` — the shape a deadline cut leaves behind.
  * A body over #{40} lines or #{4_000} chars is shown truncated with
    `omitted: %{lines:, chars:}`; the underlying entry is never changed, and
    `rows/3` with `expand: true` renders it whole.
  * Outcomes render through `Autonomous.Report.format_outcome/1` — no
    `inspect/1` in the markup.

  `rows/3` threads a context so a stream of single entries pairs and tags the
  same way a whole list does; `ctx.stale` holds rows of earlier calls that the
  latest `:end` tagged unfinished and that therefore need re-inserting.
  """

  alias Autonomous.{ConversationEntry, ConversationOutcome, Report}

  @max_lines 40
  @max_chars 4_000

  @type row :: %{
          key: String.t(),
          seq: non_neg_integer() | nil,
          at: String.t() | nil,
          kind: atom(),
          label: String.t(),
          format: :markup | :mono | :plain,
          text: String.t(),
          omitted: %{lines: non_neg_integer(), chars: non_neg_integer()} | nil,
          tool_name: String.t() | nil,
          tool_use_id: String.t() | nil,
          error?: boolean(),
          unfinished?: boolean(),
          outcome: String.t() | nil,
          chip: String.t() | nil
        }

  @type ctx :: %{
          calls: %{String.t() => row()},
          names: %{String.t() => String.t()},
          stale: [row()]
        }

  @spec new() :: ctx()
  def new, do: %{calls: %{}, names: %{}, stale: []}

  @doc """
  Rows for `entries` (in order) and the updated context. Options: `:expand`
  (render untruncated).
  """
  @spec rows([ConversationEntry.t()], ctx(), keyword()) :: {[row()], ctx()}
  def rows(entries, ctx \\ new(), opts \\ []) do
    ctx = %{ctx | stale: []}

    {rows, ctx} =
      Enum.map_reduce(entries, ctx, fn entry, ctx -> one(entry, ctx, opts) end)

    {rows, ctx} = finalize(rows, ctx)
    {rows, ctx}
  end

  @doc "One entry as a row, without touching the context (used to expand a row in place)."
  @spec row(ConversationEntry.t(), ctx(), keyword()) :: row()
  def row(%ConversationEntry{} = entry, ctx, opts \\ []) do
    {row, _ctx} = one(entry, ctx, opts)
    row
  end

  # ---- per entry ----------------------------------------------------------

  defp one(%ConversationEntry{kind: :tool_call} = e, ctx, opts) do
    id = e.body["tool_use_id"]
    name = e.body["name"]

    row =
      base(e, "tool call", :mono, pretty(e.body["input"]), opts)
      |> Map.merge(%{tool_name: name, tool_use_id: id})

    ctx =
      if id,
        do: %{ctx | calls: Map.put(ctx.calls, id, row), names: Map.put(ctx.names, id, name)},
        else: ctx

    {row, ctx}
  end

  defp one(%ConversationEntry{kind: :tool_result} = e, ctx, opts) do
    id = e.body["tool_use_id"]
    {call, calls} = Map.pop(ctx.calls, id)

    row =
      base(e, "tool result", :mono, output_text(e.body["output"]), opts)
      |> Map.merge(%{
        tool_name: (call && call.tool_name) || Map.get(ctx.names, id),
        tool_use_id: id,
        error?: e.body["is_error"] == true
      })

    {row, %{ctx | calls: calls}}
  end

  defp one(%ConversationEntry{kind: :end} = e, ctx, _opts) do
    outcome = e.body["outcome"] |> to_string() |> ConversationOutcome.decode()
    text = Report.format_outcome(outcome)

    row =
      e
      |> raw_row("end", :mono, text)
      |> Map.merge(%{outcome: text, chip: chip(outcome)})

    stale = ctx.calls |> Map.values() |> Enum.map(&%{&1 | unfinished?: true})
    {row, %{ctx | calls: %{}, stale: stale}}
  end

  defp one(%ConversationEntry{kind: :assistant_text} = e, ctx, opts),
    do: {base(e, "assistant", :markup, to_string(e.body["text"]), opts), ctx}

  defp one(%ConversationEntry{kind: :thinking} = e, ctx, opts),
    do: {base(e, "thinking", :plain, to_string(e.body["text"]), opts), ctx}

  defp one(%ConversationEntry{kind: :prompt} = e, ctx, opts),
    do: {base(e, "prompt", :plain, to_string(e.body["text"]), opts), ctx}

  defp one(%ConversationEntry{kind: :start} = e, ctx, _opts),
    do: {raw_row(e, "start", :mono, start_text(e.body)), ctx}

  defp one(%ConversationEntry{kind: :system} = e, ctx, opts),
    do:
      {base(e, "system", :mono, pretty(Map.drop(e.body, ["subtype"])), opts) |> put_subtype(e),
       ctx}

  defp one(%ConversationEntry{kind: :result} = e, ctx, opts),
    do: {base(e, "result", :mono, pretty(e.body), opts), ctx}

  defp one(%ConversationEntry{} = e, ctx, opts),
    do: {base(e, "other", :mono, pretty(e.body), opts), ctx}

  defp put_subtype(row, %{body: %{"subtype" => s}}) when is_binary(s),
    do: %{row | label: "system · " <> s}

  defp put_subtype(row, _), do: row

  # ---- row construction ---------------------------------------------------

  defp raw_row(%ConversationEntry{} = e, label, format, text) do
    %{
      key: "entry-#{e.seq}",
      seq: e.seq,
      at: e.at,
      kind: e.kind,
      label: label,
      format: format,
      text: text,
      omitted: nil,
      tool_name: nil,
      tool_use_id: nil,
      error?: false,
      unfinished?: false,
      outcome: nil,
      chip: nil
    }
  end

  defp base(%ConversationEntry{} = e, label, format, text, opts) do
    {shown, omitted} =
      if Keyword.get(opts, :expand, false), do: {text, nil}, else: truncate(text)

    %{raw_row(e, label, format, shown) | omitted: omitted}
  end

  @doc "Head of `text` within the line/char limits and what was left out."
  @spec truncate(String.t()) ::
          {String.t(), nil | %{lines: non_neg_integer(), chars: non_neg_integer()}}
  def truncate(text) do
    lines = String.split(text, "\n")

    if length(lines) <= @max_lines and String.length(text) <= @max_chars do
      {text, nil}
    else
      head =
        lines
        |> Enum.take(@max_lines)
        |> Enum.join("\n")
        |> String.slice(0, @max_chars)

      kept_lines = length(String.split(head, "\n"))

      {head,
       %{
         lines: max(length(lines) - kept_lines, 0),
         chars: String.length(text) - String.length(head)
       }}
    end
  end

  # An `:end` in this batch tags open calls: rows inside the batch are updated
  # in place; earlier ones are handed back in `ctx.stale` for re-insertion.
  defp finalize(rows, %{stale: []} = ctx), do: {rows, ctx}

  defp finalize(rows, %{stale: stale} = ctx) do
    by_key = Map.new(stale, &{&1.key, &1})
    in_batch = MapSet.new(rows, & &1.key)

    rows = Enum.map(rows, &Map.get(by_key, &1.key, &1))
    {rows, %{ctx | stale: Enum.reject(stale, &MapSet.member?(in_batch, &1.key))}}
  end

  # ---- text ---------------------------------------------------------------

  defp start_text(body) do
    [
      body["run_id"],
      body["feature_id"],
      body["phase"],
      body["model"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp pretty(nil), do: ""
  defp pretty(value) when is_binary(value), do: value

  defp pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> Kernel.inspect(value)
    end
  end

  defp output_text(nil), do: ""
  defp output_text(text) when is_binary(text), do: text

  defp output_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      other -> pretty(other)
    end)
  end

  defp output_text(other), do: pretty(other)

  # Status colour travels as a name only (`CoreComponents.status_class/1`).
  defp chip(:completed), do: "done"
  defp chip({:backgrounded_command, _}), do: "blocked"
  defp chip(:incomplete_session), do: "blocked"
  defp chip(_failure), do: "failed"
end
