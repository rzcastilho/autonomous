# Feature Specification: Analyze Auto-Remediation Loop

**Feature Branch**: `017-analyze-auto-remediation`

**Created**: 2026-07-26

**Status**: Draft

**Input**: User description: "Run auto-remediation for analyze phase until we have findings equals or worst the configured, default is high"

## Clarifications

### Session 2026-07-26

- Q: Is a Critical finding auto-remediated when the threshold is High, given the constitution requires the analyze gate to halt on Critical? → A: Yes — the threshold is a floor over the ordered severity vocabulary Low < Medium < High < Critical. Threshold High remediates High and Critical; threshold Medium remediates Medium, High, and Critical; threshold Critical remediates Critical only.
- Q: Does this feature carry the constitution amendment that Principle V needs, or assume it lands separately? → A: In scope — this feature amends Principle V (MINOR bump, Sync Impact Report) to permit bounded pre-gate auto-remediation and to state the halt-on-exhaustion guarantee that replaces the immediate halt.
- Q: What is the remediation attempt limit? → A: Configured per run, minimum 1, maximum 5, default 2. Disabling the loop is a separate off-switch, not a limit of zero.
- Q: How are repeated analyze runs and remediation attempts recorded, given per-phase artifacts are named by phase? → A: Every analyze run and every remediation attempt gets its own attempt-numbered record; nothing is overwritten. The checkpoint continues to record the phase, carrying the attempt count as metadata.
- Q: Which model runs the auto-remediation step, and how is its spend estimated when actuals are unavailable? → A: It inherits the analyze phase's model by default (overridable per run), matching the existing operator remediation path; and it gets its own cost estimate so fallback accounting is never zero.
- Q: Is auto-remediation itself switchable, and at what scope? → A: Yes — a per-run on/off setting, defaulting to on. A run is launched either with or without auto-remediation; the setting applies to the whole run and every feature in it.
- Q: Where does an operator choose the on/off setting, threshold, and attempt limit at launch? → A: All three appear as controls in the operator console's launch form, pre-filled from the configured defaults, alongside the existing launch controls. Console work is in scope for this feature.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Self-heal an analyze finding without waking a human (Priority: P1)

A feature reaches the analyze phase unattended. Analyze reports one or more
findings whose severity is at or above the configured severity threshold
(default: High) — for example "tasks.md does not cover requirement FR-004" or
"plan.md contradicts the spec's data model". Instead of immediately stopping the
feature for a human, the orchestrator feeds those findings back as a corrective
instruction, lets the working agent fix the artifacts in the feature's own
worktree, and re-runs analyze. When the re-run comes back with nothing at or
above the threshold, the feature continues to implement as normal, and the
operator sees only a completed feature plus a record of what was self-healed.

**Why this priority**: This is the entire value of the feature. Today the most
common analyze outcome on an unattended run is a High finding about an
incomplete plan or tasks file — mechanically fixable, but it stops the feature
dead and burns an operator's attention. Making that self-healing is what turns a
supervised run into an autonomous one. It is independently shippable: even with
no configurability and a fixed attempt limit, it delivers the whole benefit.

**Independent Test**: Run a feature whose analyze phase is primed to report a
single High finding on the first pass and none on the second. Verify the feature
reaches a `done` terminal state without operator input, that a remediation step
ran between the two analyze runs, and that the final recorded analyze outcome is
the clean one.

**Acceptance Scenarios**:

1. **Given** analyze reports findings whose highest severity is at or above the
   threshold, **When** the analyze gate is evaluated, **Then** the system runs a
   remediation attempt carrying those findings and re-runs analyze, instead of
   diverting the feature to a human.
2. **Given** a re-run of analyze reports no findings at or above the threshold,
   **When** the gate is evaluated, **Then** the feature advances to the next
   phase exactly as an initially clean analyze would.
3. **Given** analyze reports only findings below the threshold (e.g. Medium and
   Low with a High threshold), **When** the gate is evaluated, **Then** no
   remediation runs and the feature advances immediately — behavior is
   unchanged from today.
4. **Given** a feature that self-healed, **When** the operator reviews the run,
   **Then** each remediation attempt and each analyze re-run is individually
   visible with its findings, so the self-healing is auditable rather than
   silent.

---

### User Story 2 - Give up safely and hand the human a full history (Priority: P2)

Some findings are not mechanically fixable — a genuine constitution violation, a
contradiction that needs a product decision, or a finding the working agent
simply cannot resolve. After a bounded number of remediation attempts the
orchestrator stops trying, hands the feature to a human exactly as it does
today, and attaches the full attempt history so the human starts from the
current state rather than the original one.

