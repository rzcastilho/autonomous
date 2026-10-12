# Feature Specification: Live and Durable Agent Conversation View

**Feature Branch**: `040-live-agent-conversation`

**Created**: 2026-10-10

**Status**: Draft

**Input**: User description: "Live and durable agent conversation view. The operator can watch any running agent session's conversation live in the console and review the full conversation of any past session. Scope is EVERY agent session the orchestrator starts: all pipeline phases (specify, clarify including the reviewer and interactive-clarify answer rounds, plan, tasks, analyze, each implement chunk, converge), analyze auto-remediation, operator remediation, generic single-phase runs, and the PR describe session. … LIVE: each session publishes each stream event as it arrives; publishing is fire-and-forget and can never delay, block or fail the session or its deadline. A console Live session view, reachable from Mission Control and Run Detail for the in-flight attempt, appends events as they arrive; a viewer joining mid-session first sees the events so far, then the live tail; long tool output is truncated with an expand affordance. DURABLE: at the end of every session, on every outcome, the full conversation is saved and its location recorded on the phase-attempt record; the Transcripts page renders it, falling back to today's final text when none exists. Motivation: debugging feature 005's converge deadline on mod-player, the console transcript showed only '[orchestrator] session cut at its 50 min deadline' and the real conversation had to be dug out of the container by hand."

## Context

Today the console records one thing per agent session: the session's final
text. When a session ends badly — cut at its deadline, died at startup,
drained — that final text is a one-line orchestrator note, and the
conversation that explains *why* exists only in the agent CLI's own session
log inside the container's home directory. That directory is not mounted
from the host, so it disappears when the container is rebuilt, and reading it
requires shelling into the container, finding the session id, and parsing raw
event records by hand. This was the only way to learn that feature 005's
converge session spent 32 minutes on a cold build, failed to link, and then
waited on a backgrounded command until its deadline.

The operator needs to (a) see what an agent is doing *while* it is doing it,
and (b) read the full conversation of any finished session from the console,
for every agent session the orchestrator starts — not just one phase.

## Clarifications

### Session 2026-10-10

- Q: Where does the saved conversation live? → A: A file under `Layout.transcript_root`; Mnesia records its location and captured / not-captured status (constitution amendment ships with the feature).
- Q: The PR describe session records no phase-attempt row today; where does its conversation attach? → A: Record each describe session as a `:describe` phase-attempt row; it stays non-blocking.
- Q: How are secrets in agent output handled? → A: Mask exact values of known credential env vars (Claude auth, `GH_TOKEN`, …) in live and saved output; saved files readable by owner only.
- Q (operator review, after the container quickstart): Should the live view keep following the run into its next sessions, and where does it live on Mission Control? → A: A `follow next sessions` toggle on the live view (off by default on `/live`, `?follow=1` turns it on; on by default in Mission Control). On, the end of the shown session moves the view to the next in-flight session. Mission Control embeds the live view below the running feature's table.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch a running agent session live (Priority: P1)

An operator has a run in flight. From Mission Control (or the run's Run
Detail page) they open the live view of the session currently running —
whatever it is: a pipeline phase, an implement chunk, a remediation attempt,
or the PR describe session. They see the conversation so far (assistant
messages, each tool call with its input, each tool result), and new entries
appear as the agent produces them, without reloading. When the session ends,
the view says how it ended (completed, error, deadline cut, session died,
drained).

**Why this priority**: This is the capability that would have turned the 005
post-mortem into a glance: the operator would have seen the cold build, the
link failure and the wait loop as they happened, and could have intervened
long before the 50-minute deadline.

**Independent Test**: Start a run against a fixture target, open the live view
for the in-flight session, and confirm that entries appear in arrival order
while the session runs and that an end-of-session marker appears when it
finishes — with no other part of this feature present.

**Acceptance Scenarios**:

1. **Given** a session is running, **When** the operator opens its live view,
   **Then** they see every conversation entry produced so far, in order,
   followed by new entries as they are produced.
