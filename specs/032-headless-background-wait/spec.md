# Feature Specification: Headless Background-Wait Hardening

**Feature Branch**: `032-headless-background-wait`

**Created**: 2026-10-05

**Status**: Draft

**Input**: User description: "Harden implement sessions against 'background and wait' endings" (source plan: `autonomous-headless-background-wait-plan.md`)

## Context

Waves on the fretboard-master target (features 012, 013, 014) stall in the final
implement task-phase. The failure follows one pattern:

1. The model runs a long verification gate (test suite, build, screenshots).
2. The agent's shell tool reaches its built-in 10-minute command cap. It moves the
   command to the background and returns a "moved to the background" result.
3. The model starts a background watcher and ends its turn "waiting" for the
   command to finish.
4. The session is headless, so ending the turn ends the session. Nobody resumes it.

The shell call did return a result, so the orchestrator's existing
incomplete-session gate (unreturned tool calls) does not fire. The session counts
as a success. No task is checked off, and the next sweep repeats the same pattern
until the task-phase is declared stuck and the feature fails. That burns budget
and wall-clock time, and the failure reason ("stuck") hides the real cause.

The fretboard-master fixes on the target side (environment timeouts, CI-only
performance and screenshot checks) are tracked separately. This feature makes the
orchestrator protect **any** target against the pattern. It does so in four
layers: prevent it, discourage it, remove the tools it needs, and detect it when
it happens anyway.

Decisions taken with the operator (2026-10-05):

