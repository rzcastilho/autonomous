# Feature Specification: Classify Conversation Output — Scroll Rows, Header Fields, Footer Signals

**Feature Branch**: `042-classify-conversation-output`

**Created**: 2026-10-13

**Status**: Draft

**Input**: User description: "Classify the live agent conversation output (feature 040) the way Claude Code's terminal does: transcript rows that scroll, identity fields in the sticky header, and ephemeral progress signals in a new sticky footer status line. Scroll rows: assistant prose (sans), prompt and injected skill context (folded), thinking (folded), tool calls as one-line `Tool(summary)` with folded JSON input, tool results nested under their call with 5 visible lines, markers for background-task start/finish, failed hooks, api retries, error results, and the start/end dividers; unknown frames still render folded (completeness kept). Header gains model (alias and resolved) and CLI version. Footer shows current activity (requesting / thinking ~tokens / running tool + elapsed / hook / responding / done / outcome), turn and tool counters, background-task count, elapsed timer while live, rate-limit state, and cost/duration once the result arrives. A "show all frames" toggle restores every entry as a row. The saved Transcripts review uses the same classifier and shows the final footer state. Display-only: the recorder, entry kinds and file format are unchanged; recorder gaps (per-turn usage, stderr, subagent attribution, synthetic error text) are a separate follow-up feature. Design constitution rules (tokens only, data-status names, mono/sans roles, four keyframes, one breakpoint) apply."

## Context

Feature 040 records every frame of every agent session and shows them, live
and saved, as one uniform list: each entry is a bordered card with a label and
its body as pretty-printed JSON. That was the right first step — nothing is
lost — but a census of the 91 conversations recorded so far shows what the
operator actually scrolls through:

| entry kind | entries | what it mostly is |
|---|---|---|
| system | 2340 | `status` 725 · `thinking_tokens` 671 · `hook_started` 345 · `hook_response` 345 · `init` 91 · `task_started` 66 · `task_notification` 65 · `hook_progress` 31 · `api_retry` 1 |
| tool_call / tool_result | 704 / 703 | Bash 556 · Edit 45 · Read 31 · Write 29 · Skill 26 · Glob 17 |
| other | 405 | `tool_progress` heartbeats 278 · `rate_limit_event` 112 · injected skill text 15 |
| thinking | 299 | |
| assistant_text | 204 | the only prose |
| start / prompt / end / result | 91 / 91 / 89 / 88 | one each per session |

Roughly three entries in five are ephemeral progress signals — "requesting",
"thinking, ~50 tokens so far", "hook started", "Bash still running, 30 s", a
rate-limit notice. The agent's own terminal never scrolls these: it shows the
latest one in a status line under the transcript and keeps the transcript for
the prompt, the prose, the tool calls and their results. In the console today
those signals bury the conversation. An operator watching a 40-minute
implement session scrolls past hundreds of `system · status` and
`system · thinking_tokens` cards to find the one tool result that failed, and
the tool rows themselves show the full JSON input and up to 40 lines of
output, so even the useful entries are hard to scan.

This feature classifies every entry the recorder already produces into one of
three places — a **scroll row** in the transcript, a **header field** in the
sticky toolbar, or a **footer signal** in a new sticky status line — and gives
each class its own compact presentation. Nothing recorded is dropped: a
"show all frames" toggle restores the complete list, and the saved review
uses the same classification, so what the operator watched live is exactly
what they review later.

## Clarifications

### Session 2026-10-13

- Q: With parallel calls (one assistant message emits two calls, then both results), what does "result nested under its call" mean? → A: Group into the call — the result renders inside its call's block (call + result form one block, updated in place when the result arrives), so blocks read `[call A + result A] [call B + result B]` regardless of arrival order.
- Q: On a live join or reconnect, the catch-up window holds only the last 500 entries; where does the footer state come from? → A: Reduce the session's conversation file (appended live with the same entries) to build the footer state on join; the window still drives the rows. One bounded read per join or reconnect, never from a listing.
- Q: Should assistive technology be told when the status line changes? → A: Announce only the session's end outcome and the onset of a rate limit, politely; the status line is a labelled status region but activity, counters and elapsed are not announced.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read the transcript, watch the signals (Priority: P1)

