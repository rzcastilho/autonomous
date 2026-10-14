# Feature Specification: Close the Conversation Recorder Gaps

**Feature Branch**: `043-close-recorder-gaps`

**Created**: 2026-10-14

**Status**: Draft

**Input**: User description: "feature 043 recorder gaps" — the follow-up deferred by feature 042: make the conversation record complete where it is not today. Four gaps: (1) per-turn token usage is never recorded, so live tokens and cost are invisible until the session ends; (2) the agent CLI's stderr output is never recorded, so a session that complains or dies leaves no explanation in the conversation; (3) entries produced by a subagent carry no attribution to the call that spawned them; (4) a synthetic error result (the SDK's stand-in when the CLI produced none) is recorded as a success with its error text lost.

## Context

Feature 040 records every frame of every agent session; feature 042 classifies
what was recorded into scroll rows, header fields and a footer status line. 042
was deliberately display-only, and in building it four things surfaced that the
view cannot show because the record never held them:

| gap | what is missing today | what the operator cannot do |
|---|---|---|
| **Usage** | the per-turn token counts the CLI streams while a turn runs are dropped; cost and duration appear only in the final result | see tokens or cost move while a long implement session runs, or tell which turn was expensive |
| **stderr** | the CLI's error-stream lines go to the orchestrator's log and the workspace-trust check, never into the conversation | explain a session that ended early, warned about its workspace, or hit a transient failure — the answer is in a log file elsewhere |
| **Subagent attribution** | assistant and user entries do not say which tool call they belong to | tell main-agent output from output produced inside a subagent the agent launched |
| **Synthetic error results** | when the SDK invents a result because the CLI produced none, it arrives with an empty body; it is recorded as `is_error: false` and the error text is lost | trust the end of a failed session: it reads as a clean finish with no reason |

The fourth gap is a correctness bug, not just a missing field: the record
asserts success for a failure. The other three are omissions. All four are
changes to *what is recorded*, so — unlike 042 — this feature changes the
conversation file's contents (and therefore its format version), and then makes
the two surfaces that read it show the new information.

## Clarifications

### Session 2026-10-14

- Q: Show a running cost estimate while a session is live? → A: No — tokens only while live; cost appears only when the result reports it.
- Q: How is a chatty error stream bounded? → A: Keep the first 1,000 and the last 1,000 lines per session; one notice records how many middle lines were dropped.
- Q: Build subagent attribution display now? → A: Record the parent id only; display (nesting/marking) deferred until subagent tools are enabled.
- Q: What does the live token figure count? → A: Input and output shown separately (`in 12.1k · out 3.1k`); cache tokens excluded from the figure.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A failed session never reads as a success (Priority: P1)

An operator reviews a session that ended because the SDK produced no result of
its own. Today its result entry says the session did not error and carries no
text. After this feature the recorded result says it was an error and keeps the
reason the SDK gave, and both the live view and Transcripts show that reason.

**Why this priority**: it is the only gap where the record is *wrong* rather
than incomplete. Everything downstream — the footer outcome, a reviewer's trust
in a saved conversation — depends on a failed session not looking clean.

**Independent Test**: replay a session whose final frame is a synthetic error
result; confirm the recorded result is flagged as an error, the error text is
present in the saved file, the live and saved views render it as a result-error
marker with that text, and the footer outcome is not "done".

**Acceptance Scenarios**:

1. **Given** a session whose final frame is a synthetic error result with an
   error message, **When** it is recorded, **Then** the result entry is flagged
   as an error and carries the message verbatim (after credential masking).
2. **Given** a genuine successful result, **When** it is recorded, **Then** it
   is flagged as not an error exactly as today (no regression).
3. **Given** a recorded error result, **When** the conversation is shown live or
   from Transcripts, **Then** the marker row shows the error text and the footer
   does not show a clean finish.
4. **Given** a synthetic error result carrying no message at all, **When** it is
   recorded, **Then** it is still flagged as an error and says no reason was
   given, rather than claiming success.

---

### User Story 2 - See why a session complained or died (Priority: P2)

An operator watches a session that starts, warns, then stops. The CLI wrote the
explanation to its error stream. After this feature those lines appear in the
conversation at the point they happened — as quiet one-line rows, with
repeated identical lines collapsed — so the answer sits next to the entries it
explains instead of in a log file.

