# Contract: Conversation capture API (`Autonomous.Conversation`)

Internal Elixir API used by every session-driving site and by the console.
All functions are exit-safe: none raises or exits into its caller because a
recorder is slow, dead or missing.

## Session side

```elixir
@spec open(ConversationIdentity.t(), RunRequest.t()) ::
        {:ok, handle, RunRequest.t()} | {:not_captured, ConversationRef.t(), RunRequest.t()}
```
- Allocates `conversation_id`, creates dirs `0700` and file `0600`, starts a
  `ConversationRecorder` under `ConversationSup`, writes header + `:start` +
  `:prompt` entries, registers in `ConversationRegistry`.
- Returns the request with `AUTONOMOUS_CONVERSATION` added to
  `metadata["claude"].env` (encoded recorder pid). Nothing else in the request
  changes.
- On any failure returns `{:not_captured, ref, request}` with the request
  **unchanged** — the session runs exactly as without this feature (FR-017).

```elixir
@spec close(handle | {:not_captured, ConversationRef.t()}, PhaseResult.t()) :: ConversationRef.t()
```
- Called after the fold returns, on **every** outcome (completed, error,
  exhausted, deadline cut, session died; under drain too).
- `GenServer.call(recorder, {:close, outcome, session_id, drain?}, 30_000)`:
  recorder writes `:end`, closes the file, deregisters, broadcasts
  `{:conversation, id, :ended, outcome}`, stops `:normal`.
- Call timeout / `:noproc` / crash ⇒ ref `:partial` with reason
  `:close_timeout | :recorder_down`; never raises.
- Logs one `:warning` when the ref is not `:captured`.

### Tap (`Autonomous.SdkProxy`)

```elixir
def query(prompt, options) # and resume/3
```
- `prepare/1` pops `AUTONOMOUS_CONVERSATION` (and the 036 collector marker)
  from `options.env`.
- Wraps the inner stream: `Stream.each(stream, &send(recorder, {:frame, &1}))`.
  No marker ⇒ stream returned untouched.
- Never awaits, never raises, never alters a frame.

### Recorder messages

| Message | Effect |
|---|---|
| `{:frame, %ClaudeAgentSDK.Message{}}` | `ConversationEntry.from_frame/1` → mask → seq → window push → append line → broadcast `{:conversation, id, :entry, entry}` for each entry |
| `{:close, outcome, session_id, drain?}` (call) | as above → `{:ok, ref}` |
| `:catch_up` (call) | `{:ok, entries, last_seq, truncated?}` |
| `{:entry, seq}` (call) | `{:ok, entry} \| :not_in_window` |

A file write error mid-session marks the recorder `:partial` (reason
`{:write_failed, posix}`), keeps the window and broadcasts going, and is
reported by `close/2`.

## Viewer side

```elixir
@spec subscribe(conversation_id) :: :ok          # topic "conversation:" <> id
@spec catch_up(conversation_id) :: {:ok, [entry], last_seq, truncated?} | :not_live
@spec entry(conversation_id, seq) :: {:ok, entry} | :not_found
@spec in_flight(repo_id) :: [%{conversation_id, identity, opened_at}]   # newest first
```
- Viewer order is **subscribe → catch_up → apply broadcasts with `seq > last_seq`**.
- `catch_up/1` and `entry/2` use a 1 s timeout; timeout/dead ⇒ `:not_live`/`:not_found`.
- `in_flight/1` is a `Registry.select/2` — no process call.

PubSub messages on `"conversation:" <> id`:

```elixir
{:conversation, id, :entry, %ConversationEntry{}}
{:conversation, id, :ended, outcome}
```
And on the existing `"console:run"` topic, so Mission Control/Run Detail can
re-point the live link without polling:

```elixir
{:console, :conversation_opened, %{conversation_id:, feature_id:, phase:}}
{:console, :conversation_closed, %{conversation_id:, status:}}
```

## Saved side

```elixir
@spec ConversationFile.resolve(transcript_root, relative_path) :: Path.t()
@spec ConversationFile.page(abs_path, from_seq, limit) ::
        {:ok, [entry], next_seq | :eof} | {:error, :missing | {:unreadable, posix} | {:malformed, line_no}}
@spec ConversationFile.entry(abs_path, seq) :: {:ok, entry} | {:error, term}
```
- Read-only, streaming (`File.stream!/1`), never loads the whole file.
- A malformed line is reported with its line number; preceding lines still
  render (salvage, no invention — Principle II).

## Attempt recording

Every caller of `Writer.record_phase_attempt/2` / `record_remediation_attempt/2`
/ the chunk path passes `attempt.conversations` (list of refs). `close/2` has
returned for every ref before that call (FR-012).