An operator opens the live view of a running session. The scrolling area
shows only what the agent said, what it was asked, what tools it called and
what came back — the transcript. Below the transcript, pinned to the bottom of
the view, a single status line shows what the agent is doing right now
("requesting", "thinking · ~1.2k tok", "running Bash · 30s", "hook ·
PreToolUse", "responding", "done"), how many turns and tool calls so far, how
many background tasks are open, how long the session has been running, and
whether a rate limit is in effect. Progress frames update that line; they
never appear as rows.

**Why this priority**: This is the whole point of the feature. Three in five
recorded entries are progress noise; moving them out of the scroll turns the
live view from a frame dump into a readable conversation with a live status
line, which is what an operator needs to decide whether to intervene.

**Independent Test**: Replay a recorded conversation (any of the 91) through
the live view and confirm that no `system · status`, `system ·
thinking_tokens`, `hook_started`, successful `hook_response`,
`tool_progress` or `rate_limit_event` entry becomes a row, that each of them
updates the status line, and that every prompt, assistant text, thinking,
tool call and tool result entry is a row in arrival order — with no other part
of this feature present.

**Acceptance Scenarios**:

1. **Given** a session is running and the agent is between tool calls,
   **When** a `system · status` entry with status `requesting` arrives,
   **Then** the footer activity reads `requesting` and no new row is added to
   the transcript.
2. **Given** the agent is thinking, **When** `system · thinking_tokens`
   entries arrive, **Then** the footer activity reads `thinking · ~N tok`
   with N from the latest entry, updated in place, and no row is added.
3. **Given** the agent has called `Bash` and the result has not arrived,
   **When** `tool_progress` heartbeats arrive, **Then** the footer activity
   reads `running Bash · 30s` (elapsed from the heartbeat), and when the
   result arrives the activity moves on.
4. **Given** a hook runs, **When** `hook_started` arrives, **Then** the
   footer activity names the hook and the open-hook count increments; **When**
   its `hook_response` reports success, **Then** the count decrements and no
   row is added.
5. **Given** the agent produces prose, a thinking block, a tool call and its
   result, **When** they arrive, **Then** each appears in the transcript in
   order (the result inside its call's block), and the footer turn counter increments once per assistant message.
6. **Given** a `rate_limit_event` arrives whose status is not `allowed`,
   **When** the footer updates, **Then** a rate-limit indication shows the
   limit type and when it resets; **When** a later event reports `allowed`,
   **Then** the indication clears.
7. **Given** the session's result arrives, **When** it reports success,
   **Then** the footer shows turns, duration and cost from the result, the
   activity reads `done`, and no `result` row is added.
8. **Given** the session's end marker arrives, **When** the footer updates,
   **Then** the activity shows the session outcome (the same outcome chip
   as the end row), the elapsed figure stops, and no later signal changes it.
9. **Given** the operator is watching, **When** the session has been running
   for a while, **Then** the footer's elapsed figure reflects the time since
   the session's recorded start and advances once per second while the
   session is live.

---

### User Story 2 - Scan tool calls and results at a glance (Priority: P2)

An operator scans a transcript for what the agent did. Each tool call is one
mono line in the shape the agent's terminal uses — `Bash(mix test)`,
`Read(lib/foo.ex)`, `Edit(lib/foo.ex)`, `Grep(defmodule)`, `Skill(speckit-plan)` —
with the full input available on demand. Each result sits visibly under the
call that produced it, showing its first five lines with a "+N lines" fold,
and a failed result is flagged. Prose stays sans and open; the prompt, injected
skill context and thinking are folded to a single line until opened.

**Why this priority**: Once the noise is gone (US1), tool traffic is most of
what remains (1,400 of ~1,600 transcript rows in the census). Making each
call one scannable line, and nesting its result, is what lets the operator
find "the Bash that failed" in seconds instead of reading JSON.

**Independent Test**: Render a conversation containing calls to each of the
six observed tools plus one unknown tool, with short, long and failed
results, and check the summary line, the fold, the nesting and the error
flag for each — independently of the footer (US1) or the toggle (US3).

**Acceptance Scenarios**:

1. **Given** a `Bash` tool call with a `command` input, **When** it is
   rendered, **Then** its row reads `Bash(<command>)` on one mono line and
   the full input is shown only when the operator expands it.
2. **Given** calls to `Read`, `Write`, `Edit`, `Glob`, `Grep` and `Skill`,
   **When** rendered, **Then** each summary line shows the tool name and its
   most identifying input (path, pattern or skill name); a tool with no
   recognised input shows the tool name and the first text input it carries,
   or the name alone.
3. **Given** a tool result of 40 lines, **When** rendered, **Then** it sits
   inside its call's block, shows the first 5 lines and a `+35 lines`
   affordance, and expands in place to the full output.
4. **Given** a tool result with `is_error: true`, **When** rendered, **Then**
   it is visibly flagged as an error without using a status colour.
5. **Given** a prompt entry of 200 lines, **When** rendered, **Then** the row
   shows its first line and a fold affordance; expanding shows the whole
   prompt as plain text.
6. **Given** an injected skill-expansion text block (today an `other` entry
   carrying a user text block), **When** rendered, **Then** it is a folded
   context row labelled as context, not a raw frame.
7. **Given** a session cut before a tool result arrived, **When** the end
   marker is rendered, **Then** the open call is tagged `unfinished` as
   today, and the footer activity showed `running <tool>` until the end.
8. **Given** one assistant message emits calls A then B and result B arrives
   before result A, **When** rendered, **Then** the transcript reads
   `[A + result A] [B + result B]`, each result appearing in its call's block
   as it arrives.

---

### User Story 3 - See every frame when needed, review the same view later (Priority: P3)

An operator debugging an odd session flips a "show all frames" toggle: every
recorded entry — including the progress signals, successful hooks and the raw
`init` — becomes a row, in the same compact style, so nothing recorded is
hidden. On the Transcripts page the saved conversation renders through the
same classification, with the status line showing the session's final state
(outcome, turns, tools, duration, cost), so a review reads exactly as the
live view did.

**Why this priority**: Completeness is a 040 guarantee (nothing dropped) and
parity between live and review is what makes the recording trustworthy. Both
must survive the new classification, but neither is what an operator needs
first.

**Independent Test**: With the toggle off, count rows for a recorded
conversation; flip it on and confirm every entry is visible (blocks equal
entries minus results shown inside their call's block);
open the same conversation on Transcripts and confirm the rows and the final
status line match the live view's end state.

**Acceptance Scenarios**:

1. **Given** the toggle is off (default), **When** a conversation with 5,000
   entries renders, **Then** only transcript-class entries are rows and the
   rest are reflected in the status line.
2. **Given** the operator turns the toggle on, **When** the view updates,
   **Then** every entry is visible as a row — signals as compact folded rows labelled
   with their kind and sub-kind — in recorded order, and the choice is kept in
   the page address like the follow toggle.
3. **Given** a saved conversation, **When** opened on Transcripts, **Then**
   the rows are classified identically to the live view and a static status
   line shows the final reduced state (outcome, turns, tools, duration, cost).
4. **Given** a saved conversation over 500 entries, **When** the operator
   loads the next page, **Then** the status line reflects all pages loaded so
   far, not only the last.
5. **Given** an entry of a kind or sub-kind this feature does not name,
   **When** rendered, **Then** it is a folded raw row with its kind and
   sub-kind as the label — never dropped, never a status-line-only signal.

---

### User Story 4 - Know which model and CLI ran the session (Priority: P4)

The sticky header of the live view already names the run, feature, phase,
ordinal and session. It additionally shows the model the orchestrator asked
for and the model the agent CLI actually resolved, plus the CLI version, so an
operator reading a transcript knows what produced it.

**Why this priority**: Small, independent, and answers a question operators
ask when a session behaves differently from the last one.

**Independent Test**: Render a conversation whose start entry carries a model
alias and whose `init` system entry carries the resolved model and CLI
version; confirm all three appear in the header and that a conversation with
no `init` entry shows the alias alone.

**Acceptance Scenarios**:

1. **Given** the start entry names model `opus` and the `init` entry resolves
   it to a concrete model id with a CLI version, **When** the header renders,
   **Then** it shows the alias, the resolved id and the version in mono.
2. **Given** no `init` entry has arrived yet, **When** the header renders,
   **Then** it shows the alias only, and fills in the rest when `init`
   arrives.

---

### Edge Cases

- **Heartbeat without a visible call**: a `tool_progress` whose
  `parent_tool_use_id` matches no open call (e.g. after a catch-up window
  truncation) still updates the activity line with its tool name and elapsed;
  it never creates a row.
- **Signals after the end marker**: any entry arriving after `end` (none are
  expected) is classified normally but the footer stays frozen on the outcome.
- **Result before end, or end without result**: the footer shows result
  figures when they exist; a session that died or was cut has an `end` and no
  `result`, and the footer shows the outcome with no cost/duration figures
  rather than zeros.
- **Error result**: a `result` with `is_error` or a non-success subtype is both
  a flagged marker row and the footer's `done` state; a success result is
  footer-only.
- **Failed hook**: a `hook_response` whose outcome is not success or whose
  exit code is non-zero is a flagged marker row carrying the hook name and
  exit code, with its output folded; a successful one is footer-only.
- **API retry**: `api_retry` is a one-line marker row (attempt, max, error,
  delay) so a flaky session leaves a visible trace in the transcript.
- **Background tasks**: `task_started` and `task_notification` are both
  one-line marker rows and footer counters (open tasks = started − notified,
  floored at zero).
- **Thinking-token estimate going backwards**: the footer shows the latest
  value as reported; it does not accumulate.
- **Verbose toggle flipped mid-session**: previously hidden entries within the
  500-entry window appear as rows in recorded order; entries outside the
  window are not recoverable live (same limit as the catch-up window).
- **Mission Control embed**: the status line pins to the bottom of the
  embedded panel's own scroll area, as the toolbar pins to its top.
- **Narrow screens**: the status line wraps its groups rather than overflowing
  horizontally.
- **Long session, late join**: a viewer joining a 3,000-entry session sees
  the last 500 entries as rows but exact counters (turns, tools, background
  tasks, hooks) in the status line, reduced from the whole saved file.
- **Saved file unreadable on join**: the status line falls back to the window
  and shows its counters as lower bounds (e.g. `tools ≥ 212`).
- **Elapsed on a reconnected view**: elapsed is computed from the session's
  recorded start time, so a reload or reconnect shows the true elapsed, not a
  figure restarting at zero.
- **Pre-feature saved conversations**: a file saved by 040 renders through the
  new classification unchanged; no migration, no re-save.

## Requirements *(mandatory)*

### Functional Requirements

**Classification**

- **FR-001**: Every recorded conversation entry MUST be assigned exactly one
  placement — transcript row, header field, footer signal, or both row and
  signal — by a single pure classification shared by the live view, the
  Mission Control embed and the saved review.
- **FR-002**: The following MUST be transcript rows: prompt, assistant text,
  thinking, tool call, tool result, injected context text, the start and end
  markers, `task_started`, `task_notification`, `api_retry`, a `hook_response`
  reporting failure, a `result` reporting error, and any entry whose kind or
  sub-kind the classification does not name.
- **FR-003**: The following MUST be footer signals and MUST NOT be rows unless
  "show all frames" is on: `system · status`, `system · thinking_tokens`,
  `system · hook_started`, `system · hook_progress`, a `hook_response`
  reporting success, `system · init`, `tool_progress`, `rate_limit_event`,
  and a `result` reporting success.
- **FR-004**: `task_started`, `task_notification`, a failing `hook_response`,
  `api_retry` and an error `result` MUST be both a row and a footer signal.
- **FR-005**: The start entry's model and the `init` entry's resolved model
  and CLI version MUST be header fields, in addition to the identity fields
  the header already shows.

**Transcript rows**

- **FR-006**: Assistant text MUST render as open prose in the sans family,
  visually distinct from tool traffic, with a faint eyebrow naming it.
- **FR-007**: Prompt, injected context and thinking rows MUST fold to a single
  line by default and expand in place; the folded line MUST show the first
  line of the content.
- **FR-008**: A tool call MUST render as one mono line of the form
  `Tool(summary)`, where the summary is the call's most identifying input:
  the command for `Bash`; the path for `Read`, `Write` and `Edit`; the pattern
  for `Grep` and `Glob`; the skill name for `Skill`; for any other tool, the
  first text-valued input, or the tool name alone. The full input MUST remain
  available by expanding the row.
- **FR-009**: A tool result MUST render inside the block of the call that
  produced it (same `tool_use_id` pairing as today): the call and its result
  form one block, the block is updated in place when the result arrives, and
  blocks keep the calls' order even when results arrive in a different order
  (parallel calls). The result part shows at most 5 lines by default with a
  `+N lines` fold and expands in place to the full output. A call with no
  result yet shows the call line alone (and `unfinished` after the end
  marker). A result whose call is not in view (window truncation, page
  boundary) MUST still render as its own block, with its tool name when known.
- **FR-010**: Marker rows (`task_started`, `task_notification`, `api_retry`,
  failing `hook_response`, error `result`) MUST render as one muted mono line
  naming the sub-kind and its key values (description; status and summary;
  attempt, max, error and delay; hook name and exit code; result subtype),
  with any longer payload folded.
- **FR-011**: The start marker MUST render as a thin divider reading
  `session opened · <model>`; the end marker MUST keep today's outcome chip.
- **FR-012**: Error flags (tool result `is_error`, failing hook, error result)
  MUST render as a visible flag in the text/border roles, not as a status
  colour; status colour MUST appear only on the end marker's chip and the
  footer's outcome/activity dot.
- **FR-013**: Any entry whose kind or sub-kind is not named here MUST render
  as a folded raw row labelled `<kind> · <sub-kind>`; no recorded entry may be
  invisible with "show all frames" on.

**Footer status line**

- **FR-014**: The live view MUST show a status line pinned to the bottom of
  the scrolling area (page or embedded panel) while the conversation scrolls,
  in the mono family, carrying: current activity, turn count, tool-call count,
  open background-task count, elapsed time, rate-limit state when limited, and
  cost and duration once a result has arrived.
- **FR-015**: Activity MUST be derived from recorded entries only, as the most
  recent of: `requesting` (status), `thinking · ~N tok` (thinking tokens),
  `running <tool> · Ns` (an unpaired tool call, elapsed from heartbeats when
  present), `hook · <name>` (an open hook), `responding` (assistant text),
  `done` (result), and the session outcome (end). The outcome, once set, MUST
  NOT be replaced.
- **FR-016**: Turn count MUST be the number of distinct assistant messages
  seen (one per message, not per block); tool-call count MUST be the number
  of tool call entries; open background tasks MUST be started minus notified,
  never below zero.
- **FR-017**: Elapsed MUST be the difference between now and the session's
  recorded start time, redrawn once per second only while the session is
  live, and frozen at the end marker's time once the session has ended. It is
  a clock reading against a recorded start, not progress.
- **FR-018**: The rate-limit indication MUST show only while the latest
  `rate_limit_event` reports a status other than `allowed`, naming the limit
  type and reset time; it MUST clear when a later event reports `allowed`.
- **FR-018a**: On a live join or reconnect, the status line MUST be built by
  reducing the session's whole conversation file, not only the catch-up
  window, so counters and activity are exact for sessions over 500 entries;
  live entries after the join continue the same reduction without double
  counting (entries are applied once, by sequence). The rows still come from
  the catch-up window. The read happens once per join or reconnect and never
  from a listing. If the file cannot be read, the status line MUST be built
  from the window and its counters marked as lower bounds.
- **FR-018b**: The status line MUST be exposed to assistive technology as a
  labelled status region. Only two changes MUST be announced, politely: the
  session's end outcome, and a rate limit coming into effect. Activity,
  counters and elapsed MUST NOT be announced.
- **FR-019**: On the saved review the status line MUST be static and reflect
  the final reduced state of all pages loaded so far.

**Verbose toggle**

- **FR-020**: The live view and the saved review MUST offer a "show all
  frames" toggle, default off, kept in the page address like `follow`. On,
  every entry MUST be a row in recorded order, footer-only entries rendering
  as folded raw rows labelled with kind and sub-kind; the footer MUST keep
  working unchanged.

**Boundaries**

- **FR-021**: This feature MUST NOT change the recorder, the entry kinds, the
  masking, the catch-up window, the conversation file format or its version;
  a file saved before this feature MUST render through the new classification
  without migration.
- **FR-022**: The existing 040 guarantees MUST hold unchanged: pairing of
  results to calls, `unfinished` tagging at the end marker, the 500-entry
  catch-up notice, the follow toggle and its behaviour, the next-session
  link, the Mission Control embed switching in place, and live/review parity.
- **FR-023**: All surfaces MUST comply with the design constitution: tokens
  only, machine values mono and prose sans, status colour by name only, no new
  keyframes, motion only on a live referent, one narrow-screen breakpoint, no
  raw term dumps in markup, and the design-contract guard MUST stay green.
- **FR-024**: The classification, the tool summary and the footer reduction
  MUST each be pure, unit-testable transformations.

### Key Entities

- **Placement**: where an entry shows — `row`, `signal`, `row+signal`, or
  `header+signal` (feeds the header and the status line, not a row) — plus, for rows, a **row class** (`prose`, `context`,
  `thinking`, `call` (a call block, holding its result once paired), `result`
  (a result shown on its own because its call is not in view), `marker`, `divider`, `end` (the outcome-chip end marker), `raw`) and a
  default fold (`open`, `line` — folded to its first line, `preview5` — first
  5 lines plus a `+N lines` fold).
- **Tool summary**: the one-line `Tool(summary)` text derived from a tool
  call's name and input.
- **Session status**: the footer's reduced state — activity and its status
  name, turns, tool calls, open calls, open background tasks, open hooks,
  rate-limit state, cost, duration, started-at, elapsed, outcome, model alias,
  resolved model, CLI version — produced by folding entries in order and
  frozen at the end marker.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across the 91 recorded conversations, the default transcript
  shows at most 35% of the entries as rows (≈1,600 of ≈5,000), and every
  prompt, assistant text, thinking, tool call and tool result is among them.
- **SC-002**: With "show all frames" on, every entry of every recorded
  conversation is visible: block count equals entry count minus the tool
  results shown inside their call's block.
- **SC-003**: Every entry in the census updates the status line or becomes a
  row (or both); none is unaccounted for.
- **SC-004**: For each recorded conversation, the live view's end state and
  the saved review produce identical row sequences and identical final
  status-line values.
- **SC-005**: An operator can locate the first failed tool result in a
  2,000-entry conversation by scrolling the default transcript without
  expanding any row.
- **SC-006**: During a live session the status line reflects a new progress
  signal within 2 seconds of its recording, and the elapsed figure advances
  at one-second resolution while live and stops at the end marker.
- **SC-007**: Tool-call rows for the six observed tools each fit on one line
  at the transcript's measure; no call row shows JSON by default.
- **SC-008**: The design-contract guard passes unchanged in rule count; no new
  colour, radius, font-size or spacing literal, keyframe or breakpoint is
  introduced.

## Assumptions

- The ten entry kinds and the sub-kind fields (`body.subtype` for system
  entries, `body.raw.type` for other entries, `is_error`/`subtype` for
  results, `outcome`/`exit_code` for hook responses) are stable 040 contracts;
  this feature reads them and adds none.
- Per-turn token usage, CLI stderr and subagent attribution are not recorded
  today; the footer therefore shows cost and duration only once the result
  entry arrives, and shows the thinking-token estimate the CLI reports rather
  than a running total. Recording those is a separate follow-up feature.
- `thinking_tokens` reports an estimate for the current thinking block; the
  footer shows the latest reported value.
- A `tool_progress` heartbeat's `elapsed_time_seconds` is the authoritative
  "running for" figure while present; before the first heartbeat the activity
  reads `running <tool>` without a time.
- Rate-limit `status == "allowed"` means no limit in effect; any other status
  is shown.
- The "show all frames" address parameter follows the `follow` precedent and
  is not persisted anywhere else.
- Summary extraction for unknown tools picks the first string-valued input in
  the call's input map; this is a heuristic, not a contract.
- The embedded Mission Control panel keeps its own scroll area, so the status
  line pins to that panel's bottom edge.
