# Phase 0 Research: Auto-Remediation Exhaustion Policy

**Feature**: `021-analyze-exhaustion-policy` | **Date**: 2026-07-31

The spec arrived fully clarified (five Q/A in § Clarifications, no
`NEEDS CLARIFICATION` markers), so Phase 0 resolves *design* unknowns rather
than requirement unknowns: where in the existing pure surfaces the policy is
read, how the "advanced past findings" fact is stored and surfaced without a
new lifecycle status, and what the constitution amendment must say.

Every decision below is anchored to code that exists today on `main`.

---

## R1 — Where the policy is read: a `Pipeline` gate signal, not a suppressed `high?`

**Decision**: `Pipeline.next(:analyze, :ok, signals)` reads two new flat gate
signals — `:exhausted?` (boolean) and `:exhaustion_policy`
(`:escalate | :proceed`) — and advances instead of escalating when
`high? and exhausted? and policy == :proceed`. The `critical?` clause stays
first and unconditional.

**Rationale**: `Pipeline.next/3` is documented as "the whole decision surface"
(CLAUDE.md, `lib/speckit_orchestrator/pipeline.ex:9`). The gate's outcome is
exactly what this feature changes, so the change belongs there, expressed as
data passed in — the same shape `gate_threshold` already took in feature 017.
The alternative — having `AnalyzeRunner` set `high?: false` when the policy is
*proceed* so `Pipeline` advances "naturally" — was rejected: it makes a gate
signal lie about the phase output, which Principle I exists to prevent, and it
would make the residual-findings record (FR-007) unreachable from the gate
decision that produced it (FR-009 needs to know the gate *would have*
escalated).

**Alternatives considered**:

- *A separate `ExhaustionPolicy.next/2` table above `Pipeline`* — a third
  decision module for a single boolean branch. Rejected: `Remediation.next/2`
  already owns the loop, `Pipeline.next/3` already owns the gate; a module
  between them owns nothing.
- *Nesting the signal under the existing `signals.remediation` map* (which
  `AnalyzeRunner.exhaustion_signals/3` already writes). Rejected: `Pipeline`'s
  `signals` type is deliberately flat; mixing one nested key in would make the
  gate reach two levels down for one boolean. The existing `:remediation` map
  is left untouched — nothing that reads it changes.

**Consequence**: absent signals (`exhausted?` absent ⇒ `false`,
`exhaustion_policy` absent ⇒ `:escalate`) reproduce today's gate byte-for-byte,
which is what makes FR-002 / SC-002 a matter of defaults rather than of a
parallel code path.

---

## R2 — Where the policy is injected: `gate_signals/3`, from captured settings

**Decision**: `FeatureRunner.gate_signals(:analyze, st, step_opts)` injects
`:exhaustion_policy` from the run's `Remediation.Settings`, exactly as it
already injects `:gate_threshold`
(`lib/speckit_orchestrator/feature_runner.ex:691`). `AnalyzeRunner` supplies
`:exhausted?` alongside the `:remediation` map it already writes on the
exhaustion path (`exhaustion_signals/3`).

**Rationale**: the policy is a *run setting*, not phase output, so it follows
the settings-injection path already established for the threshold; the
exhaustion fact *is* loop output, so it follows the loop's own signal path. The
split keeps `AnalyzeRunner` ignorant of the gate and `Pipeline` ignorant of the
loop.

**Consequence**: the policy reaches the gate from `step_opts.remediation_settings`,
which `FeatureRunner` resolves once per feature run from the run's **captured**
`RunContext` and never from live `Config`
(`remediation_settings!/1`, `feature_runner.ex:465`). FR-011 (fixed for the
run's lifetime) and FR-012 (no leak into a later run) are therefore inherited
from the existing mechanism, not re-implemented.

---

## R3 — The setting's home: a fifth field on `Remediation.Settings`

**Decision**: `Remediation.Settings` gains `exhaustion_policy: :escalate | :proceed`
(default `:escalate`), validated by the same `validate/1` and decoded by the
same `from_context/1`. New error tuple: `{:error, {:invalid_exhaustion_policy, value}}`.
`RunContext` gains a ninth field, `auto_remediation_exhaustion_policy`, stored
as a **string** in the manifest (same treatment as the threshold, for the same
reason). `Config.auto_remediation_exhaustion_policy/0` supplies the default.

**Rationale**: the spec's own Key Entities section says the policy "joins [the
existing knobs] as a fourth operator-chosen value with the same lifetime and
leak-free rules". Every mechanism that gives the other three their lifetime,
validation, capture, replay-on-resume and console plumbing is keyed off these
two structs; adding a field inherits all of it. A parallel setting object would
duplicate `capture/1`, `to_map/1`, `from_map/1`, `merge/2`, the preflight, and
the console form.

