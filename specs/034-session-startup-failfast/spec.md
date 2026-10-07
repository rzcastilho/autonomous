# Feature Specification: Fail Fast on Session Startup Failure

**Feature Branch**: `034-session-startup-failfast`

**Created**: 2026-10-07

**Status**: Draft

**Input**: User description: "Fail fast when a harness session dies at startup, and stop the containerized runtime from reading a half-written host CLI config." (Incident: 2026-10-07, fretboard-master run r000001, feature 029, permissive profile, containerized console started with host login.)

## Background

On 2026-10-07 a single-spec run against `fretboard-master` showed feature 029 as `running` in the specify phase for the whole phase deadline. That is roughly 50 minutes with spend $0, no transcript, and no agent CLI process alive. Here is what happened:

1. The containerized runtime was started with the operator's host login. Its agent CLI therefore read the operator's live CLI config file. Host CLI sessions were writing that same file at the same time.
2. The orchestrator's specify session started during one of those writes. It read a half-written config, reported it as "corrupted", and exited during startup. Seconds later the file was valid again.
3. The orchestrator never learned that the session had ended. The worker kept waiting for a phase result that would never come. The operator could not tell "working" from "dead", and no resume, supersession, or drain could act before the deadline expired. When the deadline did expire, the worker would crash instead of recording a clean failure.

This feature fixes both halves. A session that dies at startup must end its phase within seconds, with a clear reason (P1). The containerized runtime must stop exposing its sessions to another process's half-written config (P2).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A session that dies at startup fails the phase promptly with a clear reason (Priority: P1)

An operator starts a run. The agent session for a phase fails to start, or ends before producing any result. Examples: the CLI exits during its startup handshake, the session's client process terminates, or the transport to the CLI closes. Within seconds, the orchestrator records the phase attempt as a startup failure. The record carries a distinct, readable reason and an excerpt of what the CLI reported. Because such failures are often transient, the orchestrator retries the phase once. If the retry also fails at startup, the feature ends as failed under the existing rules for a non-done terminal (a backlog run parks, naming the feature). Every operator surface shows why.

**Why this priority**: This is the defect that cost the operator the whole phase deadline. It also blocks every recovery path (resume, supersession, drain) for that long. Whatever made the session die, the orchestrator must never sit on a dead session.

**Independent Test**: Fully testable without real credentials. Drive a phase whose session is made to exit during startup, then check four things: the phase ends within seconds rather than at the deadline; one retry happens; the feature fails after the second startup failure with a startup-failure reason that includes the CLI's message; and the worker is no longer registered as in flight.

**Acceptance Scenarios**:

1. **Given** a running feature whose phase session exits during startup with an error message, **When** the session ends, **Then** the phase attempt is recorded as a startup failure within 30 seconds, carrying the CLI's error excerpt, and the feature is not left showing `running` against a dead session.
2. **Given** a phase whose first session dies at startup and whose retry starts normally, **When** the retry completes, **Then** the phase result reflects the retry only. The feature continues normally, and the first attempt stays visible as a recorded startup failure.
3. **Given** a phase whose session dies at startup on both the attempt and the retry, **When** the retry fails, **Then** the feature ends as `failed` with a startup-failure reason. A backlog run parks with `stopped_by` naming that feature, exactly as for any other non-done terminal.
4. **Given** a startup failure at an implement chunk, an auto-remediation step, or a remediation step, **When** the session dies at startup, **Then** the same fail-fast, retry-once, and clear-reason behavior applies as for a whole-phase session.
5. **Given** a session that started normally and later hangs without producing output, **When** its deadline expires, **Then** behavior is unchanged from today. The deadline remains the backstop for a genuinely hung session.
6. **Given** a feature failed by startup failure, **When** the operator views the final report, the status table, or the console's run detail, **Then** each surface shows that the session failed to start, plus the CLI's error excerpt. It never shows a raw internal term.

---

### User Story 2 - The containerized runtime does not read a half-written host CLI config (Priority: P2)

