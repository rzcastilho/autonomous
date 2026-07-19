# Phase 0 Research: Single-Spec Run Mode

All unknowns below were resolved against the existing codebase; none remain open.

## R1 — How does the `specify` phase receive the feature description today?

**Decision**: Reuse the existing seed mechanism — materialize a one-off breakdown
file inside the worktree.

**Findings**: `PhaseRequest.build/3` builds the `specify` prompt as
`"/speckit.specify Implement the feature specified in <breakdown_ref> (id <id>,
<slug>). Follow the constitution."`, where `breakdown_ref/1` is
`Path.join(Config.breakdown_dir(), Path.basename(feature.path))`
(`lib/speckit_orchestrator/phase_request.ex`). The CLI runs with
`cwd = <worktree path>` (`Actions.RunFeaturePhase.run/2`). So the feature
description must exist at `<worktree>/<breakdown_dir>/<basename(path)>` when
`specify` runs.

**Rationale**: If single-spec mode writes the operator's description to that exact
path inside the worktree, `PhaseRequest`, the CLI invocation, and every
downstream phase work **unchanged**. This is the smallest possible change and
keeps `Feature.path` meaningful (it points at the seed).

**Alternatives considered**:
- *Embed the description inline in the `specify` prompt when `path` is nil* —
  requires branching `PhaseRequest` (breaks its "pure, path-free, reuse CLI
  discovery" contract) and a nil-path `Feature`. Rejected: more code, contaminates
  a reused pure module.
- *Commit the seed to the base repo before creating the worktree* — mutates the
  target repo's base branch with a throwaway file. Rejected: violates "changes how
  a run is started, not the target's committed history" and risks polluting `main`.

## R2 — When and where is the seed written (committed vs on-disk)?

**Decision**: Write the seed into the worktree **after** `Worktree.create/2`,
uncommitted; the existing terminal `Worktree.commit/2` captures it with the
generated artifacts.

**Findings**: The `specify` phase reads the seed via the CLI `Read` tool from the
worktree filesystem — it does not require the file to be committed, only present.
`FeatureRunner.handle_worktree/3` runs `Worktree.commit/2` (`git add -A`) on every
terminal state before removal/retention, so an on-disk seed is committed onto the
feature branch alongside `specs/`, `plan.md`, `tasks.md`, and code.

**Rationale**: Keeps the base repo untouched; the seed lives only on the feature
branch, exactly like every other pipeline artifact.

**Alternatives considered**: committing pre-create (see R1) — rejected.

## R3 — How is the feature id auto-assigned deterministically without a backlog?

**Decision**: Next id = `max(existing NNN) + 1`, zero-padded to 3 digits;
default `001` when none exist. "Existing" scans **both** the breakdown dir
(`<repo>/<breakdown_dir>/NNN-*.md`) and existing feature branches
(`feature/NNN-*`) so a single-spec id never collides with a prior backlog or
single-spec feature.

**Findings**: `Backlog` derives ids from `NNN-slug.md` filenames
(`@file_pattern ~r/^(?<id>\d{3,})-(?<slug>.+)\.md$/`). `Worktree.locate/2`
produces branch `feature/<id>-<slug>`. Both are the authoritative "already taken"
sources.

**Rationale**: Deterministic and non-clobbering (FR-003). Reuses the established
3-digit id convention so single-spec and backlog features share one id space.

**Alternatives considered**:
- *Always `001`* — collides with an existing feature 001 and would reuse/overwrite
  its branch. Rejected (FR-003 non-clobber).
- *Timestamp id* — `init-options.json` supports `feature_numbering: "timestamp"`,
  but this project is configured `sequential`; a timestamp id would diverge from
  the `NNN` convention the rest of the system parses. Rejected for consistency.

## R4 — How is the slug derived from free-text?

**Decision**: Lowercase the description, keep `[a-z0-9]` runs, join the first N
(default 5) tokens with `-`, trim to a max length (default 40 chars), and if the
resulting `feature/<id>-<slug>` branch or seed path already exists, this is a
re-run → reuse it (FR-013), never silently rename.

**Findings**: Slugs elsewhere are kebab-case (`core-ledger`). `Worktree.create/2`
already **reuses an existing branch** (`git_worktree_add` → `branch_exists?`), so
re-running the same description resumes the same branch — matching the resolve/2
flow and the "reuse existing branch" edge case.

**Rationale**: Human-readable, deterministic for a given description, and the
existing branch-reuse behavior gives idempotent re-runs for free.

**Alternatives considered**:
- *Random/hash slug* — not human-readable; harder to locate the worktree.
  Rejected.
- *Collision-suffix (`-2`)* on a matching branch — would fork a second workspace
  instead of resuming; contradicts the re-run edge case. Rejected.

## R5 — How does a single feature run as a "wave of one"?

**Decision**: Pass `features: [feature]` (a one-element list, empty `prereqs`) to
the existing `start_run/2`; the `Coordinator` + `Release` release it immediately
and drain to a final report.

**Findings**: `SpeckitOrchestrator.run/1` already accepts an explicit `:features`
list and forwards it to `Coordinator.start_link`. `Release` releases any
`:pending` feature whose prereqs are all `:done`; with no prereqs it is releasable
on the first wave. `max_concurrency` is irrelevant for one feature. The drain path
(final report: done/escalated/halted/failed/spend) is identical to a backlog run.

**Rationale**: Zero new orchestration code; the safety/report machinery is
inherited verbatim (FR-005..FR-011, FR-014).

**Alternatives considered**: bypass the Coordinator and call `FeatureRunner.run`
directly — loses the drain report, breaker-between-features check, and status
snapshot. Rejected.

## R6 — Does the PR-stacking workflow (P3) work for a single feature?

**Decision**: Reuse `run_stacked/1` with `features: [feature]` and a
seed-writing **executor** seam.

**Findings**: `run_stacked/1` reads `features:` through `start_run/2`, forces cap
1, preflights the target remote/pack, and uses an `:executor` seam
(`(feature, base, notify) -> :ok`) that defaults to worktree-create +
`FeatureRunner`. Wrapping that executor to write the seed first is the same shape
as the non-PR runner wrapper.

**Rationale**: The single feature stacks on `pr_base` and opens one PR on `:done`,
subject to the same start-time preflight (FR-014, Story 3 AC-2).

**Alternatives considered**: a separate PR path for single-spec — needless
duplication. Rejected.

## R7 — Empty/invalid description handling

**Decision**: Validate at the facade entry (`run_spec/2`); a `nil`, empty, or
whitespace-only description returns `{:error, :empty_description}` and starts no
Coordinator, no worktree (FR-012, SC-005).

**Rationale**: Fail loud at the boundary (Principle II) before any side effect.

## Post-research Constitution re-check

No decision introduced a new dependency from pure logic on the CLI/harness, a new
privilege surface, or a new spend path. **Constitution Check remains PASS.**