**Parsing**: `:escalate`/`:proceed` atoms pass through; the strings
`"escalate"`/`"proceed"` map to them by explicit match. Anything else errors.
`String.to_atom/1` is never called on file- or form-sourced content — the
repo-wide ban (`Pipeline.parse/1`, `Severity.parse/1`, `RunContext`'s
`stringify_threshold/1` comment) applies unchanged.

**Alternatives considered**: reusing `Severity`-style `parse/1` returning
`{:ok, v} | :error` — adopted verbatim as the shape, but the parser lives in
`Remediation.Settings` rather than a new module: two atoms with no ordering do
not warrant a `Severity` sibling.

---

## R4 — Distinguishing "advanced past" from "would have advanced anyway" (FR-009)

**Decision**: one pure function, `Remediation.exhaustion_advance/2`, returns
`{:mark, record} | :none`. It marks only when **all** of: `exhausted?`,
`policy == :proceed`, `high?`, and `Severity.at_or_above?(:high, threshold)`.
`FeatureRunner` calls it at the analyze boundary and materializes the record
only on `{:mark, _}`.

**Rationale**: FR-009's whole content is "the mark is reserved for advancing
past findings the gate would otherwise have diverted". That is a predicate over
exactly the same four inputs the gate uses, so it must be evaluated from the
same values in the same place — otherwise the mark and the gate can disagree.
Making it a pure function makes the below-threshold case, the clean-analyze
case, the Critical case and the `:escalate` case four unit tests with no
process, no store, and no CLI.

**Consequence**: the three "policy is inert" edge cases (below-threshold
residuals, clean analyze at the limit, threshold pinned to `:critical`) all
fall out of the same predicate returning `:none`, rather than each needing its
own guard.

---

## R5 — The record's shape and its home: a column on `speckit_feature_run`

**Decision**: `speckit_feature_run` gains an `advanced_with_findings`
attribute (`map() | nil`), appended last, via schema **version 4** — a plain
`:mnesia.transform_table` append that sets `nil` on every existing row. It is
written in the *same transaction* as the analyze phase-attempt boundary, as a
new optional `:advanced_with_findings` key on `Store.Writer.record_phase_attempt/2`.

**Rationale**: the fact is an attribute of one feature run (FR-008a: an
annotation, not a status), read on every surface that already reads the feature
row — run detail, the final report, the PR publisher. Migration v3
(`add_pr_url/0`, `store/migrations.ex:39`) is the exact precedent: last-position
append, no existing field moves, every prior row legitimately `nil` because the
fact did not exist when it was written. `Store.Export.encode/1` is shape-generic,
so the export contract (constitution → Persistence) follows for free.

**Alternatives considered**:

- *A new `speckit_advanced_finding` table* — a table whose cardinality is
  0-or-1 per feature run, joined on every read. Rejected as unjustified schema
  surface.
- *Reusing `speckit_escalation` with a new `kind`* — rejected outright: the
  defining property of this record is that the feature was **not** escalated.
  Putting it in the escalations table would make `/escalations` show resolved-by-
  configuration rows and would corrupt the one surface an operator uses to find
  work that is actually waiting on them.
- *A separate transaction after the phase attempt* — rejected: FR-006's
  one-transaction-per-boundary rule (018 R7) exists so a reader can never see
  the attempt without the state it produced.

---

## R6 — Surfacing without a new status: decorate the terminal reason

