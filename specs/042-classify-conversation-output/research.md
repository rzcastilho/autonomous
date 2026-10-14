# Research: Classify Conversation Output (042)

All Technical Context items were resolvable from the 040 code and from the 91
recorded conversations under `~/.autonomous/transcripts/**/conversations/`
(census re-run 2026-10-13). No NEEDS CLARIFICATION remains.

## R1 — Observed sub-kind shapes (the contract this feature reads)

**Decision**: Read exactly these fields; add none to the recorder.

| entry | discriminator | fields read |
|---|---|---|
| `system` | `body.subtype` | `status` → `data.status` (`requesting`); `thinking_tokens` → `data.estimated_tokens`; `hook_started` / `hook_progress` → `data.hook_id`, `data.hook_name`, `data.hook_event`; `hook_response` → `data.hook_id`, `data.hook_name`, `data.outcome` (`success` \| `error`), `data.exit_code`, `data.output`; `init` → `data.model`, `data.claude_code_version`, `data.session_id`; `task_started` → `data.task_id`, `data.description`, `data.task_type`; `task_notification` → `data.task_id`, `data.status`, `data.summary`; `api_retry` → `data.attempt`, `data.max_retries`, `data.error`, `data.error_status`, `data.retry_delay_ms` |
| `other` | `body.raw.type` | `tool_progress` → `raw.tool_name`, `raw.parent_tool_use_id`, `raw.elapsed_time_seconds`; `rate_limit_event` → `raw.rate_limit_info.status`, `.rateLimitType`, `.resetsAt` (unix s); `text` → `raw.text` (injected skill expansion) |
| `result` | `body.subtype`, `body.is_error` | `num_turns`, `duration_ms`, `cost_usd` |
| `start` | — | `model` (alias), `at` |
| `end` | — | `outcome`, `at` |
| `assistant_text` / `thinking` | — | `text`, `message_id` |
| `tool_call` | — | `tool_use_id`, `name`, `input` |
| `tool_result` | — | `tool_use_id`, `output`, `is_error` |

Census facts that shape design: hook responses are `success/0` ×262 and
`error/1` ×83 (all a host SessionStart hook — so failing-hook marker rows are
real and common); every `rate_limit_event` so far is `allowed` (indicator
never shown in the census, still required); 293 of 299 `thinking` entries
carry `text: ""` (redacted thinking); every `result` is `success`.

**Alternatives**: parse `raw` frames anew — rejected (FR-021: recorder and
entry kinds unchanged; 040 bodies already carry these fields).

## R2 — Row model: blocks, not rows

**Decision**: `ConversationRows` keeps its name and context-threading API but
emits **blocks**. A `:call` block is keyed by its call entry (`entry-<seq>`)
and carries `result: nil | result_part`. When a result arrives, the block is
re-emitted with the same key; a LiveView `stream_insert` of an existing DOM id
replaces it in place, so order stays the calls' order (parallel calls, FR-009,
US2-AS8). A result whose call is not in the context (window truncation, page
boundary) is a standalone `:result` block keyed by its own seq.

**Rationale**: LiveView streams already update by DOM id; no client JS.
`ctx.calls` already holds open calls by `tool_use_id`; it now holds the
block. The 040 `stale` mechanism (re-insert calls tagged `unfinished` at
`:end`) is kept verbatim.

**Alternatives**: client-side DOM move of result under call — rejected
(JS for something LiveView expresses); separate result row with indent —
rejected by clarification Q1.

## R3 — One pure classifier

**Decision**: new pure module `Autonomous.Web.ConversationClass` with
`classify(entry) :: %{placement, row_class, fold}`. `ConversationRows`,
`SessionStatus` and both LiveViews call it; nothing else decides placement.
`placement ∈ :row | :signal | :row_signal | :header_signal` (init and start
feed the header; start is also a divider row). Visibility rule:
`visible? = placement in [:row, :row_signal] or all_frames?`.

**Rationale**: FR-001/FR-024 — one shared table makes live/review parity a
property of the code, not of two call sites.

## R4 — Tool summary heuristics

**Decision**: `Autonomous.Web.ToolSummary.summary(name, input)`:
`Bash`→`command` (first line, `…` if more lines); `Read`/`Write`/`Edit`/
`NotebookEdit`→`file_path` (then `notebook_path`); `Grep`/`Glob`→`pattern`;
`Skill`→`skill`; else first string-valued input in **sorted key order**
(maps have no order; sorting makes it deterministic); else name alone.
The line is ellipsized by CSS (`text-overflow: ellipsis`, single line —
Principle VII "constrained identifier MUST ellipsize"), never wrapped. Text is
truncated server-side to 200 chars to bound payload.

**Alternatives**: per-tool templates for every Claude tool — rejected; only
six appear in the census and the fallback covers the rest (spec Assumption).

## R5 — Footer state: pure fold, seeded from the file on join

**Decision**: `Autonomous.Web.SessionStatus` — `new/0`, `apply(status,
entry)`, `apply_all/2`, plus pure view helpers (`activity_text/1`,
`status_name/2` (with `live?`), `elapsed_s/2`). It records `last_seq` and ignores any entry
with `seq <= last_seq` (FR-018a "applied once, by sequence").