**Why this priority**: Without a hard stop, auto-remediation is an unbounded
spend loop and a way to launder a real quality gate into an automatic pass. This
is what makes the P1 loop safe to enable, but P1 has standalone value with a
fixed built-in limit, so this is P2.

**Independent Test**: Run a feature whose analyze phase reports the same
at-or-above-threshold finding on every pass. Verify remediation is attempted
exactly the configured number of times, that the feature then reaches the same
human-facing terminal state it would have reached with the feature disabled, and
that the worktree is retained with every attempt's record.

**Acceptance Scenarios**:

1. **Given** the attempt limit is N, **When** analyze still reports
   at-or-above-threshold findings after the Nth remediation attempt, **Then** the
   gate decides the outcome from the final findings under its existing rules —
   halted for Critical, escalated for High — with a reason that states the limit
   was exhausted.
2. **Given** a remediation attempt itself fails to run to completion, **When**
   the failure is observed, **Then** the loop stops immediately rather than
   consuming the remaining attempts, and the feature reaches a terminal state
   naming the remediation failure.
3. **Given** the cost circuit breaker trips during the loop, **When** the current
   step finishes, **Then** no further remediation attempt or analyze re-run
   starts and the feature halts between phases — the existing drain-don't-kill
   rule wins over the loop.
4. **Given** a feature that exhausted its attempts and was handed to a human,
   **When** the human inspects it, **Then** every attempt's corrective
   instruction and resulting findings are available, and the artifacts on the
   branch reflect the last attempt's edits.
5. **Given** a feature the human has already been handed, **When** the human
   resumes or resolves it, **Then** the attempt budget is fresh for that new run
   — an exhausted budget never permanently disqualifies a feature.

---

### User Story 3 - Launch a run with or without auto-remediation (Priority: P3)

An operator decides, per run, whether self-healing happens at all and how
aggressive it is. Auto-remediation is on by default; the operator can launch a
run with it off to get today's fail-fast behavior back unchanged. When it is on,
they set the severity threshold at which remediation kicks in (default High, so
High and Critical both trigger it) and the maximum number of attempts per
feature. All three settings are chosen at launch, apply to every feature in that
run, and do not carry over to the next run.

**Why this priority**: Useful, but the default configuration is the one almost
every run will use. The loop delivers its value with defaults alone.

**Independent Test**: Launch three runs against the same feature reporting a
High finding — one with auto-remediation off, one on with threshold Critical,
one on with threshold High. Verify the finding escalates untouched, **advances
untouched** (High is below the Critical threshold, so the gate does not divert
it either), and is remediated, respectively; then launch a fourth run
specifying nothing and verify it defaults to on.

**Acceptance Scenarios**:

1. **Given** no explicit configuration, **When** a run starts, **Then**
   auto-remediation is on, the threshold is High, and the attempt limit is 2.
2. **Given** the threshold is set to Critical, **When** analyze reports a High
   finding and no Critical one, **Then** no remediation runs and the feature
   **advances to the next phase** — the threshold governs the gate as well as
   the loop, so a finding below it is neither remediated nor human-facing
   (amended Constitution Principle V, 2.0.0).
3. **Given** a run launched with auto-remediation off, **When** analyze reports
   a finding of any severity, **Then** the feature's behavior is
   indistinguishable from the behavior before this feature existed.
4. **Given** an unrecognized threshold, or an attempt limit outside 1 to 5,
   **When** the run is launched, **Then** the run is rejected at launch with a
   message naming the bad setting — it does not start and silently fall back to
   a default or clamp to the nearest bound.
5. **Given** the threshold is set to Medium, **When** analyze reports a Medium
   finding, **Then** remediation runs — a severity that carries no behavior at
   all today.
6. **Given** a run launched with auto-remediation off, **When** a subsequent run
   is launched without specifying the setting, **Then** that run has
   auto-remediation on — the previous run's choice did not become the new
   default.
7. **Given** a run in progress, **When** an operator changes the
   auto-remediation settings, **Then** the in-progress run is unaffected and the
   change applies only to runs launched afterward.
8. **Given** the operator opens the launch form, **When** they have changed
   nothing, **Then** the three controls show the configured defaults —
   auto-remediation on, threshold High, attempt limit 2 — and launching without
   touching them produces a run with exactly those settings.
9. **Given** the operator enters an attempt limit outside 1 to 5 in the launch
   form, **When** they attempt to launch, **Then** the form tells them which
   setting is wrong and no run starts.

