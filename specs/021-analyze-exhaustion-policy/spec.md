# Feature Specification: Auto-Remediation Exhaustion Policy

**Feature Branch**: `021-analyze-exhaustion-policy`

**Created**: 2026-07-31

**Status**: Draft

**Input**: User description: "When the auto remediation attempts exhausted, it must read a configuuration by run indicating if it can proceed to the next phase or stops and escalate."

## Clarifications

### Session 2026-07-31

- Q: What is the default exhaustion policy for a run that does not choose one? → A: *escalate* — today's behaviour. A run that says nothing keeps the human-facing handoff; *proceed* is an explicit, recorded per-run opt-in.
- Q: Under *proceed*, what happens to the residual findings the loop could not fix? → A: Recorded only. They are captured in the feature's record and surfaced to the operator; no downstream phase's input changes, so the advance is byte-identical to a clean-analyze advance apart from the record itself.
- Q: How is a feature that advanced under *proceed* represented in the feature lifecycle? → A: As an annotation, not a status. The terminal status stays `done`; the advanced-with-unresolved-findings fact is a recorded annotation surfaced in the report and console, so no existing consumer of the feature status enum changes.
- Q: Where must the unresolved findings surface for the human who eventually reviews the work? → A: In the orchestrator's own surfaces (console, run report, stored records) **and** in the feature's pull request body — *proceed* removes the escalation, so PR review is the last remaining human gate and the findings must reach it.
- Q: How is the Principle V amendment handled? → A: In scope for this feature, as a MAJOR bump (2.2.0 → 3.0.0) with a Sync Impact Report. An unconditional human-facing terminal state becomes configurable away — the same shape as the 2.0.0 bump — and the constitution lands with the code, not before or after it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Let an unattended run finish despite a stubborn finding (Priority: P1)

An operator launches a long unattended backlog run overnight and accepts that
some analyze findings will not be mechanically fixable. They launch the run with
the exhaustion policy set to *proceed*. A feature reaches analyze, reports a High
finding, burns all its remediation attempts without clearing it, and — instead of
stopping for a human — continues to the next phase and on through the rest of the
pipeline. In the morning the operator sees the feature completed, plus a clearly
marked record that it advanced with an unresolved High finding and what that
finding was.

**Why this priority**: This is the whole feature. Today an exhausted loop always
hands the feature to a human, which means one stubborn finding stops a backlog
run cold and wastes the hours that remain in an unattended window. Letting the
operator declare up front that they would rather have the work land and review
the findings afterwards is what makes a long unattended run finish. It is
independently shippable: the *escalate* side of the policy is exactly today's
behaviour, so shipping only the *proceed* path plus its record delivers the whole
value.

**Independent Test**: Launch a run with the policy set to *proceed* against a
feature whose analyze phase reports the same High finding on every pass. Verify
remediation is attempted exactly the configured number of times, that the feature
then advances to the phase after analyze rather than escalating, that it reaches
`done` without operator input, and that the unresolved finding is recorded and
surfaced against that feature.

**Acceptance Scenarios**:

1. **Given** a run whose exhaustion policy is *proceed*, **When** the attempt
   limit is reached with a High finding still present and no Critical finding,
   **Then** the feature advances to the next phase and continues through the
   pipeline exactly as an initially clean analyze would — no downstream phase
   receives the residual findings as input.
2. **Given** a feature that advanced under the *proceed* policy, **When** the
   operator reviews the run, **Then** the feature is visibly distinguished from
   one whose analyze was clean, naming the unresolved findings it advanced past
   and the exhausted attempts that preceded them.
3. **Given** a run whose exhaustion policy is *proceed*, **When** the attempt
   limit is reached with a Critical finding present, **Then** the feature halts
   for a human exactly as it does today — the policy MUST NOT apply to Critical.
4. **Given** a run whose exhaustion policy is *proceed*, **When** analyze clears
   on a remediation attempt before the limit is reached, **Then** the policy
   never applies and the feature advances with no record of unresolved findings.

---

### User Story 2 - Keep today's fail-fast handoff by default (Priority: P2)

An operator who has not thought about this setting, or who wants a human to see
every finding the loop could not fix, launches a run without touching it. The
exhaustion policy defaults to *escalate*, and every exhaustion outcome is
byte-for-byte what it is today: halted on Critical, escalated on High when the
run's threshold is High or lower, advancing when every residual finding is below
the threshold, each with a reason naming exhausted auto-remediation.

**Why this priority**: Silently turning a quality gate into an automatic pass is
the failure mode this feature is most likely to cause. The default must be the
conservative one, and the *escalate* path must be provably unchanged, before the
*proceed* path is safe to offer. It is P2 rather than P1 only because it is
today's behaviour — nothing new ships to deliver it, but it must be pinned by
tests that fail if the new path leaks into the default.

