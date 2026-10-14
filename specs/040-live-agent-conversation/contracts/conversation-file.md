# Contract: `speckit.conversation` v1 file

**Location**: `<transcript_root>/conversations/<run_id>/<feature_id>/<conversation_id>.jsonl`
(`transcript_root` = `Layout.transcript_root`, under `~/.autonomous`, never in
a target working tree). Path stored on the attempt **relative** to
`transcript_root`.

**Permissions**: every directory this feature creates `0700`; file `0600`,
set before the first byte is written.

**Encoding**: UTF-8 JSON Lines, `\n`-terminated, one JSON object per line,
appended as entries arrive; never rewritten in place.

**Line 1 — header**

```json
{"format":"speckit.conversation","version":1,"conversation_id":"clarify-1-m3k9w0q4-3",
 "run_id":"r000012","feature_id":"003","phase":"clarify","ordinal":1,
 "kind":"phase","chunk":null,"attempt":null,"opened_at":"2026-10-10T14:02:11Z"}
```

**Lines 2…n — entries**

```json
{"seq":0,"at":"…","kind":"start","body":{…identity,"model":"opus"}}
{"seq":1,"at":"…","kind":"prompt","body":{"text":"…"}}
{"seq":2,"at":"…","kind":"system","body":{"subtype":"init","data":{…}}}
{"seq":3,"at":"…","kind":"assistant_text","body":{"text":"…","message_id":"msg_…"}}
{"seq":4,"at":"…","kind":"tool_call","body":{"tool_use_id":"toolu_…","name":"Bash","input":{"command":"mix test"}}}
{"seq":5,"at":"…","kind":"tool_result","body":{"tool_use_id":"toolu_…","output":"…","is_error":false}}
{"seq":6,"at":"…","kind":"result","body":{"subtype":"success","num_turns":12,"duration_ms":…,"cost_usd":…,"is_error":false,"result":"…"}}
{"seq":7,"at":"…","kind":"end","body":{"outcome":"completed","session_id":"…","drain_requested":false}}
```

Rules:
- `seq` starts at 0, strictly increasing by 1. A reader that sees a gap
  reports `{:malformed, line}`.
- Content is complete and untruncated; the only alteration is
  `[masked:NAME]` substitution of exact credential values (FR-024).
- Outcome terms are encoded as strings in the system's own vocabulary
  (`"deadline_exceeded"`, `"session_died:start_failed"`, `"error:<reason>"`),
  decoded by `ConversationOutcome.decode/1`.
- **Clean** file: last line is the single `kind: "end"` entry. A file without
  one is what a `:partial` ref points to; readers render what is there and
  then an "ended without an end marker" row.
- Unknown `kind` values in a future version are rendered as `:other`; a
  header `version` greater than 1 is refused with a named error
  (Principle II — no guessing at a newer contract).

The same entry objects are the payload of the live PubSub messages, so the
live tail and the saved file are identical entry-for-entry (SC-006).

> **Amended by feature 043** (`specs/043-close-recorder-gaps/contracts/recording.md`): header
> `version` is now 2 (adds `usage` and `stderr` kinds, `result.error`, `parent_tool_use_id`);
> readers accept v1 and v2 and refuse ≥ 3 with `{:unsupported_version, v}`.