---

### Edge Cases

- **Analyze output is unreadable.** A malformed or absent findings report is a
  failed analyze phase today, not a pass. It stays a failure and does not enter
  the remediation loop — there is nothing to remediate against.
- **Findings get worse.** A remediation attempt introduces a Critical finding
  where there was only a High one. The loop continues under the same attempt
  budget; the terminal state on exhaustion is decided by the findings from the
  final analyze run, not the first.
- **Findings churn without converging.** Each attempt clears one finding and
  introduces another. The attempt limit is what stops this, regardless of
  whether the finding set changes between attempts.
- **Zero findings but the report is stale.** Only the most recent analyze run
  decides the gate; earlier runs never contribute to the decision.
- **A remediation attempt makes no change at all.** The attempt still counts
  against the budget; the loop does not treat a no-op as a retryable transient.
- **The run's overall budget is nearly exhausted.** The loop respects the
  existing cost breaker and reservation rules; it never gets a private budget
  exemption.
- **Concurrent features.** Each feature carries its own independent attempt
  budget; one feature exhausting its budget has no effect on another.
- **A threshold below High exhausts its attempts.** With the threshold at
  Medium and only Medium findings remaining after the last attempt, the feature
  advances — a best-effort cleanup that failed does not invent a stop that the
  gate never had (FR-006).
- **The feature was resumed at analyze by a human with a correction note.** The
  human's own pre-phase correction step runs first, as it does today, and the
  auto-remediation loop then applies to the analyze run that follows.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST compare the highest severity present in an analyze
  run's findings against a configured severity threshold, and treat findings at
  or above that threshold as remediable rather than immediately human-facing.
- **FR-001a**: The system MUST recognize exactly four ordered finding
  severities — Low < Medium < High < Critical — and MUST treat the threshold as
  an inclusive floor over that ordering: threshold High matches High and
  Critical; threshold Medium matches Medium, High, and Critical; threshold
  Critical matches Critical only; threshold Low matches every finding.
- **FR-002**: The system MUST default the severity threshold to High, so that
  both High and Critical findings trigger remediation by default.
- **FR-003**: When an analyze run produces at-or-above-threshold findings and
  attempts remain, the system MUST run a remediation step that is given those
  findings, and then MUST re-run analyze, repeating until either no
  at-or-above-threshold findings remain or the attempt limit is reached.
- **FR-004**: The system MUST enforce a per-feature maximum number of remediation
  attempts, configured per run, defaulting to 2, and MUST never exceed it within
  a single feature run.
- **FR-004a**: The system MUST accept an attempt limit only in the inclusive
  range 1 to 5. A limit of zero is not a way to disable the loop — FR-010's
  off-switch is the only way to do that.
- **FR-005**: The system MUST decide the analyze gate outcome from the most
  recent analyze run only.
- **FR-006**: When the attempt limit is reached with at-or-above-threshold
  findings still present, the system MUST hand the feature to the gate unchanged
  and let the gate's rules decide the outcome — halted for a Critical finding,
  escalated for a High one **when the threshold is High or lower**, and
  advancing when every remaining finding is below the threshold — and MUST
  record a reason that identifies exhausted auto-remediation as the cause.
  Lowering the threshold below High MUST NOT create a new human-facing terminal
  state for a severity that has none today.
- **FR-006a**: The configured severity threshold MUST govern the analyze gate
  as well as the remediation loop: a finding below the threshold is neither
  remediated nor diverted to a human, and the feature advances. A Critical
  finding is the one exception — it outranks every threshold and MUST halt
  unconditionally, so no configuration can pass a constitution violation
  through unattended (amended Constitution Principle V, 2.0.0).
- **FR-007**: The system MUST NOT run any remediation attempt after a feature has
  been diverted to a human, so a human-facing gate decision is never
  automatically retried.
- **FR-008**: The system MUST stop the loop immediately if a remediation attempt
  or an analyze re-run fails to complete, and MUST place the feature in a
  terminal state naming that failure rather than consuming remaining attempts.
- **FR-009**: The system MUST subject every remediation attempt and analyze
  re-run to the existing cost accounting and circuit breaker, MUST count their
  spend toward the run budget, and MUST stop starting new loop steps once the
  breaker has tripped, allowing the in-flight step to finish.
- **FR-009a**: The system MUST run each auto-remediation step on the analyze
  phase's configured model by default, and MUST let an operator override that
  model per run. The model override is a configuration-level setting, not one of
  the three launch-form controls in FR-010d — the common case does not touch it.
