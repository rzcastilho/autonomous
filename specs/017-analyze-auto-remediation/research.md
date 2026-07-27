# Research: Analyze Auto-Remediation Loop

**Feature**: `017-analyze-auto-remediation` | **Date**: 2026-07-26 | **Phase**: 0

All Technical Context unknowns are resolved below. Each entry states the
decision, why, and what was rejected. Items marked **contested** are places
where two spec statements pull in different directions; the reading taken is
recorded so `/speckit-analyze` re-checks the decision rather than re-litigating
it.

---

## R1 — Where the loop lives: inside the analyze step, not around the gate

**Decision**: The loop is driven by a new edge module `AnalyzeRunner`, invoked
from `FeatureRunner.run_step/9` for `phase == :analyze` — exactly the way
`ChunkRunner` is invoked for `phase == :implement` (015). `AnalyzeRunner`
returns the `agent` shape `FeatureRunner` already expects, whose
`last_outcome`/`last_signals` come from the **final** analyze run. `Pipeline.next/3`
is not modified.

**Rationale**: FR-005 (only the most recent analyze run decides the gate),
FR-006 (hand the feature to the gate unchanged) and FR-007 (never remediate
after a human-facing diversion) are all *structural* if the loop finishes
before the transition table is consulted. Putting the loop above
`Pipeline.next/3` would require the gate to become re-entrant and would make
"never retried past the human" a behavioural promise instead of a shape.
Principle I also keeps `Pipeline` a side-effect-free decision surface — a loop
there would need to run phases.

**Alternatives rejected**:
- *Loop in `FeatureRunner.loop/10` around the `Pipeline.next/3` result* — makes
  the transition table re-entrant, and every future gate has to reason about
  whether it is being retried.
- *Loop inside the `RunFeaturePhase` action* — the 45-minute
  `jido_action` timeout and the per-phase telemetry span would then cover N
  sessions instead of one, exactly the failure 015/R3 documented.

---

## R2 — Severity is a new pure module, not two more booleans

**Decision**: New pure module `SpeckitOrchestrator.Severity` owning the ordered
vocabulary `:low < :medium < :high < :critical`, with `"blocker"` retained as a
case-insensitive synonym for `:critical`. `AnalyzeResult` gains
`max_severity/1` and `findings_at_or_above/2` built on it; the existing
`critical?`/`high?` booleans stay exactly as they are.

**Rationale**: FR-001a promotes the ordering itself into the contract (Medium
and Low have no behaviour today). A rank function is the smallest thing that
makes "at or above" total and testable, and keeping `critical?`/`high?`
untouched is what makes SC-007a ("off is indistinguishable from before")
mechanically checkable — the gate reads the same two fields it reads today.

**Alternatives rejected**: adding `medium?`/`low?` booleans (four booleans
cannot express an inclusive floor without the caller re-deriving the order);
comparing severity strings directly (no total order, and "blocker" breaks it).

---

## R3 — Unrecognized severity strings are below every threshold (**contested**)

**Decision**: A finding whose `severity` is absent or is a string outside
`low|medium|high|critical|blocker` ranks `:unknown` and matches **no**
threshold, including `:low`. It is counted and logged (a
`[:speckit, :remediation, :unknown_severity]`-style warn line in the feed), never
silently dropped from the record.

**Rationale**: FR-001a says "threshold Low matches every finding". Read
literally that includes a typo'd severity. But Principle II forbids inventing
data to paper over a malformed contract, and the two ways to honour the literal
reading are both worse: mapping unknown → `:critical` lets one model typo halt
a run; mapping unknown → `:low` makes a typo remediable only at the least-used
threshold, which is arbitrary. Today an unrecognized severity carries no
behaviour at all, so excluding it is also the choice that preserves SC-007a.
Read FR-001a as "every finding carrying a recognized severity".

**Follow-up**: this reading is stated in `contracts/severity.md` §3 and is the
one item `/speckit-analyze` should confirm against FR-001a.

---

## R4 — Settings are captured into `RunContext`, not read live

**Decision**: `RunContext` gains four fields — `auto_remediation` (boolean),
`auto_remediation_threshold` (string), `auto_remediation_attempt_limit`
(integer), `auto_remediation_model` (string or nil). They are captured by
`RunContext.capture/1` at `run/1` time from opts-or-`Config`, recorded into the
run manifest and every checkpoint, and threaded into `FeatureRunner.run/2`
alongside the six that already travel that path.