**Decision**: `FeatureRunner.loop/*` threads a small `marks` map; when the
analyze boundary marks the feature, the eventual `{:done, :done}` transition is
reported with reason `{:done, :advanced_with_unresolved_findings}` instead of
`:done`. `Coordinator` already retains per-feature reasons
(`coordinator.ex:147`), so `build_report/2` gains
`advanced_with_findings: [feature_id]` with no change to `notify/4`'s arity or
to the `:runner` seam.

**Rationale**: FR-008 requires the run's final report to distinguish these
features; FR-008a forbids a new status. Reason decoration is the existing,
precedented way this codebase adds a fact to a terminal without touching the
status enum — `Remediation.terminal_reason/2` already decorates
`{:escalated, :high_findings}` into `{:escalated, {:high_findings, :auto_remediation_exhausted}}`.
The status stays `:done`; every existing consumer of the status enum is
untouched (SC-002 for the `:escalate` path, FR-008a generally).

**Why a thread rather than agent state**: `AnalyzeRunner.patch/2` merges into
the *returned* agent copy, not the `AgentServer`'s state, so a fact set at
analyze does not survive to converge. The `marks` map is the smallest honest
carrier; it is also where any future cross-phase annotation would go.

**Consequence**: a feature that advanced under *proceed* and then **failed**
downstream (spec Edge Cases) keeps its ordinary `:failed` status and reason —
the mark is only a `:done`-reason decoration — while the store annotation
(R5) still records what it advanced past. The store, not the reason, is the
record of truth; the reason is the report's index into it.

---

## R7 — The pull request body (FR-008b, SC-008)

**Decision**: a pure renderer, `Remediation.pr_note/1`, turns the stored
annotation into a markdown section. `SpeckitOrchestrator.pr_text/2`
(`speckit_orchestrator.ex:2171`) appends it to **both** branches — the
Claude-authored `pr_description` and the template fallback — reading the
annotation from the same `Store.run/1` detail it already reads for
`pr_description`.

**Rationale**: `pr_text/2` is already the single place a PR body is assembled
and already reads the store detail, so appending is one call at one site and
cannot be bypassed by the fallback path. Making the renderer pure keeps SC-008
("names the residual findings in its body") a unit test on a string rather than
a `gh` integration test.

**Content rules**: no emoji, no marketing copy (constitution → prohibitions
apply to human-facing output generally); the section names the policy under its
real setting name (`auto_remediation_exhaustion_policy: proceed`), the attempts
consumed, and each residual finding's severity and text verbatim — the same
"speak the system's vocabulary" rule Principle VII sets for the console.

---

## R8 — Console surface (FR-013, FR-014, FR-008)

**Decision**: three touches, all reusing existing markup and tokens.

1. **Launch form** (`TriggerLive`): a `<select name="exhaustion_policy">` added
   to the existing `#auto-remediation-form`, disabled with the rest when
   auto-remediation is off, pre-filled from
   `Config.auto_remediation_exhaustion_policy/0`, validated through the same
   `Remediation.Settings.validate/1` the form already calls, refusing via the
   existing `<.form_refusal>` with label `auto-remediation-exhaustion-policy`.
2. **Run-level display** (FR-014): free. `RunDetailLive`'s settings chips render
   `{k, v}` over the run's captured settings map generically
   (`run_detail_live.ex:294`), so the policy appears the moment
   `RunContext.to_map/1` includes it.
3. **Feature marker** (FR-008): a `data-advanced-with-findings` block in the
   feature panel, sibling to the existing `data-remediation-attempts` block,
   listing severity + finding text and the attempts consumed. Requires
   `Store.Query` to carry `advanced_with_findings` into the feature slice.

**Design-constitution compliance** (Principle VII, `docs/design-constitution.md`):
the marker introduces **no new color, radius, font-size or spacing literal** —
it reuses the `run-context` / `run-context-chip` classes. Critically, it MUST
NOT use a status color: this is not a run status, and "a status color MUST NEVER
appear on a non-status element" is absolute. Severity is conveyed as a mono
`data-severity` label, not as hue. `test/support/design_contract.ex` enforces
the literal ban mechanically and will fail the build if this is violated.

