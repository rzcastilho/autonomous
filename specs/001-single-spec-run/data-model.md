# Phase 1 Data Model: Single-Spec Run Mode

No persistent datastore. "Entities" are in-memory structs and on-disk files.

## Feature (reused, unchanged struct)

`SpeckitOrchestrator.Feature` — the existing work-unit struct. Single-spec mode
constructs one, it is not a new type.

| Field | Type | Single-spec value |
|-------|------|-------------------|
| `id` | `String.t()` (zero-padded, `~r/\d{3,}/`) | **auto-assigned** = `max(existing NNN)+1`, default `"001"` |
| `slug` | `String.t()` (kebab-case) | **derived** from the description |
| `path` | `String.t()` | seed path `"<breakdown_dir>/<id>-<slug>.md"` (relative; basename is what `specify` reads) |
| `prereqs` | `[String.t()]` | always `[]` (wave of one) |
| `status` | `Feature.status()` | starts `:pending`; terminal ∈ `{:done, :escalated, :halted, :failed}` |

**Invariants**:
- id is unique across existing breakdown files **and** `feature/NNN-*` branches.
- `prereqs == []` always (single-spec never has dependencies).
- Constructing a Feature performs **no IO** — it is pure (Principle I).

## FeatureDescription (input value)

The operator-supplied free-text string. Not a struct — a validated argument.

**Validation** (at `run_spec/2` entry, Principle II):
- `nil` / `""` / whitespace-only → `{:error, :empty_description}`, no side effects.
- Otherwise trimmed and used both to derive id/slug and as the seed body.

## Seed file (on-disk artifact)

The materialized one-off breakdown file that seeds the `specify` phase.

| Property | Value |
|----------|-------|
| Location | `<worktree>/<breakdown_dir>/<id>-<slug>.md` |
| Written by | the seed-writing runner wrapper, **after** `Worktree.create/2`, before `FeatureRunner.run/2` |
| Committed by | existing terminal `Worktree.commit/2` (`git add -A`) onto the feature branch |
| Format | a minimal breakdown doc: `# <id> — <Title>`, the operator's description, and a `## Prerequisites` section reading `None` |
| Read by | the `specify` phase via `PhaseRequest` `breakdown_ref/1` (unchanged) |

**Rule**: written inside the worktree only — never in the base repo tree
(Principle III containment).

## SingleSpecRun (invocation, not persisted)

One call to the facade. Reuses the existing `Run` concept held by the
`Coordinator` (statuses, in-flight, spend, final report). Single-spec adds no new
run state — it supplies a one-element `features` list and a seed-writing runner to
the existing `start_run/2` / `run_stacked/1`.

## Derivation rules (pure, in new `SingleSpec` module)

- **next_id(existing_ids)**: `existing_ids` gathered from breakdown filenames and
  `feature/NNN-*` branches; returns `max+1` zero-padded to ≥3 digits, or `"001"`
  when empty. Pure over the passed-in id list (the *gathering* IO lives in the
  facade).
- **slug(description)**: downcase → keep `[a-z0-9]+` tokens → take first 5 →
  join `-` → truncate ≤40 chars. Non-empty guaranteed for a non-empty
  description; a description with no alphanumerics falls back to `"feature"`.
- **seed_body(id, title, description)**: renders the breakdown-format markdown
  (see Seed file → Format).

## State transitions

Unchanged from the existing pipeline — single-spec mode does not introduce new
states or transitions. The one feature moves
`:pending → :running → {:done | :escalated | :halted | :failed}` exactly as a
backlog feature, governed by `Pipeline.next/3` and the clarify/analyze gates.
