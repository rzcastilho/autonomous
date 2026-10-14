# Research: Close the Conversation Recorder Gaps

Feature 043 · Phase 0 · 2026-10-14

Every unknown in the plan's Technical Context is resolved below. Sources are the
pinned dependencies under `deps/` (`claude_agent_sdk`, `jido_claude`) and the
2026-10-13/14 census of real conversation files under
`~/.autonomous/transcripts/*/*/conversations/` (91 files, 88 `result` entries).

---

## R1 — What a synthetic error result looks like at the tap

**Decision**: Read the result's error flag and error text from the parsed
`ClaudeAgentSDK.Message` `data` map as well as `raw`; the entry is an error when
`raw["is_error"] == true` **or** `data.is_error == true`; the error text is
`data.error` (falling back to `raw["error"]`), recorded only for error results.

**Evidence**: `ClaudeAgentSDK.Message.error_result/2`
(`deps/claude_agent_sdk/lib/claude_agent_sdk/message.ex:181`) is the SDK's
stand-in when the CLI produced no result (transport failure, decode failure,
process exit). It builds `%Message{type: :result, subtype: :error_during_execution,
data: %{error: msg, is_error: true, session_id: …, error_details: …}, raw: %{}}`.
`ConversationEntry.result/2` reads only `raw`, so today it records
`is_error: false` (from `nil == true`), `result: nil`, and loses `data.error`.
The subtype survives (`subtype/1` reads the struct), which is why the 042 view
already draws a `result_error` marker — but with no text, and the flag in the
file asserts success.

A *genuine* CLI result with an error subtype also goes through
`build_result_data/2`, which sets `data.is_error = raw["is_error"] || true`; the
new rule therefore also corrects a genuine error result whose raw `is_error` was
absent. A genuine `success` result is unchanged: `raw["is_error"]` false and
`data.is_error` false → `false` (FR-003).

**Census**: 88 of 88 recorded results are `success / is_error false / result
present`; 3 files have no result at all. No synthetic result exists in the
census, so SC-001 is proven against a fixture shaped from `error_result/2`, plus
an opt-in census re-check (R11).

**No message at all**: `error_result/2` requires a binary; it can be `""`. The
SDK's own `get_error_message/2` substitutes a default only on the CLI-parsed
path. Recorded body: `"error" => nil` when the text is absent or blank — the
record does not invent prose. The views render `no reason given` for an error
result whose `error` is `nil` (FR-002, scenario US1-4).

**Alternatives considered**:
- *Read only `data`* — rejected: genuine results' `raw` is the receipt and 040
  fixed `raw` as the source for every other field; `data` is used only for the
  two fields `raw` cannot supply.