- **FR-009b**: The system MUST carry a cost estimate dedicated to the
  auto-remediation step, so that an attempt whose actual spend is not reported
  still contributes a non-zero amount to the run's accounting.
- **FR-010**: The system MUST expose auto-remediation as a per-run on/off
  setting that defaults to on, so an operator launches a run either with or
  without it. When off, analyze gate behavior MUST be identical to the behavior
  before this feature — no remediation step, no analyze re-run, no added spend.
- **FR-010a**: The system MUST allow an operator to configure the severity
  threshold and the attempt limit per run, alongside the on/off setting.
- **FR-010d**: The system MUST present all three settings as controls in the
  operator console's launch form, pre-filled from the configured defaults, so a
  run can be launched with or without auto-remediation without editing
  configuration or restarting.
- **FR-010e**: The launch form MUST reject an out-of-range attempt limit or an
  unrecognized threshold before the run starts, showing the operator which
  setting is wrong rather than failing after launch.
- **FR-010f**: Choosing settings in the launch form MUST NOT alter the defaults
  shown on the next launch — the form is how one run is configured, not how the
  defaults are edited (FR-010c).
- **FR-010b**: The on/off setting, the threshold, and the attempt limit MUST
  apply uniformly to every feature in the run for that run's whole lifetime, and
  MUST NOT be changeable once the run has started.
- **FR-010c**: A run's auto-remediation settings MUST NOT leak into any later
  run — a run launched with the loop off MUST NOT change the default for the
  next launch.
- **FR-011**: The system MUST reject a run at launch when the configured
  threshold is not one of the four recognized severities, or the attempt limit is
  not a whole number within 1 to 5, rather than silently substituting a default
  or clamping to the nearest bound.
- **FR-012**: The system MUST record, per attempt, the findings that triggered
  it, the corrective instruction given, the attempt's outcome, and its cost, and
  MUST make that history available to an operator reviewing the feature.
- **FR-012a**: The system MUST persist every analyze run and every remediation
  attempt as its own attempt-numbered record, and MUST NOT overwrite an earlier
  attempt's record with a later one — including for a feature that converges and
  is later cleaned up as `done`.
- **FR-012b**: The system MUST continue to record the pipeline position as the
  analyze phase, with the attempts consumed carried as metadata alongside it, so
  that resume and recovery behavior is unchanged by the presence of the loop.
- **FR-013**: The system MUST make an in-progress remediation loop observable
  while it runs, showing which attempt of how many is currently executing.
- **FR-014**: The system MUST confine all remediation edits to the feature's own
  worktree and branch, under the same containment rules as any other phase.
- **FR-015**: The system MUST reset the attempt budget for each new feature run,
  including a human-initiated resume or resolve of a previously exhausted
  feature.
- **FR-016**: The system MUST leave features whose analyze findings are all below
  the threshold — including features with no findings at all — unaffected, with
  no remediation step and no added latency.
- **FR-017**: This feature MUST deliver the governing-document amendment that
  permits bounded pre-gate auto-remediation, replacing the current
  "halt immediately on a Critical finding" rule with the halt-on-exhaustion
  guarantee of FR-006 and FR-007, and MUST record the amendment through the
  project's established amendment procedure (impact record plus version bump).
  The amendment MUST NOT weaken any other quality gate.

### Key Entities

- **Auto-remediation run settings**: The three per-run knobs chosen at launch in
  the operator console — on/off (default on), severity threshold (default High),
  attempt limit (default 2, range 1–5). Fixed for the run's lifetime, uniform
  across its features, recorded as part of the run's own settings, and never
  carried into a later run.
- **Severity threshold**: The configured minimum finding severity that makes an
  analyze result remediable, expressed as an inclusive floor over the ordered
  vocabulary Low < Medium < High < Critical. Defaults to High.
- **Remediation attempt**: One corrective step targeting a specific set of
  analyze findings. Carries the triggering findings, the instruction issued, an
  outcome, a cost, and its position in the attempt sequence.
- **Remediation loop state (per feature run)**: The attempts made so far, the
  attempt limit, and the most recent analyze result. Lives only for the duration
  of one feature run, and is surfaced as metadata on the recorded analyze
  position rather than as a pipeline position of its own.
- **Analyze result**: The existing per-run set of findings with severities, which
  now additionally drives the remediation decision, not only the gate decision.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a backlog whose analyze findings are mechanically fixable, at
  least 70% of features that would previously have stopped for a human instead
  reach completion with no operator input.
