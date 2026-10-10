# Research: Live and Durable Agent Conversation View

**Feature**: 040-live-agent-conversation | **Date**: 2026-10-10

Inputs: a sweep of every session-starting site (`RunFeaturePhase`,
`ChunkRunner`→`RunFeaturePhase`, `RunRemediation`, `RunAutoRemediation`,
`Describe`, legacy `Actions.RunPhase`), `PhaseSession`/`PhaseResult`, the
pinned `jido_claude` mapper and `ClaudeAgentSDK.Message`, `Autonomous.SdkProxy`,
the Mnesia store (schema v7, `Writer`, `Query`, `Export`), `Layout`, the
console (router, `ConsoleProjection`, `TranscriptsLive`, `RunDetailLive`,
`TranscriptMarkup`, `design_contract.ex`), and the three spec clarifications
of 2026-10-10. Each decision names the alternative it rejected.

---

## R1 — Where to tap the conversation

**Decision**: Tap at **`Autonomous.SdkProxy`**, the `:jido_claude, :sdk_module`
seam (`config/config.exs:65`). `SdkProxy.query/2` and `resume/3` wrap the
inner SDK's `%ClaudeAgentSDK.Message{}` stream with a `Stream.each/2` that
`send/2`s every frame to the session's conversation recorder (R3). The
recorder pid travels in the request env under a new marker
`AUTONOMOUS_CONVERSATION`, stripped by `SdkProxy.prepare/1` exactly as the 036
stderr-collector marker is, so the CLI never sees it (FR-026).

**Rationale**:
- Every session — all phases, chunks, both remediation kinds, `run_spec/2`
  (which is an ordinary `FeatureRunner` run) and **the PR describe session**,
  which bypasses `PhaseSession` — reaches the CLI through
  `Jido.Harness.run_request(:claude, …)` → adapter → `sdk_module`. One tap
  point therefore covers FR-001 regardless of which fold path the result takes
  (FR-002) without changing `Describe`'s behaviour.
- The tap sees **pre-mapper** frames. The pinned mapper
  (`deps/jido_claude/lib/jido_claude/mapper.ex`) is lossy: user frames with
  only text blocks map to `[]`, `message_start`/`message_delta` map to `[]`,
  and one assistant message with N blocks becomes N events sharing one `raw`.
  Below the mapper there is nothing to dedupe and nothing dropped (FR-013).
- `send/2` to a pid never blocks and never raises, even when the pid is dead
  (FR-005). The tap does no masking, encoding or I/O.

**Alternatives considered**:
- *Tap `Jido.Harness.Event`s in `PhaseSession.announce_events/2`*: misses
  `Describe` (FR-002), sees the lossy post-mapper stream, and needs raw-dedupe
  logic (same `raw` on N events) plus a separate rule to tell assistant text
  blocks from `stream_event` deltas (both map to `:output_text_delta`).
- *Route `Describe` through `PhaseSession.reduce/2`*: gives describe a deadline
  it does not have today — a behaviour change this feature does not ask for.

## R2 — Source of the saved conversation (refines the spec's "Source of truth" assumption)

**Decision**: The saved conversation is written by the orchestrator from the
**same raw CLI frames it receives on the stream**, appended to the file as
each frame arrives. The CLI's own `~/.claude/projects/*/<session>.jsonl` is
**not** read.

**Rationale**: The stream-json frames the SDK decodes *are* the CLI's own
message records (`Message.raw` is the decoded JSON frame,
`claude_agent_sdk/message.ex`), so tapping below the mapper (R1) captures
everything the CLI log would contain for the conversation — prompt, every
assistant message (text, thinking, tool_use), every user/tool_result frame,
system frames, and the result frame. Reading the CLI log instead would:
- encode a guess about a fast-moving external contract (the
  `projects/<encoded-cwd>/` layout and `$CLAUDE_CONFIG_DIR`) in core code
  (Principle I);
- need a second normalizer, and make SC-006 (live vs saved, zero duplicates
  or gaps at the seam) a cross-source comparison instead of a property that
  holds by construction (same `seq` numbers in both);