2. **Given** the operator is viewing a live session, **When** the agent makes a
   tool call and receives its result, **Then** the call (tool name and input)
   and the result appear as separate entries within a few seconds of each
   happening.
3. **Given** a tool result is very long, **When** it is shown, **Then** it is
   truncated with a visible indication of how much was omitted and an
   affordance to expand it in place.
4. **Given** the session ends for any reason, **When** the operator is
   watching, **Then** the view shows an end marker naming the outcome
   (e.g. `:deadline_exceeded`, `{:session_died, …}`) and stops expecting new
   entries.
5. **Given** a run moves from one session to the next (e.g. implement chunk 3
   ends and chunk 4 starts), **When** the operator is on Mission Control,
   **Then** the entry point leads to the session that is in flight now.
7. **Given** the operator has turned `follow next sessions` on, **When** the
   shown session ends and the run opens its next session, **Then** the view
   moves to that session on its own; with the toggle off it stays on the end
   marker and offers a `next session` link instead.
8. **Given** a run is in flight, **When** the operator is on Mission Control,
   **Then** the live session is shown below the running feature without
   navigating away, following the run's sessions by default.
6. **Given** no session is in flight, **When** the operator looks for the live
   view, **Then** the console says so plainly rather than showing an empty or
   stale stream.

---

### User Story 2 - Review the full conversation of a finished session (Priority: P2)

After a session has ended — including one that was cut at its deadline, died,
or was drained — the operator opens it from the Transcripts page (or from the
phase row in Run Detail) and reads the whole conversation: the prompt the
orchestrator sent, every assistant message, every tool call and result, and
the final result. This remains available after the container is restarted or
rebuilt.

**Why this priority**: Post-mortems of failed or parked features are the
operator's most common debugging task; today they require shell access to the
container and are impossible once it has been rebuilt.

**Independent Test**: Run a phase to completion and another that is cut at a
short deadline, rebuild the container, and confirm both conversations are
readable in full from the Transcripts page.

**Acceptance Scenarios**:

1. **Given** a session has ended with any outcome, **When** the operator
   opens it on the Transcripts page, **Then** the full conversation is shown
   as the same entry timeline the live view uses, ending with the outcome.
2. **Given** the container has been rebuilt since the session ran, **When** the
   operator opens the session, **Then** the full conversation is still
   available.
3. **Given** a session recorded before this feature existed (no saved
   conversation), **When** the operator opens it, **Then** today's final-text
   transcript is shown, with a note that no full conversation was recorded for
   this attempt.
4. **Given** a saved conversation cannot be read (missing or unreadable),
   **When** the operator opens the session, **Then** the console says so,
   naming the expected location, and still shows the final-text transcript.
5. **Given** a session ran with a retry (e.g. session-died retried once),
   **When** the operator reviews the phase, **Then** each attempt's
   conversation is reviewable separately.

---

### User Story 3 - Join a long session mid-way without losing context (Priority: P3)

The operator opens the live view of a session that has already been running
for a long time (e.g. 40 minutes into an implement chunk). They first see the
conversation so far, then the live tail continues seamlessly, with no
duplicated or missing entries at the seam.

**Why this priority**: Operators rarely open a view at the exact moment a
session starts; without catch-up the live view is only useful for the first
few seconds of a session.

**Independent Test**: Start a session that produces entries steadily, open
the live view part-way through, and compare the entries shown against the
session's saved conversation: same entries, same order, no gaps or
duplicates.

**Acceptance Scenarios**:

1. **Given** a session has produced entries before the operator joins, **When**
   they open the live view, **Then** the earlier entries are shown first,
   then new ones, with no gap and no duplicate at the boundary.
2. **Given** the session has produced more entries than the catch-up window
   holds, **When** the operator joins, **Then** the view shows the most recent
   window and states that earlier entries are available in the full
   conversation once the session ends.
