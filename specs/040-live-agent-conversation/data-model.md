# Data Model: Live and Durable Agent Conversation View

**Feature**: 040-live-agent-conversation | Decisions: [research.md](research.md)

## ConversationIdentity (in-memory; built by `FeatureRunner`)

| Field | Type | Notes |
|---|---|---|
| `repo_id` | `String.t()` | registry lookup key for `in_flight/1` |
| `run_id` | `String.t()` | e.g. `r000012` |
| `feature_id` | `String.t()` | store feature key |
| `phase` | `atom()` | `:specify … :converge`, `:implement_chunk`, `:auto_remediation`, `:remediation`, `:describe` |
| `ordinal` | `pos_integer()` | the attempt ordinal the row will carry |
| `kind` | `:phase \| :implement_chunk \| :auto_remediation \| :remediation \| :describe` | |
| `chunk` | `term() \| nil` | chunk scope (`{:task_phase, _}`, `{:sweep, _}`) for `:implement_chunk` |
| `attempt` | `pos_integer() \| nil` | auto-remediation attempt / clarify round |
| `transcript_root` | `Path.t()` | from the run's `Layout` |

Validation: all of `run_id`, `feature_id`, `phase`, `ordinal`,
`transcript_root` required; `open/2` returns `{:error, {:bad_identity, field}}`
otherwise (programmer error surfaced loudly in tests, logged in prod, never
fails the session).

## ConversationEntry (pure; one line of the saved file, one live message)

| Field | Type | Notes |
|---|---|---|
| `seq` | `non_neg_integer()` | per-conversation, assigned by the recorder, strictly increasing, no gaps |
| `at` | ISO-8601 string | recorder receive time |
| `kind` | `:start \| :prompt \| :assistant_text \| :thinking \| :tool_call \| :tool_result \| :system \| :result \| :other \| :end` | |
| `body` | map | per kind, below; every string masked (R9) |

| Kind | `body` |
|---|---|
| `:start` | identity (minus `transcript_root`), `model` |
| `:prompt` | `text` — the prompt the orchestrator sent |
| `:assistant_text` | `text`, `message_id` |
| `:thinking` | `text`, `message_id` |
| `:tool_call` | `tool_use_id`, `name`, `input` (map, untouched) |
| `:tool_result` | `tool_use_id`, `output` (string or content list), `is_error` |
| `:system` | `subtype`, `data` |
| `:result` | `subtype`, `result`, `num_turns`, `duration_ms`, `cost_usd`, `is_error` |
| `:other` | `raw` — any frame type not above, whole |
| `:end` | `outcome` (below), `session_id`, `drain_requested` (boolean) |

`stream_event` frames produce no entry (R5).

**Outcome** (`ConversationOutcome.from_result/1`, pure, from `PhaseResult`):
`:completed` · `{:error, reason}` · `:exhausted` (max turns) ·
`:deadline_exceeded` · `{:session_died, :start_failed | :ended_early}` ·
`{:backgrounded_command, …}` / `:incomplete_session` passed through as the
gate terms they already are. Rendered with the system's own term vocabulary.

## ConversationWindow (pure; recorder state)

`%{entries: :queue.queue(), size: n, cap: 500, first_seq: s, last_seq: s, dropped: n}`
— `push/2` evicts the oldest at `cap`; `snapshot/1` →
`{entries, last_seq, truncated? = dropped > 0}`. Released with the recorder.

## Conversation file (on disk)

`<transcript_root>/conversations/<run_id>/<feature_id>/<conversation_id>.jsonl`,
dirs `0700`, file `0600`. Line 1 header:

```json
{"format":"speckit.conversation","version":1,"conversation_id":"implement_chunk-3-m3k9x2a1-7","run_id":"r000012","feature_id":"005","phase":"implement_chunk","ordinal":3,"opened_at":"…"}
```

Lines 2…: one `ConversationEntry` each, JSON-encoded, in `seq` order. A
clean file ends with exactly one `:end` entry. See
[contracts/conversation-file.md](contracts/conversation-file.md).

## ConversationRef (Mnesia; element of `PhaseAttempt.conversations`)

| Field | Type | Notes |
|---|---|---|
| `conversation_id` | `String.t()` | |
| `path` | `String.t() \| nil` | relative to `transcript_root`; `nil` only when `:not_captured` before any file existed |
| `status` | `:captured \| :partial \| :not_captured` | R6 |
| `reason` | `term() \| nil` | `nil` iff `:captured`; e.g. `{:open_failed, :eacces}`, `:recorder_down`, `:close_timeout` |
| `session_id` | `String.t() \| nil` | agent CLI session id |
| `entries` | `non_neg_integer()` | |
| `bytes` | `non_neg_integer()` | |
| `outcome` | outcome term | as in the `:end` entry |

## PhaseAttempt (existing `speckit_phase_attempt`, schema v7 → v8)

Fields unchanged plus, appended last:

| Field | Type | Meaning |
|---|---|---|
| `conversations` | `nil \| [ConversationRef]` | `nil` = written before 040 (no conversation recorded); `[]` = no session (e.g. `:implement` roll-up); otherwise one ref per session, in run order |

New attempt kind: **`phase: :describe`**, ordinal 1, `label: "describe"`, no
cost entry (R11).

**Migration v8** (`Store.Migrations`): `transform_table(:speckit_phase_attempt,
&Tuple.insert_at(&1, tuple_size(&1), nil), @phase_attempt_v8_attributes)`;
`current_version/0` → 8; moduledoc paragraph; `Schema`, `Records.PhaseAttempt`
struct/type and `Export` updated. No row dropped or rewritten lossily (FR-016).

## Process / registry state

| Name | Kind | Contents |
|---|---|---|
| `Autonomous.ConversationRegistry` | `Registry, keys: :unique` | key `conversation_id` → value `ConversationIdentity` (minus root) + `opened_at` |
| `Autonomous.ConversationSup` | `DynamicSupervisor` | `ConversationRecorder` children, `restart: :temporary` |
| `ConversationRecorder` state | GenServer | identity, `io` device, `seq`, `ConversationWindow`, mask pairs, `bytes`, `entries`, `status` |

## State transitions (recorder)

```text
open/2 ──► :open ──frame*──► :open ──close/2──► :closed (file has :end) ──► stop
             │                   │
             │ open failed       └─ recorder crash / close timeout ──► ref :partial
             └──► ref :not_captured (no process kept)
```

## Relationships

- One session ⇄ one recorder ⇄ one file ⇄ one `ConversationRef`.
- One `PhaseAttempt` → 0..n `ConversationRef` (n = sessions incl. retry).
- `ConversationIdentity.{run_id, feature_id, phase, ordinal}` = the attempt's
  `attempt_id` components (`Store.Ids`), so the Transcripts page finds a
  conversation from the row alone; listings read refs, never files (FR-021).
