# Phase 0 Research: Self-Sufficient Resume

No open `NEEDS CLARIFICATION` remained in the spec (both questions resolved in the
2026-07-21 clarification session). Research here records the design decisions that
resolve the *how*, grounded in the existing code.

## D1 — Where the feature identity lives, and how resume rebuilds it

**Decision**: Extend the checkpoint record with `slug` and `path` (the two
`Feature` fields not already stored; `id` is the record key, `status`/`prereqs`
are not needed to resume — `prereqs` are irrelevant once a feature is diverted and
resumed alone). `resume/2` rebuilds `%Feature{id, slug, path, status: :pending}`
from the checkpoint when the caller supplies no explicit definition.

**Rationale**: `FeatureRunner` already writes the checkpoint at the diverted
terminal (`feature_runner.ex:201`) and holds the full `feature` there — slug and
path are in hand at write time at zero extra cost. `Feature`'s `@enforce_keys` are
exactly `[:id, :slug, :path]`, so those three fully reconstruct a runnable
work-unit; `Worktree.locate/2` derives branch/worktree from `id`+`slug`, so no
extra locator field is needed (FR-001 "plus any field required to locate its
branch/worktree" is satisfied by slug).

**Alternatives considered**:
- *Keep leaning on the backlog* — rejected: FR-004 requires resume without a
  loadable backlog (single-spec runs never had one). Today `resume/2` calls
  `load_backlog/0` eagerly via `Keyword.get_lazy`, which fails a single-spec
  resume outright.
- *A separate identity file* — rejected: the spec assumption fixes the checkpoint
  as the single durable per-feature artifact; a second file doubles the
  corrupt/absent/partial matrix.

## D2 — Precedence when identity is available from both sources (FR-003)

**Decision**: Explicit caller-supplied definition wins; otherwise checkpoint
identity. Implemented by *resolution*, not argument order: if `resume/2` finds the
id in the (explicitly passed or lazily loaded) `:features` list, that struct is
used; only when it is absent does resume reconstruct from the checkpoint. This is
the RECOMMENDED rule in FR-003 and is order-independent.

**Rationale**: Preserves today's behavior for the backlog case (acceptance 3),
adds the id-only case as a pure fallback, and never depends on which argument came
first. Backlog loading becomes *best-effort* on the resume path: a load failure or
a missing feature is no longer fatal — it falls through to checkpoint identity.

**Key behavioral change**: `resume/2` must **not** eagerly `load_backlog/0` and
fail on `{:error, {:unknown_feature, id}}` when a checkpoint exists. New order:
read checkpoint first (or attempt both and prefer explicit). The distinct
`{:unknown_feature, id}` outcome now fires only when there is **neither** an
explicit/backlog feature **nor** a checkpoint identity (edge: unknown-feature).

## D3 — What run context is captured, where, and how it reaches the checkpoint

**Decision**: A new pure `RunContext` captures exactly the six run-shaping settings
(`pr_workflow`, `max_concurrency`, `budget_usd`, `plan_stack`, `pr_base`,
`pr_remote`) from the effective run opts (`opt || Config.<key>()`) at `run/1` time.
The facade threads the captured `RunContext` into the runner/executor closures →
`FeatureRunner.run(feature, run_context: ctx, ...)` → `Checkpoint.write` persists
its `to_map/1` form under a `context` key.

**Rationale**: The context is fully known at `run/1` (opts + Config) — that is the
one place all six values are resolved. `FeatureRunner` is the only writer of the
checkpoint, so threading the map through the runner closure (the closures already
capture per-run state like `description`, `tracker`, `publisher`) is the minimal
seam. Capturing at run-start (not re-reading Config at checkpoint-write) is what
makes the value *original-run-shaped* rather than *whatever-env-exists-at-divert*.

**Alternatives considered**:
- *Re-read Config inside `Checkpoint.write`* — rejected: the checkpoint may be
  written in a later phase/process where env already drifted; that reintroduces the
  bug for the write side.
- *Persist context in a Coordinator-owned run file* — rejected: same single-artifact
  argument as D1; and a resumed feature has no live Coordinator to read from.

## D4 — Reapplying context on resume, precedence (FR-007), and PR-workflow routing (FR-009)

**Decision**: `resume/2` merges recorded context into the run opts with
`RunContext.merge/2`: for each of the six keys, **explicit resume opt** wins, else
**recorded value**, else leave unset so `run/1` falls to `Config`. Because `run/1`
already reads each setting as `Keyword.get(opts, key, Config.<key>())`, injecting
the recorded value as an explicit opt key is exactly what makes "recorded beats
live Config" true without touching `run/1`'s internals.

For **FR-009** (a resumed PR-workflow feature must keep stacking/preflight/PR):
selection of the resume worktree strategy becomes context-aware:
- If effective `pr_workflow` is **false** → inject `:runner` = the resume runner
  (reuse/recreate the existing branch's worktree; today's behavior).
- If effective `pr_workflow` is **true** → inject `:executor` = a *resume executor*
  (reuse/recreate the existing worktree instead of `Worktree.create(base:)`), and
  let `run_stacked/1` wrap it with its stacking + `pr_notify` (publish-on-`:done`).
  Preflight and cap-1 come for free from the `run_stacked` path.

**Rationale**: `run_stacked/1` builds `runner = opts[:runner] || stacked_runner(...)`
— injecting `:runner` would bypass stacking, losing PR-on-done. Injecting an
`:executor` instead keeps the stacking wrapper and only overrides *how the worktree
is obtained*, which is exactly the resume-specific difference. This satisfies FR-009
without duplicating the stacking logic.

**Note on single-feature stacking**: a resumed PR-workflow feature stacks on
`pr_base` (recorded) as the tracker's initial top and, on `:done`, publishes a PR
against it — the correct shape for a one-feature resume.

## D5 — Fallback for missing/partial context and observability (FR-008)

**Decision**: `RunContext.from_map/1` tolerates an absent `context` key (old
checkpoint) and a partial map (some keys missing). Missing keys are simply not
injected, so `run/1` falls to live Config/default. When the recorded context is
absent or partial, `resume/2` emits a single `Logger.info` line naming which
settings fell back to live config (e.g. `resume 007: no recorded run context;
using live config for pr_workflow, max_concurrency, ...`).

**Rationale**: FR-008 requires the fallback be *observable*, consistent with
Principle II. A log line at the resume boundary is the established pattern
(`publish_and_advance` logs, terminal emits log). We do not crash and do not
fabricate — partial context applies what it has (edge: partial context).

## D6 — Best-effort write and no-secrets guarantees (FR-010, FR-011)

**Decision**: No new failure modes. `Checkpoint.write/1` already rescues all errors
and returns `:ok`; adding `slug`/`path`/`context` keys to the encoded map keeps that
property (an encode/IO failure is still rescued). `RunContext` is defined to hold
**only** the six enumerated settings — no field can carry an API key/token — so
"context excludes secrets" is structural, not a runtime filter (FR-011).

**Rationale**: Best-effort is a pre-existing invariant (Principle IV / FR-010);
we preserve it by not adding any raising path. Structural exclusion of secrets is
stronger than a denylist and cannot drift.

## D7 — Atom-table safety on the extended record

**Decision**: `slug`/`path` are plain strings — no atom conversion. `context`
booleans/numbers/string-lists decode directly from JSON. The only atom on the read
path stays `last_phase`, already guarded by `String.to_existing_atom` +
`Pipeline.phase?/1` (`speckit_orchestrator.ex:211-215`). `pr_workflow` decodes as a
JSON boolean, not an atom.

**Rationale**: Preserves the existing atom-table-exhaustion protection; a
hand-corrupted checkpoint still cannot mint arbitrary atoms.
