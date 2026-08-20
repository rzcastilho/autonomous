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
            subtype: nil,
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
          subtype: String.t() | nil,
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
              subtype: nil,
              num_turns: nil,
              count: 0
  end

  # Substrings (lower-cased) that mark a transient server/API failure worth
  # retrying — a dropped/incomplete stream rather than a real, deterministic
  # error. Kept specific so a genuine failure is not retried repeatedly.
  @transient_markers [
    "server error",
    "api error",
    "mid-response",
    "overloaded",
    "rate limit",
    "temporarily unavailable",
    "service unavailable",
    "connection reset",
    "connection closed",
    " 503",
    " 502",
    " 529"
  ]

  @doc """
  True when a phase failure looks **transient** (a server/API drop) rather than a
  real, deterministic error — used to retry the phase instead of failing the
  feature.

  Transient: a harness-level error (`nil` — the request never returned a stream),
  an `:incomplete` stream (no terminal event arrived — the connection was cut
  mid-response), or an `:error` result whose text carries a known server/API
  failure signature. A clean `:error` with an application message, and any `:ok`
  result, are **not** transient.
  """
  @spec transient?(t() | nil) :: boolean()
  def transient?(nil), do: true
  def transient?(%__MODULE__{status: :incomplete}), do: true

  def transient?(%__MODULE__{status: :error} = r) do
    blob = String.downcase("#{r.final_text} #{inspect(r.error)}")
    Enum.any?(@transient_markers, &String.contains?(blob, &1))
  end

  def transient?(%__MODULE__{}), do: false

  @doc """
  True when the session ended because it exhausted its turn budget —
  `:session_failed`'s `"subtype"` of `"error_max_turns"` — rather than a real
  error. Classified from the harness's own deterministic subtype (never
  inferred from error prose), and checked **before** the transient-retry
  ladder: `transient?/1` is left unchanged so exhaustion and a transient
  server/API drop stay distinct classifications (research R1, FR-014).
  """
  @spec exhausted?(t() | nil) :: boolean()
  def exhausted?(%__MODULE__{subtype: "error_max_turns"}), do: true
  def exhausted?(_), do: false

  @doc """
  True when an **`:ok`** session ended with tool calls that never returned a
  result — the mechanical signature of "the model ended its turn while work was
  still in flight".

  This exists because the harness gives us no direct signal for it:
  `:session_completed` carries only `result / num_turns / duration_ms /
  is_error`, so a session that dispatched background subagents and then ended
  its turn is indistinguishable, at the event level, from one that finished its
  job — both fold to `status: :ok`. In a headless one-shot, ending the turn
  *is* ending the session, and nothing collects the outstanding work later.

  Derived instead from `tool_events`: `:tool_call` carries a `"call_id"` and the
  matching `:tool_result` echoes it, so a call id with no result is a stranded
  call. Three properties are load-bearing:

    * **Name-agnostic** — any unreturned call counts, not just the subagent
      tool. The tool has been named both `Task` and `Agent` across CLI
      versions; a name allowlist would fail open on the next rename.
    * **At least one matched pair is required.** If some transport never
      surfaced `:tool_result` events, every call would look stranded and every
      phase would fail. Demanding proof that results *do* arrive on this
      session puts the false-positive direction at "do not flag" — the same
      posture as the artifact gate's broken-probe handling.
    * **`:ok` only.** A max-turns kill or a cut stream also strands calls;
      those stay classified by `exhausted?/1` / `transient?/1`.
  """
  @spec outstanding_work?(t() | nil) :: boolean()
  def outstanding_work?(%__MODULE__{status: :ok} = r) do
    {calls, results} = call_ids(r)

    MapSet.size(MapSet.intersection(calls, results)) >= 1 and
      not MapSet.equal?(MapSet.difference(calls, results), MapSet.new())
  end

  def outstanding_work?(_), do: false

  @doc """
  The tool names of the calls `outstanding_work?/1` found stranded, in call
  order, for logging. `[]` whenever `outstanding_work?/1` is false.
  """
  @spec outstanding_calls(t() | nil) :: [String.t()]
  def outstanding_calls(%__MODULE__{} = r) do
    if outstanding_work?(r) do
      {calls, results} = call_ids(r)
      stranded = MapSet.difference(calls, results)

      for %{kind: :call, payload: p} <- r.tool_events,
          MapSet.member?(stranded, p["call_id"]),
          do: p["name"] || "(unnamed)"
    else
      []
    end
  end

  def outstanding_calls(_), do: []

  # Call ids seen on each side. A call with no `"call_id"` is unmatchable in
  # either direction, so it is dropped rather than counted as stranded.
  defp call_ids(%__MODULE__{tool_events: events}) do
    Enum.reduce(events, {MapSet.new(), MapSet.new()}, fn
      %{kind: kind, payload: %{"call_id" => id}}, {calls, results} when is_binary(id) ->
        case kind do
          :call -> {MapSet.put(calls, id), results}
          :result -> {calls, MapSet.put(results, id)}
        end

      _event, acc ->
        acc
    end)
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
    %{acc | status: :error, error: Map.get(p, "error"), subtype: Map.get(p, "subtype")}
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
      subtype: acc.subtype,
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