3. **Given** the operator's connection drops and reconnects, **When** the view
   reconnects, **Then** it resumes from where it left off without duplicating
   entries.

---

### Edge Cases

- **Session dies at startup** (no events, or only an error): the live view and
  the saved conversation both show the start, the failure, and the outcome;
  no empty pane.
- **Deadline cut mid-tool-call**: the last tool call is shown without a
  result and is marked as unfinished; the end marker names the deadline.
- **No viewer connected**: sessions run exactly as they do today; nothing is
  buffered beyond the bounded catch-up window.
- **Slow or stalled viewer**: a viewer that cannot keep up never slows the
  session; it may miss live entries but recovers them from the catch-up
  window or the saved conversation.
- **Console restarted mid-session** (feature 038 rebuild): reopening the live
  view still shows the in-flight session's catch-up window if the session is
  still running.
- **Supersession drain**: a drained session's conversation is saved like any
  other, with the drain as its outcome.
- **Two sessions overlap briefly** (a finishing session and the next one
  starting): each has its own live view and saved conversation; entries never
  cross between them.
- **Very large conversation** (hundreds of tool calls, multi-megabyte tool
  output): saving never truncates or drops recorded content; the view stays
  responsive by truncating long entries in display only.
- **Session log not found at session end** (e.g. the agent CLI never wrote
  one): the attempt records that no full conversation was captured and why;
  the session's own outcome is unaffected.
- **Sensitive content in tool output** (environment variables, tokens printed
  by a command): exact values of known orchestrator credentials are masked
  in both the live view and the saved file (FR-024); other secrets a command
  prints are not detected, and the saved file is owner-only (FR-025).

## Requirements *(mandatory)*

### Functional Requirements

**Coverage**

- **FR-001**: Every agent session the orchestrator starts MUST be observable
  live and saved durably: every pipeline phase (specify, clarify — including
  the reviewer and interactive-clarify answer rounds — plan, tasks, analyze,
  each implement chunk, converge), every analyze auto-remediation attempt,
  every operator remediation, every generic single-phase run, and every PR
  describe session.
- **FR-002**: Coverage MUST NOT depend on which internal path a session's
  result is folded through; a session that bypasses the deadline-owning
  session wrapper (the PR describe session does today) MUST be covered the
  same as one that does not.
- **FR-002a**: Each PR describe session MUST be recorded as its own `:describe`
  phase-attempt record (outcome, duration, agent session id, conversation
  location), visible in Run Detail like any other attempt. Describe stays
  non-blocking: a failed, empty or unparseable describe still falls back to
  the default commit message and never changes the feature's status. Run spend
  accounting for describe is unchanged by this feature.
- **FR-003**: The test suite MUST fail if any code path that starts an agent
  session does not publish and save its conversation.

**Live**

- **FR-004**: Each session MUST publish each conversation entry as it is
  received from the agent: session start (with the attempt identity), the
  prompt sent, assistant text, tool call (tool name, input), tool result
  (output, error flag), and session end (outcome).
- **FR-005**: Publishing MUST be fire-and-forget: it MUST NOT delay, block,
  fail, or change the outcome of the session, and MUST NOT interfere with the
  session's deadline, its drain checks, or its retry decisions — with no
  viewer, a slow viewer, or a failing publish path.
- **FR-006**: The console MUST provide a live session view, reachable from
  Mission Control and from Run Detail for whichever session is in flight, that
  appends entries as they arrive without a page reload.
- **FR-007**: A viewer joining mid-session MUST first receive the session's
  recent entries from a bounded per-session catch-up window, then the live
  tail, with no gap and no duplicate at the seam.
- **FR-008**: The catch-up window MUST be bounded (default: the most recent
  500 entries per in-flight session) and MUST be released when the session
  ends; it is never the durable record.
- **FR-009**: The live view MUST show the session's identity using the
  system's own identifiers (run id, feature number, phase atom, attempt
  number) and the session's outcome when it ends.