**Rationale for the small footprint**: the spec bounds console work to "the
launch-form control and the run-level display of the chosen policy, plus the
marking of advanced-with-findings features". Two of the three are additive
markup inside blocks that already exist.

---

## R9 — Resume, checkpoints, and the attempt budget

**Decision**: no new mechanism. The policy rides `RunContext`, so
`RunContext.merge/2`'s explicit-opts > recorded > live-Config precedence
reapplies it on `resume/2` exactly as it reapplies the threshold and limit. The
attempt budget is already fresh per feature run (`AnalyzeRunner.run/1` seeds
`attempts_used: 0`), which is what the spec's edge case asserts.

**Rationale**: the spec's assumption "Configuration follows the project's
existing run-configuration pattern … no new persistence mechanism" is
satisfiable by field addition alone. The checkpoint's `analyze_remediation`
provenance map (`AnalyzeRunner.provenance/1`) is left as-is: it records what was
*tried*, and this feature does not change what is tried.

---

## R10 — The constitution amendment (FR-016)

**Decision**: amend Principle V's third auto-remediation bullet, bump
**2.2.0 → 3.0.0**, prepend a Sync Impact Report, and land it in the same change
as the behaviour.

**Current text** (`.specify/memory/constitution.md:305`):

> - on exhaustion the gate decides the outcome from the **final** analyze run
>   under the rules above, unchanged, with a recorded reason naming exhausted
>   auto-remediation;

**Why MAJOR**: identical in kind to the 2.0.0 bump. A guarantee that was
unconditional — an exhausted loop always hands a residual High finding to a
human — becomes configurable away by a recorded per-run choice. That is a
relaxation of a governance bound, not an expansion of one. The 2.0.0 report
states the test explicitly ("an operator can now configure away a human-facing
terminal state that was previously unconditional … MAJOR rather than MINOR"),
and the spec's Clarifications adopt it.

**What the amendment must preserve**: the unconditional Critical halt (stated
twice in Principle V and reinforced here), the boundedness of the loop, the
per-attempt recording, the cost-breaker precedence, and the exact-restoration
guarantee when the loop is disabled. The amendment adds one new obligation —
that an advance past a residual finding is **recorded and surfaced to the human
who reviews the work** — so the relaxation is paired with a compensating
control rather than being a bare removal.

**Sync Impact Report must flag**: `CLAUDE.md` (Pure core → `Pipeline` /
`Remediation` descriptions and the Phase-7 narrative both state the gate's
behaviour on exhaustion), `docs/workflow.md`, `docs/runbook.md`, and
`specs/017-analyze-auto-remediation/` (left as an accurate historical record,
per the 2.1.0 precedent for superseded feature artifacts).

---

## R11 — Test strategy

**Decision**: the feature is provable almost entirely in the default hermetic
suite.

- **Pure** (`pipeline_test`, `remediation_test`, new `exhaustion_advance`
  cases): the full 2×2×N matrix of {policy} × {exhausted?} × {critical, high,
  below-threshold, clean} against `Pipeline.next/3` and
  `Remediation.exhaustion_advance/2`. SC-003 (no Critical ever advances) is a
  property over every policy × every threshold.
- **Regression pin for SC-002**: the `:escalate`-and-default paths asserted
  against the *existing* expectations, in the existing test files, so a leak of
  the new path into the default fails a test that predates it.
- **Runner** (`feature_runner_test`, `analyze_runner_test`): the injected-seam
  style already in use — a scripted agent that reports the same High finding on
  every analyze pass, asserting attempts consumed, the advance, the annotation,
  and the decorated `:done` reason.
- **Store** (`writer_test`, migration test): the v4 transform over a v3-shaped
  row, and the one-transaction-per-boundary invariant.
- **Console** (`trigger_live_test`, run-detail test): pre-filled default,
  refusal on a bad value with no run started, settings chip, feature marker.
- **Design guard**: `design_contract_test` is already in the default suite and
  needs no new case — it fails on any literal the new markup might introduce.

**Rationale**: Quality & Test Discipline mandates >90% on the pure core and a
hermetic default suite; every decision above was shaped to keep the new logic
pure enough to satisfy that without `--include integration`.