- Long shell timeouts are set on **every orchestrator-started session** (the
  guarantee, whatever the state of the target's pack). The enforcement pack
  **also** carries the timeouts as defaults.
- The pack change raises the pack contract from **3 to 4**.

## Clarifications

### Session 2026-10-05

- Q: How is a backgrounded command matched as "resolved" (a later read of its completion)? → A: A later tool call or tool result resolves it only if it references the background task's identifier or output-file path, as given in the "moved to the background" result.
- Q: Does the retry tell the model why it is retrying? → A: For a backgrounding retry only, the prompt gets a short note that names the backgrounded command and tells the model to run it in the foreground. Retries for other reasons keep today's prompt.
- Q: How far below the session deadline must the maximum shell timeout sit? → A: Maximum = min(45 min, deadline − 5 min). Default = min(30 min, maximum). If the deadline is 10 min or less, set no override and keep the CLI defaults.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A session that ends while waiting on background work is never counted as a success (Priority: P1)

An operator runs a wave unattended. One implement session moves a long command to
the background and ends its turn waiting for it. The orchestrator classifies that
session as incomplete, the same way it classifies a session that ended with tool
calls still unreturned. It retries the phase once. If the retry ends the same way,
the feature fails loudly with a reason that names the backgrounded command. The
reason is not a generic "stuck task-phase".

**Why this priority**: This is the backstop. Prevention (US2–US4) can be bypassed
by a future CLI change or by model behavior. Detection makes sure the failure
always surfaces honestly and quickly, never as a fake success that the orchestrator
retries until the task-phase is declared stuck.

**Independent Test**: Replay a recorded session event stream that contains a
"moved to the background" tool result, then a session-success ending, with no read
of the command's output. Confirm the phase is classified as incomplete, retried
once, and then failed with a reason that names the backgrounded command.

**Acceptance Scenarios**:

1. **Given** a session that reports success and whose events include a tool result
   saying a command was moved to the background, with no later read of that
   command's completion, **When** the orchestrator evaluates the phase, **Then**
   the phase is classified as ended with work outstanding and is retried once.
   The retry prompt carries a note that names the backgrounded command and tells
   the model to run it in the foreground.
2. **Given** a session that started a command in background mode explicitly and
   ended without reading the command's completion, **When** the orchestrator
   evaluates the phase, **Then** the phase gets the same classification and retry.
3. **Given** the retried session ends the same way, **When** the orchestrator
   evaluates it, **Then** the feature fails. The operator-visible reason and the
   log identify the stranded work as a backgrounded shell command.
4. **Given** a session that backgrounded a command and then read the command's
   completion before it ended, **When** the orchestrator evaluates the phase,
   **Then** the phase is **not** flagged.

---

### User Story 2 - Long verification gates finish in the foreground (Priority: P1)

An implement session runs a gate that takes 15–30 minutes. The command runs to
completion in the foreground and is never moved to the background. The orchestrator
gives every session it starts shell timeouts long enough for realistic gates. The
timeouts are always shorter than that session's own deadline, so the
orchestrator's clean shutdown always fires first.

**Why this priority**: This removes the trigger. Without the 10-minute cap the
model has nothing to wait on, and most stalls never happen.

**Independent Test**: Start an orchestrated session for a phase and for an
implement chunk. Inspect the environment the session receives. Confirm that the
default and maximum shell timeouts are present, are longer than 10 minutes, and
are shorter than the session's deadline.

**Acceptance Scenarios**:

1. **Given** any orchestrator-started session, **When** the session launches,
   **Then** the session carries a default and a maximum shell-command timeout. The
   orchestrator sets both itself and does not depend on the target repository's
   files.
2. **Given** a session deadline (phase or scaled implement chunk), **When** the
   orchestrator computes the timeouts, **Then** maximum = min(45 min,
   deadline − 5 min) and default = min(30 min, maximum).
3. **Given** a session deadline of 10 minutes or less, **When** the session
   launches, **Then** no timeout override is set.
4. **Given** a target repository that has not installed the updated pack, **When**
   an orchestrated session runs there, **Then** the long timeouts still apply.

---

### User Story 3 - The model is told the session is headless (Priority: P2)

Every implement task-phase, implement sweep, and converge prompt states that the
session is headless. The prompt tells the model to run every command in the
foreground with a long timeout, never to use background execution or a background
watcher, and never to end its turn while a command is running, because ending the
turn ends the session.

**Why this priority**: This is cheap. It addresses the model's reasoning ("I'll
wait for it") directly. It is not enough alone, because models do not always
follow instructions.

**Independent Test**: Build the implement task-phase, sweep, and converge prompts.
Confirm each prompt contains the headless rule. Confirm the prompts of phases this
feature does not touch stay byte-identical.

**Acceptance Scenarios**:

1. **Given** an implement task-phase or sweep session, **When** the prompt is
   built, **Then** it contains the headless foreground-only rule.
2. **Given** a converge session, **When** the prompt is built, **Then** it contains
   the same rule.
3. **Given** a phase outside implement and converge, **When** the prompt is built,
   **Then** the prompt is byte-identical to its pre-032 form.

---

### User Story 4 - Background-wait tools are unavailable to headless sessions (Priority: P2)

The tool that arms a background watcher (and any tool that only reads output from
backgrounded commands, if the pinned CLI exposes one) joins the existing list of
tools excluded from every headless session. The list already holds the subagent
and scheduled-wakeup tools. The exclusion applies under both containment profiles,
strict and permissive.

**Why this priority**: This removes the "wait" half of the pattern, so the model
cannot arm a watcher and leave. It comes after US2 because a model can still
background a command without the watcher tool. US1 catches that case.

**Independent Test**: Build the session request for every phase under both
profiles. Confirm the background-watcher tool is in the excluded-tool list each
time.

**Acceptance Scenarios**:

1. **Given** any headless phase session under the strict profile, **When** its
   request is built, **Then** the background-watcher tool is excluded.
2. **Given** the same session under the permissive profile, **When** its request
   is built, **Then** the background-watcher tool is still excluded. The exclusion
   is about headlessness, not containment.

---

### User Story 5 - The enforcement pack carries long timeouts without clobbering the target's settings (Priority: P3)

When an operator installs or upgrades the enforcement pack into a target
repository, the pack's settings file brings default long shell timeouts. Any
environment entries the target already defines are preserved: install merges
instead of overwriting, and the target's own values win on a key conflict. The pack
contract version becomes 4. A permissive-run preflight against a target whose
committed pack is still at contract 3 refuses to start and tells the operator to
upgrade the pack.

**Why this priority**: This is a complement, not the guarantee (US2 is the
guarantee). It also helps the operator's own interactive sessions in the target
and keeps the pack honest about what it ships.

**Independent Test**: Install the pack into a target whose settings file already
defines environment entries. Confirm the target's entries survive unchanged and
the pack's timeout entries are added. Run the permissive preflight against a
contract-3 pack and confirm it is refused with the upgrade hint.

**Acceptance Scenarios**:

1. **Given** a target with no settings file, **When** the pack is installed,
   **Then** the settings file includes the default long shell timeouts.
2. **Given** a target whose settings file defines its own environment entries,
   including one of the timeout keys, **When** the pack is installed, **Then**
   every target entry is preserved with its value, and only the missing pack keys
   are added.
3. **Given** a committed pack at contract 3, **When** a permissive run is
   preflighted, **Then** the run is refused as pack-outdated with an upgrade hint.
4. **Given** a committed pack at contract 3, **When** a strict run is preflighted,
   **Then** preflight behaves as it did before 032. The session-level timeouts
   (US2) still apply.

---

### Edge Cases

- **Backgrounded, then read**: a command moved to the background whose completion
  the session later reads is not stranded and must not be flagged (no false
  positive). The read can use any tool, as long as it references the task
  identifier or output-file path.
- **Backgrounded, then unrelated work**: later tool calls that do not reference
  the backgrounded command's identifier or output path leave the command
  stranded. The session is still flagged.
- **No identifier in the marker**: a backgrounding result that carries neither a
  task identifier nor an output path cannot be resolved, so the command counts as
  stranded.
- **Backgrounded on a non-success session**: a session that ends through max-turns
  exhaustion, a cut stream, or a deadline kill keeps its existing classification
  (exhausted or transient). The new check applies only to sessions that report
  success.
- **Both gates fire**: a session that has both unreturned tool calls and a
  backgrounded command is classified once, as ended with work outstanding. It is
  retried once, not twice.
- **Branch drift wins**: a session that drifted off its branch and also
  backgrounded a command is classified as branch drift, which is never retried.
  The existing gate order is preserved.
- **Deadline shorter than the default timeout**: if the configured phase or chunk
  deadline is short, the formula clamps both timeouts to at least 5 minutes below
  it. With a deadline of 10 minutes or less, no override is set and the CLI
  defaults apply.
- **Target key conflict**: when the target's settings define a timeout key with a
  different value, the target's value is kept on install. The session-level value
  set by the orchestrator governs orchestrated sessions.
- **Marker text changes in a future CLI**: if the "moved to the background"
  wording changes, the explicit background-mode check (US1, scenario 2), the tool
  exclusion (US4), and the long timeouts (US2) still cover the pattern. The
  harness-contract document records the marker so a CLI bump re-checks it.
- **Interactive human sessions**: the operator's own sessions in the target are
  not orchestrated. They get only the pack's defaults, never the session-level
  values, the tool exclusion, or the gate.

## Requirements *(mandatory)*

### Functional Requirements

**Detection (US1)**

- **FR-001**: The orchestrator MUST classify a phase or implement-chunk session
  that reports success as **ended with work outstanding** when its event stream
  shows a shell command moved to the background, by tool-result wording or by
  explicit background mode, and shows no later read of that command's completion.
  A backgrounded command counts as **resolved** only when a later tool call or
  tool result references its background task identifier or its output-file path,
  as given in the backgrounding result. An unrelated later tool call does not
  resolve it.
- **FR-002**: A session classified under FR-001 MUST follow the same retry-once
  path as the existing incomplete-session gate. A second occurrence MUST fail the
  feature.
- **FR-002a**: When the retry was caused by FR-001, the retried session's prompt
  MUST carry a short corrective note. The note names the backgrounded command(s)
  and instructs the model to run them in the foreground. A retry caused by any
  other reason (for example plain unreturned calls, or an artifact substance
  failure) MUST keep its prompt byte-identical to before 032.
- **FR-003**: The failure reason and logs MUST identify the stranded work as a
  backgrounded shell command, distinct from a generic unreturned tool call.
- **FR-004**: The detection MUST apply only to sessions that report success, and
  MUST NOT change the classification of exhausted, transient, or branch-drifted
  sessions.
- **FR-005**: The detection MUST apply at every session-driving site that already
  applies the incomplete-session gate: phase sessions, implement chunks, and
  remediation sessions.

**Prevention: timeouts (US2)**

- **FR-006**: Every orchestrator-started session MUST receive a default and a
  maximum shell-command timeout through the session environment. The orchestrator
  MUST set them itself, independent of the target repository's files.
- **FR-007**: Both timeouts MUST be derived from that session's own deadline:
  maximum = min(45 min, deadline − 5 min), and default = min(30 min, maximum).
  The maximum therefore always leaves at least 5 minutes of headroom before the
  deadline, so the session can read a timed-out result and tick tasks before the
  orchestrator's shutdown fires.
- **FR-008**: When the session deadline is 10 minutes or less, the orchestrator
  MUST NOT set either timeout override, so the CLI's built-in defaults apply.
  With the default 50-minute phase deadline, the result is a 45-minute maximum
  and a 30-minute default.

**Prevention: prompt (US3)**

- **FR-009**: The implement task-phase block, the implement sweep block, and the
  converge prompt MUST include a headless rule. The rule says to run commands in
  the foreground with a long timeout, never to use background execution or a
  background watcher, and never to end the turn while a command runs, because
  ending the turn ends the session.
- **FR-010**: Prompts for every other phase MUST stay byte-identical to their
  pre-032 form.

**Prevention: tools (US4)**

- **FR-011**: The background-watcher tool MUST be added to the tool exclusion list
  applied to every headless session, under both the strict and permissive
  profiles. Any background-output reader tool exposed by the pinned CLI version
  MUST be excluded the same way.

**Pack (US5)**

- **FR-012**: The enforcement pack's settings file MUST carry default long
  shell-timeout entries in its environment section.
- **FR-013**: Pack install MUST merge the pack's environment entries into an
  existing target settings file. It MUST preserve every existing target
  environment entry and its value, adding only keys that are absent. The rest of
  the pack-owned settings keep today's overwrite semantics.
- **FR-014**: The pack contract version MUST become 4. The permissive-run
  preflight MUST refuse a committed pack below contract 4 as pack-outdated with an
  upgrade hint. Its existing "no deny list" rule stays. The strict-run preflight
  MUST behave as it did before 032.

**Documentation**

- **FR-015**: The operator runbook MUST gain a symptom, cause, and fix entry for
  "implement sweeps stall after a command is moved to the background".
- **FR-016**: The harness-contract document MUST record the agent's built-in
  10-minute command cap, the background marker wording, and the environment
  override. The project guide's session-deadline paragraph MUST record how
  shell timeouts relate to session deadlines.

### Key Entities

- **Backgrounded command**: a shell invocation in a session's event stream that
  was moved to the background (by tool-result wording or explicit mode). It is
  either *resolved*, when a later event reads its completion, or *stranded*.
- **Session shell timeouts**: the pair (default, maximum) the orchestrator gives a
  session. It is bounded above by that session's deadline.
- **Pack contract**: the version the enforcement pack advertises (3 to 4). The
  permissive preflight checks it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A replay of the recorded fretboard-master 014 stall (session
  `3e935ca9`) is classified as ended with work outstanding on the first
  evaluation. It is retried exactly once and never reaches a stuck-task-phase
  failure.
- **SC-002**: Zero false positives: every existing recorded session fixture that
  does not involve backgrounding keeps its current classification. A session that
  backgrounds and then reads its command is not flagged.
- **SC-003**: For 100% of orchestrated sessions, phase and implement chunk alike,
  the maximum shell timeout is at least 5 minutes less than the session deadline,
  or no override is set when the deadline is 10 minutes or less.
- **SC-004**: Pack install preserves 100% of a target's pre-existing environment
  entries and their values.
- **SC-005**: Prompts and session requests for phases this feature does not touch
  are byte-identical to before 032. The existing test suite passes unchanged
  except for the deliberately updated cases.
- **SC-006**: The next unattended fretboard-master wave completes its final
  implement task-phase (Polish) without a stall caused by a backgrounded command.

## Assumptions

- The pinned agent CLI honors the default and maximum shell-timeout environment
  overrides (`BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS`). Planning confirms
  this against the pinned version.
- The CLI's "moved to the background" tool-result wording is stable within the
  pinned version. The explicit-background-mode check and the tool exclusion cover
  wording drift.
- The background-watcher tool is named `Monitor` in the pinned CLI. Planning
  confirms whether a separate background-output reader exists and needs
  excluding.
- The orchestrator already sets environment markers on every session it starts.
  The timeouts travel through the same mechanism.
- Target-side fixes (fretboard-master environment timeouts, CI-only performance
  and screenshot checks) are out of scope.
- No constitution amendment is required. The change tightens containment (one
  more excluded tool) and strengthens fail-loud classification. It does not relax
  any MUST.
- Code anchors for planning (not requirements): the incomplete-session check in
  the phase-result module, the retry reason in the phase step, the headless
  exclusion list and prompt blocks in the phase-request module, the converge
  prompt, the target-pack installer and its contract check, and the
  orchestrated-session environment markers in the containment module.
