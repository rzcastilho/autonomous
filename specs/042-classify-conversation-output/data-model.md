# Data Model: Classify Conversation Output (042)

Display-only. No stored type, file format, entry kind or schema version
changes (FR-021). Every type below is an in-memory value computed from
`Autonomous.ConversationEntry` (040) by pure functions.

## Placement (`Autonomous.Web.ConversationClass`)

```text
classify(entry) :: %{placement, row_class, fold, label}
```

| field | values | notes |
|---|---|---|
| `placement` | `:row` · `:signal` · `:row_signal` · `:header_signal` | `:header_signal` = feeds header + footer, not a row (init). |
| `row_class` | `:prose` · `:context` · `:thinking` · `:call` · `:result` · `:marker` · `:divider` · `:end` · `:raw` | the class used when the entry is visible |
| `fold` | `:open` · `:line` · `:preview5` | `:line` = `<details>` showing first line; `:preview5` = first 5 lines + `+N lines` |
| `label` | string | `"<kind> · <sub-kind>"` for raw/marker rows |

### Classification table (normative — mirrored in `contracts/classification.md`)

| entry (kind · sub-kind) | placement | row_class | fold |
|---|---|---|---|
| `start` | `:row_signal` | `:divider` | `:open` |
| `prompt` | `:row` | `:context` | `:line` |
| `other · text` (injected skill text) | `:row` | `:context` | `:line` |
| `assistant_text` | `:row_signal` | `:prose` | `:open` |
| `thinking` | `:row_signal` | `:thinking` | `:line` |
| `tool_call` | `:row_signal` | `:call` | `:line` (input) |
| `tool_result` (call in view) | `:row_signal` | — (inside call block) | `:preview5` |
| `tool_result` (call not in view) | `:row_signal` | `:result` | `:preview5` |
| `system · task_started` | `:row_signal` | `:marker` | `:line` |
| `system · task_notification` | `:row_signal` | `:marker` | `:line` |
| `system · api_retry` | `:row_signal` | `:marker` | `:line` |
| `system · hook_response` (outcome ≠ `success` or exit_code ≠ 0) | `:row_signal` | `:marker` (flagged) | `:line` |
| `system · hook_response` (success) | `:signal` | `:raw` | `:line` |
| `system · status` · `thinking_tokens` · `hook_started` · `hook_progress` | `:signal` | `:raw` | `:line` |
| `system · init` | `:header_signal` | `:raw` | `:line` |
| `other · tool_progress` · `other · rate_limit_event` | `:signal` | `:raw` | `:line` |
| `result` (is_error or subtype ≠ `success`) | `:row_signal` | `:marker` (flagged) | `:line` |
| `result` (success) | `:signal` | `:raw` | `:line` |
| `end` | `:row_signal` | `:end` | `:open` |
| anything else (unknown kind or sub-kind) | `:row` | `:raw` | `:line` |

Rule: `visible?(c, all_frames?) = c.placement in [:row, :row_signal] or all_frames?`.
Invariant (SC-003): every entry is visible or feeds `SessionStatus` (or both);
`:signal`/`:header_signal` entries always feed it.

## Block (`Autonomous.Web.ConversationRows`, revised)

One rendered unit of the transcript; replaces the 040 per-entry row.

| field | type | notes |
|---|---|---|
| `key` | string | `"entry-<seq>"` of the entry that opened the block (call seq for call blocks) — the stream DOM id |
| `seq`, `at` | | of the opening entry |
| `class` | `row_class` | |
| `label` | string | eyebrow / marker label |
| `summary` | string | one-line text: `Tool(summary)`, first line of folded text, marker key values |
| `body` | string | folded body (040 truncation applied unless expanded) |
| `omitted` | `%{lines, chars}` \| nil | 040 truncation receipt |
| `tool_name`, `tool_use_id` | string \| nil | call / result blocks |
| `result` | `ResultPart` \| nil | call blocks only; nil until paired |
| `flag` | nil \| `:is_error` \| `:hook_failed` \| `:result_error` | rendered as `.conv-flag`, never a status colour |
| `unfinished?` | boolean | call block with no result at `end` (040 rule, kept) |
| `outcome`, `chip` | string \| nil | end block only; `chip` is a status *name* |

**ResultPart**: `seq`, `preview` (first 5 lines), `more_lines` (N, ≥ 0),
`full` (only when expanded), `error?`.

