# Breakdown file format (Backlog parser contract)

`SpeckitOrchestrator.Backlog.load!/1` parses a directory of per-feature
breakdown files into the dependency DAG. This documents the format it expects,
so it can be reconciled with the real `macro-spec-breakdown` skill output later
(closing CONFIRM #5 against production-shaped input).

## Filename

`NNN-slug.md` where:

- `NNN` — zero-padded numeric id, 3+ digits (`001`, `002`, …). Becomes
  `Feature.id`.
- `slug` — kebab-case name. Becomes `Feature.slug`.

Files not matching (e.g. `README.md`) are **ignored**.

## Prerequisites section

Declared in a `## Prerequisites` heading (any level `#`..`######`,
case-insensitive). The section runs until the next heading. Rules:

- Every 3+-digit token in the section is read as a prereq feature id.
- `None`, an empty section, or no section at all → no prerequisites.
- Only the Prerequisites section is scanned — digits elsewhere in the file
  (titles, prose, acceptance criteria) are ignored.

Example:

```markdown
# 003 — Budgets

## Prerequisites

- 002 Categories
```

→ `%Feature{id: "003", slug: "budgets", prereqs: ["002"], status: :pending}`.

## Validation (load-time, raises)

- **Dangling prereq** → `Backlog.MissingPrereqError`.
- **Dependency cycle** → `Backlog.CycleError` (Kahn-style resolution; any node
  that can't be topologically ordered is in or feeds a cycle).

## Reference fixtures

`test/fixtures/breakdown/` is the LedgerLite 7-feature DAG (plan §7.1);
`test/fixtures/breakdown_cyclic/` is a 2-node cycle used to prove `load!/1`
raises.
