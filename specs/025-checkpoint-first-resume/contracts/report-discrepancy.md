# Contract: the discrepancy on the existing operator surface

**Kind**: rendering extension of an existing report (no new surface).
**Modules**: `SpeckitOrchestrator.Recovery.Report`, `SpeckitOrchestrator.Recovery`
**Extends**: `specs/014-recovery-reconciliation/contracts/recovery-report.md`
**Satisfies**: FR-005, FR-006, FR-012, SC-005; Principle V, Principle VII

---

## 1. Where an operator sees it before any spend

`SpeckitOrchestrator.resumable/1` (and `resumable_run/0`) call
`Recovery.reconcile_run/2`, which calls `plan_run/2` — **read-only for
non-`:done` verdicts** — and return `%{report:, statuses:, resume_phases:,
gap_possible?:}`. No `Coordinator` is started, no phase runs, no reservation
is made. `Recovery.Report.format/1` renders it.

FR-006 therefore needs **no new code path**: the discrepancy appears in the
existing preview the moment `Reconcile.status/3` produces it. What this
contract adds is that the preview *names the two phases*.

`SpeckitOrchestrator.recover_record/1` previews through
`Recovery.Rebuild.propose/3`, which builds `conflicts` from its
`:unreconcilable` discrepancies with `detail: reason` — the widened reason
travels there unchanged (FR-012).

---

## 2. Type change

```elixir
# Recovery.Report
@type conflict_reason :: atom() | {atom(), map()}
@type conflict_row :: %{id: String.t(), reason: conflict_reason()}
```

`Report`'s struct gains no field. `Recovery.persisted_status/1`'s
`{:conflict, _reason}` clause is unchanged (wildcard).

---

## 3. `reason_label/1`

```elixir
@doc "Operator-facing label for a conflict reason. Pure."
@spec reason_label(Reconcile.conflict_reason()) :: String.t()
```

| Input | Output |
|---|---|
| `:ambiguous_evidence` | `"ambiguous_evidence"` |
| `:pr_without_branch` | `"pr_without_branch"` |
| `:done_without_artifacts` | `"done_without_artifacts"` |
| `:checkpoint_without_branch` | `"checkpoint_without_branch"` |
| `{:checkpoint_behind_trail, %{checkpoint: :plan, trail: :analyze}}` | `"checkpoint_behind_trail (checkpoint: plan, trail: analyze)"` |
| `{:damaged_checkpoint, %{phase: "implemnt", last_completed_phase: nil}}` | `"damaged_checkpoint (phase: \"implemnt\", last_completed_phase: nil)"` |

Rules:

- A bare atom renders exactly as `to_string/1` does today — **no existing
  output changes** (FR-014/SC-004).
- A `{tag, detail}` renders as `"<tag> (k: v, k: v)"`, keys in the map's
  insertion-sorted order, values via `to_string/1` for atoms and phases and
  `inspect/1` for anything else (so a garbled string stays quoted and
  visibly not-a-phase).
- The label is the real atom, never a friendlier synonym — Principle VII
  ("the UI speaks the system's vocabulary").

---

## 4. Call sites (both existing)

```elixir
defp reconciled_label({:conflict, reason}), do: "conflict:" <> reason_label(reason)
```

```elixir
Map.has_key?(conflict_reasons, id) ->
  "CONFLICT — #{reason_label(Map.fetch!(conflict_reasons, id))}; human resolve"
```

Today both interpolate the reason directly, which raises `Protocol.UndefinedError`
on a tuple — these two edits are what make the widened reason renderable.

---

## 5. Rendered example

A whole-run preview in which feature `003`'s checkpoint is behind its trail:

```
Feature  Recorded  Reconciled                                 Note
001      done      done
002      running   running (resume: implement)                 next runnable
003      running   conflict:checkpoint_behind_trail (checkpoint: plan, trail: analyze)  CONFLICT — checkpoint_behind_trail (checkpoint: plan, trail: analyze); human resolve

Spend: $12.40 (preserved)   Next runnable: ["002"]
```

`003` is `:blocked` (`persisted_status/1`), so `Release.next/3` never releases
it and `dispatch_statuses/2` never flips it to `:pending` — no phase runs and
no budget is spent for it (SC-005, Principle IV). `002` still resumes: a
blocked feature is not a `{:stopped, _, _}`, because `:blocked` is absent from
`Feature.terminal_statuses/0`.

---

## 6. Console

Unchanged. `lib/speckit_orchestrator/web/` renders no conflict reason today
(`grep -rn conflict lib/speckit_orchestrator/web/` is empty), so there is no
LiveView template, no status color, and no `console.css` token to touch — the
`design_contract_test` guard is unaffected. The spec's Assumptions state no
new operator surface is introduced.

---

## 7. Non-goals

- No `discrepancies` list entry: that list is 016's rebuild-proposal
  vocabulary (`:absent_from_backlog`/`:absent_from_record`/`:unreconcilable`).
  A checkpoint-vs-trail contradiction is a **conflict**, which is the list
  that already blocks its feature.
- No new footer, column, or `Report` struct field.