**Independent Test**: Launch a run specifying nothing and one specifying
*escalate* explicitly, both against a feature reporting a persistent High
finding. Verify both escalate with the exhausted-auto-remediation reason, that
the worktree is retained, and that the outcome is identical to a run of the same
feature before this feature existed.

**Acceptance Scenarios**:

1. **Given** a run launched without specifying the exhaustion policy, **When**
   attempts are exhausted with a High finding present, **Then** the feature
   escalates with the exhausted-auto-remediation reason — the default is
   *escalate*.
2. **Given** a run whose exhaustion policy is *escalate*, **When** attempts are
   exhausted with residual findings entirely below the run's severity threshold,
   **Then** the feature advances, unchanged from today — the policy adds no stop
   where the gate never had one.
3. **Given** a run launched with auto-remediation disabled, **When** analyze
   reports a finding of any severity, **Then** the exhaustion policy is inert and
   behaviour is indistinguishable from before this feature existed, whatever the
   policy is set to.
4. **Given** a run launched with the policy set to *proceed*, **When** a
   subsequent run is launched without specifying it, **Then** that run's policy
   is *escalate* — the previous run's choice did not become the new default.

---

### User Story 3 - Choose the policy at launch and see it on the run (Priority: P3)

The operator picks the exhaustion policy in the console's launch form, alongside
the three auto-remediation controls that are already there (on/off, threshold,
attempt limit). It is pre-filled with the default, an unrecognized value is
rejected before the run starts, and once the run is under way the chosen policy
is visible on the run so a reviewer can tell why a feature advanced past a
finding without having to reconstruct the launch.

**Why this priority**: The setting is usable from configuration alone, and the
default covers most runs; the launch control and the run-level display are what
make it a per-run decision in practice rather than a deployment-wide one.

**Independent Test**: Open the launch form, confirm the policy control shows the
default; launch with *proceed*, confirm the run's own recorded settings show
*proceed* and the console displays it; attempt to launch with an unrecognized
value and confirm the form names the bad setting and starts no run.

**Acceptance Scenarios**:

1. **Given** the operator opens the launch form having changed nothing, **When**
   they read the exhaustion-policy control, **Then** it shows *escalate*, and
   launching without touching it produces a run with that policy.
2. **Given** an unrecognized exhaustion policy value, **When** the run is
   launched, **Then** it is rejected with a message naming the bad setting, and
   no run starts and no default is silently substituted.
3. **Given** a run in progress, **When** an operator changes the exhaustion
   policy setting, **Then** the in-progress run is unaffected and the change
   applies only to runs launched afterward.
4. **Given** a run under way, **When** an operator inspects it, **Then** the
   policy that run was launched with is visible alongside its other
   auto-remediation settings.

---

### Edge Cases

- **Critical is never covered by the policy.** Whatever the policy, an exhausted
  loop whose final analyze run contains a Critical finding halts. *Proceed* is
  therefore entirely inert on a run whose severity threshold is Critical, since
  the only findings the loop acts on there are Critical ones.
- **A remediation attempt itself fails.** That is a failure path, not an
  exhaustion — the loop already stops immediately and the feature reaches a
  terminal state naming the remediation failure. The policy does not apply, and
  *proceed* MUST NOT convert a failed step into an advance.
- **The cost breaker trips mid-loop.** The feature halts between phases under the
  existing drain-don't-kill rule. The policy does not apply; *proceed* MUST NOT
  keep a run going past a tripped breaker.
- **The attempt limit is reached but analyze is clean.** No unresolved findings
  exist, so the policy never applies and nothing is recorded as
  advanced-with-findings.
- **Analyze output is unreadable.** Unchanged: a failed analyze phase, never a
  loop entry, and never a policy decision.
- **Residual findings are entirely below the threshold.** The gate already
  advances. The policy changes nothing, and the advance MUST NOT be marked as
  advanced-with-unresolved-findings — that mark is reserved for advancing past
  findings the gate would otherwise have diverted.
- **A feature that advanced under *proceed* is later resumed or resolved by a
  human.** The attempt budget is fresh for that new run, as it is today, and the
  new run's own policy applies.
- **The downstream phase fails because of the very finding that was not fixed.**
  That is an ordinary phase failure with its ordinary terminal state; the policy
  makes no promise that the work will succeed, only that the pipeline is allowed
  to try.
- **Concurrent features.** The policy is a run-level setting applied identically
  to every feature in the run; one feature advancing under it has no effect on
  another.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST expose a per-run **exhaustion policy** with exactly
  two values — *escalate* and *proceed* — read when the auto-remediation attempt
  limit is reached with findings still at or above the run's severity threshold.
