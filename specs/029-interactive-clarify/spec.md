# Feature Specification: Interactive Clarify Answering

**Feature Branch**: `029-interactive-clarify`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Interactive NEEDS HUMAN answering at clarify, configurable per run. Today a clarify-phase `## NEEDS HUMAN` escalation is terminal — the feature escalates, its worktree is kept, and the run parks; the only way forward is for an operator to answer later through the Escalations resume form's single free-text prompt, which re-runs clarify. These escalations are usually just questions the reviewer has for the user; answering them live, inside the run, keeps the flow moving. A per-run switch (default off, off = byte-identical to today) makes the feature wait in a non-terminal 'awaiting answers' state, surfaces the questions to the operator in the console and iex, re-runs clarify with the operator's answers folded in (bounded rounds), and falls back to today's escalation on timeout, exhausted rounds, breaker trip, or supersession drain. The clarify prompt gains a structured, numbered question format so questions can be answered one by one."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Answer the reviewer's questions live and keep the run going (Priority: P1)

An operator starts a run with interactive clarify switched on. The clarify reviewer decides a feature needs a human: it writes `## NEEDS HUMAN` with its open questions. Today the feature would escalate and the run would park. With the switch on, the feature waits instead, in a visible "awaiting answers" state:

- its worktree stays live
- the run does not park
- no other feature is released

The operator sees each question in the console and types an answer. The operator submits. Clarify runs again with those answers treated as authoritative and folds them into the spec. The feature then continues to plan, all inside the same run.

**Why this priority**: This is the whole value of the feature. A backlog run no longer stops on a question a human can answer in a minute. The operator no longer has to come back later, find the parked run, and resume it by hand.

