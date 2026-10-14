defmodule Autonomous.Web.ConversationClass do
  @moduledoc """
  The one placement table of the conversation views (feature 042). Pure.

  Every `ConversationEntry` is placed as a transcript **block** (`:row`), a
  footer **signal** (`:signal`), both (`:row_signal`), or a header/footer
  signal that is never a block (`:header_signal`, the `init` frame). The live
  view, the embedded panel, the saved-conversation view and `SessionStatus`
  all read this table, so live/review parity is a property of the code.

  Total: an unknown kind or sub-kind is a raw row (`:row`/`:raw`), never
  dropped and never raised on.
  """

  alias Autonomous.ConversationEntry

  @type placement :: :row | :signal | :row_signal | :header_signal
  @type row_class ::
          :prose
          | :context
          | :thinking
          | :call
          | :result
          | :marker
          | :divider
          | :end
          | :stderr
          | :raw
  @type fold :: :open | :line | :preview5
  @type t :: %{
          placement: placement(),
          row_class: row_class(),
          fold: fold(),
          label: String.t(),
          flag: nil | :hook_failed | :result_error
        }

  @spec classify(ConversationEntry.t()) :: t()
  def classify(%ConversationEntry{kind: :start}), do: put(:row_signal, :divider, :open, "start")
  def classify(%ConversationEntry{kind: :prompt}), do: put(:row, :context, :line, "prompt")

  def classify(%ConversationEntry{kind: :assistant_text}),
    do: put(:row_signal, :prose, :open, "assistant")

  def classify(%ConversationEntry{kind: :thinking}),
    do: put(:row_signal, :thinking, :line, "thinking")

  def classify(%ConversationEntry{kind: :tool_call}),
    do: put(:row_signal, :call, :line, "tool call")

  def classify(%ConversationEntry{kind: :tool_result}),
    do: put(:row_signal, :result, :preview5, "tool result")

  def classify(%ConversationEntry{kind: :usage, body: body}),
    do: put(:signal, :raw, :line, "usage" <> opt_sub(body["event"]))

  def classify(%ConversationEntry{kind: :stderr, body: %{"notice" => _}}),
    do: put(:row, :marker, :line, "stderr")

  def classify(%ConversationEntry{kind: :stderr}), do: put(:row, :stderr, :line, "stderr")

  def classify(%ConversationEntry{kind: :end}), do: put(:row_signal, :end, :open, "end")

  def classify(%ConversationEntry{kind: :result} = e) do
    if e.body["is_error"] == true or
         (is_binary(e.body["subtype"]) and e.body["subtype"] != "success"),
       do: put(:row_signal, :marker, :line, label(e), :result_error),
       else: put(:signal, :raw, :line, label(e))
  end

  def classify(%ConversationEntry{kind: :system} = e) do
    case sub_kind(e) do
      s when s in ~w(task_started task_notification api_retry) ->
        put(:row_signal, :marker, :line, label(e))

      "hook_response" ->
        if hook_failed?(e),
          do: put(:row_signal, :marker, :line, label(e), :hook_failed),
          else: put(:signal, :raw, :line, label(e))

      s when s in ~w(status thinking_tokens hook_started hook_progress) ->
        put(:signal, :raw, :line, label(e))

      "init" ->
        put(:header_signal, :raw, :line, label(e))

      _ ->
        put(:row, :raw, :line, label(e))
    end
  end

  def classify(%ConversationEntry{kind: :other} = e) do
    case sub_kind(e) do
      s when s in ~w(tool_progress rate_limit_event) -> put(:signal, :raw, :line, label(e))
      "text" -> put(:row, :context, :line, "context")
      _ -> put(:row, :raw, :line, label(e))
    end
  end

  def classify(%ConversationEntry{} = e), do: put(:row, :raw, :line, label(e))

  @doc "Whether the entry is shown as a block under the current frames setting."
  @spec visible?(t(), boolean()) :: boolean()
  def visible?(%{placement: p}, all_frames?), do: p in [:row, :row_signal] or all_frames?

  @doc "`body.subtype` (system/result) or `body.raw.type` (other); nil when absent."
  @spec sub_kind(ConversationEntry.t()) :: String.t() | nil
  def sub_kind(%ConversationEntry{kind: :other, body: body}) do
    case body do
      %{"raw" => %{"type" => t}} when is_binary(t) -> t
      _ -> nil
    end
  end

  def sub_kind(%ConversationEntry{body: %{"subtype" => s}}) when is_binary(s), do: s
  def sub_kind(%ConversationEntry{}), do: nil

  defp hook_failed?(%ConversationEntry{body: body}) do
    data = body["data"] || %{}
    data["outcome"] not in [nil, "success"] or data["exit_code"] not in [nil, 0]
  end

  defp opt_sub(event) when is_binary(event), do: " · " <> event
  defp opt_sub(_), do: ""

  defp put(placement, row_class, fold, label, flag \\ nil),
    do: %{placement: placement, row_class: row_class, fold: fold, label: label, flag: flag}

  defp label(%ConversationEntry{kind: kind, body: body} = e) do
    kind_name = if kind == :other, do: unknown_kind(body), else: Atom.to_string(kind)

    case sub_kind(e) do
      nil -> kind_name
      sub -> kind_name <> " · " <> sub
    end
  end

  # A decoded-unknown entry keeps the file's kind string in `body.kind`.
  defp unknown_kind(%{"kind" => k}) when is_binary(k), do: k
  defp unknown_kind(_), do: "other"
end