- **FR-002**: The system MUST default the exhaustion policy to *escalate*, so a
  run that does not choose one behaves exactly as it does today.
- **FR-003**: Under the *escalate* policy, the system MUST decide the exhaustion
  outcome exactly as it does today: halted on a Critical finding, escalated on a
  High finding when the run's severity threshold is High or lower, advancing when
  every residual finding is below the threshold, each with a reason naming
  exhausted auto-remediation.
- **FR-004**: Under the *proceed* policy, the system MUST advance the feature to
  the phase after analyze, and let the pipeline continue normally to its terminal
  state, when the final analyze run's residual findings are at or above the
  threshold and none of them is Critical.
- **FR-004a**: Advancing under *proceed* MUST NOT alter the input of any
  downstream phase. The residual findings are recorded and surfaced, never fed
  forward as context or corrective instruction, so every phase after analyze runs
  byte-identically to how it would run after a clean analyze.
- **FR-005**: The system MUST halt on a Critical finding regardless of the
  exhaustion policy. No value of the policy may pass a Critical finding through
  unattended.
- **FR-006**: The exhaustion policy MUST apply only at attempt exhaustion. It
  MUST NOT change the outcome of a remediation step that failed to run, of a
  tripped cost breaker, of a failed or unparseable analyze phase, or of any gate
  decision reached before the attempt limit was consumed.
- **FR-007**: When a feature advances under the *proceed* policy, the system MUST
  record that it advanced with unresolved findings, together with the residual
  findings verbatim and the number of attempts consumed, and MUST make that
  record available to an operator reviewing the run.
- **FR-008**: A feature that advanced under the *proceed* policy MUST be visibly
  distinguishable, in the operator surface and in the run's final report, from a
  feature whose analyze was clean — reaching the same terminal state MUST NOT
  make the two indistinguishable.
- **FR-008a**: The system MUST NOT introduce a new terminal lifecycle status for
  this case. A feature that advanced under *proceed* reaches the terminal status
  its remaining phases produce — normally `done` — and carries the
  advanced-with-unresolved-findings fact as a recorded annotation, so no existing
  consumer of the feature status changes.
- **FR-008b**: When a feature that advanced under *proceed* produces a pull
  request, that pull request's body MUST name the residual findings it advanced
  past and the policy that permitted it, so the reviewer — the last remaining
  human gate for that feature — sees them without leaving the review.
- **FR-009**: The system MUST NOT mark a feature as
  advanced-with-unresolved-findings when the gate would have advanced anyway —
  that is, when every residual finding is below the run's severity threshold.
- **FR-010**: The system MUST accept the exhaustion policy only as one of the two
  recognized values, and MUST reject a run at launch when it is anything else,
  rather than silently substituting the default.
- **FR-011**: The system MUST fix the exhaustion policy for the run's whole
  lifetime, apply it uniformly to every feature in the run, and MUST NOT allow it
  to change once the run has started.
- **FR-012**: A run's exhaustion policy MUST NOT leak into any later run — a run
  launched with *proceed* MUST NOT change the default for the next launch.
- **FR-013**: The system MUST present the exhaustion policy as a control in the
  operator console's launch form, pre-filled from the configured default,
  alongside the existing auto-remediation controls, and MUST reject an
  unrecognized value in the form before the run starts, naming the wrong setting.
- **FR-014**: The system MUST capture the chosen exhaustion policy into the run's
  own recorded settings and display it on the run, so a reviewer can tell which
  policy produced a given outcome.
- **FR-015**: When auto-remediation is disabled for a run, the exhaustion policy
  MUST have no observable effect whatsoever — no behaviour change, no added
  spend, no added record — for either of its values.
- **FR-016**: This feature MUST deliver the governing-document amendment that
  permits an exhausted loop to advance past a non-Critical residual finding,
  replacing the current unconditional "on exhaustion the gate decides the outcome
  under the rules above, unchanged" guarantee, and MUST record the amendment
  through the project's established amendment procedure — a Sync Impact Report
  plus a MAJOR version bump (2.2.0 → 3.0.0), since a previously unconditional
  human-facing terminal state becomes configurable away. The amendment MUST
  preserve the unconditional Critical halt and MUST NOT weaken any other quality
  gate, and MUST land together with the behaviour it permits.

### Key Entities

- **Exhaustion policy**: A per-run setting with two values — *escalate*
  (default) and *proceed* — read only when the auto-remediation attempt limit is
  reached with residual findings at or above the run's severity threshold. Fixed
  for the run's lifetime, uniform across its features, captured into the run's
  own recorded settings, and never carried into a later run.