- *Record `"error" => "no reason given"`* — rejected: the file would carry
  display prose as if the SDK had said it (Principle II, don't invent data).

---

## R2 — Where per-turn usage arrives, and how to total it without double counting

**Decision**: Record usage from `stream_event` frames only, as a new `:usage`
entry for `message_start` (carries `message.usage`: input, cache-read,
cache-creation, initial output) and `message_delta` (carries `usage` with the
**cumulative** output count for that API message). Every other `stream_event`
still produces no entry. The running figure is a pure fold (R6):
per message, keep the latest value of each field; total = sum over messages.

**Evidence**: the `jido_claude` adapter forces `include_partial_messages: true`
(`deps/jido_claude/lib/jido_claude/adapter.ex:183`), so the CLI is launched with
`--include-partial-messages` and the SDK delivers `%Message{type: :stream_event,
data: %{event: map, parent_tool_use_id: …}}` with `raw["event"]` the Anthropic
streaming event. Anthropic stream semantics: one `message_start` per API
request with input-side usage; zero or more `message_delta` events whose
`usage.output_tokens` is a running total for that message. `ConversationEntry`
drops all `stream_event` frames today (040 R5: their *content* is repeated in
the assistant frame — their *usage* is not). The assistant frame's
`message.usage` is a partial snapshot and the `result` frame's `usage` is the
session aggregate; neither updates while a turn runs (US3).

**Double counting** (spec edge case): a `message_delta` replaces, never adds
to, the previous output figure of the same message; a new `message_start` opens
the next message. Within one stream, events of one message are contiguous for a
given `parent_tool_use_id` (main agent `nil`); the fold keys "current message"
by that scope so a future interleaved subagent cannot corrupt main-agent totals.

**Volume**: two usage entries per API request (start + final delta, sometimes a
couple of deltas) — small next to the heartbeat frames 042 counted.

**Alternatives considered**:
- *Usage from assistant frames* — rejected: one assistant frame per content
  block repeats the same `message.usage` → double counting, and the figure is a
  snapshot taken before output finishes.
- *Only the result's `usage`* — rejected: that is today's behaviour (nothing
  until the end), the gap itself.
- *Running totals computed in the recorder* — rejected: the file must allow the
  totals at any point to be reconstructed (FR-010); a pure fold over recorded
  entries gives that, live and from Transcripts, with one implementation (SC-005).

---

## R3 — How stderr reaches the recorder without blocking or altering the session

**Decision**: `SdkProxy.prepare/1` already pops the conversation marker; it now
decodes it and passes the recorder pid to `callback/2`. The callback keeps its
two existing effects verbatim (log line, untrusted-workspace forward to the
`WorkspaceTrust.Collector`, FR-009) and adds a bare `send(recorder, {:stderr,
line})`. Nil or dead recorder → no-op.

**Evidence**: `SdkProxy` installs the `:stderr` callback on the SDK options
(feature 036, because the adapter drops it); the callback runs in the SDK
transport process for every CLI stderr line. `send/2` never blocks, never
raises on a dead pid, and returns before the SDK continues (FR-021). The
recorder is started by `Conversation.open/2` *before* `run_request`, so lines
emitted during a startup failure (session dies before any frame) are captured
(spec edge case "stderr during startup failure"). Lines emitted after
`Conversation.close/2` reach a dead pid and are dropped; the log still has them.

**Ordering**: frames are sent from the stream-consuming process, stderr from
the transport process; the recorder's mailbox order is the recorded order. The
views label nothing as "exact interleaving" (spec edge case).

**Alternatives considered**: reading the `WorkspaceTrust.Collector` at close —
rejected: the collector keeps only untrusted-workspace lines and loses
interleaving; and routing through the collector would couple the 036 check to
recording.

---

## R4 — Bounding a stderr flood (head 1,000 + rolling tail 1,000)

**Decision**: a new pure module `Autonomous.StderrBound` owned by the recorder:
`new(head, tail)`, `push(bound, line) → {:emit, line, bound} | {:held, bound}`,
`flush(bound) → {dropped_count, [tail_line]}`. The first `head` lines are
emitted on arrival; past that, lines go to a `:queue` capped at `tail`, counting
evictions as dropped. At `close`, before the `:end` entry, the recorder emits one
`:stderr` notice entry (`"notice" => "dropped", "dropped" => n`) when `n > 0`,
then the held tail lines in arrival order. ≤ head + tail lines total → every
line recorded, no notice (FR-008). Sizes come from
`Config.conversation_stderr_head/0` and `conversation_stderr_tail/0`
(app env `:conversation_stderr_head` / `:conversation_stderr_tail`, default
1,000 each, positive integers, validated at read like other `Config` accessors).

SC-006 arithmetic: 100,000 lines → 1,000 emitted + 1,000 held, 98,000 dropped,
2,000 line entries + 1 notice.

**Alternatives considered**: per-second rate limit (rejected: loses the end of
a retry storm, which is what explains the death); byte cap (rejected: the
clarification fixed a line count).

---

## R5 — Subagent attribution

**Decision**: `ConversationEntry.from_frame/1` adds `"parent_tool_use_id"` to
every entry it builds from an `:assistant` or `:user` frame when
`raw["parent_tool_use_id"]` is a non-empty binary; absent otherwise (never
`nil`, never `""`, FR-017). Usage entries carry it the same way (R2's scoping
needs it). No view reads it (FR-016).

**Evidence**: the CLI stamps `parent_tool_use_id` on every top-level
`assistant`/`user`/`stream_event` line (`schema/message.ex:22,33,72`); the SDK
keeps it in `raw`. The census has none (headless sessions disallow
`Agent`/`Task`, feature 039), so tests use a fixture.

---

## R6 — Status-line token figure

**Decision**: `SessionStatus` gains `usage` (the R2 fold state: `%{scope =>
current_message}` + `done` totals) and two derived figures, `input_tokens` and
`output_tokens` (`nil` until the first `:usage` entry — FR-013, never `0`).
`tokens_text/1` renders `in 12.1k · out 3.1k` (thousands to one decimal; under
1,000 the integer), prefixed `≥` when the status is a lower bound (042's
window-only seed). Cache fields are folded and kept in the struct but not in
the figure (FR-011). Cost stays exactly as 042: `nil` until the `:result`
entry's `cost_usd` (FR-012). Usage entries after the outcome are ignored the
same way every post-outcome entry is.

Parity (SC-005): live and Transcripts already fold the same entries through
`SessionStatus.apply/2`; the figure needs no separate code path.

**Latency (SC-003)**: a usage entry is broadcast by the recorder like any entry;
`ConversationLive` re-renders the status line on every entry (042), so the
figure updates on the same path whose ≤ 2 s bound 042 already met.

---

## R7 — Displaying the result error and footer truth

**Decision**: the 042 `result_error` marker row gains the error text:
`result · error_during_execution — <error>` (or `— no reason given`). In
`SessionStatus`, a result with `is_error` sets `activity: {:result_error, text}`
instead of `{:done}` and records `result_error`. The footer outcome still comes
from the `:end` entry (the session's classified outcome), **except** that an
`:end` outcome whose chip is `done` while a result error is recorded renders
chip `failed` with text `<outcome> · result error` — the record says the result
failed, so the footer may not show a clean finish (FR-004).

**Why the exception is reachable at all**: the harness mapper turns a
non-success result into a failure event, so in practice the end outcome is
already a failure; the rule guards the one combination where it is not, rather
than trusting that mapping (Principle VII, "show the receipt").

---

## R8 — Stderr rows and repeat collapse

**Decision**: `ConversationClass` places `:stderr` as `:row` with a new row
class `:stderr` (quiet one-line row, mono, `--text-faint`-family token already
in `console.css`); the notice entry is a `:marker` row (`stderr · 98000 lines
dropped`). `ConversationRows` collapses consecutive `:stderr` entries with
identical `line` text into one block with a `repeat` count, re-emitting the same
stream key with the incremented count (the 042 call+result regrouping
technique); any other entry in between ends the run. The file keeps every line
(FR-006). `frames=all` does not affect stderr rows (visible either way — US2-4).

`:usage` is `:signal` / `:raw` (visible only under `frames=all`, FR-014), label
`usage · message_start|message_delta`.

Design-contract guard: new CSS uses existing tokens only, no new keyframes,
breakpoints, or tokens; rule count unchanged (FR-023, SC-008).

---

## R9 — File format v2 and compatibility

**Decision**: `ConversationFile` `@version` 1 → 2. New kinds `:usage`,
`:stderr`; new optional fields `result.error`, `*.parent_tool_use_id`. The
existing header check (`v <= @version` accepts, newer → `{:error,
{:unsupported_version, v}}`) already gives "accept v1 and v2, refuse newer" —
FR-019 needs no new reader code, only the bump and a test for v3 refusal.

v1 parity (SC-004): v1 files contain none of the new kinds or fields; the
result rule of R1 on a v1 entry is never re-run (decode reads the stored flag),
so a v1 file renders byte-identically. The census test (opt-in) re-renders all
local v1 files and compares against 042 output.

**Store (FR-020)**: `ConversationRef`, capture statuses and Mnesia schema v8
unchanged — the version lives only in the file header. No migration of old
files (spec Assumptions).

**Old build reading a v2 file** (mixed rollback): refused by version with the
existing message — FR-019 as specified.

---

## R10 — Live window, masking, never-block

- New entries go through the recorder's single `emit/2` (mask → seq → window →
  append → broadcast): `CredentialMask.mask/2` covers `line` and `error` with no
  new code (FR-007); they count toward the 500-entry window and `entries`/`bytes`
  on the ref.
- A `{:stderr, line}` message that fails processing is caught by the same
  `rescue` → `:error` capture-status degradation as frames (FR-021).
- `handle_info({:stderr, _})` is O(1) (queue push); the flush at close is
  bounded by `tail`.

---

## R11 — Testing strategy

- Pure unit tests: `ConversationEntry` (R1/R2/R5 cases), `StderrBound`
  (≤, =, >, 100k), `SessionStatus` (usage fold, cumulative replace, scope
  separation, nil-not-zero, lower bound, result_error footer), `ConversationClass`
  and `ConversationRows` (stderr collapse, notice, error text), `Config`
  accessors.
- Process tests: `ConversationRecorder` with `{:stderr, line}` + close flush
  order; `SdkProxy` callback forwards to recorder **and** still logs/collects.
- LiveView: `ConversationLive` and `TranscriptsLive` parity for token figure
  and result error; `frames=all` unchanged for stderr.
- Fixture: `test/fixtures/conversations/043_sample.jsonl` (v2: usage start /
  delta ×2 messages, stderr burst + repeats + notice + tail, parent ids,
  synthetic error result) plus frame-level fixtures built from
  `Message.error_result/2` in-test.
- Opt-in `:census` re-run of 042's census asserting v1 output unchanged.
