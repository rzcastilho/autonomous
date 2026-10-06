defmodule Autonomous.PhaseResult do
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

  alias Autonomous.{BackgroundMarker, PhaseResult}

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

  # `subtype` of a session the orchestrator cut at its own deadline
  # (`deadline_exceeded/2`) — namespaced so it can never collide with a subtype
  # the harness itself emits (`error_max_turns`, …).
  @deadline_subtype "orchestrator_deadline"

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
  def exhausted?(%__MODULE__{subtype: @deadline_subtype}), do: true
  def exhausted?(_), do: false

  @doc """
  True when the session was cut by the orchestrator's own wall-clock deadline
  (`PhaseSession.reduce/2`) rather than by anything the harness reported.
  Classified `exhausted?/1` too — a session that ran out of *time* is, to the
  chunk loop, the same shape as one that ran out of *turns*: progress made so
  far stands, and the scope is re-dispatched (or judged stuck) by the same
  no-progress rule, never retried as a server drop.
  """
  @spec deadline_exceeded?(t() | nil) :: boolean()
  def deadline_exceeded?(%__MODULE__{subtype: @deadline_subtype}), do: true
  def deadline_exceeded?(_), do: false

  @doc """
  Fold `partial` (whatever the cut stream had produced — `nil` when nothing
  could be salvaged) into a deadline result: `status: :error`, the
  orchestrator's own `subtype`, and `error: {:deadline_exceeded, ms}`. Cost,
  session id, tool events and text seen before the cut are preserved so the
  Ledger and the transcript still account for the partial session.
  """
  @spec deadline_exceeded(t() | nil, pos_integer()) :: t()
  def deadline_exceeded(partial, deadline_ms) do
    base = partial || %__MODULE__{}

    %{
      base
      | status: :error,
        subtype: @deadline_subtype,
        error: {:deadline_exceeded, deadline_ms},
        final_text:
          String.trim(
            (base.final_text || "") <>
              "\n\n[orchestrator] session cut at its #{div(deadline_ms, 60_000)} min deadline"
          )
    }
  end

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

  defmodule BackgroundedCommand do
    @moduledoc """
    A Bash command the CLI moved to the background during a session
    (feature 032, data-model §1). `resolved?` is true when a **later** tool
    event referenced its `task_id` or `output_path` — i.e. the model actually
    went back for the result.
    """
    defstruct call_id: nil,
              command: "(unknown command)",
              mode: :explicit,
              task_id: nil,
              output_path: nil,
              position: 0,
              resolved?: false

    @type t :: %__MODULE__{
            call_id: String.t() | nil,
            command: String.t(),
            mode: BackgroundMarker.mode(),
            task_id: String.t() | nil,
            output_path: String.t() | nil,
            position: non_neg_integer(),
            resolved?: boolean()
          }
  end

  @doc """
  The commands the CLI moved to the background in this session, in call
  order, each with its resolution state (feature 032, FR-001).

  A command is backgrounded when its result carries a CLI marker
  (`BackgroundMarker.parse/1`) or when its call set `run_in_background: true`
  (a call with no recognised marker keeps `nil` identifiers and can then
  never resolve). One entry per call.

  **Resolution** is identifier-based: a tool event at an index *after* the
  backgrounding result whose call input or result text contains the
  `task_id` or the `output_path`. The marker's own event never counts. This
  is deliberately name-agnostic — `Read` of the output file, a `TaskOutput`
  style reader, or a `tail` in Bash all resolve it.
  """
  @spec backgrounded_commands(t() | nil) :: [BackgroundedCommand.t()]
  def backgrounded_commands(%__MODULE__{tool_events: events}) do
    indexed = Enum.with_index(events)

    calls =
      for {%{kind: :call, payload: %{"call_id" => id} = p}, _} <- indexed,
          is_binary(id),
          into: %{},
          do: {id, p}

    indexed
    |> Enum.flat_map(&backgrounding_entry(&1, calls, indexed))
    |> Enum.uniq_by(&(&1.call_id || &1.position))
    |> Enum.map(&resolve(&1, indexed))
  end

  def backgrounded_commands(_), do: []

  @doc """
  The commands of the unresolved `backgrounded_commands/1`, in call order, for
  a session that otherwise reported success. `[]` unless `status == :ok`
  (FR-004) — a cut or failed session stays classified by `exhausted?/1` /
  `transient?/1`.
  """
  @spec stranded_background(t() | nil) :: [String.t()]
  def stranded_background(%__MODULE__{status: :ok} = r) do
    for %BackgroundedCommand{resolved?: false, command: c} <- backgrounded_commands(r), do: c
  end

  def stranded_background(_), do: []

  # A result event whose output carries a marker, or whose call was explicit.
  defp backgrounding_entry({%{kind: :result, payload: p}, idx}, calls, _indexed) do
    call = Map.get(calls, p["call_id"], %{})
    input = Map.get(call, "input", %{})

    case BackgroundMarker.parse(p["output"]) do
      {:ok, m} ->
        [entry(p["call_id"], input, m.mode, m.task_id, m.output_path, idx)]

      :none ->
        if BackgroundMarker.explicit_call?(input),
          do: [entry(p["call_id"], input, :explicit, nil, nil, idx)],
          else: []
    end
  end

  # An explicit call that never returned a result at all.
  defp backgrounding_entry(
         {%{kind: :call, payload: %{"input" => input} = p}, idx},
         _calls,
         indexed
       ) do
    id = p["call_id"]

    if BackgroundMarker.explicit_call?(input) and
         not Enum.any?(indexed, fn {e, _} ->
           e.kind == :result and is_binary(id) and e.payload["call_id"] == id
         end),
       do: [entry(id, input, :explicit, nil, nil, idx)],
       else: []
  end

  defp backgrounding_entry(_event, _calls, _indexed), do: []

  @doc """
  Make a gate-signal map authoritative about `:backgrounded` across runs on the
  same agent (feature 032).

  `Jido` folds an action's state update into the agent with a **deep merge**, so
  a fresh `last_signals` map does not clear keys a previous run on the same agent
  left behind. A phase retried after a backgrounding would otherwise still carry
  `backgrounded: [cmd]` on its clean second session and be re-classified. When
  `signals` has no `:backgrounded` of its own but `previous` did, emit an
  explicit `[]` (a non-keyword list is replaced, not merged). A run that never
  backgrounded keeps its signal map byte-identical.
  """
  @spec reset_background(map(), map() | nil) :: map()
  def reset_background(signals, previous) do
    case {Map.has_key?(signals, :backgrounded), Map.get(previous || %{}, :backgrounded)} do
      {false, [_ | _]} -> Map.put(signals, :backgrounded, [])
      _ -> signals
    end
  end

  defp entry(call_id, input, mode, task_id, path, position) do
    %BackgroundedCommand{
      call_id: call_id,
      command: command_text(input),
      mode: mode,
      task_id: task_id,
      output_path: path,
      position: position
    }
  end

  defp command_text(%{"command" => c}) when is_binary(c) and c != "", do: c
  defp command_text(%{"description" => d}) when is_binary(d) and d != "", do: d
  defp command_text(_), do: "(unknown command)"

  defp resolve(%BackgroundedCommand{task_id: nil, output_path: nil} = c, _indexed), do: c

  defp resolve(%BackgroundedCommand{} = c, indexed) do
    keys = Enum.reject([c.task_id, c.output_path], &is_nil/1)

    resolved? =
      Enum.any?(indexed, fn {event, idx} ->
        idx > c.position and Enum.any?(keys, &String.contains?(event_text(event), &1))
      end)

    %{c | resolved?: resolved?}
  end

  defp event_text(%{kind: :call, payload: p}), do: encode(Map.get(p, "input"))

  defp event_text(%{kind: :result, payload: p}),
    do: BackgroundMarker.flatten(p["output"]) || encode(p["output"])

  defp event_text(_), do: ""

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      _ -> inspect(term)
    end
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