Join order becomes **subscribe → catch_up (window, `last_seq`) → seed status
from file up to `last_seq` → apply broadcasts `seq > last_seq`**. The file
path comes from the registry identity (`Conversation.in_flight/1` already
exposes `identity`; `ConversationFile.relative_path/2` + `resolve/2`) via a new
viewer-side `Conversation.file_path/1` — no extra recorder call.

The seed read is a new `ConversationFile.fold/4` (`File.stream!` line by line,
decode, stop after `last_seq`, never materializing the list). It stops at
`last_seq` so a line the recorder is writing concurrently is never read; a
malformed/missing file → `{:error, _}` → the view seeds from the window and
sets `lower_bound?: true` (counters render `≥ N`).

**Rationale**: clarification Q2; bounded memory; reading the file is the 040
saved-review path already (`page/3`), not a listing (constitution
Persistence). One read per join/reconnect.

**Alternatives**: recorder keeps a running status — rejected (FR-021: no
recorder change); seed from window only — rejected (wrong counters past 500).

## R6 — Turn counting without message ids on tool calls

**Finding**: `tool_call` bodies carry no `message_id`; text and thinking do.

**Decision**: a turn opens on the first assistant-side entry (`assistant_text`,
`thinking`, `tool_call`) after a user-side entry (`prompt`, `tool_result`,
injected `other·text`) or at session start, and also whenever an
assistant-side entry carries a `message_id` different from the turn's known
one. Once a `result` arrives, its `num_turns` replaces the live count
(US1-AS7). Saved and live views run the same fold, so parity holds.

**Alternatives**: count distinct `message_id`s only — undercounts tool-only
messages; count tool calls — wrong for parallel calls.

## R7 — Elapsed timer

**Decision**: server tick. While `live? and not status.ended?` the LiveView
schedules `Process.send_after(self(), :tick, 1000)` and assigns `now`;
`elapsed = now − started_at`, where `started_at` is the `start` entry's `at`
(from the file seed), falling back to `in_flight` `opened_at`. At `end` the
figure is `end.at − started_at` and the tick stops. Saved review: static
`end.at − start.at`.

**Rationale**: FR-017 says clock against a recorded start; server-rendered
LiveView is the stack default; one tiny diff per second per viewer. Principle
VII's "never a timer standing in for progress" is honoured — elapsed is
labelled as a duration, not progress.

**Alternatives**: client hook computing from `data-started-at` — viable, but
adds JS where LiveView suffices; kept as a fallback if tick load is measured
as a problem.

## R8 — Accessibility of the status line

**Decision**: footer is `<section role="region" aria-label="session status">`
(not `role=status`, which would announce every change), with one visually
hidden `<p class="sr-only" aria-live="polite" data-announce>` whose text is
set only when (a) the outcome is set or (b) the rate-limit state turns from
allowed to limited. Existing `.sr-only` class is reused (no new CSS).

## R9 — Show-all-frames toggle

**Decision**: query param `frames=all` on `/live`, `/live/:id`, and
`/transcripts`; embedded panel toggles in place (no URL, like follow). Flip →
the view rebuilds rows from source: live → one fresh `Conversation.catch_up/1`
(the window), saved → re-page `0..loaded` via `ConversationFile.page/3`.
The status fold is not rebuilt (unchanged by the toggle, FR-020). Hidden
entries are never streamed while off (payload stays small). Signal rows in
all-frames mode are `:raw` class, folded, label `<kind> · <sub-kind>`.

**Alternatives**: always stream every entry and hide with CSS — rejected:
3× DOM size and payload for the common case.

## R10 — Folding and expansion

**Decision**: line-folded rows (prompt, context, thinking, raw, marker
payload, call input) use native `<details>`/`<summary>` (summary = first line,
mono or sans per role) — no server round-trip. The body inside keeps 040's
40-line/4,000-char truncation and its server `expand` event. Tool results
render their first 5 lines plus a `+N lines` button that fires the existing
`expand` event (`phx-value-seq` = result seq); the server rebuilds the
**owning call block** with the full result (`ctx` maps result seq → call
key). Empty thinking (redacted) renders a summary `thinking` with no body.

## R11 — Census effect (SC-001 check)

Measured on the 91 files: 5,014 entries; default-visible **blocks** =
prompt 91 + assistant 204 + thinking 299 + call blocks 704 + context 15 +
start 91 + end 89 + task 131 + api_retry 1 + failed hooks 83 = **1,708
(34.1%)** ≤ 35%. Counting results separately would be 48% — SC-001 is met
only because results live inside call blocks (R2). Note the margin is thin;
failing hooks (83) are the main contributor beyond the spec's estimate.

A hermetic test uses a committed synthetic fixture shaped from R1; an opt-in
`@tag :census` test (excluded by default) runs SC-001..SC-004 against
`AUTONOMOUS_CENSUS_DIR` for re-measuring on a real machine.

## R12 — Status colour and motion

**Decision**: activity dot uses the existing status-dot pattern with a
`data-status` name: `running` while live activity, `done`/`failed`/`blocked`
from the outcome chip mapping already in `ConversationRows.chip/1`. Pulse =
existing `.transcript-live` / `scPulse` only while live — live referent. Error
flags reuse `.conv-flag` (text/border roles). No new keyframes, tokens or
breakpoints; footer wrapping uses `flex-wrap` and the existing 760px query.
