defmodule Autonomous.ConversationEntry do
  @moduledoc """
  One conversation entry — a line of the saved file and a live message
  (feature 040, R5). Pure.

  `from_frame/1` normalizes one raw CLI frame (`ClaudeAgentSDK.Message`) into
  zero or more entries; `seq` and `at` are assigned later by the recorder.
  Bodies carry **string keys** so the live entry and the decoded saved entry are
  identical. Nothing is dropped: an unrecognized frame becomes `:other` with its
  whole raw map (FR-013); `stream_event` partials produce no entry because their
  content arrives complete in the assistant frame.
  """

  @kinds ~w(start prompt assistant_text thinking tool_call tool_result system result usage stderr other end)a
  @kind_by_name Map.new(@kinds, &{Atom.to_string(&1), &1})

  defstruct [:seq, :at, :kind, body: %{}]

  @type kind ::
          :start
          | :prompt
          | :assistant_text
          | :thinking
          | :tool_call
          | :tool_result
          | :system
          | :result
          | :usage
          | :stderr
          | :other
          | :end

  @type t :: %__MODULE__{
          seq: non_neg_integer() | nil,
          at: String.t() | nil,
          kind: kind(),
          body: map()
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec new(kind(), map()) :: t()
  def new(kind, body) when kind in @kinds, do: %__MODULE__{kind: kind, body: body}

  @doc "A recorded CLI error-stream line (feature 043)."
  @spec stderr(String.t()) :: t()
  def stderr(line) when is_binary(line), do: new(:stderr, %{"line" => line})

  @doc "The receipt for stderr lines discarded between the kept head and tail."
  @spec stderr_dropped(pos_integer()) :: t()
  def stderr_dropped(n) when is_integer(n) and n > 0,
    do: new(:stderr, %{"notice" => "dropped", "dropped" => n})

  @doc "Entries for one raw frame."
  @spec from_frame(term()) :: [t()]
  def from_frame(%{type: type} = frame) do
    raw = raw(frame)

    case type do
      :stream_event -> usage(frame, raw)
      :assistant -> raw |> assistant() |> attribute(raw)
      :user -> raw |> user() |> attribute(raw)
      :system -> [system(frame, raw)]
      :result -> [result(frame, raw)]
      _ -> [new(:other, %{"raw" => raw_or_frame(frame, raw)})]
    end
  end

  def from_frame(other), do: [new(:other, %{"raw" => jsonable(other)})]

  defp raw(%{raw: raw}) when is_map(raw), do: raw
  defp raw(_), do: %{}

  defp raw_or_frame(_frame, raw) when map_size(raw) > 0, do: raw
  defp raw_or_frame(frame, _), do: jsonable(Map.from_struct(frame))

  # Subagent attribution is recorded, never rendered (feature 043, R5): only a
  # non-empty string is kept, so an absent id is an absent key.
  defp attribute(entries, raw) do
    case parent_id(raw) do
      nil -> entries
      id -> Enum.map(entries, &%{&1 | body: Map.put(&1.body, "parent_tool_use_id", id)})
    end
  end

  defp parent_id(%{"parent_tool_use_id" => id}) when is_binary(id) and id != "", do: id
  defp parent_id(_), do: nil

  # Per-message token usage from the streaming events (feature 043, R2); every
  # other stream event repeats content the assistant frame carries whole.
  defp usage(frame, raw) do
    data = data(frame)

    case stream_event(raw, data) do
      %{"type" => "message_start"} = ev ->
        [usage_entry("message_start", ev, ev["message"], frame, raw)]

      %{"type" => "message_delta"} = ev ->
        [usage_entry("message_delta", ev, ev, frame, raw)]

      _ ->
        []
    end
  end

  defp stream_event(%{"event" => ev}, _data) when is_map(ev), do: ev
  defp stream_event(_raw, %{event: ev}) when is_map(ev), do: ev
  defp stream_event(_raw, _data), do: nil

  @usage_fields ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  defp usage_entry(event, _ev, holder, frame, raw) do
    counts = if is_map(holder), do: holder["usage"], else: nil

    fields =
      for f <- @usage_fields, is_map(counts), is_integer(counts[f]), into: %{}, do: {f, counts[f]}

    body = Map.put(fields, "event", event)

    body =
      case holder do
        %{"id" => id} when event == "message_start" and is_binary(id) ->
          Map.put(body, "message_id", id)

        _ ->
          body
      end

    scope =
      parent_id(raw) || parent_id(%{"parent_tool_use_id" => data(frame)[:parent_tool_use_id]})

    new(:usage, if(scope, do: Map.put(body, "parent_tool_use_id", scope), else: body))
  end

  defp message_content(raw), do: get_in(raw, ["message", "content"])

  defp assistant(raw) do
    message_id = get_in(raw, ["message", "id"])

    case message_content(raw) do
      text when is_binary(text) ->
        [new(:assistant_text, %{"text" => text, "message_id" => message_id})]

      blocks when is_list(blocks) ->
        Enum.map(blocks, &assistant_block(&1, message_id))

      _ ->
        [new(:other, %{"raw" => raw})]
    end
  end

  defp assistant_block(%{"type" => "text", "text" => text}, id),
    do: new(:assistant_text, %{"text" => text, "message_id" => id})

  defp assistant_block(%{"type" => "thinking"} = b, id),
    do: new(:thinking, %{"text" => b["thinking"] || b["text"] || "", "message_id" => id})

  defp assistant_block(%{"type" => "tool_use"} = b, _id),
    do:
      new(:tool_call, %{
        "tool_use_id" => b["id"],
        "name" => b["name"],
        "input" => b["input"] || %{}
      })

  defp assistant_block(other, _id), do: new(:other, %{"raw" => other})

  defp user(raw) do
    case message_content(raw) do
      blocks when is_list(blocks) -> Enum.map(blocks, &user_block/1)
      _ -> [new(:other, %{"raw" => raw})]
    end
  end

  defp user_block(%{"type" => "tool_result"} = b),
    do:
      new(:tool_result, %{
        "tool_use_id" => b["tool_use_id"],
        "output" => b["content"],
        "is_error" => b["is_error"] == true
      })

  defp user_block(other), do: new(:other, %{"raw" => other})

  defp system(frame, raw) do
    subtype = raw["subtype"] || subtype(frame)
    new(:system, %{"subtype" => subtype, "data" => Map.drop(raw, ["type", "subtype"])})
  end

  # A synthetic result (`ClaudeAgentSDK.Message.error_result/2`) has an empty
  # `raw`; its flag and text live in the parsed `data` (feature 043, R1).
  defp result(frame, raw) do
    data = data(frame)
    is_error = raw["is_error"] == true or data[:is_error] == true

    body = %{
      "subtype" => raw["subtype"] || subtype(frame),
      "result" => raw["result"],
      "num_turns" => raw["num_turns"],
      "duration_ms" => raw["duration_ms"],
      "cost_usd" => raw["total_cost_usd"] || raw["cost_usd"],
      "is_error" => is_error
    }

    new(:result, if(is_error, do: Map.put(body, "error", error_text(data, raw)), else: body))
  end

  defp data(%{data: data}) when is_map(data), do: data
  defp data(_), do: %{}

  defp error_text(data, raw) do
    case data[:error] || raw["error"] do
      text when is_binary(text) ->
        if String.trim(text) == "", do: nil, else: text

      _ ->
        nil
    end
  end

  defp subtype(%{subtype: nil}), do: nil
  defp subtype(%{subtype: s}), do: to_string(s)
  defp subtype(_), do: nil

  # Anything that cannot be JSON-encoded as-is is rendered, never dropped.
  defp jsonable(term) when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term),
    do: term

  defp jsonable(term) when is_atom(term), do: Atom.to_string(term)
  defp jsonable(term) when is_list(term), do: Enum.map(term, &jsonable/1)
  defp jsonable(%_{} = s), do: s |> Map.from_struct() |> jsonable()

  defp jsonable(term) when is_map(term),
    do: Map.new(term, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(term), do: inspect(term)

  @doc "JSON-ready map of the entry (kind as its string name)."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = e),
    do: %{"seq" => e.seq, "at" => e.at, "kind" => Atom.to_string(e.kind), "body" => e.body}

  @doc "Inverse of `encode/1`; an unknown `kind` decodes as `:other`."
  @spec decode(map()) :: t()
  def decode(%{"kind" => kind} = m) do
    case Map.fetch(@kind_by_name, kind) do
      {:ok, k} ->
        %__MODULE__{seq: m["seq"], at: m["at"], kind: k, body: m["body"] || %{}}

      :error ->
        %__MODULE__{
          seq: m["seq"],
          at: m["at"],
          kind: :other,
          body: %{"raw" => m["body"], "kind" => kind}
        }
    end
  end
end
