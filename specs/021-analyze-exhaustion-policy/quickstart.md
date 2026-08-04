# Quickstart: Auto-Remediation Exhaustion Policy

**Feature**: `021-analyze-exhaustion-policy`

Runnable scenarios that prove the feature works end to end. Details of *what* is
being asserted live in `contracts/exhaustion-policy.md` and
`contracts/advanced-record.md`; this file is the run guide.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

Everything below runs in the **default, hermetic** suite — no CLI, no worktree,
no machine-global Mnesia directory. The one opt-in scenario is marked.

---

## Scenario 1 — the gate advances under *proceed* (US1, FR-004)

Pure, no process. Feed `Pipeline.next/3` the exhaustion cell directly.

```bash
mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs
```

Expected:

- `high?` + `exhausted?` + `exhaustion_policy: :proceed` at threshold `:high`
  ⇒ `{:cont, :implement}`
- the same signals with `exhaustion_policy: :escalate`
  ⇒ `{:escalated, :high_findings}`
- the same signals with `exhausted?` absent
  ⇒ `{:escalated, :high_findings}`

## Scenario 2 — Critical never advances (US1 AS3, FR-005, SC-003)

```bash
mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs
```

Expected: for **every** `{policy, threshold}` pair, `critical? == true` yields
`{:halted, :critical_finding}`. Written as a table-driven case over
`Severity.values()` × `[:escalate, :proceed]` so a future threshold or policy
member cannot quietly escape it (contract §4.3 invariant I1).

## Scenario 3 — the mark fires only where the gate would have diverted (FR-009)

```bash
mise exec -- mix test test/speckit_orchestrator/remediation_test.exs
```

Expected: `Remediation.exhaustion_advance/2` reproduces the truth table in
`contracts/advanced-record.md` §1.1 — in particular `:none` for
below-threshold residuals, for a clean final analyze, and for a run whose
threshold is `:critical`.

## Scenario 4 — validation refuses a bad value (US3 AS2, FR-010, SC-007)

```bash
mise exec -- mix test test/speckit_orchestrator/remediation_test.exs
mise exec -- mix test test/speckit_orchestrator/web/trigger_live_test.exs
```

Expected:

- `Settings.validate(%{exhaustion_policy: "prcoeed"})`
  ⇒ `{:error, {:invalid_exhaustion_policy, "prcoeed"}}`
- `"escalate"` / `"proceed"` / `:escalate` / `:proceed` all accepted; absent
  ⇒ `:escalate`
- the launch form renders a refusal naming
  `auto-remediation-exhaustion-policy` and dispatches **no** run

## Scenario 5 — the full loop: exhaust, advance, annotate (US1, FR-007)

```bash
mise exec -- mix test test/speckit_orchestrator/analyze_runner_test.exs
mise exec -- mix test test/speckit_orchestrator/feature_runner_test.exs
```

Drives a scripted agent that reports the same High finding on every analyze
pass, through the existing injected seams.

Expected:

- remediation attempted exactly `attempt_limit` times — no more, no fewer
- the feature advances past `:analyze` instead of escalating
- it reaches `:done` with no operator input
- the terminal reason is `{:done, :advanced_with_unresolved_findings}`
- the residual findings appear in the annotation **verbatim**

## Scenario 6 — today's behaviour is unchanged (US2, SC-002)

```bash
mise exec -- mix test
```

Expected: every pre-existing assertion about the `:escalate` path still passes,
untouched. The regression pin lives in the **existing** test files rather than
in a new one, so a leak of the new path into the default fails a test that
predates the feature. Includes: no policy specified ⇒ escalate; explicit
`:escalate` ⇒ escalate; auto-remediation disabled ⇒ the policy is inert at
either value (FR-015).

## Scenario 7 — persistence and migration (FR-007, schema v4)

```bash
mise exec -- mix test test/speckit_orchestrator/store/
```

Expected:

- a v3-shaped `speckit_feature_run` row transforms to v4 with
  `advanced_with_findings: nil`
- `Store.Migrations.current_version/0 == 4`
- the annotation and the analyze phase attempt land in **one** transaction — a
  reader never sees one without the other
- `Store.Export.encode/1` round-trips the annotation with no Mnesia dependency

## Scenario 8 — the operator surfaces (FR-008, FR-013, FR-014)

```bash
mise exec -- mix test test/speckit_orchestrator/web/
mise exec -- mix test test/speckit_orchestrator/design_contract_test.exs
```

Expected:

- the launch form's policy control is pre-filled with `escalate`
- launching with `proceed` records it in the run's captured settings, and the
  run header renders the `auto_remediation_exhaustion_policy` chip
- a feature with an annotation renders a `data-advanced-with-findings` block
  naming the findings; a feature with a clean analyze renders none
- the design guard passes: **no** new color / radius / font-size / spacing
  literal, **no** status color on the new block

## Scenario 9 — the pull request body (FR-008b, SC-008)

```bash
mise exec -- mix test test/speckit_orchestrator/pull_request_test.exs
```

Expected: `Remediation.pr_note/1` renders the findings section; `pr_text/2`
appends it to **both** the Claude-authored body and the template fallback;
`pr_note(nil) == ""` so an ordinary feature's PR body is byte-identical to
today's.

## Scenario 10 — live end-to-end (opt-in)

```bash
mise exec -- mix test --include integration
```

Against a target repo whose analyze reports a persistent, non-mechanically-fixable
High finding: launch with `auto_remediation_exhaustion_policy: :proceed`, confirm
the feature completes unattended, the PR body names the finding, and the console
marks the feature. This is the only scenario that touches the real CLI and a real
worktree.

---

## Full gate before calling it done

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix test --cover        # pure core stays >90%
```

## Manual verification (constitution amendment, FR-016)

Not automatable — read and confirm:

- `.specify/memory/constitution.md` version line reads **3.0.0**
- a Sync Impact Report for `2.2.0 → 3.0.0` is prepended, with the MAJOR
  rationale and the prior reports preserved below it
- Principle V's exhaustion bullet permits the advance, still states the
  unconditional Critical halt, and adds the record-and-surface obligation
- no other principle's text changed
- the amendment is in the **same commit range** as the behaviour it permits
- `CLAUDE.md`, `docs/workflow.md`, and `docs/runbook.md` describe the new
  policy; `specs/017-analyze-auto-remediation/` is left as a historical record
