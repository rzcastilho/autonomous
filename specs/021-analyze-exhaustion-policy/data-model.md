# Phase 1 Data Model: Auto-Remediation Exhaustion Policy

**Feature**: `021-analyze-exhaustion-policy` | **Date**: 2026-07-31

Three entities, all extensions of things that already exist. Nothing here
introduces a new lifecycle status, a new table, or a new persistence mechanism.

---

## 1. Exhaustion policy (setting)

A per-run value with exactly two members. Read at one moment only: when the
auto-remediation attempt limit is reached with residual findings at or above the
run's severity threshold.

| Property | Value |
|---|---|
| Type | `:escalate \| :proceed` |
| Default | `:escalate` (FR-002) |
| Lifetime | fixed for the run (FR-011) |
| Scope | uniform across every feature in the run (FR-011) |
| Leakage | none — never becomes the next run's default (FR-012) |

### Where it lives

**`SpeckitOrchestrator.Remediation.Settings`** — a fifth field beside the four
that already exist:

```elixir
defstruct enabled?: true,
          threshold: :high,
          attempt_limit: 2,
          model: nil,
          exhaustion_policy: :escalate    # new
```

**`SpeckitOrchestrator.RunContext`** — a ninth captured field. Stored as a
string, never an atom, because the manifest is JSON and `String.to_atom/1` on
file-sourced content is banned repo-wide:

```elixir
auto_remediation_exhaustion_policy: String.t() | nil    # "escalate" | "proceed"
```

**`SpeckitOrchestrator.Config`** — the deployment default:

```elixir
@spec auto_remediation_exhaustion_policy() :: :escalate | :proceed
def auto_remediation_exhaustion_policy,
  do: get(:auto_remediation_exhaustion_policy, :escalate)
```

### Validation rules

Applied by the single existing validator, `Remediation.Settings.validate/1`,
checked after `model` so the existing error ordering is unchanged:

| Input | Result |
|---|---|
| `:escalate` / `:proceed` | accepted as-is |
| `"escalate"` / `"proceed"` | accepted, normalized to the atom |
| absent / `nil` | the default `:escalate` (FR-002) |
| anything else | `{:error, {:invalid_exhaustion_policy, value}}` (FR-010) |

Never clamps, never substitutes a default for a bad value, never partially
applies — the rule the other four fields already follow. Case handling matches
`Severity.parse/1`: the string form is downcased before matching, so `"Proceed"`
is accepted and `"proceeed"` is not.

`Settings.from_context/1` decodes it with the same tolerance the other fields
get: an **absent** field falls back to the default; a **present but invalid**
field still errors.

### Resolution order (unchanged mechanism, per R2)

```
explicit run/1 opt  >  recorded RunContext  >  live Config default
```

For an in-flight feature run the value comes from the run's **captured**
`RunContext` and never from live `Config` — this is what makes FR-011's
"MUST NOT change once the run has started" and User Story 3 scenario 3
(a mid-run setting change does not affect the in-progress run) structural
rather than newly enforced.

---

## 2. Gate signals (transient)

Two new members of `Pipeline.signals`, flat like every existing member:

```elixir
@type signals :: %{
        optional(:needs_human?) => boolean(),
        optional(:critical?) => boolean(),
        optional(:high?) => boolean(),
        optional(:gate_threshold) => Severity.severity(),
        optional(:exhausted?) => boolean(),                       # new
        optional(:exhaustion_policy) => :escalate | :proceed,     # new
        optional(:not_ready?) => boolean(),
        optional(:missing_artifact) => String.t()
      }
```

| Signal | Source | Absent means |
|---|---|---|
| `:exhausted?` | `AnalyzeRunner.exhaustion_signals/3` — set only on the `{:gate, {:exhausted, n}, _}` branch | `false` |
| `:exhaustion_policy` | `FeatureRunner.gate_signals(:analyze, …)`, from the run's `Settings` | `:escalate` |

Both absent ⇒ the gate is byte-identical to today (FR-002, SC-002).

The existing nested `signals.remediation` map
(`%{attempts:, limit:, exhausted?: true}`) is **unchanged** and still written;
nothing that reads it today changes.

### Gate decision table (`Pipeline.next(:analyze, :ok, signals)`)

Rows evaluated top-to-bottom, first match wins:

