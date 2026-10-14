# Contract: Recording (feature 043)

Delta over `specs/040-live-agent-conversation/contracts/conversation-capture.md`
and `conversation-file.md`. Everything not named here is unchanged.

## `Autonomous.ConversationEntry` (pure)

```elixir
@spec kinds() :: [kind()]          # + :usage, :stderr
@spec from_frame(term()) :: [t()]  # revised, see below
@spec stderr(String.t()) :: t()                       # new: line entry
@spec stderr_dropped(pos_integer()) :: t()            # new: notice entry
```

`from_frame/1` changes:

| frame | before | after |
|---|---|---|
| `:result`, SDK synthetic (`raw: %{}`, `data.is_error: true`) | `is_error: false`, text lost | `is_error: true`, `error: data.error \|\| nil` |
| `:result`, genuine success | — | byte-identical body |
| `:result`, genuine error subtype, `raw.is_error` absent | `is_error: false` | `is_error: true`, `error: data.error` |
| `:stream_event` `message_start` / `message_delta` | `[]` | `[usage entry]` |
| `:stream_event`, other event types | `[]` | `[]` |
| `:assistant` / `:user` with `raw.parent_tool_use_id` | field dropped | each entry body gains `"parent_tool_use_id"` |

## `Autonomous.StderrBound` (pure, new)

```elixir
@spec new(pos_integer(), pos_integer()) :: t()
@spec push(t(), String.t()) :: {:emit, String.t(), t()} | {:held, t()}
@spec flush(t()) :: {non_neg_integer(), [String.t()]}
```

## `Autonomous.ConversationRecorder` (process)

New message, never replied to:

```elixir
{:stderr, line :: String.t()}
```

- head: `StderrBound.push/2` → `{:emit, …}` ⇒ `emit(state, ConversationEntry.stderr(line))`
  (masked, seq'd, windowed, appended, broadcast like any entry).
- past head: held; nothing emitted.
- `{:close, …}`: before the `:end` entry, `StderrBound.flush/1`; when
  `dropped > 0` emit `stderr_dropped(dropped)`, then each held line.
- a processing fault degrades `error` (capture status `partial`) exactly as a
  frame fault; never crashes the session.

## `Autonomous.SdkProxy`

```elixir
@spec callback(collector :: pid() | nil, recorder :: pid() | nil) :: (String.t() -> :ok)
```

`prepare/1` decodes the `"AUTONOMOUS_CONVERSATION"` marker (still stripped from
the CLI env) and installs `callback(collector, recorder)`. The callback: logs
`"CLI stderr: " <> line` (unchanged), forwards untrusted-workspace lines to the
collector (unchanged), then `send(recorder, {:stderr, line})` when `recorder`
is a pid. `callback/1` stays as `callback(collector, nil)` for existing callers.

## `Autonomous.Config`

```elixir
@spec conversation_stderr_head() :: pos_integer()   # :conversation_stderr_head, default 1000
@spec conversation_stderr_tail() :: pos_integer()   # :conversation_stderr_tail, default 1000
```

A non-positive or non-integer value raises at read (boundary violation,
Principle II), like other `Config` accessors.

## `Autonomous.ConversationFile`

`@version 2`. `header_of/1`, `page/3`, `fold/4`, `entry/2`: accept versions 1
and 2; version ≥ 3 → `{:error, {:unsupported_version, v}}` (existing rule,
now exercised with 3).

## Unchanged (explicitly)

`ConversationRef`, capture statuses, store schema v8, `Conversation.open/2` /
`close/2` signatures, `ConversationWindow` cap (500), `CredentialMask`,
`WorkspaceTrust.Collector`, `SessionExit.classify/2`, the CLI launch env.
