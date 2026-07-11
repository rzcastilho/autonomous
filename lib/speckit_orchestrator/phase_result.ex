defmodule SpeckitOrchestrator.PhaseResult do
  @moduledoc """
  Normalized outcome of running one pipeline phase, folded from the harness
  event stream by `reduce/1`.

  The fold is agnostic to whether the adapter streams or buffers — it consumes
  the returned enumerable uniformly (Phase 0 finding: the Claude adapter
  streams). Event `type` atoms are the vocabulary emitted by
  `Jido.Claude.Mapper`:

  * `:session_started`   — carries `session_id`
  * `:output_text_delta` — assistant text chunk (`payload["text"]`)
  * `:thinking_delta`    — reasoning chunk (captured count only)
  * `:tool_call`         — `payload` `%{"name","input","call_id"}`
  * `:tool_result`       — `payload` `%{"output","call_id","is_error"}`
  * `:usage`             — `payload` `%{"cost_usd","input_tokens",...}`
  * `:session_completed` — `payload` `%{"result","num_turns","is_error",...}`
  * `:session_failed`    — `payload` `%{"error","subtype"}`

  Provider-extended / unknown types are counted in `event_count` but otherwise
  ignored — `reduce/1` never crashes on an unrecognized event.
  """

  alias SpeckitOrchestrator.PhaseResult

  defstruct final_text: "",
            session_id: nil,
            cost_usd: nil,
            usage: nil,
            tool_events: [],
            status: :incomplete,
            error: nil,
            num_turns: nil,
            event_count: 0

  @type tool_event :: %{kind: :call | :result, payload: map()}

  @type t :: %__MODULE__{
          final_text: String.t(),
          session_id: String.t() | nil,
          cost_usd: float() | nil,
          usage: map() | nil,
          tool_events: [tool_event()],
          status: :ok | :error | :incomplete,
          error: term() | nil,
          num_turns: non_neg_integer() | nil,
          event_count: non_neg_integer()
        }

  # Internal accumulator so the public struct stays clean.
  defmodule Acc do
    @moduledoc false
    defstruct session_id: nil,
              deltas: [],
              result_text: nil,
              cost_usd: nil,
              usage: nil,
              tool_events: [],
              status: :incomplete,
              error: nil,
              num_turns: nil,
              count: 0
  end

  @doc """
  Fold an enumerable of `%Jido.Harness.Event{}` into a `%PhaseResult{}`.

  `final_text` prefers the terminal `:session_completed` result string; if the
  run produced only streamed deltas it falls back to the concatenated
  `:output_text_delta` chunks in arrival order.
  """
  @spec reduce(Enumerable.t()) :: t()
  def reduce(events) do
    events
    |> Enum.reduce(%Acc{}, &apply_event/2)
    |> finalize()
  end

  # ---- per-event folding --------------------------------------------------

  defp apply_event(event, acc) do
    acc = %{acc | count: acc.count + 1}
    acc = capture_session_id(acc, event)
    reduce_type(event_type(event), event, acc)
  end

  defp reduce_type(:output_text_delta, event, acc),
    do: %{acc | deltas: [text(event) | acc.deltas]}

  defp reduce_type(:tool_call, event, acc),
    do: %{acc | tool_events: [%{kind: :call, payload: payload(event)} | acc.tool_events]}

  defp reduce_type(:tool_result, event, acc),
    do: %{acc | tool_events: [%{kind: :result, payload: payload(event)} | acc.tool_events]}

  defp reduce_type(:usage, event, acc) do
    p = payload(event)
    %{acc | usage: p, cost_usd: acc.cost_usd || Map.get(p, "cost_usd")}
  end

  defp reduce_type(:session_completed, event, acc) do
    p = payload(event)

    status = if Map.get(p, "is_error") == true, do: :error, else: :ok

    %{
      acc
      | result_text: Map.get(p, "result"),
        num_turns: Map.get(p, "num_turns"),
        status: status,
        error: if(status == :error, do: Map.get(p, "result"), else: acc.error)
    }
  end

  defp reduce_type(:session_failed, event, acc) do
    p = payload(event)
    %{acc | status: :error, error: Map.get(p, "error")}
  end

  # :thinking_delta, :session_started, :provider_event, and any unknown type:
  # counted (above) but not otherwise reduced.
  defp reduce_type(_other, _event, acc), do: acc

  # ---- finalize -----------------------------------------------------------

  defp finalize(%Acc{} = acc) do
    final_text =
      case acc.result_text do
        text when is_binary(text) and text != "" -> text
        _ -> acc.deltas |> Enum.reverse() |> Enum.join("")
      end

    %PhaseResult{
      final_text: final_text,
      session_id: acc.session_id,
      cost_usd: acc.cost_usd,
      usage: acc.usage,
      tool_events: Enum.reverse(acc.tool_events),
      status: acc.status,
      error: acc.error,
      num_turns: acc.num_turns,
      event_count: acc.count
    }
  end

  # ---- accessors tolerant of struct or plain map events -------------------

  defp capture_session_id(%{session_id: nil} = acc, event) do
    case event_session_id(event) do
      sid when is_binary(sid) and sid != "" -> %{acc | session_id: sid}
      _ -> acc
    end
  end

  defp capture_session_id(acc, _event), do: acc

  defp event_type(%{type: type}), do: type
  defp event_session_id(%{session_id: sid}), do: sid
  defp event_session_id(_), do: nil
  defp payload(%{payload: p}) when is_map(p), do: p
  defp payload(_), do: %{}
  defp text(event), do: payload(event) |> Map.get("text", "")
end