An operator runs the orchestrator in the container using their host login, while also using the agent CLI on the host. Host sessions keep rewriting the operator's CLI config file. The orchestrator's sessions in the container never see that file mid-write. They read a stable, complete config of their own and keep the authentication and per-project trust/settings they rely on today.

**Why this priority**: This is the trigger of the incident. With P1 in place, a torn read costs one quick retry instead of a lost deadline. Still, a host operator who works alongside the container hits the race repeatedly. Removing the race removes a whole class of spurious failures. It ranks P2 because P1 alone already restores a safe, visible outcome.

**Independent Test**: Start the container with host login. Rewrite the host config file in a tight loop while the orchestrator starts sessions repeatedly. No session reports a corrupted config. Sessions still authenticate, and a target repo trusted before the change is still treated as trusted.

**Acceptance Scenarios**:

1. **Given** the container started with host login, **When** host processes rewrite the host CLI config continuously while orchestrator sessions start, **Then** no orchestrator session fails because of a partially written config.
2. **Given** the container started with host login, **When** an orchestrator session starts, **Then** it is authenticated as the operator's host login without any extra step, and the per-project trust/settings it relied on before this change still apply.
3. **Given** the host config file is itself invalid when the container starts, **When** the runtime prepares its own config, **Then** startup fails loudly with an operator-readable message naming the file. It does not silently proceed with no or partial config.
4. **Given** the container started without host login (token-based authentication), **When** sessions start, **Then** behavior is unchanged from today.
5. **Given** the documented container smoke checks, **When** the operator runs the host-login check, **Then** it verifies the new isolation, so it still means something.

---

### Edge Cases

- **Startup failure while draining**: a startup failure on a feature that is mid-drain (breaker tripped or run superseded) ends the phase promptly. There is no retry, because drain allows no new sessions. Drain completes immediately instead of waiting on the deadline.
- **Startup failure with no message**: the CLI dies at startup without any error output. The reason still names a startup failure and states that no message was captured.
- **Very long CLI error output**: the excerpt is bounded so a huge error output cannot flood operator surfaces or stored records.
- **Session dies after some output but before a result**: if the session produced some output and then ended without a result, that is a mid-session death, not a startup failure. It fails promptly and is labelled as such, distinct from a timeout and from a startup failure. It gets the same retry-once treatment.
- **Resume after a startup failure**: a feature failed by startup failure resumes at the phase that failed, with no special handling.
- **Cost**: a startup failure records zero actual spend. A cost reservation made for the failed attempt is released, not committed.
- **Host config changes after container start** (US2): authentication and trust changes the operator makes on the host after the container started are not expected to reach the running container without a restart. This is documented.

## Requirements *(mandatory)*

### Functional Requirements

**Startup failure detection (US1)**

- **FR-001**: When an agent session ends before producing a phase result, the system MUST detect it and end the waiting phase within 30 seconds. The phase MUST NOT wait for its deadline. This covers a session that never started, a CLI exiting during startup, a session client terminating, and the transport closing.
- **FR-002**: The system MUST record each such ended attempt as a phase-attempt entry with an outcome distinct from success, from timeout, and from every existing failure kind. "Session failed to start" and "session ended without a result" MUST be distinguishable.
- **FR-003**: The recorded reason MUST include a bounded excerpt of the CLI's error output when one exists (at most 2,000 characters), or an explicit "no output captured" when none does.
- **FR-004**: The worker driving a feature MUST NEVER remain blocked waiting for a result from a session that has already ended. A dead session MUST NOT leave the feature displayed as `running`.
- **FR-005**: A phase whose attempt ended this way MUST NOT be advanced on stale state. The pipeline MUST treat it as a failed attempt, not as the previous phase's outcome.
- **FR-006**: The system MUST retry a phase once after a startup failure or a session ended without a result, the same way existing retryable session failures are retried. If the retry fails the same way, the feature MUST end `failed` with that reason.
- **FR-007**: A feature failed this way MUST follow the existing non-done-terminal rules unchanged. A backlog run parks with `stopped_by` naming the feature, and an ad-hoc feature finishes failed.
- **FR-008**: FR-001 through FR-007 MUST hold at every session-driving site: whole-phase sessions, implement chunks, auto-remediation steps, and remediation steps.
- **FR-009**: The session deadline MUST remain the backstop for a session that started and then hangs. This feature MUST NOT change deadline values, the shell-timeout derivation, or the drain-don't-kill discipline.
- **FR-010**: A tripped breaker or a drain request MUST suppress the retry in FR-006. The attempt still ends promptly, and drain completes without waiting on the deadline.
- **FR-011**: A failed-at-startup attempt MUST commit zero actual spend and MUST release any reservation it held.