- **SC-002**: Operator interruptions caused by analyze findings drop by at least
  half across a full unattended backlog run, measured against the same backlog
  run with the loop disabled.
- **SC-003**: No feature ever performs more remediation attempts than its
  configured limit, across every run — verifiable from the recorded attempt
  history.
- **SC-004**: A feature whose findings are all below the threshold takes no more
  time and no more spend than it did before this feature existed.
- **SC-005**: Every feature handed to a human after exhausted remediation
  arrives with a complete attempt history, so a reviewer can see what was tried
  without re-reading raw transcripts.
- **SC-006**: Total run spend stays within the configured budget plus at most one
  outstanding reservation, unchanged by the presence of the loop.
- **SC-007**: An operator can turn auto-remediation off, or change the threshold
  or the attempt limit, and observe the corresponding change in behavior on the
  next run — choosing all three at launch, without editing configuration files
  or restarting anything.
- **SC-007a**: A run launched with auto-remediation off is byte-for-byte
  indistinguishable in behavior and spend from the same run before this feature
  existed, and leaves the next run's default untouched.
- **SC-008**: Every remediation attempt and analyze re-run contributes a
  non-zero amount to the run's recorded spend, including when the underlying
  tool reports no actual cost — no loop step is ever accounted as free.

## Assumptions

- **"Equals or worse than the configured" means at or above the threshold in the
  Low < Medium < High < Critical ordering** (FR-001a, confirmed in
  Clarifications). With the default of High, both High and Critical findings
  trigger remediation; Medium and Low do not.
- **Medium and Low are new to the acted-on vocabulary.** Today only Critical
  (and its synonym "blocker") and High carry behavior; Medium and Low findings
  are reported but never acted on. Making them selectable as thresholds turns
  the severity ordering into part of the contract rather than two special cases.
- **Critical findings are remediated before halting, not instead of halting.**
  The project's rule that a human-facing gate diversion must never be retried is
  preserved by running the loop strictly *before* the gate diverts (FR-007) and
  by preserving the identical terminal state on exhaustion (FR-006). Once a
  feature has been handed to a human, no automatic attempt follows. This is
  nonetheless a deliberate, bounded softening of Principle V's "the analyze gate
  MUST halt on a constitution Critical finding", so it requires a recorded
  amendment rather than a silent deviation — carried by this feature itself
  (FR-017), not deferred. An operator who wants the old fail-fast behavior
  disables the loop.
- **The attempt limit is a bounded per-run knob: 1 to 5, default 2**
  (confirmed in Clarifications). Two attempts cover the common "artifact
  incomplete" finding and the one partial fix that sometimes follows it, while
  capping worst-case added spend per feature at 2 remediation steps plus 2
  analyze re-runs. The upper bound of 5 exists so a misconfiguration cannot turn
  the loop into an unbounded spend sink.
- **The remediation step is a single corrective step with write access to the
  feature's worktree**, reusing the existing pre-phase remediation mechanism
  rather than re-running earlier pipeline phases. If a finding is best fixed by
  regenerating plan or tasks, the corrective instruction says so and the step
  does it in place. It also inherits that mechanism's model rule — the target
  phase's model, which for analyze means the analyze model (FR-009a) — so there
  is one routing rule for both the operator-driven and automatic paths.
- **Findings are passed to the remediation step verbatim**, including severity,
  title, and detail, so the corrective instruction is grounded in what analyze
  actually reported rather than a summary of it.
- **Configuration follows the project's existing run-configuration pattern** —
  the same shape as the run's other launch-time knobs (concurrency, budget,
  workflow mode): a default in configuration, overridable at launch, captured
  into the run's own recorded settings, with no new persistence mechanism.
- **A run's settings are captured, not consulted live.** Because the settings
  are fixed at launch (FR-010b) and must not leak forward (FR-010c), the run
  records its own chosen values rather than re-reading global configuration
  mid-run. This is the same failure mode the project already hit when a launch
  toggle wrote itself back into global state and silently became the next run's
  default.
- **Console work is in scope, bounded to the launch form and the loop's
  progress display** (FR-010d, FR-013). The console remains an operator surface
  over run state, not a second source of truth: it collects the three settings
  at launch and shows attempt progress while the loop runs, but the run's own
  recorded settings and per-attempt records stay authoritative.
- **Existing analyze artifact and parse rules are unchanged.** A missing artifact
  or an unparseable findings report remains a phase failure and never enters the
  loop.
- **The existing human pre-phase correction path (feature 013) is unchanged** and
  composes with this loop rather than being replaced by it.
