# Contract: `## NEEDS HUMAN` rule and question format

## One rule (FR-018)

`SpeckitOrchestrator.NeedsHuman` is the only definition. It is used by
`RunFeaturePhase` (for both the final-text match and the `spec.md` scan) and
by `EscalationsLive`. It also supplies the questions stored on each round
row, so round rows use it too.

| function | contract |
|---|---|
| `marker/0` | `~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m`, the heading on its own line only |
| `present?(text)` | `Regex.match?(marker(), text \|\| "")` |
| `extract(text)` | the text after the heading, up to the next `^## ` or EOF, trimmed. `nil` if absent |
| `parse_questions(block)` | `{:numbered, [Question]}` or `{:freeform, block}` |

The gate, scan and console behaviour for today's inputs is byte-identical
(SC-003). Existing tests for the moved regex keep passing unchanged.

## Format the clarify reviewer is taught (FR-012)

`priv/prompts/clarify.md` gains a "Question format" section:

```markdown
## NEEDS HUMAN

### Q1: Does a mid-month plan change prorate the current period?
**Context**: Decides whether ledger entries split at the change date (data model) and what the
customer sees on the statement.
**Options**: A) Prorate by day · B) Apply from next period · C) Charge the higher plan for the whole period
**Recommended**: B — no split entries, simplest statement

### Q2: …
```

These rules go in the prompt:

- Number items from Q1 with no gaps.
- Each item has `**Context**` and at least one of `**Options**` /
  `**Recommended**`.
- The materiality test and "bound and batch" rules are unchanged.

## Parse rules

- Items split on `^### Q(\d+)[:.][ \t]*(.+)$`.
- Field lines are `**Context**:`, `**Options**:` and `**Recommended**:`.
  Case is ignored. Continuation lines append to the current field.
- `Options` split on `·` or on `- ` bullet lines.
- If ids are not contiguous from 1, or an item has neither Options nor
  Recommended, or any non-blank text sits before `### Q1`, the result is
  `{:freeform, block}`.
- An empty or whitespace-only block gives `{:freeform, ""}`.

## Answer-folding instruction (re-run prompt, FR-008)

When `:clarify_answers` is set for a clarify session, `PhaseRequest.build/3`
appends this after the existing prompt and any resume guidance:

```
---
Operator answers (authoritative, round N of M):
Q1: <answer>            # or "Q1 (accepted recommended): <default>"
…                       # freeform: the single answer verbatim
These answers come from the human operator and override any default you would pick.
Fold every answer into `## Clarifications` as a resolved decision, realign stale
requirement text to match, and remove each answered item from `## NEEDS HUMAN`.
Delete the `## NEEDS HUMAN` heading entirely when no unanswered material question
remains. Do not re-ask an answered question.
```

Mode off never sets `:clarify_answers`, so the prompt is byte-identical.