**Independent Test**: Start a run with the switch on, against a feature whose clarify reliably produces `## NEEDS HUMAN` (e.g. LedgerLite 007's seeded month-end trap). Answer the questions, then observe:

- the feature leaves "awaiting answers"
- clarify re-runs with the answers
- the spec records the answers under its clarifications
- the feature proceeds to plan
- the run never parks

**Acceptance Scenarios**:

1. **Given** a run with interactive clarify on, **When** the clarify gate detects an unresolved `## NEEDS HUMAN`, **Then** the feature enters "awaiting answers", the run stays active (not parked), no further feature is released, and the questions become visible to the operator.
2. **Given** a feature awaiting answers, **When** the operator submits answers, **Then** clarify re-runs for that feature with the answers supplied as authoritative operator input, and on a clean re-run the feature advances to plan in the same run.
3. **Given** a feature awaiting answers, **When** no model session is running for it, **Then** no spend is incurred while it waits.
4. **Given** a run with interactive clarify **off** (the default), **When** the clarify gate detects `## NEEDS HUMAN`, **Then** the outcome is identical to today: escalated, worktree kept, run parked, the same records and report.

---

### User Story 2 - Fall back safely when nobody answers (Priority: P1)

An operator turns on interactive clarify and walks away. A feature starts awaiting answers, and nobody responds within the run's answer timeout. The feature then escalates exactly as it would with the switch off. The run parks and the escalation record matches today's. Every other reason the wait must end without answers falls back the same way:

- the cost breaker trips
- a new run supersedes this one and drains it
- the configured number of question rounds is used up

In none of these cases does the feature hang forever or lose its work.

**Why this priority**: Without a guaranteed exit, an unattended run could sit forever and hold the single in-flight slot. The fallback is what makes turning the switch on safe.

**Independent Test**: Set a short answer timeout, let a feature reach "awaiting answers", and do not answer. Confirm the feature escalates, the run parks, and the recorded outcome matches today's. Repeat once each for a breaker trip, a supersession, and a feature whose re-run keeps asking until the round limit.

**Acceptance Scenarios**:

1. **Given** a feature awaiting answers, **When** the answer timeout elapses, **Then** the feature escalates with a recorded reason that says the answer window expired, and the run parks exactly as it does for today's escalation.
2. **Given** a feature awaiting answers, **When** the cost breaker trips, **Then** the wait ends, the feature escalates without starting another session, and the run drains per the existing drain-don't-kill discipline.
3. **Given** a feature awaiting answers, **When** a new run for the same repository asks this run to drain, **Then** the wait ends promptly, well within the drain bound, and the feature escalates. The new run is never blocked for the full answer timeout.
4. **Given** a feature whose re-run after answers still reports `## NEEDS HUMAN`, **When** the configured round limit has been reached, **Then** the feature escalates with a recorded reason that says rounds were exhausted, instead of waiting again.
5. **Given** a feature whose re-run still reports `## NEEDS HUMAN` and rounds remain, **When** the re-run finishes, **Then** the feature starts a new round: it awaits answers again, with the new questions shown and the round number advanced.

---

### User Story 3 - Answer question by question, from console or iex (Priority: P2)

The reviewer writes its open questions in a numbered format (Q1, Q2, …), each with context and options or a recommended default. The operator gets one answer field per question and can accept a question's recommended default with one action. An operator working in iex can list pending questions and submit answers there. If the reviewer produced free-form text instead of numbered questions, the operator still gets a single answer field for the whole block.

**Why this priority**: Structured questions make answering faster and more precise, and iex parity serves operators who do not open the console. But answering through a single free-text field already delivers the core value (US1), so this is an enhancement.

**Independent Test**: Let a feature await answers with numbered questions. Confirm the console shows one field per question, with each recommended default available. Answer via iex and confirm the feature proceeds. Repeat with an unstructured question block and confirm a single field appears.

**Acceptance Scenarios**:

1. **Given** a feature awaiting answers whose questions are numbered, **When** the operator opens the console, **Then** each question is shown with its context, its options or recommended default, and its own answer field. The view updates live when the feature enters or leaves the waiting state, with no manual refresh.
2. **Given** a feature awaiting answers, **When** the operator lists pending questions from iex, **Then** they see the feature, the round, and each question. **When** they submit answers for that round from iex, **Then** the feature proceeds exactly as with a console submission.
3. **Given** answers submitted for a round that is no longer current (already answered, timed out, or superseded by a newer round), **When** they arrive, **Then** they are rejected with a clear reason and have no effect on the feature.
4. **Given** questions that are not in the numbered format, **When** they are shown, **Then** the operator gets a single answer field for the whole question block, and submission works the same way.
5. **Given** a numbered question the operator leaves blank, **When** the operator submits, **Then** the question is answered with its recommended default when one exists. When a question has no default, the form asks for an answer before it can be submitted.

---

### User Story 4 - See and configure it per run (Priority: P2)

When starting a run, the operator chooses from the trigger form or from the run's start options:

- whether interactive clarify is on
- the answer timeout
- the maximum number of question rounds

The choice is recorded with the run's settings, so the run's detail view, report, and any later resume all show which mode was in force. Awaiting-answers features appear distinctly in status views: in the console, in the iex status table, and in the list of what is in flight.

**Why this priority**: The choice has to be visible and recorded, or operators cannot tell why one run waited and another parked. It is still secondary to the waiting behavior itself.

**Independent Test**: Start two runs, one with the switch on and one off. Confirm each run's recorded settings and detail view show the chosen mode, timeout, and round limit. Confirm that an awaiting feature shows a distinct status in every status surface.

**Acceptance Scenarios**:

1. **Given** the trigger form, **When** the operator enables interactive clarify and sets a timeout and round limit, **Then** the run starts with those values recorded in its settings. Out-of-range values are rejected before the run starts.
2. **Given** a run started with no interactive-clarify options, **When** its settings are inspected, **Then** interactive clarify is off and the defaults are recorded.
3. **Given** a feature awaiting answers, **When** any status surface is viewed, **Then** the feature shows as "awaiting answers", distinct from running, escalated, and halted, together with the elapsed wait and the time left before timeout.
4. **Given** an interrupted run that recorded interactive clarify on, **When** it is resumed, **Then** the recorded mode applies unless the operator explicitly overrides it.

---

### Edge Cases

- **Answers arrive just as the timeout fires**: exactly one outcome wins. Either the answers are applied or the feature escalates, never both. A late answer is rejected as stale.
- **The re-run after answering fails for a reason unrelated to questions** (session error, artifact gate): the existing retry and failure handling applies unchanged. Answers are not re-requested.
- **The operator answers, then the breaker trips before the re-run starts**: the feature drains without starting the re-run, and escalates with the submitted answers preserved in the record, so a later resume can reuse them.
- **The orchestrator process restarts while a feature is awaiting answers**: the wait does not survive the restart. On recovery the feature is treated as escalated at clarify, with its pending questions preserved, and the existing resume path applies.
- **The reviewer writes `## NEEDS HUMAN` with an empty body**: the operator gets a single free-text field. An empty submission is rejected.
- **An operator uses the existing resume form while a feature is awaiting answers**: the feature counts as in flight, so the existing active-run guard applies. The operator is pointed to the answer surface instead.
- **Interactive clarify is on, but the feature never hits `## NEEDS HUMAN`**: there is no behavioral difference from today.
- **Stacked backlog**: while one feature awaits answers, the rule of one feature at a time holds. Nothing downstream is released until it advances or escalates.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each run MUST carry three recorded settings:
  - an **interactive clarify** switch, default off
  - an **answer timeout**, default 30 minutes
  - a **maximum question rounds**, default 3

  Each is settable when the run is started (programmatically and from the console trigger form) and validated to a bounded range before the run starts. Timeout is at least 1 minute and at most 24 hours; rounds is 1–5.
- **FR-002**: With interactive clarify off, clarify-gate behavior, records, reports, and console output MUST be identical to today's.
- **FR-003**: With interactive clarify on, when the clarify gate detects an unresolved `## NEEDS HUMAN` and rounds remain, the feature MUST enter a new non-terminal lifecycle state, **awaiting answers**, instead of escalating.
- **FR-004**: While a feature awaits answers, all of the following MUST hold:
  - no model session runs for it
  - no cost is reserved or committed for it
  - its worktree is retained
  - the run is not parked
  - the feature counts as the run's single in-flight feature, so no other feature is released
- **FR-005**: When a feature enters "awaiting answers", the system MUST durably record the round: feature, round number, question text, when the wait started, and when it will time out. The record MUST let answers be matched to exactly one round.
- **FR-006**: The system MUST surface pending questions to the operator in the console, live (no manual refresh), and through an iex function that lists pending questions.
- **FR-007**: The operator MUST be able to submit answers for the current round from the console and from iex. Answers for a round that is not current MUST be rejected with a stated reason and MUST have no effect.
- **FR-008**: On accepted answers, the system MUST durably record them against the round. It MUST then re-run clarify for that feature with the answers supplied as authoritative operator input. The reviewer MUST be told to fold them into the spec's clarifications and bring stale spec text into line.
- **FR-009**: After the re-run, the gate MUST be evaluated again. If `## NEEDS HUMAN` is resolved, the feature continues the pipeline in the same run. If it is still present and rounds remain, a new round begins (FR-003). If rounds are exhausted, the feature escalates with a reason stating that rounds were exhausted.
- **FR-010**: If the answer timeout elapses, the feature MUST escalate with a reason stating that the answer window expired. From that point on, the escalation, parking, worktree retention, and records MUST match today's `## NEEDS HUMAN` escalation, apart from the stated reason.
- **FR-011**: While a feature awaits answers, a tripped cost breaker or a supersession drain request MUST end the wait promptly and escalate the feature without starting any new session. Both MUST honor the existing drain-don't-kill discipline. The supersession drain MUST NOT be forced to wait for the full answer timeout.
- **FR-012**: The clarify reviewer MUST be instructed to write open questions under `## NEEDS HUMAN` as numbered items (Q1..Qn). Each item gives its context, and either concrete options or a recommended default.
- **FR-013**: When the questions follow the numbered format, the console MUST offer one answer field per question and let the operator accept a question's recommended default. A blank answer to a question that has a default takes that default. A question with no default MUST be answered before submission. When the questions do not follow the format, the console MUST offer a single answer field for the whole block.
- **FR-014**: "Awaiting answers" MUST appear as a distinct status in every operator status surface: console views, the iex status table, the run report, and the in-flight listing. Each shows elapsed wait and time remaining. Its visual treatment MUST follow the operator-surface design rules (a named status, no ad-hoc color).
- **FR-015**: Every round MUST be recorded as part of the feature's run history: questions asked, answers given (or the timeout, drain, or exhaustion outcome), and timestamps. It MUST be visible in the run's detail view and in the report.
- **FR-016**: If the orchestrator restarts while a feature is awaiting answers, the feature MUST NOT be left in "awaiting answers". On recovery it is treated as escalated at clarify, with its pending questions preserved. The existing resume path MUST be able to continue it.
- **FR-017**: A resumed run MUST use its recorded interactive-clarify settings unless the operator explicitly overrides them when resuming.
- **FR-018**: The rule that recognizes an unresolved `## NEEDS HUMAN` MUST be defined once and shared by every place that checks for it: the gate, the console, and the spec-file scan.
- **FR-019**: The project constitution's Human-in-the-Loop principle MUST be amended before implementation. It must permit a bounded, per-run, operator-attended wait ahead of the clarify escalation. The amendment keeps these obligations:
  - default off
  - bounded by timeout and rounds
  - every exit that is not an answer falls back to today's escalation
  - no ambiguity is resolved without a human answer
- **FR-020**: The operator runbook and project guidance MUST document the mode, its settings, the answering surfaces, and every fallback.

### Key Entities *(include if feature involves data)*

- **Interactive clarify settings**: per-run choice of on/off, answer timeout, and maximum rounds. Recorded with the run's settings, and shown on the run's detail view and report.
- **Question round**: one waiting episode for one feature. It holds the feature, the round number (1..max), the question text (the raw block plus any parsed numbered questions), when the wait started, and the deadline. Its outcome is one of: answered, timed out, drained, breaker-stopped, or exhausted.
- **Question**: one numbered item within a round. It has an identifier (Q1..Qn), context, options, and an optional recommended default.
- **Answer set**: the operator's answers for one round, keyed by question identifier or given as a single free-text answer. It records when it was submitted and through which surface (console or iex).
- **Awaiting answers (feature status)**: a new non-terminal lifecycle state, between running and the terminal outcomes. It counts as in flight.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With interactive clarify on and an operator present, a feature that hits `## NEEDS HUMAN` proceeds to plan in the same run. There is no parked run and no manual resume, and the operator's only work is answering the questions.
- **SC-002**: The time from submitting answers to the clarify re-run starting is under 5 seconds, excluding the re-run's own duration.
- **SC-003**: With interactive clarify off, every existing clarify-gate test passes unchanged, and the recorded outcome for a `## NEEDS HUMAN` feature matches today's exactly.
- **SC-004**: In all tested fallback paths (timeout, breaker, supersession drain, exhausted rounds), the feature reaches an escalated outcome. In none does it remain awaiting answers, and none incurs spend while waiting.
- **SC-005**: A supersession drain of a run whose feature is awaiting answers finishes within the existing drain bound, independent of the configured answer timeout.
- **SC-006**: Stale or duplicate answer submissions change feature state in 0% of cases.
- **SC-007**: In a live validation run, LedgerLite feature 007 (the seeded month-end/proration trap) with interactive clarify on completes clarify from operator answers and advances past clarify without a parked run.
- **SC-008**: The operator-surface design guard passes with the new status added.

## Assumptions

- A single operator answers any given round. Concurrent answering by several operators is out of scope beyond the rule that the first accepted submission wins and later ones are rejected as stale.
- Only the clarify-phase `## NEEDS HUMAN` escalation becomes interactive. Analyze-gate escalations and halts, publish failures, and branch drift are unchanged.
- Waiting across an orchestrator restart is out of scope. A restart turns a waiting feature into today's escalation, with the questions preserved (FR-016).
- Answers are fed back by re-running the existing clarify reviewer. The system does not write answers into the spec itself.
- The existing mechanism for adding operator guidance to a phase is suitable for carrying answers into the clarify re-run.
- Notifications outside the console and iex (email, chat, push) are out of scope. The operator is expected to be watching the console or iex when the mode is on.
- The defaults (off; 30-minute timeout; 3 rounds) suit an attended run. Operators running unattended simply leave the mode off.
- **Dependency**: the constitution amendment to Principle V (FR-019) is ratified as constitution 5.0.0 (2026-09-24). It permits the bounded, opt-in, human-answered wait ahead of the clarify escalation.
