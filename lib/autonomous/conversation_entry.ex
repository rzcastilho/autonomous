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

  @kinds ~w(start prompt assistant_text thinking tool_call tool_result system result other end)a
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

  @doc "Entries for one raw frame."
  @spec from_frame(term()) :: [t()]
  def from_frame(%{type: type} = frame) do
    raw = raw(frame)

    case type do
      :stream_event -> []
      :assistant -> assistant(raw)
      :user -> user(raw)
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

  defp result(frame, raw) do
    new(:result, %{
      "subtype" => raw["subtype"] || subtype(frame),
      "result" => raw["result"],
      "num_turns" => raw["num_turns"],
      "duration_ms" => raw["duration_ms"],
      "cost_usd" => raw["total_cost_usd"] || raw["cost_usd"],
      "is_error" => raw["is_error"] == true
    })
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