**Why this priority**: it turns "the session just ended" into a diagnosable
event and is the most frequently useful omission after the correctness bug.

**Independent Test**: replay a session that emits error-stream lines between
frames; confirm each appears in the saved file in order relative to the frames,
shows as a stderr row live and saved, and that a burst of identical lines shows
once with a count.

**Acceptance Scenarios**:

1. **Given** a session whose CLI writes a line to its error stream, **When** the
   line arrives, **Then** it is recorded in order with the surrounding entries
   and shown live as a one-line stderr row.
2. **Given** the same line repeated many times in a row, **When** shown,
   **Then** it appears once with a repeat count, and the full repeats remain in
   the saved file.
3. **Given** a line containing a configured credential value, **When** it is
   recorded, **Then** the value is masked exactly as in every other entry.
4. **Given** the default view, **When** stderr rows are present, **Then** they
   are visible (they are evidence, not heartbeat) and the "show all frames"
   toggle changes nothing about them.
5. **Given** an extremely chatty error stream, **When** it is recorded, **Then**
   the first 1,000 and last 1,000 lines are kept, with one notice saying how
   many lines in between were dropped (see FR-008).

---

### User Story 3 - Watch tokens move while the session runs (Priority: P3)

An operator watching a long implement session sees tokens used so far in the
status line, updating as each turn streams — not a blank until the final
result. Cost is not estimated: it appears only when the result reports it.

**Why this priority**: valuable and visible, but informational only (cost never
stops a run, per feature 039), so it follows the correctness and diagnosability
work.

**Independent Test**: replay a session with streamed usage updates; confirm the
status line's token figure increases across the session before any result
exists, the saved conversation shows the same final figure as the live end
state, and no cost figure appears before the result reports one.

**Acceptance Scenarios**:

1. **Given** a session streaming usage updates, **When** each arrives, **Then**
   the status line's input and output figures reflect the latest totals
   without waiting for the result, and cache tokens do not change them.
2. **Given** a session with no usage updates (older sessions, or none emitted),
   **When** shown, **Then** no token figure appears — never a zero standing in
   for "unknown".
3. **Given** a live session before its result, **When** shown, **Then** no cost
   figure appears; **Given** the result arrives with a reported cost, **Then**
   that cost is displayed.
4. **Given** a saved conversation, **When** reviewed in Transcripts, **Then**
   the token figure equals what the live view showed at the end of the session.

---

### User Story 4 - Keep subagent attribution in the record (Priority: P4)

When a frame says it was produced inside a subagent — by carrying the
identifier of the tool call that launched it — the recorded entry keeps that
identifier. Nothing in the views changes in this feature: the attribution is
there for a later feature (or a reader of the saved file) to use once subagent
tools are enabled.

**Why this priority**: lowest — headless sessions disable the subagent tools
today (see Assumptions), so this only future-proofs the record; it is cheap to
capture while the format is being revised anyway, and display is deferred.

**Independent Test**: replay a session in which some assistant and user frames
carry a parent call identifier; confirm the saved entries keep it and the views
render those entries exactly as they render the same entries without it.

**Acceptance Scenarios**:

1. **Given** frames carrying a parent tool-call identifier, **When** recorded,
   **Then** each entry stores that identifier.
2. **Given** such entries, **When** shown live or from Transcripts, **Then**
   they render exactly as entries without the identifier (no display change).
3. **Given** entries with no parent identifier, **When** recorded, **Then** no
   identifier field is written (absent, never empty).

---

### Edge Cases

- **Older files.** Conversation files written before this feature (format v1)
  must still open, in Transcripts and anywhere else, and show exactly what they
  showed before — no usage figure, no stderr rows. The newest
  files must be recognised by the version marker; a file from a *newer* format
  than the running build is refused by name, as today.
- **Mixed runs.** A run spanning the upgrade has v1 and v2 files side by side;
  Transcripts and Run Detail treat each by its own version.
- **Usage totals vs. increments.** Streamed usage may be cumulative per turn
  rather than per request; the displayed figure must not double count a turn.
- **Stderr during startup failure.** When the session dies before any frame,
  stderr may be the *only* content; it must still be recorded and shown.
