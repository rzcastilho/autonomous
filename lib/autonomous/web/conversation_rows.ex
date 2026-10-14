defmodule Autonomous.Web.ConversationRows do
  @moduledoc """
  Pure block model for the conversation views (features 040, 042). The live
  view and the saved-conversation view render the same blocks through the same
  component, so what an operator watched is what they later review.

  Placement comes from `Autonomous.Web.ConversationClass`; this module turns
  each visible entry into a **block** and threads a context so a stream of
  single entries blocks the same way a whole list does.

  * A tool result is grouped **inside its call's block** (paired by
    `tool_use_id`): the call block is re-emitted under the same key, so a
    LiveView stream replaces it in place and parallel calls keep call order. A
    result whose call is not in the context is a standalone `:result` block.
  * A call with no result when the session's `:end` entry arrives is tagged
    `unfinished?` — the shape a deadline cut leaves behind.
  * A body over #{40} lines or #{4_000} chars is shown truncated with
    `omitted: %{lines:, chars:}`; the underlying entry is never changed, and
    `expand/2` renders it whole.
  * Entries hidden by the classifier (`visible?/2`) produce no block but still
    advance the context; `new(all_frames: true)` shows every entry.
  * Outcomes render through `Autonomous.Report.format_outcome/1` — no
    `inspect/1` in the markup.

  `ctx.stale` holds blocks of earlier calls that the latest `:end` tagged
  unfinished and that therefore need re-inserting.
  """

  alias Autonomous.{ConversationEntry, ConversationOutcome, Report}
  alias Autonomous.Web.{ConversationClass, ToolSummary}

  @max_lines 40
  @max_chars 4_000
  @preview_lines 5

  @type result_part :: %{
          seq: non_neg_integer() | nil,
          preview: String.t(),
          more_lines: non_neg_integer(),
          full: String.t() | nil,
          error?: boolean()
        }

  @type block :: %{
          key: String.t(),
          seq: non_neg_integer() | nil,
          at: String.t() | nil,
          kind: atom(),
          class: ConversationClass.row_class(),
          label: String.t(),
          summary: String.t(),
          format: :markup | :mono | :plain,
          body: String.t(),
          omitted: %{lines: non_neg_integer(), chars: non_neg_integer()} | nil,
          tool_name: String.t() | nil,
          tool_use_id: String.t() | nil,
          result: result_part() | nil,
          flag: nil | :is_error | :hook_failed | :result_error,
          unfinished?: boolean(),
          outcome: String.t() | nil,
          chip: String.t() | nil
        }

  @type ctx :: %{
          calls: %{String.t() => block()},
          names: %{String.t() => String.t()},
          stale: [block()],
          result_owner: %{non_neg_integer() => String.t()},
          all_frames?: boolean()
        }

  @doc "Fresh context. Option: `:all_frames` (show every entry as a block)."
  @spec new(keyword()) :: ctx()
  def new(opts \\ []),
    do: %{
      calls: %{},
      names: %{},
      stale: [],
      result_owner: %{},
      all_frames?: Keyword.get(opts, :all_frames, false)
    }

  @doc """
  Blocks for `entries` (in order) and the updated context. A block may appear
  again in a later call (pairing, `unfinished`) under the same `key`. Options:
  `:expand` (render untruncated).
  """
  @spec rows([ConversationEntry.t()], ctx(), keyword()) :: {[block()], ctx()}
  def rows(entries, ctx \\ new(), opts \\ []) do
    ctx = %{ctx | stale: []}

    {blocks, ctx} =
      Enum.flat_map_reduce(entries, ctx, fn entry, ctx -> one(entry, ctx, opts) end)

    {blocks, ctx} = finalize(blocks, ctx)
    {collapse(blocks), ctx}
  end

  @doc """
  The full (untruncated) block for an entry. A tool result returns its owning
  call block carrying the whole result; a result with no call in view returns
  the standalone result block.
  """
  @spec expand(ConversationEntry.t(), ctx()) :: block() | nil
  def expand(%ConversationEntry{kind: :tool_result} = entry, ctx) do
    id = entry.body["tool_use_id"]

    case Map.get(ctx.calls, id) do
      %{result: %{seq: seq}} = call when seq == entry.seq ->
        %{call | result: result_part(entry, true)}

      _ ->
        standalone_result(entry, ctx, true)
    end
  end

  def expand(%ConversationEntry{} = entry, ctx) do
    {blocks, _ctx} = one(entry, %{ctx | stale: []}, expand: true)
    List.last(blocks)
  end

  # ---- per entry ----------------------------------------------------------

  defp one(%ConversationEntry{} = e, ctx, opts) do
    c = ConversationClass.classify(e)

    if ConversationClass.visible?(c, ctx.all_frames?),
      do: build(e, c, ctx, opts),
      else: {[], ctx}
  end

  defp build(%ConversationEntry{kind: :tool_call} = e, _c, ctx, opts) do
    id = e.body["tool_use_id"]
    name = e.body["name"]

    block =
      base(e, :call, "tool call", :mono, pretty(e.body["input"]), opts)
      |> Map.merge(%{
        summary: ToolSummary.summary(name, e.body["input"]),
        tool_name: name,
        tool_use_id: id
      })

    ctx =
      if id,
        do: %{ctx | calls: Map.put(ctx.calls, id, block), names: Map.put(ctx.names, id, name)},
        else: ctx

    {[block], ctx}
  end

  defp build(%ConversationEntry{kind: :tool_result} = e, _c, ctx, opts) do
    id = e.body["tool_use_id"]
    part = result_part(e, Keyword.get(opts, :expand, false))

    case Map.get(ctx.calls, id) do
      nil ->
        {[standalone_result(e, ctx, Keyword.get(opts, :expand, false))], ctx}

      call ->
        call = %{call | result: part, unfinished?: false, flag: if(part.error?, do: :is_error)}

        {[call],
         %{
           ctx
           | calls: Map.put(ctx.calls, id, call),
             result_owner: Map.put(ctx.result_owner, e.seq, id)
         }}
    end
  end

  defp build(%ConversationEntry{kind: :end} = e, _c, ctx, _opts) do
    {text, chip} = outcome(e)

    block =
      e
      |> raw_block(:end, "end", :mono, text)
      |> Map.merge(%{summary: text, outcome: text, chip: chip})

    {stale, calls} = tag_unfinished(ctx.calls)
    {[block], %{ctx | calls: calls, stale: stale}}
  end

  defp build(%ConversationEntry{kind: :assistant_text} = e, _c, ctx, opts),
    do: {[base(e, :prose, "assistant", :markup, to_string(e.body["text"]), opts)], ctx}

  defp build(%ConversationEntry{kind: :thinking} = e, _c, ctx, opts) do
    text = to_string(e.body["text"])

    {[base(e, :thinking, "thinking", :plain, text, opts) |> Map.put(:summary, first_line(text))],
     ctx}
  end

  defp build(%ConversationEntry{kind: :prompt} = e, _c, ctx, opts) do
    text = to_string(e.body["text"])

    {[base(e, :context, "prompt", :plain, text, opts) |> Map.put(:summary, first_line(text))],
     ctx}
  end

  defp build(%ConversationEntry{kind: :start} = e, _c, ctx, _opts) do
    summary = "session opened" <> opt(e.body["model"])

    {[raw_block(e, :divider, "start", :mono, start_text(e.body)) |> Map.put(:summary, summary)],
     ctx}
  end

  defp build(%ConversationEntry{} = e, %{row_class: :context}, ctx, opts) do
    text = to_string(get_in(e.body, ["raw", "text"]))

    {[base(e, :context, "context", :plain, text, opts) |> Map.put(:summary, first_line(text))],
     ctx}
  end

  defp build(%ConversationEntry{} = e, %{row_class: :marker} = c, ctx, opts) do
    block =
      base(e, :marker, c.label, :mono, pretty(payload(e)), opts)
      |> Map.merge(%{summary: marker_summary(e, c), flag: c.flag})

    {[block], ctx}
  end

  defp build(%ConversationEntry{} = e, c, ctx, opts) do
    {[base(e, :raw, c.label, :mono, pretty(payload(e)), opts) |> Map.put(:summary, c.label)], ctx}
  end

  defp payload(%ConversationEntry{kind: :system, body: body}), do: Map.drop(body, ["subtype"])
  defp payload(%ConversationEntry{body: body}), do: body

  # ---- marker text --------------------------------------------------------

  defp marker_summary(%ConversationEntry{kind: :result, body: b}, _c),
    do: join(["result", b["subtype"]])

  defp marker_summary(%ConversationEntry{body: %{"data" => data}} = e, c) do
    case ConversationClass.sub_kind(e) do
      "task_started" ->
        join(["task started", data["description"]])

      "task_notification" ->
        join(["task #{data["status"]}", data["summary"]])

      "api_retry" ->
        join([
          "api_retry",
          "attempt #{data["attempt"]}/#{data["max_retries"]}",
          data["error"],
          data["retry_delay_ms"] && "#{data["retry_delay_ms"]} ms"
        ])

      "hook_response" ->
        join([
          "hook_response",
          data["hook_name"],
          data["exit_code"] && "exit #{data["exit_code"]}"
        ])

      _ ->
        c.label
    end
  end

  defp marker_summary(_e, c), do: c.label

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, false, ""])) |> Enum.join(" · ")

  defp opt(nil), do: ""
  defp opt(value), do: " · " <> to_string(value)

  # ---- block construction -------------------------------------------------

  defp raw_block(%ConversationEntry{} = e, class, label, format, body) do
    %{
      key: "entry-#{e.seq}",
      seq: e.seq,
      at: e.at,
      kind: e.kind,
      class: class,
      label: label,
      summary: label,
      format: format,
      body: body,
      omitted: nil,
      tool_name: nil,
      tool_use_id: nil,
      result: nil,
      flag: nil,
      unfinished?: false,
      outcome: nil,
      chip: nil
    }
  end

  defp base(%ConversationEntry{} = e, class, label, format, text, opts) do
    {shown, omitted} =
      if Keyword.get(opts, :expand, false), do: {text, nil}, else: truncate(text)

    %{raw_block(e, class, label, format, shown) | omitted: omitted}
  end

  defp standalone_result(%ConversationEntry{} = e, ctx, expand?) do
    id = e.body["tool_use_id"]
    name = Map.get(ctx.names, id)

    raw_block(e, :result, "tool result", :mono, "")
    |> Map.merge(%{
      summary: "tool result" <> opt(name),
      tool_name: name,
      tool_use_id: id,
      result: result_part(e, expand?),
      flag: if(e.body["is_error"] == true, do: :is_error)
    })
  end

  defp result_part(%ConversationEntry{} = e, expand?) do
    text = output_text(e.body["output"])
    lines = String.split(text, "\n")

    preview =
      lines |> Enum.take(@preview_lines) |> Enum.join("\n") |> String.slice(0, @max_chars)

    %{
      seq: e.seq,
      preview: preview,
      more_lines: max(length(lines) - @preview_lines, 0),
      full: if(expand?, do: text),
      error?: e.body["is_error"] == true
    }
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

  defp tag_unfinished(calls) do
    stale =
      calls
      |> Map.values()
      |> Enum.filter(&(is_nil(&1.result) and not &1.unfinished?))
      |> Enum.map(&%{&1 | unfinished?: true})

    {stale, Enum.reduce(stale, calls, &Map.put(&2, &1.tool_use_id, &1))}
  end

  # An `:end` in this batch tags open calls: blocks inside the batch are updated
  # in place; earlier ones are handed back in `ctx.stale` for re-insertion.
  defp finalize(blocks, %{stale: []} = ctx), do: {blocks, ctx}

  defp finalize(blocks, %{stale: stale} = ctx) do
    by_key = Map.new(stale, &{&1.key, &1})
    in_batch = MapSet.new(blocks, & &1.key)

    blocks = Enum.map(blocks, &Map.get(by_key, &1.key, &1))
    {blocks, %{ctx | stale: Enum.reject(stale, &MapSet.member?(in_batch, &1.key))}}
  end

  # One block per key, at the position of its first appearance, with the content
  # of its last (a call paired within the same batch).
  defp collapse(blocks) do
    last = Map.new(blocks, &{&1.key, &1})

    blocks
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(&Map.fetch!(last, &1.key))
  end

  # ---- text ---------------------------------------------------------------

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp start_text(body) do
    [body["run_id"], body["feature_id"], body["phase"], body["model"]]
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

  @doc """
  The rendered outcome text and its status name of an `:end` entry (also read by
  `SessionStatus`). Colour travels as a name only (`CoreComponents.status_class/1`).
  """
  @spec outcome(ConversationEntry.t()) :: {String.t(), String.t()}
  def outcome(%ConversationEntry{body: body}) do
    outcome = body["outcome"] |> to_string() |> ConversationOutcome.decode()
    {Report.format_outcome(outcome), chip(outcome)}
  end

  defp chip(:completed), do: "done"
  defp chip({:backgrounded_command, _}), do: "blocked"
  defp chip(:incomplete_session), do: "blocked"
  defp chip(_failure), do: "failed"
end