- **Advanced-with-unresolved-findings record**: The record produced when the
  *proceed* policy sends a feature onward past findings the gate would otherwise
  have diverted. Carries the residual findings verbatim, their severities, the
  attempts consumed, and the policy that produced the advance. Surfaced in three
  places: the run's stored records, the operator console and final report, and
  the feature's pull request body.
- **Auto-remediation run settings**: The existing per-run knobs — on/off,
  severity threshold, attempt limit, model override — which the exhaustion policy
  joins as a fourth operator-chosen value with the same lifetime and leak-free
  rules.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a backlog whose analyze findings are not mechanically fixable, a
  run launched with *proceed* completes every feature that would previously have
  stopped for a human, except those with Critical findings, with no operator
  input.
- **SC-002**: A run launched with *escalate*, or launched without choosing a
  policy, produces outcomes identical to the same run before this feature
  existed — every terminal state, reason, and retained worktree unchanged.
- **SC-003**: Across every run, no feature with a Critical finding in its final
  analyze run ever advances past the analyze gate, at any policy and any
  threshold.
- **SC-004**: Every feature that advanced under *proceed* is identifiable in the
  run's final report, with its unresolved findings readable without opening raw
  transcripts.
- **SC-005**: An operator can choose the policy at launch and observe the
  corresponding change in behaviour on the next run, without editing
  configuration files or restarting anything, and the choice does not alter the
  default offered on the following launch.
- **SC-006**: The policy adds no spend and no latency to any feature that does
  not exhaust its remediation attempts.
- **SC-007**: A run launched with an unrecognized policy value never starts, and
  the message names the offending setting.
- **SC-008**: Every pull request produced by a feature that advanced under
  *proceed* names the residual findings in its body, so a reviewer who opens only
  the pull request still learns what analyze flagged.

## Assumptions

- **"Proceed to the next phase" means the pipeline continues normally**, not that
  it advances one phase and then stops. Once the gate advances the feature, the
  remaining phases run exactly as they would after a clean analyze, and the
  feature reaches whatever terminal state that produces.
- **The default is *escalate*, i.e. today's behaviour** (confirmed in
  Clarifications). The project's established pattern is that a new per-run knob
  defaults to the pre-existing behaviour so an unspecified run is never silently
  relaxed (feature 017, FR-010/FR-010c).
- **The policy is a single run-level choice, not per-severity or per-feature.**
  It follows the shape of the three auto-remediation knobs it joins: chosen at
  launch, captured into the run's settings, uniform for the run's lifetime.
- **The policy is observable in exactly one cell of the exhaustion matrix** — a
  residual High finding with no Critical finding, on a run whose severity
  threshold is High or lower. Below-threshold residuals already advance and
  Critical always halts, so *proceed* narrows to precisely the case the gate
  would have escalated. This is what keeps the relaxation bounded.
- **No new terminal status is introduced** (confirmed in Clarifications, FR-008a).
  A feature that advances under *proceed* reaches the ordinary terminal state its
  remaining phases produce (normally `done`); the "advanced with unresolved
  findings" fact is carried as a recorded annotation on the feature. Adding a
  status would ripple through every consumer of the feature lifecycle for a fact
  that is an attribute of one gate decision, not a new outcome of a run.
- **The residual findings are recorded, never fed forward** (confirmed in
  Clarifications, FR-004a). *Proceed* is a gate decision only: the pipeline after
  analyze is byte-identical to a clean-analyze advance. The feature deliberately
  does not try to get the findings fixed downstream — it accepts them and makes
  sure a human sees them.
- **The amendment this needs is a MAJOR bump** (confirmed in Clarifications,
  FR-016), by the precedent set when the gate became threshold-governed: a
  previously unconditional human-facing terminal state (escalate on exhaustion
  with a High finding) becomes configurable away. It is a deliberate, recorded
  relaxation of a governance bound, not an expansion of one.
- **PR review is the compensating control for *proceed*** (FR-008b). Because the
  policy removes the escalation, the pull request body is the one place a human
  is still guaranteed to look, so the residual findings must appear there. This
  assumes the run opens a pull request for the feature; a run configured
  otherwise still gets the orchestrator-side surfaces of FR-007 and FR-008.
- **Console work is in scope, bounded to the launch-form control and the
  run-level display of the chosen policy** (FR-013, FR-014), plus the marking of
  advanced-with-findings features required by FR-008. The console remains an
  operator surface over run state, not a second source of truth.
- **Configuration follows the project's existing run-configuration pattern** — a
  default in configuration, overridable at launch, captured into the run's own
  recorded settings, validated at launch with no clamping or substitution, and no
  new persistence mechanism.
- **Everything about the loop itself is unchanged** — when it runs, what it feeds
  the corrective step, the attempt limit and its bounds, per-attempt recording,
  cost accounting, and the breaker's precedence. This feature changes only what
  happens at the moment the limit is reached.