- **FR-010**: The live view MUST never block on the run controller; if run
  state cannot be read, the view keeps streaming what it has and shows the
  existing delayed-status indication (feature 038 behaviour).
- **FR-011**: Long entries MUST be truncated in display only (default: first
  40 lines / 4,000 characters), showing how much was omitted and offering an
  in-place expand; the underlying entry is never altered.

**Durable**

- **FR-012**: When a session ends — on every outcome: completed, error,
  exhausted, deadline cut, session died, drained, retried — its full
  conversation MUST be saved before the attempt is recorded as finished.
- **FR-013**: The saved conversation MUST be complete: every entry the agent
  produced, untruncated, in order, including the orchestrator's prompt and the
  final result. The only alteration permitted is the credential masking of
  FR-024.
- **FR-014**: The saved conversation MUST survive container restart and
  rebuild, and MUST live under the orchestrator's machine-global root, never
  inside a target repository's working tree.
- **FR-015**: The saved conversation MUST be a file under the orchestrator's
  existing per-repository transcript root (`Layout.transcript_root`), one file
  per session attempt, never stored in Mnesia. Mnesia stays authoritative for
  *whether* a conversation was captured: the attempt's record holds the file's
  location and a captured / not-captured status (with reason). This requires
  a constitution amendment (Technology Stack → Persistence) naming the
  full-conversation file as the one permitted durable artifact outside Mnesia;
  the amendment ships with this feature. A recorded file that is later
  missing MUST be reported as missing, never silently treated as "no
  conversation".
- **FR-016**: Each phase-attempt record MUST record whether a full
  conversation was saved, and where; records written before this feature MUST
  continue to load and render unchanged (versioned schema migration; no
  existing record dropped or rewritten lossily).
- **FR-017**: A failure to capture or save the conversation MUST NOT change
  the session's outcome or the feature's status; it MUST be recorded on the
  attempt (with a reason) and logged, and the console MUST show it.

**Credential masking**

- **FR-024**: Before any entry is published live or written to a saved
  conversation, every exact occurrence of the value of a known credential the
  orchestrator handles (the Claude CLI authentication values and `GH_TOKEN`,
  plus any other credential env var the orchestrator passes to sessions) MUST
  be replaced by a fixed marker naming the variable (e.g. `[masked:GH_TOKEN]`).
  The masked set is a single, explicit list owned by the orchestrator. Empty
  or very short values (fewer than 8 characters) are not masked, to avoid
  corrupting unrelated text. Pattern-based or heuristic masking is out of scope.
- **FR-025**: Saved conversation files (and directories the feature creates
  for them) MUST be readable and writable by the owning operator account only.
- **FR-026**: Masking MUST NOT change what the agent itself sees or does; it
  applies only to what the orchestrator publishes and saves.

**Review**

- **FR-018**: The Transcripts page and Run Detail phase rows MUST open the full
  conversation of any attempt that has one, rendered as the same entry
  timeline the live view uses.
- **FR-019**: When an attempt has no saved conversation (pre-feature records,
  or capture failed), the console MUST fall back to the existing final-text
  transcript and say why no full conversation is available.
- **FR-020**: Each attempt of a retried phase (session-died retry, artifact
  retry, chunk re-runs) MUST be reviewable separately.
- **FR-021**: Viewing a full conversation MUST NOT load other attempts'
  conversations; history and summary listings MUST NOT load conversation
  content.

**Presentation constraints**

- **FR-022**: All new console surfaces MUST comply with the design
  constitution: tokens only, machine values (tool names, inputs, outputs,
  identifiers) in mono and prose in sans, status color only for outcome,
  motion only on the live tail, no raw term dumps in markup, and the existing
  design-contract guard MUST stay green.
- **FR-023**: Turning conversation entries into display rows MUST be a pure,
  unit-testable transformation shared by the live view and the review view.