**Rationale**: FR-010b (fixed for the run's lifetime), FR-010c (never leaks
forward) and FR-010f (the form configures one run, not the defaults) are
exactly the failure mode `TriggerLive` already documents in prose: the
`pr_workflow` toggle used to mirror itself into app env and silently became the
next run's default. `RunContext` is the existing mechanism whose whole purpose
is "the run records its own shape"; adding a field costs one line in
`to_map/1`, `from_map/1` and `@keys`.

**Alternatives rejected**: a separate `RemediationSettings` struct threaded in
parallel (a second capture path with its own leak risk); reading `Config`
inside `AnalyzeRunner` (breaks FR-010b/c outright — a mid-run `Config` edit
would change an in-flight run).

**Storage shape**: the threshold is an **atom in config and in the pure
`Settings` struct, a string in `RunContext`**. `RunContext` is JSON-encoded into
the manifest and checkpoints, and `String.to_atom/1` on file-sourced content is
banned repo-wide (atom-table safety); `Settings.validate/1` normalizes either
form to an atom and is the only place the conversion happens.

---

## R5 — `auto_remediation_model`, not `remediation_model`

**Decision**: The per-run model override for the automatic step is named
`auto_remediation_model`. It is **not** the same knob as `resume/2`'s existing
`:remediation_model`.

**Rationale**: 013 already owns `:remediation_model` — the model for the
*operator-supplied* pre-phase correction step, a resume-only option. FR-009a's
override is a run-shaping setting for a different step that runs unattended.
Reusing the name would make one keyword mean two lifetimes. Resolution logic is
shared: both call `Config.remediation_model(:analyze, override)`, which already
defaults to the target phase's model and rejects an unknown alias loudly.

---

## R6 — A distinct cost tag `:auto_remediation`, and a config hole to close

**Decision**: The automatic step charges the ledger under the phase tag
`:auto_remediation` with its own entry in `:cost_estimates`. While confirming
this, a live defect surfaced: `config/config.exs` replaces the whole
`cost_estimates` map and **omits `:remediation`**, so `Config.cost_estimate(:remediation)`
returns `0.0` today — 013's operator remediation step is accounted as free
whenever the CLI reports no actual cost. Both keys are added.

**Rationale**: SC-008 requires every loop step to contribute a non-zero amount
even with no reported actual. `Cost.for_phase/2` already prefers actuals and
falls back to the per-phase estimate, so the only thing needed is an estimate
that exists. A distinct tag keeps the automatic and operator paths separately
accountable in the ledger and in telemetry.