- lose the whole conversation when the CLI dies before writing, or when
  `--with-login` is off (the container's `~/.claude` is not mounted).
Appending as frames arrive also keeps a partial file on disk if the BEAM
itself dies mid-session.

The spec's assumption ("the CLI's own session log is the source for the
complete saved conversation") is satisfied in substance — the saved content is
the CLI's own records — while the "session log not found" edge case maps to
"no frame ever arrived / the file could not be written", which is recorded as
`:not_captured` (or `:partial`) with a reason (R6). The clarify step should
confirm this reading; no FR changes.

**Alternatives considered**: *Copy the CLI log at session end, stream file as
fallback*: two sources, two formats, two failure modes; rejected for the
reasons above.

## R3 — Recorder process model

**Decision**: One **`Autonomous.ConversationRecorder`** `GenServer` per
session, `restart: :temporary`, started under a new
`{DynamicSupervisor, name: Autonomous.ConversationSup}` and registered in a
new `{Registry, keys: :unique, name: Autonomous.ConversationRegistry}` under
its `conversation_id`, with the session identity as the registry value. The
recorder owns: the open file, the `seq` counter, the bounded catch-up window,
masking, and the PubSub broadcast. It is a thin shell over pure modules
(`ConversationEntry`, `CredentialMask`, `ConversationWindow`).

Lifecycle, driven by the session-driving site (never by the session):
`Conversation.open/2` (before `run_request`) → frames via the tap →
`Conversation.close/2` (after the fold returns, any outcome) → recorder writes
the end entry, closes the file, deregisters, broadcasts `:ended`, stops.

**Rationale**: per-session processes keep overlapping sessions (a finishing
session and the next starting) fully separate (edge case), confine a crash to
one conversation, and mean a dead recorder costs the session nothing (sends to
a dead pid are dropped). A slow recorder only grows its own mailbox; the
session is never awaited (FR-005). Not linked to the fold Task, so the 034
session-death path and the deadline `cut/2` are untouched.

**Alternatives considered**:
- *One global `LiveSessions` GenServer*: one slow file write delays every
  session's live view; one crash loses every in-flight window.
- *Publish straight to PubSub from the tap*: PubSub dispatch runs in the
  caller (the fold Task) and the catch-up window would still need an owner;
  masking would also move into the session's process.

## R4 — Live delivery, catch-up and the seam

**Decision**: Topic `"conversation:" <> conversation_id` on
`Autonomous.PubSub`. A viewer (1) subscribes, (2) calls
`Conversation.catch_up(id)` (exit-safe `GenServer.call`, 1 s timeout) which
returns `{window_entries, last_seq, truncated?}`, (3) renders the window and
then applies only broadcast entries with `seq > last_seq`. Because the
recorder assigns `seq`, appends to the window and broadcasts in one callback,
and serves `catch_up` from the same mailbox, the seam has no gap and no
duplicate (FR-007, SC-006). Reconnect = remount = the same three steps.
Window: last 500 entries (`ConversationWindow`, pure, `:queue`-based),
released when the recorder stops (FR-008). `truncated?` drives the
"earlier entries are in the full conversation once the session ends" notice
(US3-2).

A `catch_up` timeout or a dead recorder is not an error to the viewer: the
view says the session is not reachable live and links the saved conversation
(FR-010 spirit — the live view never blocks; it never calls the Coordinator
at all, and run-state chrome uses the existing 038 `ConsoleProjection.last_known/1`).

**Alternatives considered**: *ETS window read directly by viewers*: avoids a
call but reintroduces a seam race between the ETS read and the subscription.

## R5 — Entry model and frame normalization

**Decision**: Pure `Autonomous.ConversationEntry.from_frame/1` maps one raw
CLI frame to zero or more entries of kinds `:start`, `:prompt`,
`:assistant_text`, `:thinking`, `:tool_call`, `:tool_result`, `:system`,
`:result`, `:other`, `:end`. `stream_event` frames (partial-message deltas)
produce **no entry**: their content arrives again, complete, in the assistant
frame. Anything unrecognized becomes `:other` carrying the masked raw map, so
nothing is dropped (FR-013). `:start` (identity) and `:prompt` are written by
`open/2`; `:end` (outcome) by `close/2`.

The **saved file holds full entries**; display truncation happens only in
`ConversationRows` (R8), so the stored entry is never altered (FR-011).

## R6 — Capture status and the phase-attempt record (schema v8)

**Decision**: `speckit_phase_attempt` gains one field, **`conversations`**: a
list of conversation refs, one per session the attempt drove, in order (a
session-died retry inside `PhaseStep`/`SessionRetry` yields two; the
`:implement` roll-up row yields `[]` — its chunks have their own
`:implement_chunk` rows). Each ref records `conversation_id`, relative `path`,
`status` (`:captured | :partial | :not_captured`), `reason`, `session_id`,
`entries`, `bytes`, `outcome`.

Migration v8 appends the field with value **`nil`** to every existing row
(`transform_table` + frozen `@phase_attempt_v8_attributes`, the v7 pattern).
`nil` means *pre-040, never recorded*; `[]` means *recorded, no session*.
That keeps US2-3 ("no full conversation was recorded for this attempt") apart
from FR-017 ("capture failed, here is why") with no inference.

Status rules (pure `ConversationOutcome.capture_status/1`):
- `:captured` — file closed cleanly with its `:end` entry;
- `:partial` — file exists but the recorder died or `close/2` timed out
  before the `:end` entry was written; the reason names which;
- `:not_captured` — no file (open failed: mkdir/permission/disk), reason
  carries the `File` error.
None of these changes the session outcome or feature status (FR-017); each is
logged once at `:warning` when not `:captured`.

**Alternatives considered**: *A row per retried session*: changes attempt
numbering and `Run Detail` grouping that 017/018 rely on. *A separate
`speckit_conversation` table*: another table to migrate, prune and export for
data that is 1:1 with attempts.

## R7 — File location, format, permissions

**Decision**:
`<transcript_root>/conversations/<run_id>/<feature_id>/<conversation_id>.jsonl`
— `transcript_root` is already per repository, under the machine-global root
(`~/.autonomous`, same-path mounted in the container, so it survives rebuild —
FR-014), and nothing writes there today. `conversation_id` =
`"<phase>-<ordinal>-<stamp>"`, `stamp` = base-36
`System.os_time(:microsecond)` made unique with
`System.unique_integer([:positive, :monotonic])`, so concurrent and retried
sessions never collide and opening a conversation never needs a store
transaction (a store outage must not reach the session path). `File.open/2`
with `[:exclusive]` makes a collision a loud `:eexist`, never an overwrite. Format:
JSON Lines, first line a header `{"format":"speckit.conversation","version":1,…identity}`,
then one entry per line. Directories created `0700`, file opened `0600`
(`File.open/2` then `File.chmod/2` before the first write), so FR-025 holds
from byte one. The ref stores the path **relative** to `transcript_root`;
resolving it is `ConversationFile.resolve/2`.

A recorded file later missing or unreadable renders as **missing at
`<path>`** (FR-015, US2-4), never as "no conversation".

Run export (`Store.Export`) gains per-attempt conversation *status* only
(status, reason, entries, bytes) — no path, no content — honouring the export's
no-side-files / no-local-paths rule (`export.ex:3-9`). Prune
(`Writer.prune…`, `writer.ex:1050`) deletes the conversation files of the
attempts it deletes, after its transaction commits.

## R8 — Display rows, truncation, expand

**Decision**: Pure `Autonomous.Web.ConversationRows.rows/2` turns entries into
display rows for both the live view and the review view (FR-023): one row per
entry, tool results paired to their call by `tool_use_id`, a tool call with no
result at `:end` marked `unfinished` (deadline edge case), long text cut to the
first 40 lines / 4,000 characters with `omitted: %{lines:, chars:}` (FR-011).
Expand is a server event (`phx-click="expand"`, `phx-value-seq`) that fetches
the full entry (live: `Conversation.entry/2` from the window, else the file;
saved: `ConversationFile.entry/2`) and `stream_insert`s the untruncated row.
Rows use LiveView **streams** (`stream/3`, `phx-update="stream"`) so neither
a multi-megabyte conversation nor a long live tail is held in assigns. The
review view loads entries in pages of 500 with a "load next 500" control.

**Alternatives considered**: `<details>` with the full body in the DOM —
ships megabytes of hidden markup; rejected for very large tool output.

## R9 — Credential masking

**Decision**: Pure `Autonomous.CredentialMask`: the single owned list
`~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GH_TOKEN GITHUB_TOKEN)`
(the SDK's credential passthrough vars, `claude_agent_sdk/config/env.ex:115`,
plus the publish tokens the container entrypoint and smoke script use).
`pairs/1` reads values at the edge (`System.get_env/1`) once per recorder,
dropping values shorter than 8 characters; `mask/2` replaces every exact
occurrence, longest value first, with `[masked:NAME]`, recursively over every
string in an entry (keys and values). Applied by the recorder before the
window, the broadcast and the file — never on the request, so the agent is
unaffected (FR-024, FR-026).

## R10 — Identity threading

**Decision**: `FeatureRunner` (the only place holding `run_key`) builds a
`ConversationIdentity` (`run_id`, `feature_id`, `phase`, `ordinal`,
`kind ∈ :phase | :implement_chunk | :auto_remediation | :remediation | :describe`,
`chunk`/`attempt` when present) and passes it in the signal data of every
`"phase.run"` / `"remediation.run"` / auto-remediation signal and to
`Describe.run/4`. The action calls `Conversation.open/2` with it and the
request; refs come back in the action's state update as
`conversations: [ref]`, accumulated by `PhaseStep` across its retry, and
`record_attempt/9` / `ChunkRunner.record_chunk_attempt` /
`AnalyzeRunner` write them on the row — so the file is closed **before** the
attempt is recorded (FR-012). A site given no identity (only possible from
tests / `Actions.RunPhase`) opens nothing; the FR-003 guard (R12) proves no
production path does that.

## R11 — `:describe` attempt row

**Decision**: `FeatureRunner.commit_message_and_pr` records a
`:describe` phase-attempt (ordinal 1, `label: "describe"`, outcome from the
`PhaseResult`, `session_id`, duration, `conversations`) through the same
no-cost-entry path the `:implement_chunk` rows use — `cost_usd` on the row
for display, **no** `speckit_cost_entry`, so run spend is unchanged
(FR-002a). Describe stays non-blocking: any failure still falls back to the
default commit message and never changes status. `Run Detail` and Transcripts
list it like any other attempt. `model_for_record(:describe, …)` reads
`Config.model_for(:describe)` (already routed — `PhaseRequest.build/3` uses it).

## R12 — FR-003 coverage guard

**Decision**: Two tests.
1. **Source guard** (`conversation_coverage_test.exs`): scans `lib/**/*.ex`
   for `Jido.Harness.run_request` / `Jido.Harness.run`; every hit must be in an
   explicit allowlist of session sites, and each allowlisted site must also
   reference `Conversation.open`. A new site fails the suite until it opens a
   conversation.
2. **Behavioural**: with `:sdk_proxy_inner` set to a fake SDK that emits a
   scripted frame stream and asserts the `AUTONOMOUS_CONVERSATION` marker is
   present, drive each session kind (phase, implement chunk, auto-remediation,
   remediation, describe) and assert a closed, `:captured` file plus a ref on
   the recorded attempt. The fake SDK fails the test on a missing marker.
`Actions.RunPhase` (no production caller) is deleted rather than allowlisted.

## R13 — Constitution amendment

**Decision**: 7.0.0 → **7.1.0 (MINOR — materially expanded section)**.
Technology Stack → Persistence gains: *the full-conversation file under the
repository's transcript root is the one permitted durable artifact outside
Mnesia; Mnesia remains authoritative for whether one was captured and where;
the file is owner-only, never inside a target working tree, never loaded by a
listing, and a recorded-but-missing file is reported as missing.* No MUST is
removed, so not MAJOR. Ships with the feature (FR-015), Sync Impact Report
prepended.

## R14 — Console surfaces and design contract

**Decision**: New `Autonomous.Web.ConversationLive` at `/live` (follows the
repository's in-flight session: `Conversation.in_flight/1` via a Registry
select, newest first) and `/live/:conversation_id` (pinned). Mission Control's
in-flight feature card and Run Detail's in-flight row gain a `live session`
link (SC-001: one click). On `:ended` the view shows the end marker and, if
another session is now in flight, a link to it (US1-5); with none in flight it
states so plainly (US1-6). Transcripts gains a conversation pane per attempt
(per session when a retry produced two — FR-020), falling back to the
existing `TranscriptMarkup` final text with the reason (FR-019).
`design_contract.ex` `@surfaces` gains the new LiveView, component and
`ConversationRows`; the only motion is the existing `scBlink` live dot on
selectors containing `live`, listed in the reduced-motion block. Machine
values (tool names, inputs, outputs, ids, outcome terms) in mono; assistant
prose in sans via `TranscriptMarkup`.

## R15 — Testing

Default suite hermetic: recorder, window, masking, rows, outcome and entry
modules unit-tested pure; recorder + file tests under `tmp_dir`; LiveView
tests with `Phoenix.LiveViewTest` publishing synthetic frames; the migration
tested from a v7 fixture table. SC-004 (wall time ±1%) is checked by a test
that runs the fake SDK with zero, one and a never-reading viewer (a subscriber
process that never receives) and compares outcome and `duration_ms`; the live
container check is a quickstart step, not a suite test.