**Context (`ctx`)**: 040 `calls` (now `tool_use_id → block`), `names`,
`stale`, plus `result_owner: %{result_seq => call_key}` (expand a result in
place) and `all_frames?`.

Transitions of a call block: `open` (no result) → `paired` (result set, block
re-emitted under the same key) | `unfinished` (`end` arrives first; re-emitted
via `ctx.stale`). A result arriving after `unfinished` pairs normally (040
behaviour) — not expected in practice.

## ToolSummary (`Autonomous.Web.ToolSummary`)

`summary(name, input) :: String.t()` → `"Name(text)"` or `"Name"`.
Key preference by tool: `Bash: command` · `Read|Write|Edit: file_path` ·
`NotebookEdit: notebook_path` · `Grep|Glob: pattern` · `Skill: skill` ·
other: first string value by sorted key. Text: first line, `…` appended when
more lines exist, capped at 200 chars. `nil` name → `"tool"`.

## SessionStatus (`Autonomous.Web.SessionStatus`)

Reduced footer + header state; `apply/2` is a pure fold, idempotent by seq.

| field | type | source |
|---|---|---|
| `last_seq` | int \| nil | highest applied seq; `apply` ignores `seq <= last_seq` |
| `activity` | `{:requesting}` · `{:thinking, tokens}` · `{:running, tool, secs \| nil}` · `{:hook, name}` · `{:responding}` · `{:done}` · `{:outcome, text, chip}` · nil | most recent per FR-015 |
| `turns` | int | R6 fold; replaced by `result.num_turns` once present |
| `turn_msg` / `side` | internal | turn-boundary bookkeeping (R6) |
| `tool_calls` | int | count of `tool_call` |
| `open_calls` | `%{tool_use_id => tool_name}` | drives `running <tool>` |
| `open_tasks` | int | `max(started − notified, 0)` |
| `open_hooks` | `MapSet` of hook_id | started minus responded |
| `rate_limit` | nil \| `%{type, resets_at}` | set when latest event status ≠ `allowed` |
| `cost_usd`, `duration_ms` | number \| nil | from `result` only (never 0-filled) |
| `started_at`, `ended_at` | ISO8601 \| nil | `start.at`, `end.at` |
| `outcome` | nil \| `{text, chip}` | from `end`; once set, `activity` is frozen |
| `model_alias` | string \| nil | `start.body.model` |
| `model_resolved`, `cli_version` | string \| nil | `init.data.model`, `init.data.claude_code_version` |
| `session_id` | string \| nil | `init.data.session_id` (moves 040's `session_id_of/1` here) |
| `lower_bound?` | boolean | seeded from window because the file was unreadable |
| `announce` | nil \| string | last polite announcement (outcome / rate-limit onset) |

Activity transitions (latest wins, frozen after `end`):

```text
status(requesting)        → {:requesting}
thinking_tokens(n)        → {:thinking, n}           (latest value, no accumulation)
tool_call(name)           → {:running, name, nil}    (+ open_calls)
tool_progress(name, s)    → {:running, name, s}      (even with no open call)
tool_result               → closes open call; activity → next open call's {:running,…} or unchanged
hook_started(name)        → {:hook, name}            (+ open_hooks)
hook_response             → − open_hooks
assistant_text            → {:responding}
result                    → {:done}  (+ turns/cost/duration)
end                       → {:outcome, text, chip}   (terminal; later entries change nothing but last_seq)
```

Derived view values (pure): `activity_text/1` (`requesting`,
`thinking · ~1.2k tok`, `running Bash · 30s`, `hook · PreToolUse`,
`responding`, `done`, outcome text); `status_name(status, live?)` (`running` while live,
else the outcome chip); `elapsed_s(status, now)` (`now − started_at` while
not ended, `ended_at − started_at` after; nil without `started_at`);
`count_text(n, lower_bound?)` (`212` / `≥ 212`).

## Header fields

`ConversationLive` header = 040 identity line + `model_alias` · `model_resolved`
· `cli_version` from `SessionStatus` (mono). Missing values are omitted, never
shown as placeholders (US4-AS2).

## Unchanged (040)

`ConversationEntry`, `ConversationWindow` (500), `ConversationFile` format v1,
`ConversationRecorder`, masking, `ConversationRef`/store schema v8. Added read
helpers only: `ConversationFile.fold/4`, `Conversation.file_path/1`.