**Values**: `auto_remediation: 1.26` (it runs on the analyze model and is a
comparable-size step, so it inherits analyze's recalibrated estimate);
`remediation: 0.95`, the pre-recalibration `0.30` scaled by the same 3.15x
factor every other estimate carries.

**Scope note**: the `:remediation` fix is adjacent to this feature, not
required by it. It is included deliberately (one line, same defect class as
SC-008) and called out here rather than smuggled in.

---

## R7 — A new action and a new signal, not an extension of `RunRemediation`

**Decision**: New action `Actions.RunAutoRemediation`, routed by a new
`"auto_remediation.run"` signal carrying `%{prompt: String.t(), model: String.t(), attempt: pos_integer()}`
in its data. `Actions.RunRemediation` (013) is untouched.

**Rationale**: The two steps differ in three ways — prompt provenance
(generated per attempt vs. read once from agent state), cost tag, and
telemetry. Extending `RunRemediation` with optional params would put a
per-attempt parameter path through the module that FR-010's off-switch promises
is *byte-identical to before this feature* when the loop is disabled. A separate
~70-line action that mirrors the existing fold shape is cheaper than proving
non-interference.

**Prompt construction**: `PhaseRequest.build_remediation/3` is reused unchanged
(same framing header, same `permission_mode: :accept_edits` + write/Bash tool
set, same worktree `cwd`) — the corrective instruction is built by a pure
`Remediation.instruction/2` from a versioned pack in
`priv/prompts/analyze_remediation.md` plus the findings **verbatim**, per the
spec's assumption. No new request builder, so FR-014 containment is inherited
rather than re-implemented.

---

## R8 — Extract `PhaseStep` rather than duplicate the retry/span/transcript trio

**Decision**: Move `FeatureRunner`'s private `run_phase/7` +
`run_phase_with_retry/8` into a new module `SpeckitOrchestrator.PhaseStep`,
parameterized by a transcript **label** (defaulting to the phase name).
`FeatureRunner` delegates; `AnalyzeRunner` reuses it for every analyze run in
the loop.

**Rationale**: The loop re-runs analyze N times and each run must keep the same
`[:speckit, :phase]` span, the same transient-retry policy
(`Config.phase_max_retries/0` + `PhaseResult.transient?/1`), and the same
durable transcript machinery — only the filename differs. Duplicating that in
`AnalyzeRunner` would fork the retry policy, which is precisely the kind of
"one rule, two homes" drift the repo has already paid for.

**Alternatives rejected**: `ChunkRunner`'s approach of dispatching `"phase.run"`
itself and re-implementing the span (precedented, but it duplicates the retry
policy — `ChunkRunner` gets away with it because `Chunking.next/2` absorbs
per-chunk transients, which the analyze loop does not do); passing a closure
down from `FeatureRunner` (works, but hides the retry policy inside an
anonymous function and makes the label a positional concern).

**Risk control**: the extraction is behaviour-preserving and lands with the
existing `feature_runner_test.exs` suite unchanged as its regression proof.

---

## R9 — Attempt-numbered records: `-a<k>` labels, roll-up keeps today's name

**Decision**: When the loop performs **at least one** remediation attempt, every
record of that analyze step is attempt-numbered under the step's own number
`NN`:

- `NN-analyze-a<k>.md` — the k-th analyze run (k starts at 1)
- `NN-remediation-a<k>.md` — the k-th remediation attempt
- `NN-analyze.md` — the roll-up, written once at the end, holding the **final**
  analyze run

When the loop performs no attempt (disabled, or nothing at or above threshold),
only `NN-analyze.md` is written — byte-identical to today.

**Rationale**: FR-012a forbids overwriting an earlier attempt's record, and
015 already established the pattern (`implement-p01-a1` … plus a roll-up under
the plain phase name) for exactly this shape. Keeping the plain `NN-analyze.md`
name matters beyond aesthetics: `Recovery.Evidence` locates the durable
`07-converge.md` by exact filename, and the console/transcript views list by
step. Transcripts already write a durable copy outside the worktree, so
FR-012a's "including for a feature that converges and is later cleaned up as
`done`" holds with no extra work.

**Also decided**: attempt records must **not** consume pipeline step numbers —
analyze stays step 5 for every attempt, same rule as 015/R6.

---

## R10 — Checkpoint carries attempt metadata; it is never restored as budget

**Decision**: `Checkpoint` gains one optional key `analyze_remediation`
(`%{attempts_used, limit, threshold, enabled?}`), written with the same
`maybe_put_*`-omit-when-absent pattern as `implement_chunk`. `last_phase` stays
`analyze` (FR-012b). On resume the recorded `attempts_used` is **informational
only** — the loop always starts a new feature run at zero (FR-015).

**Rationale**: FR-012b explicitly wants resume/recovery behaviour unchanged, so
the loop must not become a pipeline position. FR-015 wants a fresh budget for
every human-initiated re-run, so restoring the counter would be a bug, not a
feature. A pre-017 checkpoint (no key) reads and resolves exactly as today.

---

## R11 — Exhaustion decorates the gate reason; the gate itself is untouched

**Decision**: `Pipeline.next/3` keeps returning `{:halted, :critical_finding}` /
`{:escalated, :high_findings}`. When — and only when — the loop ran and
exhausted its attempts, `FeatureRunner` decorates the terminal reason to
`{:critical_finding, :auto_remediation_exhausted}` /
`{:high_findings, :auto_remediation_exhausted}` before it is recorded and
notified.

**Rationale**: FR-006 requires both "hand the feature to the gate unchanged"
and "record a reason that identifies exhausted auto-remediation as the cause" —
decoration after the decision satisfies both without teaching the transition
table a new vocabulary. A survey of the tree confirms no production code
pattern-matches these atoms (the console renders `inspect(reason)`; only
`pipeline_test`/`feature_runner_test` assert on them), so the decorated shape is
additive.

**Byte-identical rule**: with the loop off, or with no attempt made, the reason
is the bare atom exactly as today (SC-007a).

---

## R12 — Breaker: checked before each loop step, in-flight step always finishes

**Decision**: `AnalyzeRunner` checks `Ledger.breaker_tripped?/1` **between**
loop steps — after an analyze run and before starting a remediation attempt,
and after an attempt before starting the next analyze run. A tripped breaker
ends the loop with `terminal_reason: {:halted, :breaker}` via the existing
`FeatureAgent.terminal_reason` seam, which `FeatureRunner` already honours.

**Rationale**: FR-009 and Principle IV's drain-don't-kill. The seam already
exists for exactly this outcome in the chunked implement step
(`chunk_terminal_override/1`), which this feature generalizes to
`terminal_override/1` — no new mechanism.

---

## R13 — Validation happens once, in a pure function, called from two places

**Decision**: `Remediation.Settings.validate/1` is the single validator:
unrecognized threshold → `{:error, {:invalid_threshold, value}}`; attempt limit
not an integer in `1..5` → `{:error, {:invalid_attempt_limit, value}}`; unknown
model alias → `{:error, {:unknown_model, alias}}` (delegated to
`Config.remediation_model/2`). `run/1` calls it in preflight and refuses with
`{:error, {:preflight, [reason]}}`, starting no work; `TriggerLive` calls the
same function before dispatching and renders the field error.

**Rationale**: FR-011 and FR-010e are the same rule at two altitudes; the repo
already has this shape (`RunContext.effective_max_concurrency/2` — "one rule,
one home — the console previews it before a run starts and `run/1` records it
once started"). A limit of `0` is rejected as out of range, not treated as an
off-switch (FR-004a).

---

## R14 — Console: three controls, a sub-label, and a history summary

**Decision**: Console work is bounded to (a) three controls on `/trigger`
pre-filled from `Config`, validated by R13's function, never written back to
app env; (b) an analyze phase-cell sub-label `attempt k/n` fed by a new
`[:speckit, :remediation]` telemetry span folded into the feature slice
(mirroring the existing chunk sub-label); (c) an "auto-remediation N/M
exhausted" line on the escalations surface, read from the checkpoint's
`analyze_remediation` key.

**Rationale**: FR-010d, FR-013, SC-005, and the spec's own assumption that the
console stays an operator surface over run state. Every piece reuses an
existing path — `ConsoleProjection` already folds telemetry and broadcasts
diffs; `core_components` already renders a phase sub-label for implement
chunks; `escalations_live` already reads checkpoints. No new process, no JS.

---

## R15 — The constitution amendment is part of this feature

**Decision**: Amend Principle V — replace "The analyze gate MUST halt to
`:halted` on a constitution Critical finding" with a formulation that permits a
**bounded, pre-gate** auto-remediation loop and guarantees the identical
terminal state on exhaustion. MINOR bump `1.1.0 → 1.2.0`, with a Sync Impact
Report prepended per the Governance section.

**Rationale**: FR-017 puts the amendment in scope, and the Governance section
requires the impact record plus the version bump. MINOR is correct: an existing
principle is materially expanded (a new bounded exception plus a new
guarantee), not removed or made backward-incompatible — the human-facing
outcome for an unfixable Critical finding is unchanged.

**Amendment must not weaken anything else**: the clarify gate, the
never-retry-past-the-human rule, worktree retention, and `resolve/1` are all
restated verbatim. Draft text is in `contracts/constitution-amendment.md`.

---

## R16 — Existing analyze-gate tests must pin the new default

**Decision**: Because the default is **on** (FR-002/FR-010), every existing test
that asserts today's analyze-gate behaviour with a High or Critical finding must
explicitly set `auto_remediation: false` (or assert the new loop behaviour).
This is a known, enumerable edit, not incidental churn.

**Rationale**: Discovered while reading `feature_runner_test.exs:307,380` and
`pipeline_test.exs:105,119,124`. `pipeline_test` is unaffected (the transition
table does not change); `feature_runner_test`'s two analyze-gate assertions run
through the new delegation and would otherwise perform fake remediation
attempts. Flagged here so `/speckit-tasks` schedules the edit instead of
discovering it as a red suite.
