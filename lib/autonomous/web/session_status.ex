defmodule Autonomous.Web.SessionStatus do
  @moduledoc """
  Pure fold of a conversation's entries into the sticky status line and header
  fields (feature 042). The live view folds broadcasts into it; the saved view
  folds every loaded page; `ConversationFile.fold/4` seeds it on a live join.
  The same fold over the same entries gives the same status (live == saved).

  `apply/2` is idempotent by `seq` (an entry at or below `last_seq` is
  ignored) and freezes at the `:end` entry: after it, activity, `ended_at` and
  `outcome` never change. Cost and duration are `nil` until a `:result` entry —
  never zero-filled.
  """

  import Kernel, except: [apply: 2]

  alias Autonomous.ConversationEntry
  alias Autonomous.Web.ConversationRows

  defstruct last_seq: nil,
            activity: nil,
            turns: 0,
            turn_msg: nil,
            side: nil,
            tool_calls: 0,
            open_calls: %{},
            open_tasks: 0,
            open_hooks: MapSet.new(),
            rate_limit: nil,
            cost_usd: nil,
            duration_ms: nil,
            started_at: nil,
            ended_at: nil,
            outcome: nil,
            model_alias: nil,
            model_resolved: nil,
            cli_version: nil,
            session_id: nil,
            lower_bound?: false,
            announce: nil

  @type activity ::
          nil
          | {:requesting}
          | {:thinking, non_neg_integer() | nil}
          | {:running, String.t(), non_neg_integer() | nil}
          | {:hook, String.t() | nil}
          | {:responding}
          | {:done}
          | {:outcome, String.t(), String.t()}

  @type t :: %__MODULE__{
          last_seq: non_neg_integer() | nil,
          activity: activity(),
          turns: non_neg_integer(),
          turn_msg: String.t() | nil,
          side: nil | :user | :assistant,
          tool_calls: non_neg_integer(),
          open_calls: %{String.t() => String.t()},
          open_tasks: non_neg_integer(),
          open_hooks: MapSet.t(),
          rate_limit: nil | %{type: String.t() | nil, resets_at: integer() | nil},
          cost_usd: number() | nil,
          duration_ms: number() | nil,
          started_at: String.t() | nil,
          ended_at: String.t() | nil,
          outcome: nil | {String.t(), String.t()},
          model_alias: String.t() | nil,
          model_resolved: String.t() | nil,
          cli_version: String.t() | nil,
          session_id: String.t() | nil,
          lower_bound?: boolean(),
          announce: String.t() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec apply_all(t(), Enumerable.t()) :: t()
  def apply_all(%__MODULE__{} = status, entries), do: Enum.reduce(entries, status, &apply(&2, &1))

  @doc "Counters seeded from a window only (the file was unreadable) are lower bounds."
  @spec mark_lower_bound(t()) :: t()
  def mark_lower_bound(%__MODULE__{} = status), do: %{status | lower_bound?: true}

  @doc "Set `started_at` from a fallback source (e.g. the registry's `opened_at`) when unknown."
  @spec put_started_at(t(), String.t() | nil) :: t()
  def put_started_at(%__MODULE__{started_at: nil} = status, at) when is_binary(at),
    do: %{status | started_at: at}

  def put_started_at(status, _at), do: status

  @spec apply(t(), ConversationEntry.t()) :: t()
  def apply(%__MODULE__{last_seq: last} = status, %ConversationEntry{seq: seq})
      when is_integer(seq) and is_integer(last) and seq <= last,
      do: status

  def apply(%__MODULE__{outcome: outcome} = status, %ConversationEntry{} = e)
      when not is_nil(outcome),
      do: seen(status, e)

  def apply(%__MODULE__{} = status, %ConversationEntry{} = e),
    do: status |> fold(e) |> seen(e)

  defp seen(status, %ConversationEntry{seq: seq}) when is_integer(seq),
    do: %{status | last_seq: seq}

  defp seen(status, _e), do: status

  # ---- per kind -----------------------------------------------------------

  defp fold(s, %ConversationEntry{kind: :start} = e),
    do: %{s | started_at: e.at, model_alias: e.body["model"]}

  defp fold(s, %ConversationEntry{kind: :prompt}), do: %{s | side: :user}

  defp fold(s, %ConversationEntry{kind: :assistant_text} = e),
    do: %{assistant_side(s, e.body["message_id"]) | activity: {:responding}}

  defp fold(s, %ConversationEntry{kind: :thinking} = e),
    do: assistant_side(s, e.body["message_id"])

  defp fold(s, %ConversationEntry{kind: :tool_call} = e) do
    id = e.body["tool_use_id"]
    name = e.body["name"] || "tool"
    s = assistant_side(s, nil)
    open = if id, do: Map.put(s.open_calls, id, name), else: s.open_calls

    %{s | tool_calls: s.tool_calls + 1, open_calls: open, activity: {:running, name, nil}}
  end

  defp fold(s, %ConversationEntry{kind: :tool_result} = e) do
    open = Map.delete(s.open_calls, e.body["tool_use_id"])
    s = %{s | open_calls: open, side: :user}

    case next_open(open) do
      nil -> s
      name -> %{s | activity: {:running, name, nil}}
    end
  end

  defp fold(s, %ConversationEntry{kind: :result} = e) do
    %{
      s
      | activity: {:done},
        cost_usd: e.body["cost_usd"],
        duration_ms: e.body["duration_ms"],
        turns: if(is_integer(e.body["num_turns"]), do: e.body["num_turns"], else: s.turns)
    }
  end

  defp fold(s, %ConversationEntry{kind: :end} = e) do
    {text, chip} = ConversationRows.outcome(e)

    %{
      s
      | activity: {:outcome, text, chip},
        outcome: {text, chip},
        ended_at: e.at,
        announce: text
    }
  end

  defp fold(s, %ConversationEntry{kind: :system, body: body} = e) do
    data = body["data"] || %{}
    system(s, body["subtype"], if(is_map(data), do: data, else: %{}), e)
  end

  defp fold(s, %ConversationEntry{kind: :other, body: %{"raw" => %{"type" => type} = raw}}),
    do: other(s, type, raw)

  defp fold(s, %ConversationEntry{kind: :other, body: _}), do: s

  defp system(s, "status", _data, _e), do: %{s | activity: {:requesting}}

  defp system(s, "thinking_tokens", data, _e),
    do: %{s | activity: {:thinking, int(data["estimated_tokens"])}}

  defp system(s, "hook_started", data, _e) do
    %{
      s
      | open_hooks: MapSet.put(s.open_hooks, data["hook_id"]),
        activity: {:hook, data["hook_name"]}
    }
  end

  defp system(s, "hook_response", data, _e),
    do: %{s | open_hooks: MapSet.delete(s.open_hooks, data["hook_id"])}

  defp system(s, "init", data, _e),
    do: %{
      s
      | model_resolved: data["model"],
        cli_version: data["claude_code_version"],
        session_id: data["session_id"]
    }

  defp system(s, "task_started", _data, _e), do: %{s | open_tasks: s.open_tasks + 1}
  defp system(s, "task_notification", _data, _e), do: %{s | open_tasks: max(s.open_tasks - 1, 0)}
  defp system(s, _other, _data, _e), do: s

  defp other(s, "tool_progress", raw) do
    secs = raw["elapsed_time_seconds"]
    name = raw["tool_name"] || "tool"
    %{s | activity: {:running, name, if(is_number(secs), do: round(secs))}}
  end

  defp other(s, "rate_limit_event", raw) do
    info = raw["rate_limit_info"] || %{}

    if info["status"] in [nil, "allowed"] do
      %{s | rate_limit: nil}
    else
      limit = %{type: info["rateLimitType"], resets_at: info["resetsAt"]}
      announce = if s.rate_limit == nil, do: "rate limited · #{limit.type}", else: s.announce
      %{s | rate_limit: limit, announce: announce}
    end
  end

  defp other(%{side: _} = s, "text", _raw), do: %{s | side: :user}
  defp other(s, _type, _raw), do: s

  # A turn opens on the first assistant-side entry after a user-side one (or at
  # the start), and whenever a different `message_id` shows up (research R6).
  defp assistant_side(%{side: :assistant, turn_msg: cur} = s, msg)
       when is_nil(msg) or is_nil(cur) or msg == cur,
       do: %{s | turn_msg: cur || msg}

  defp assistant_side(s, msg), do: %{s | side: :assistant, turn_msg: msg, turns: s.turns + 1}

  defp next_open(open) when map_size(open) == 0, do: nil
  defp next_open(open), do: open |> Enum.min_by(&elem(&1, 0)) |> elem(1)

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)
  defp int(_), do: nil

  # ---- view helpers ---------------------------------------------------------

  @spec activity_text(t()) :: String.t() | nil
  def activity_text(%__MODULE__{activity: nil}), do: nil
  def activity_text(%__MODULE__{activity: {:requesting}}), do: "requesting"
  def activity_text(%__MODULE__{activity: {:thinking, nil}}), do: "thinking"
  def activity_text(%__MODULE__{activity: {:thinking, n}}), do: "thinking · ~#{tokens(n)} tok"
  def activity_text(%__MODULE__{activity: {:running, tool, nil}}), do: "running #{tool}"
  def activity_text(%__MODULE__{activity: {:running, tool, s}}), do: "running #{tool} · #{s}s"
  def activity_text(%__MODULE__{activity: {:hook, nil}}), do: "hook"
  def activity_text(%__MODULE__{activity: {:hook, name}}), do: "hook · #{name}"
  def activity_text(%__MODULE__{activity: {:responding}}), do: "responding"
  def activity_text(%__MODULE__{activity: {:done}}), do: "done"
  def activity_text(%__MODULE__{activity: {:outcome, text, _chip}}), do: text

  defp tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp tokens(n), do: Integer.to_string(n)

  @doc "The `data-status` name for the activity dot: the outcome chip once ended, `running` while live."
  @spec status_name(t(), boolean()) :: String.t() | nil
  def status_name(%__MODULE__{outcome: {_text, chip}}, _live?), do: chip
  def status_name(_status, true), do: "running"
  def status_name(_status, false), do: nil

  @doc "Whole seconds since the recorded start (to `now` while open, to the end once ended); `nil` without a start."
  @spec elapsed_s(t(), DateTime.t()) :: non_neg_integer() | nil
  def elapsed_s(%__MODULE__{started_at: nil}, _now), do: nil

  def elapsed_s(%__MODULE__{started_at: started, ended_at: ended}, now) do
    with {:ok, from, _} <- DateTime.from_iso8601(started),
         {:ok, to} <- until(ended, now) do
      max(DateTime.diff(to, from, :second), 0)
    else
      _ -> nil
    end
  end

  defp until(nil, now), do: {:ok, now}

  defp until(ended, _now) do
    case DateTime.from_iso8601(ended) do
      {:ok, to, _} -> {:ok, to}
      error -> error
    end
  end

  @spec count_text(non_neg_integer(), boolean()) :: String.t()
  def count_text(n, true), do: "≥ #{n}"
  def count_text(n, false), do: Integer.to_string(n)
end