**Operator visibility (US1)**

- **FR-012**: The final report, the status table, and the console's run detail MUST show a startup failure as a human-readable reason that includes the CLI error excerpt. No raw internal terms may appear in console markup.
- **FR-013**: The startup failure and its retry MUST be logged at warning level or higher, with the feature, phase, attempt number, and excerpt.

**Container config isolation (US2)**

- **FR-014**: When the container runs with the operator's host login, the orchestrator's sessions MUST NOT read the operator's live host CLI config file. Writes to that file made by host processes MUST NOT be observable mid-write by an orchestrator session.
- **FR-015**: Orchestrator sessions in that mode MUST keep the authentication and per-project trust/settings they had before this change, without extra operator steps.
- **FR-016**: If the host config the runtime derives its own copy from is unreadable or invalid at container start, startup MUST fail loudly, naming the file and the problem.
- **FR-017**: Writes made inside the container by orchestrator sessions MUST NOT corrupt or race the operator's host CLI config file.
- **FR-018**: Container modes that do not use the host login MUST be unaffected.
- **FR-019**: The container documentation MUST describe the isolation, including that host-side login or trust changes made after container start need a container restart to take effect. The host-login container smoke check MUST verify the isolation.

### Key Entities

- **Phase attempt (startup failure)**: one phase-attempt record whose outcome says the session failed to start or ended without a result. It carries the phase, the attempt number, a bounded CLI error excerpt, and zero spend.
- **Container CLI config**: the CLI configuration the orchestrator's sessions read inside the container. When the container uses host login, it is derived from the host's config but is a separate copy. It holds authentication state and per-project trust/settings.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A session that dies at startup ends its phase attempt within 30 seconds in 100% of cases, compared with the full phase deadline (about 50 minutes) in the incident.
- **SC-002**: After a startup failure, an operator can tell from any one operator surface, without reading container logs, that the session failed to start and what the CLI reported.
- **SC-003**: A transient startup failure (one bad attempt followed by a good one) costs the feature at most one extra session start and does not fail the feature.
- **SC-004**: After a startup failure, the run is never in a state where resume, supersession, or drain must wait for a session deadline. Each acts within 30 seconds.
- **SC-005**: In a stress check with the host config rewritten continuously while 50 consecutive orchestrator sessions start in a host-login container, 0 sessions fail on a corrupted config.
- **SC-006**: Every session-driving site (whole phase, implement chunk, auto-remediation, remediation) passes the same startup-failure acceptance check.
- **SC-007**: Runs with no startup failure behave the same as before: same phase outcomes, spend, and operator output.

## Assumptions

- The host-login container mode (the opt-in mode that brings the operator's host CLI login into the container) is the only container mode that shares the host's live CLI config file. Token-based modes are unaffected.
- Authentication and per-project trust carried in the host config at container start are enough for a whole container session. Picking up later host-side changes needs a restart, which is acceptable and documented.
- "Within seconds" is bounded at 30 seconds, to tolerate process-exit detection and cleanup. Typical detection is expected to be much faster.
- Retry-once matches the existing retry budget for session-level failures. No new retry configuration knob is introduced.
- The startup-failure and ended-without-result reasons are new failure reasons on the existing `failed` terminal. No new lifecycle status is introduced.
- Out of scope: changing the deadline mechanism, the drain-don't-kill discipline, and the clarify/analyze gates.
