# Contract: The numbering contract

**Feature**: `019-stacked-sequential-only`

The operator's single, explicit ordering input. This contract is what
`docs/breakdown-format.md` must document for operators (FR-013).

---

## The rule

**The number in the filename determines execution order. Renumbering is how
order is changed.** Nothing else reorders the work.

```
docs/breakdown/          →  execution order
  001-core-ledger.md          001-core-ledger
  005-categories.md           005-categories
  020-reports.md              020-reports
```

---

## Parsing

| Aspect | Rule |
|---|---|
| Filename pattern | `^(?<number>\d{3,})-(?<slug>.+)\.md$` — unchanged |
| Non-matching files | ignored (e.g. `README.md`) — unchanged |
| `id` | the number **as written**, zero-padding preserved: `"001"`. This is the branch name (`feature/001-core-ledger`), the store key, and the operator-facing label. |
| `number` | the number **parsed as an integer**: `1`. This is the ordering key and nothing else. |

---

## Ordering

Ascending by `number`, compared **numerically**:

- `001` before `002` before `1000` — string comparison would put `"1000"` before
  `"999"`; numeric comparison does not.
- Differing zero-padding widths order predictably: `01-a.md` is not legal (needs
  3+ digits), but `001-a.md` and `1000-b.md` coexist and order correctly.

---

## Gaps are legal (FR-011)

`001, 005, 020` runs in that order with no error, no warning, and no attempt to
fill or interpret the gaps. Operators number for intent, not for contiguity.

---

## Duplicates are rejected at load (FR-012)

Two files whose numbers are **numerically equal** make the order ambiguous. The
loader raises rather than picking one:

```
** (SpeckitOrchestrator.Backlog.DuplicateNumberError) two features claim number 2:
     docs/breakdown/002-categories.md
     docs/breakdown/0002-categories-v2.md
```

Note `002` and `0002` are duplicates — numeric equality, not string equality
(spec Assumptions). The message names every conflicting file so the fix is
obvious without searching.

---

## Prerequisites are inert (FR-010)

A `## Prerequisites` section in a breakdown file is **prose for humans**. The
system does not read it, does not validate it, and does not act on it. It has no
effect on ordering.

Operators are not required to delete these sections from existing files (spec
Assumptions). A file declaring `- 002 Categories` as a prerequisite still runs
wherever its own number places it.

**What this replaces**: `Backlog.load!/1` no longer raises `MissingPrereqError`
on a dangling reference or `CycleError` on a cycle — a dangling reference is
just prose naming something that does not exist, and a cycle in prose is not a
cycle in anything the system executes.

---

## What the system does not validate

The system validates that numbering is **unambiguous**. It does not infer
whether the chosen order is **semantically correct** (spec Assumptions):

> An operator who numbers a dependent feature before the work it depends on gets
> the order they asked for.

This is deliberate. Ordering is now the operator's single explicit input, and a
system that second-guessed it would reintroduce the dependency layer this
feature removes.

---

## Ad-hoc features

Ad-hoc single-spec features have no operator-chosen number — their id is
auto-assigned. They form their own group, **"Ad-hoc"**, ordered by creation time
(oldest first), and are never links in the backlog chain: each branches from the
configured base branch and leaves the chain top where it found it (FR-024,
FR-025, FR-028).

Every operator-facing listing shows the two groups distinctly, so it is never
ambiguous which ordering rule applies to a given feature (FR-027).
