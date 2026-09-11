# Contract: Spec directory resolution

Covers FR-009 – FR-011 (net one). Changes `SpeckitOrchestrator.SpecDir` only;
its public signatures are unchanged.

## 1. Public API (unchanged)

```elixir
@spec resolve(Path.t() | nil, map() | nil) :: Path.t() | nil
@spec file(Path.t() | nil, map() | nil, String.t()) :: Path.t() | nil
```

`feature` still needs only `:id`/`:slug` for a plain map to work; it now also
reads `:spec_number` when present. `Feature.spec_id/1` semantics apply: a map
with no `:spec_number` resolves under `:id`, which is what every existing test
fixture and every wave-1 feature already does.

## 2. Candidate rules

Ordered, most authoritative first. Every candidate is now constrained to this
feature's own spec id.

| # | Candidate | Constraint | Change |
|---|---|---|---|
| 1 | `<worktree>/specs/<spec_id>-<slug>` | exact | composed from `spec_id` instead of `id` |
| 2 | `<worktree>/<feature.json feature_directory>` | relative, no `..`, **and** `Path.basename/1`'s numeric prefix `== spec_id` | **new constraint** |
| 3 | `<worktree>/specs/<spec_id>-*` | **exactly one** wildcard match | **new constraint** |

Candidate 2's new constraint closes a live leak: `.specify/feature.json` is a
committed file, so a stacked worktree carries the **previous** feature's
`feature_directory` — a plain relative path with no `..`, which every pre-022
check accepts (research R4).

Candidate 3's new constraint is FR-010: two or more matches ⇒ that candidate
contributes nothing. Ambiguity is never settled by ordering — lexicographic,
creation time, or otherwise.

## 3. Behaviour table

Worktree carries `specs/001-core-ledger/` (complete) and `specs/001-billing/`
(this feature, wave-numbered `001`, spec-numbered `015` after allocation, so its
real directory is `specs/015-billing/`).

| Situation | `file(wt, feature, "tasks.md")` |
|---|---|
| `specs/015-billing/tasks.md` exists | that path |
| `specs/015-billing/` exists, empty; `feature.json` points at `specs/015-billing-2/` holding `tasks.md` | `specs/015-billing-2/tasks.md` (candidate 2: prefix `015` matches) |
| `feature.json` points at `specs/001-core-ledger/` | `nil` — prefix `001` ≠ `015` |
| only `specs/001-core-ledger/tasks.md` exists | `nil` (FR-009) |
| `specs/015-billing/` and `specs/015-billing-alt/` both exist, neither is the exact name, one holds `tasks.md` | `nil` (FR-010 — two prefix matches) |
| no candidate exists | `nil` |

`resolve/2` follows the same candidate list, returning the first candidate that
is a directory.

## 4. Downstream meaning of `nil` (FR-011, unchanged in shape)

| Caller | `nil` means |
|---|---|
| `RunFeaturePhase.missing_artifact/3` (plan/tasks artifact gate) | artifact **missing** → gate fails loud |
| `RunFeaturePhase.spec_has_needs_human?/2` (clarify scan) | **no marker** → do not escalate on a file we cannot identify |
| `TaskPlan.load/2` | **no task list** → `ChunkRunner` falls back to the unstructured plan and dispatches the work (US3 scenario 3) |
| `RunFeaturePhase` `artifact_absent_at_start?` probe (new) | artifact **absent** → the empty-checkpoint net is armed |
| `EscalationsLive` spec/plan reads | nothing to show |

These are today's directions, restated because FR-011 fixes them: an unresolved
artifact must never become "the other feature's file", and must never let
`TaskPlan` adopt a completed list it did not produce.