| # | Condition | Outcome |
|---|---|---|
| 1 | `critical?` | `{:halted, :critical_finding}` — unconditional, FR-005/SC-003 |
| 2 | `high?` and **not** `at_or_above?(:high, gate_threshold)` | advance (today's threshold behaviour) |
| 3 | `high?` and `exhausted?` and `policy == :proceed` | **advance** — the one new cell, FR-004 |
| 4 | `high?` | `{:escalated, :high_findings}` — FR-003 |
| 5 | otherwise | advance |

Row 1 sits above every policy check, so no value of the policy can pass a
Critical finding (FR-005). Row 3 is reachable only when the loop actually
exhausted its attempts, so the policy cannot alter a decision reached before the
limit was consumed (FR-006).

---

## 3. Advanced-with-unresolved-findings record (annotation)

Produced exactly when the gate takes row 3 above. **Not** a status
(FR-008a) — an annotation on the feature run.

### Shape

```elixir
%{
  policy: "proceed",           # the policy that permitted the advance
  attempts_used: 2,            # attempts consumed before exhaustion
  attempt_limit: 2,
  threshold: "high",           # the run's severity threshold
  max_severity: "high",
  findings: [ ... ],           # residual findings, VERBATIM as analyze reported
  advanced_at: ~U[...]
}
```

`findings` are the model-authored `AnalyzeResult.finding()` maps passed through
untouched — the same verbatim-passthrough rule
`speckit_remediation_attempt.findings` already follows. Atoms are avoided in
the stored map (strings for policy/threshold/severity) so the record survives
`Store.Export.encode/1` into a Mnesia-free format.

### Storage

A new attribute appended to the existing `speckit_feature_run` table:

```
:speckit_feature_run
  attributes: [..., :pr_url, :advanced_with_findings]    # appended last
  type: :set, storage: :disc_copies
```

**Schema version 4** — a plain `:mnesia.transform_table` append, structurally
identical to version 3's `add_pr_url/0`: no existing field changes position, and
every pre-existing row legitimately receives `nil` because the fact did not
exist when the row was written.

```elixir
{4, "append feature_run.advanced_with_findings", &add_advanced_with_findings/0}
```

`Store.Migrations.current_version/0` becomes `4`.

### Write point

One write, in the **same transaction** as the analyze phase-attempt boundary:
`Store.Writer.record_phase_attempt/2` gains an optional `:advanced_with_findings`
key that updates the feature-run row. A reader can therefore never see the
analyze attempt without the annotation it produced (018 R7, FR-006).

`run_key: nil` (a non-store-backed run — most unit tests) is a silent no-op,
as it already is for every other write on that path.

### Lifecycle

| Moment | Value |
|---|---|
| feature run opened | `nil` |
| gate takes row 3 | set, once |
| any other gate row | stays `nil` (FR-009) |
| feature reaches `:done` / `:failed` / … | unchanged — the annotation is independent of the terminal status |

It is written at most once per feature run: the loop runs once per feature run,
and `Pipeline` sees exactly one `:analyze` outcome per feature run (017 FR-007).

---

## 4. Terminal reason decoration (report index)

`Feature` status values are **unchanged** — `:pending | :running | :done |
:escalated | :halted | :failed | :never_started`. No member added, no member
redefined (FR-008a).

The `:done` *reason* is decorated when the feature was marked:

| Situation | Reason reported to `Coordinator` |
|---|---|
| ordinary completion | `:done` (unchanged) |
| completed after advancing under *proceed* | `{:done, :advanced_with_unresolved_findings}` |

`Coordinator` already retains per-feature reasons, so `build_report/2` gains one
derived key with no change to the `notify/4` contract or the `:runner` seam:

```elixir
%{
  done: [...], escalated: [...], halted: [...], failed: [...],
  not_started: [...], stopped_by: ..., spend: ..., breaker_tripped: ...,
  advanced_with_findings: ["003"]        # new — subset of :done
}
```

`advanced_with_findings` is a **subset of `done`**, never a sibling category —
that is the report-level expression of FR-008a.

---

## Entity relationships

```
Run
 └── RunSettings (captured RunContext, incl. auto_remediation_exhaustion_policy)
 └── FeatureRun  (status unchanged; + advanced_with_findings annotation)
      ├── PhaseAttempt(:analyze, ordinal 1..N)      ← unchanged
      ├── RemediationAttempt(ordinal 1..limit)      ← unchanged
      └── pr_description / pr_url                    ← body gains a rendered
                                                       section from the annotation
```

Nothing above changes the cardinality or key of any existing relationship.

---

## What is deliberately NOT modelled

- **No new terminal status** (FR-008a) — see §4.
- **No feed-forward channel.** The residual findings are stored and rendered;
  they are never added to any downstream phase's prompt, context, or corrective
  instruction (FR-004a). There is deliberately no field anywhere that a
  downstream phase reads.
- **No per-severity or per-feature policy.** One run-level value (spec
  Assumptions).
- **No change to the loop's own state.** `Remediation.state`,
  `AnalyzeRunner.provenance/1`, and the checkpoint's `analyze_remediation` map
  record what was *tried*; this feature changes only what happens when trying
  stops.