- **Stderr tail placement.** Lines past the head are held until the session
  ends, so in a flooded session the tail lines appear after the last frame,
  behind the dropped-lines notice, not interleaved with the frames they
  arrived among; the live view shows them only at the end.
- **Stderr ordering.** Lines and frames arrive on different channels; their
  recorded order is arrival order at the recorder, which may differ slightly
  from wall-clock order. The view must not claim exact interleaving.
- **Stderr after close.** A line the CLI writes after the session's
  conversation is closed is not recorded (the recorder has stopped); it still
  reaches the orchestrator log. Closing never waits for late stderr.
- **Credential masking.** Every new kind of recorded text (error-message text,
  stderr lines) goes through the same masking as existing entries.
- **Recorder never affects the session.** None of the four capture paths may
  delay, fail or change the outcome of the session they observe; a recorder
  fault degrades capture status, never the run (feature 040's guarantee).
- **Entry-count and size limits.** The new entries count toward the
  conversation reference's `entries`/`bytes` totals and the 500-entry live
  window. The conversation file has no size cap of its own; stderr's
  contribution is bounded by the head-and-tail rule (FR-008), so a stderr
  flood adds at most head + tail + 1 entries.
- **Classification completeness.** Every new entry is either a visible row or
  feeds the status line (042's completeness rule); nothing is silently hidden.

## Requirements *(mandatory)*

### Functional Requirements

**Synthetic error results (gap 4)**

- **FR-001**: A result the SDK synthesises because the CLI produced none MUST be
  recorded as an error, never as a success.
- **FR-002**: The recorded result MUST carry the error text the SDK supplied
  (verbatim, after credential masking); when none was supplied it MUST say that
  no reason was given.
- **FR-003**: Genuine results MUST be recorded exactly as before (error flag,
  subtype, cost, duration, turn count).
- **FR-004**: The live view, Transcripts and the footer outcome MUST present a
  recorded error result as an error with its text, not as a clean finish.

**stderr (gap 2)**

- **FR-005**: Lines the agent CLI writes to its error stream during a session
  MUST be recorded in the session's conversation, in arrival order relative to
  the frames, each as its own entry.
- **FR-006**: stderr entries MUST be visible rows in the default view (one line,
  quiet styling), with consecutive identical lines collapsed to one row and a
  repeat count; the saved file keeps every line.
- **FR-007**: stderr text MUST be credential-masked identically to other entries.
- **FR-008**: stderr capture MUST be bounded per session by a head-and-tail
  rule: the first 1,000 lines are recorded as they arrive; once that head is
  full, later lines are held in a rolling tail of the most recent 1,000; when
  the session ends, one notice entry saying how many lines were dropped is
  recorded, followed by the held tail. Both sizes MUST be configurable. A
  session with 2,000 lines or fewer records every line and no notice.
- **FR-009**: Existing consumers of stderr (the orchestrator log and the
  workspace-trust check) MUST keep working unchanged; recording is additive.

**Usage (gap 1)**

- **FR-010**: Per-turn token usage streamed by the CLI MUST be recorded so that
  the totals at any point in the session can be reconstructed from the file.
- **FR-011**: The status line MUST show input and output tokens used so far as
  two figures (`in 12.1k · out 3.1k`; thousands abbreviated to one decimal)
  while the session is live, and the same final figures when reviewed from
  Transcripts. Cache-read and cache-creation tokens are recorded but not part
  of the figure.
- **FR-012**: No cost figure is shown while a session is live; cost is shown
  only when the session's result reports it. No running cost estimate is
  computed or displayed.
- **FR-013**: When no usage was recorded, no token figure is shown (never zero).
- **FR-014**: Usage entries are signals: they feed the status line and appear as
  rows only under "show all frames".

**Subagent attribution (gap 3)**

- **FR-015**: When a frame identifies a parent tool call, the recorded entry
  MUST store that identifier.
- **FR-016**: The views MUST NOT change for entries carrying a parent
  identifier in this feature; displaying attribution is deferred.
- **FR-017**: Entries without a parent identifier MUST be recorded without the
  field and render exactly as before.

**Format and compatibility**

- **FR-018**: The conversation file's format version MUST increase, with every
  addition expressed as new entry kinds or new optional fields; a v1 file MUST
  continue to open and render identically to today.
- **FR-019**: A file written by a newer format than the running build MUST be
  refused by version with a clear message, never partially rendered.
- **FR-020**: Mnesia/store records, capture-status values and the
  conversation reference MUST be unchanged except where an additional field is
  strictly necessary; no store schema bump is expected.

**Cross-cutting**

- **FR-021**: No capture path may block, delay, fail or alter the outcome of the
  session it observes; faults degrade capture status only.
- **FR-022**: Every new entry MUST be classified (visible row or status-line
  signal) so the 042 completeness invariant — nothing silently dropped — holds.
- **FR-023**: Design-constitution rules and the design-contract guard apply to
  all new markup unchanged, with no new guard rules.
- **FR-024**: The runbook MUST document the new rows, the status-line token
  figure, the stderr cap and the format-version behaviour.

### Key Entities

- **Result entry (revised)**: the session's final result; gains a reliable error
  flag and the error text for synthetic results.
- **stderr entry (new kind)**: one CLI error-stream line (or the single
  "N lines dropped" notice), credential-masked; head lines in arrival order,
  held tail lines at session end.
- **Usage entry (new kind)**: a streamed per-turn token-usage observation
  (input, output, cache-read, cache-creation as reported); a signal feeding
  the status line's input/output figures.
- **Parent link (new optional field)**: on assistant/user entries, the
  identifier of the tool call that spawned the producing subagent.
- **Conversation file (format v2)**: v1 plus the above; readers accept v1 and
  v2, refuse anything newer.
- **Session status (extended)**: gains input-tokens and output-tokens so far;
  cost still comes only from the result.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a replay of every session whose result was synthetic, 100% are
  recorded as errors with their reason (or "no reason given"); 0 read as clean.
- **SC-002**: For sessions with a recorded error-stream line, 100% of the lines
  that reach the recorder before the session's conversation is closed are
  findable in the conversation view without opening a log file; lines written
  after close remain only in the orchestrator log.
- **SC-003**: During a live session that streams usage, the status line's token
  figure changes within 2 seconds of each usage update.
- **SC-004**: Every v1 conversation file recorded so far (91 in the 2026-10-13
  census) opens and renders with output identical to before the change.
- **SC-005**: For any recorded session, the token figure and outcome shown live
  at the end equal those shown from Transcripts afterwards.
- **SC-006**: A session whose error stream emits 100,000 lines produces a
  conversation with exactly 2,000 stderr line entries (first 1,000, last 1,000)
  and one notice reporting 98,000 dropped, and the session's duration and
  outcome are unchanged.
- **SC-007**: Across the new entries, the 042 invariant holds: every entry is
  either a visible row or reflected in the status line (0 silently dropped).
- **SC-008**: Design-contract guard passes with its rule count unchanged.

## Assumptions

- **Display is in scope.** The four gaps are only worth closing if the views
  show the result; this feature therefore includes the minimal display (error
  text on the result marker, stderr rows, a token figure); subagent attribution
  is recorded only, its display deferred. It
  does not redesign the views — 042's classification, density and tokens stand.
- **Format change, not store change.** The file moves to a new version; the
  stored reference and capture statuses are untouched (FR-020). Readers stay
  backward compatible; there is no migration of old files.
- **Usage is cumulative per turn.** The CLI reports running totals within a
  turn; the figure shown is the latest total summed across turns, never a sum
  of repeated cumulative values. Where a field is absent it contributes nothing.
- **No cost estimate.** Live tokens are exact; a token-derived dollar figure
  would not be (cache reads, model mix), so the only cost shown is the
  result's reported cost (feature 039: cost is informational).
- **Subagents are rare today.** Headless sessions disable the agent/task tools,
  so attribution will usually be empty in practice. It is recorded when
  present, closing the record gap before the tools are ever enabled; its
  display waits for real attributed data (no census evidence exists yet).
- **stderr volume is usually small**, with occasional floods (retry storms,
  repeated warnings); the 1,000 + 1,000 head-and-tail bound is a generous
  limit, not a target.
- **Existing guarantees stand.** Masking (040), the 500-entry live window, the
  recorder-never-blocks rule, drain-don't-kill and the container boundary are
  unchanged and inherited.
- **Out of scope.** Changing which frames the CLI emits, enabling subagent
  tools, displaying subagent attribution, charging or limiting by cost, exporting stderr outside the
  conversation, and retroactively enriching v1 files.