- **FR-027**: The live view MUST offer a follow mode, labelled `follow next
  sessions`. Follow means following the conversation: on, the view MUST keep
  scrolled to the newest entry of the current session as entries arrive
  (pausing while the operator has scrolled up), and when that session ends it
  MUST move to the next in-flight session (at once if one is open, else when
  one opens) and keep following it the same way. Off, the view MUST neither
  auto-scroll nor move: it stays on the end marker and only offers a link.
  Default off on the full-page view (`?follow=1` turns it on and is kept in
  the URL); default on in Mission Control. The toggle and a live-session
  badge MUST stay visible at the top of the view while its conversation
  scrolls.
- **FR-028**: Mission Control MUST embed the live session view below the
  running feature's table while a run is in flight; the embedded view MUST
  switch sessions in place and never navigate the Mission Control page.

### Key Entities

- **Session**: one agent CLI session the orchestrator starts — identified by
  run, feature, phase (or remediation/describe kind), and attempt number;
  carries the agent's session id and an outcome.
- **Conversation entry**: one item in a session's conversation — prompt,
  assistant text, tool call, tool result, or lifecycle marker (start, end with
  outcome); ordered within its session.
- **Catch-up window**: the bounded, ephemeral list of a running session's most
  recent entries, used only to seed a viewer joining mid-session.
- **Saved conversation**: the complete, durable record of a finished session's
  entries: a file under the repository's transcript root, associated with
  exactly one phase-attempt record, which holds its location.
- **Phase-attempt record** (existing): gains whether a saved conversation
  exists, where it is, and, if capture failed, why. Gains a new attempt kind,
  `:describe`, for PR describe sessions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can see the current activity of any in-flight agent
  session from Mission Control in 2 clicks or fewer.
- **SC-002**: New conversation entries appear in an open live view within
  2 seconds of the agent producing them, in at least 95% of cases.
- **SC-003**: 100% of agent sessions started by the orchestrator — across all
  five session kinds — have a saved full conversation or a recorded reason why
  none was captured.
- **SC-004**: Session duration and outcome are unchanged by this feature:
  with zero, one, or a deliberately stalled viewer, a reference session's
  outcome is identical and its wall time differs by no more than 1%.
- **SC-005**: A post-mortem like the feature-005 converge deadline (identify
  what the agent was doing when it was cut) can be done entirely from the
  console, with no shell access to the container, after a container rebuild.
- **SC-006**: A viewer joining mid-session sees zero duplicated and zero missing
  entries at the catch-up seam, verified against the saved conversation.
- **SC-007**: Every attempt recorded before this feature still opens on the
  Transcripts page and shows its existing final-text transcript.
- **SC-008**: In a session where a command prints every masked credential's
  value, zero occurrences of those values appear in the live view or the saved
  file.

## Assumptions

- **Audience and access**: the console is a single-operator, machine-local
  surface (as today); the conversation is visible to whoever can reach the
  console. No new authentication or console access control is introduced.
  Known orchestrator credentials are masked by exact value (FR-024) and saved
  files are owner-only (FR-025); any other secret a command prints remains
  visible, and operators are expected to treat the orchestrator root
  accordingly.
- **Source of truth**: the agent CLI's session event stream (as already
  consumed by the orchestrator) is the source for live entries; the CLI's own
  session log is the source for the complete saved conversation. Where the
  two disagree, the saved conversation is authoritative for review.
- **Retention**: saved conversations are kept as long as the run record they
  belong to. Pruning follows whatever operator pruning applies to run state;
  no automatic deletion is added.
- **Read-only**: the live view is observation only. Steering or interrupting
  a session from it is out of scope.
- **Single node**: one orchestrator instance per target repository, one
  machine; there's no cross-machine streaming.
- **Defaults**: a 500-entry catch-up window and a 40-line / 4,000-character
  display truncation threshold are reasonable starting values and may become
  configuration later.
- **Out of scope**: search across conversations, export beyond the existing
  run export, diffing conversations between attempts, and changing what the
  agent sees or does.
