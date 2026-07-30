# Breakdown file format (Backlog parser contract)

`SpeckitOrchestrator.Backlog.load!/1` parses a directory of per-feature
breakdown files into the numbered backlog. This documents the format it
expects, so it can be reconciled with the real `macro-spec-breakdown` skill
output later (closing CONFIRM #5 against production-shaped input).

## Filename

`NNN-slug.md` where:

- `NNN` — zero-padded numeric id, 3+ digits (`001`, `002`, …). Becomes
  `Feature.id` **as written**, zero-padding preserved — this is the branch
  name (`feature/001-core-ledger`), the store key, and the operator-facing
  label.
- `slug` — kebab-case name. Becomes `Feature.slug`.

Files not matching (e.g. `README.md`) are **ignored**.

## The numbering contract (FR-013)

**The number in the filename determines execution order. Renumbering is how
order is changed.** Nothing else reorders the work (`contracts/backlog-order.md`
in `specs/019-stacked-sequential-only/`).

- `Feature.number` is the filename's number **parsed as an integer** — the
  ordering key, and nothing else. Ordering compares numerically: `001` before
  `002` before `1000` (string comparison would wrongly put `"1000"` before
  `"999"`).
- **Gaps are legal.** `001, 005, 020` runs in that order with no error, no
  warning, and no attempt to fill or interpret the gaps. Operators number for
  intent, not for contiguity.
- **Duplicates are rejected at load.** Two files whose numbers are
  **numerically equal** — `002` and `0002` are duplicates, not distinct —
  raise `Backlog.DuplicateNumberError` naming every conflicting file, rather
  than picking one silently.
- The system validates that numbering is **unambiguous**. It does not infer
  whether the chosen order is semantically correct: an operator who numbers a
  dependent feature before the work it depends on gets the order they asked
  for.

## Prerequisites section — inert prose (FR-010)

A `## Prerequisites` heading (any level `#`..`######`, case-insensitive) is
**prose for humans only**. The system does not read it, does not validate it,
and does not act on it — it has no effect on ordering. Operators are not
required to delete these sections from existing files; a file declaring
`- 002 Categories` as a prerequisite still runs wherever its own number places
it.

```markdown
# 003 — Budgets

## Prerequisites

- 002 Categories
```

→ `%Feature{id: "003", number: 3, slug: "budgets", group: :backlog, status: :pending}`.
The Prerequisites section changes nothing about when `003` runs.

**What this replaces**: `Backlog.load!/1` no longer raises `MissingPrereqError`
on a dangling reference or `CycleError` on a cycle — a dangling reference is
just prose naming something that does not exist, and a cycle in prose is not a
cycle in anything the system executes.

## Ad-hoc features

Ad-hoc single-spec features (`SingleSpec.build/3`) have no operator-chosen
number — their id is auto-assigned and they never come from a breakdown file.
They form their own group, **"Ad-hoc"**, ordered by creation time (oldest
first), and are never links in the backlog chain: each branches from the
configured base branch and leaves the chain top where it found it (FR-024,
FR-025, FR-028). Every operator-facing listing shows the two groups distinctly
(FR-027).

## Validation (load-time, raises)

- **Numerically equal numbers** across two or more files →
  `Backlog.DuplicateNumberError`, naming every conflicting file.

## Reference fixtures

`test/fixtures/breakdown/` is the LedgerLite 7-feature backlog (plan §7.1);
`test/fixtures/breakdown_duplicate/` holds two files with numerically equal
numbers, used to prove `load!/1` raises `DuplicateNumberError`.
