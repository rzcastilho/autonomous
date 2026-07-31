# Contract: Advanced-with-unresolved-findings record

**Feature**: `021-analyze-exhaustion-policy`

The record produced when the *proceed* policy sends a feature past findings the
gate would otherwise have diverted, and the three surfaces it must reach. The
gate decision that produces it is `exhaustion-policy.md` §4.

---

## 1. When it exists — `Remediation.exhaustion_advance/2`

One pure function decides it, from exactly the values the gate used, so the mark
and the gate can never disagree (FR-009).

```elixir
@type advance_record :: %{
        policy: String.t(),
        attempts_used: non_neg_integer(),
        attempt_limit: pos_integer(),
        threshold: String.t(),
        max_severity: String.t(),
        findings: [AnalyzeResult.finding()],
        advanced_at: DateTime.t()
      }

@doc """
`{:mark, record}` when the run's *proceed* policy advanced a feature past
residual findings the gate would otherwise have escalated; `:none` otherwise.

Marks only when ALL hold (FR-009):
  * the loop exhausted its attempts (`exhausted?`),
  * the policy is `:proceed`,
  * the final analyze run reported a High finding (`high?`),
  * `Severity.at_or_above?(:high, threshold)` — i.e. the gate WOULD have
    diverted at this run's threshold.
"""
@spec exhaustion_advance(Pipeline.signals(), map()) :: {:mark, advance_record()} | :none
```

### 1.1 Truth table

| `exhausted?` | policy | `high?` | `critical?` | threshold | Result | Why |
|---|---|---|---|---|---|---|
| `true` | `:proceed` | `true` | `false` | `:high` | `{:mark, …}` | the one observable cell |
| `true` | `:proceed` | `true` | `false` | `:low`/`:medium` | `{:mark, …}` | gate would still have escalated |
| `true` | `:proceed` | `true` | `false` | `:critical` | `:none` | gate advances anyway (FR-009) |
| `true` | `:proceed` | `true` | `true` | any | `:none` | halted — never reaches the mark (FR-005) |
| `true` | `:proceed` | `false` | `false` | any | `:none` | residuals below threshold; gate advances anyway (FR-009) |
| `true` | `:escalate` | `true` | `false` | `:high` | `:none` | escalated, not advanced (FR-003) |
| `false` | any | any | any | any | `:none` | never exhausted (FR-006) |

The `critical? == true` row is unreachable in practice — `Pipeline` row 1 halts
the feature before `FeatureRunner` consults this function — and is specified
here so the function is total and independently testable.

### 1.2 Findings source

`AnalyzeResult.findings_at_or_above(final_result, threshold)` — the same call
the loop already makes to decide whether to remediate, evaluated against the
**final** analyze run. Findings are carried **verbatim**: the model-authored maps
are neither reshaped, reordered, filtered beyond the threshold, nor summarized.

`AnalyzeRunner` attaches this candidate list to the returned agent state as
`analyze_residual_findings` on the exhaustion branch (it is the only component
that holds the parsed final result); `FeatureRunner` passes it into
`exhaustion_advance/2`. No candidate is attached when the loop did not exhaust.

---

## 2. Storage

### 2.1 Schema

`speckit_feature_run` gains one attribute, appended last:

```elixir
%{
  name: :speckit_feature_run,
  attributes: [
    :key, :run_key, :feature_id, :slug, :path, :number, :group, :created_at,
    :status, :terminal_reason, :worktree_path, :branch, :pr_description,
    :started_at, :ended_at, :pr_url,
    :advanced_with_findings            # new, last
  ],
  type: :set,
  storage: :disc_copies,
  index: [:run_key, :feature_id]
}
```

`Store.Records.FeatureRun` gains the matching struct field and typespec entry
(`advanced_with_findings: map() | nil`).

### 2.2 Migration — schema version 4

```elixir
def current_version, do: 4

{4, "append feature_run.advanced_with_findings", &add_advanced_with_findings/0}

defp add_advanced_with_findings do
  transform_table(
    :speckit_feature_run,
    &Tuple.insert_at(&1, tuple_size(&1), nil),
    Schema.table(:speckit_feature_run).attributes
  )
end
```

Structurally identical to version 3's `add_pr_url/0`: a plain append, no
existing field moves position, every v3 row receives `nil` — correct, because
the fact did not exist when those rows were written. A v1 store still hits
version 2's refusal migration; a v2 store still transforms through 3 then 4.

This is a **transform**, not a clean break: no refusal migration is registered
and no recorded state is dropped, truncated, or auto-deleted (constitution →
Persistence).

### 2.3 Write point

`Store.Writer.record_phase_attempt/2` gains an optional key:

```elixir
Writer.record_phase_attempt(run_key, %{
  attempt: attempt,
  cost: cost,
  checkpoint: checkpoint,
  transcript: transcript,
  advanced_with_findings: record        # new, optional
})
```

- Written inside the **existing** transaction for that boundary, so a reader can
  never see the analyze attempt without the annotation it produced (018 R7).
- Absent or `nil` ⇒ the feature-run row is not touched at all.
- `run_key: nil` ⇒ silent no-op, as for every other write on this path.
- Written at most once per feature run: the loop runs once per feature run and
  `Pipeline` sees exactly one `:analyze` outcome per feature run.

### 2.4 Serialization

Stored values are strings and plain maps — `policy`, `threshold`,
`max_severity` are strings, not atoms — so `Store.Export.encode/1` produces a
record readable without Mnesia (constitution → Persistence, "a run's record MUST
be exportable in a format readable without Mnesia"). `Store.Export` itself is
shape-generic and needs no change.

---

## 3. Surface 1 — the run's final report (FR-008)

### 3.1 Terminal reason decoration

`FeatureRunner.loop/*` threads a `marks` map. When `exhaustion_advance/2`
returns `{:mark, _}` at the analyze boundary, `marks` records it; when the
feature later reaches `{:done, :done}`, the reason reported on the terminal
notify is decorated:

| Situation | status | reason |
|---|---|---|
| ordinary completion | `:done` | `:done` |
| completed after advancing under *proceed* | `:done` | `{:done, :advanced_with_unresolved_findings}` |
| advanced under *proceed*, then failed downstream | `:failed` | the ordinary failure reason (undecorated) |

The status is **never** changed (FR-008a). A downstream failure keeps its own
reason — the annotation in the store is still the record of what it advanced
past (spec Edge Cases: "an ordinary phase failure with its ordinary terminal
state").

### 3.2 `Coordinator.build_report/2`

```elixir
%{
  done: [...],
  escalated: [...],
  halted: [...],
  failed: [...],
  not_started: [...],
  stopped_by: ...,
  spend: ...,
  breaker_tripped: ...,
  advanced_with_findings: ["003"]      # new — a SUBSET of :done
}
```

Derived from `state.reasons`, which the `Coordinator` already retains — so
`notify/4`'s arity and the `:runner` seam are unchanged, and every existing
`Coordinator` test keeps passing.

`advanced_with_findings` is a subset of `done`, never a sibling category: that
is the report-level expression of "no new terminal status".

### 3.3 `Report.format_status/1`

One extra line, emitted only when non-empty:

```
advanced: 003, 006   (proceeded past unresolved findings)
```

Absent from the output entirely when no feature advanced under *proceed*, so the
`:escalate`-path report is byte-identical to today's (SC-002). The snapshot map
gains the same key from the same source.

---

## 4. Surface 2 — the operator console (FR-008, FR-014)

### 4.1 Run-level policy display (FR-014)

No new code. `RunDetailLive`'s `run_header` renders the run's captured settings
map generically as `run-context-chip` elements, so
`auto_remediation_exhaustion_policy` appears the moment `RunContext.to_map/1`
includes it. Verified by test, not by new markup.

### 4.2 Feature marker (FR-008)

`Store.Query` carries `advanced_with_findings` into the run-detail feature
slice. `RunDetailLive`'s feature panel gains a block sibling to the existing
`data-remediation-attempts` block:

```heex
<div :if={f.advanced_with_findings} data-advanced-with-findings>
  <h4>Advanced with unresolved findings</h4>
  <div class="run-context">
    <span class="run-context-chip">auto_remediation_exhaustion_policy: proceed</span>
    <span class="run-context-chip">attempts: 2/2</span>
    <span class="run-context-chip">threshold: high</span>
  </div>
  <div :for={finding <- f.advanced_with_findings["findings"]} class="run-context">
    …severity + finding text, mono…
  </div>
</div>
```

### 4.3 Design-constitution compliance (Principle VII)

Binding rules for this markup, enforced mechanically by
`test/support/design_contract.ex` (already in the default suite):

- **No new literal.** No color, radius, font-size, or spacing value appears in
  the template — only the existing `run-context` / `run-context-chip` classes and
  the `:root` token set.
- **No status color.** "Advanced with unresolved findings" is *not* a run
  status; a status color MUST NEVER appear on a non-status element. Severity is
  conveyed as a mono `data-severity` text label, never as hue.
- **No second accent hue**, no emoji, no marketing copy, no centered body text.
- **Machine values are mono.** Setting keys, atoms, severities, and finding text
  render in the mono family; the heading is sans.
- **The UI speaks the system's vocabulary.** The chip reads
  `auto_remediation_exhaustion_policy: proceed` — the real config key and the
  real value, not a friendly rename.
- **Show the receipt.** The block is rendered only from the stored annotation;
  it asserts nothing the record does not contain.
- **No motion.** The block is a resting element; it MUST NOT animate on entry.

### 4.4 What the console does NOT gain

No new route, no new nav entry, no escalation row. A feature that advanced under
*proceed* is deliberately **absent** from `/escalations` — it is not waiting on
a human, and putting it there would corrupt the one surface that answers "what
needs me right now".

---

## 5. Surface 3 — the pull request body (FR-008b, SC-008)

### 5.1 Renderer

```elixir
@doc "Markdown section naming the residual findings a feature advanced past."
@spec pr_note(advance_record() | nil) :: String.t()
def pr_note(nil), do: ""
```

Output shape (no emoji, no marketing copy — the same vocabulary rule the console
follows):

```markdown
---

## Advanced with unresolved analyze findings

This branch was built by `speckit_orchestrator` with
`auto_remediation_exhaustion_policy: proceed`. Auto-remediation used 2 of 2
attempts and did not clear the findings below; the analyze gate was permitted to
advance instead of escalating to a human. **These findings are unresolved in this
branch.**

Severity threshold: `high`

- **high** — <finding text, verbatim>
- **high** — <finding text, verbatim>
```

Pure and total: `nil` ⇒ `""`, so the call site is unconditional.

### 5.2 Call site

`SpeckitOrchestrator.pr_text/2` appends it to **both** branches — the
Claude-authored `pr_description` and the template fallback — reading the
annotation from the same `Store.run/1` detail it already reads for
`pr_description`:

```elixir
defp pr_text(feature, base) do
  note = Remediation.pr_note(store_advanced_with_findings(feature.id))

  case store_pr_description(feature.id) do
    %{pr_title: t, pr_body: b} when t not in [nil, ""] and b not in [nil, ""] ->
      {t, b <> note}

    _ ->
      {"feat(...)", "..." <> note}
  end
end
```

Appending at the single assembly site means the fallback path cannot silently
drop the findings — which is what SC-008 ("every pull request … names the
residual findings") actually requires.

### 5.3 Failure behaviour

Reading the annotation is best-effort, exactly as `store_pr_description/1`
already is: a non-store-backed run or a read failure yields `nil` ⇒ `""`, and a
PR still opens. It cannot turn a successful publish into a failed run. A run
that opens no PR at all still has the FR-007/FR-008 orchestrator-side surfaces
(spec Assumptions).

---

## 6. Invariants

- **V1** — `advanced_with_findings` is non-`nil` ⟺ the gate took row 3 of
  `exhaustion-policy.md` §4.1. (FR-009)
- **V2** — a feature with a non-`nil` annotation has status `:done` or an
  ordinary downstream failure status; never a status that did not exist before
  this feature. (FR-008a)
- **V3** — `report.advanced_with_findings ⊆ report.done`. (FR-008a)
- **V4** — with the policy `:escalate`, or with auto-remediation disabled, no
  annotation is ever written, for any threshold and any finding. (FR-003,
  FR-015, SC-002)
- **V5** — the annotation's `findings` are byte-identical to the corresponding
  subset of the final analyze run's parsed findings. (FR-007)
- **V6** — no phase after `:analyze` reads the annotation. Its only readers are
  the report, the console, and the PR renderer. (FR-004a)
