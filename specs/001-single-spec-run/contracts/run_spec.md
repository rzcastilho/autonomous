# Contract: `run_spec/2` facade + seed + runner seam

The single-spec entry point. This is the project's interface contract for
Feature 001 (an Elixir library / `iex` operator surface — no HTTP/CLI-arg layer).

## 1. Facade function

```elixir
@spec SpeckitOrchestrator.run_spec(description :: String.t(), opts :: keyword()) ::
        GenServer.on_start()
        | {:error, :empty_description}
        | {:error, {:preflight, [term()]}}
```

**Behavior**:
1. Validate `description`. `nil` / empty / whitespace-only → `{:error,
   :empty_description}` with **no** Coordinator, worktree, or file side effect.
2. Gather taken ids (breakdown dir + `feature/NNN-*` branches); build a
   `Feature{}` via `SingleSpec` (auto id, derived slug, seed path, `prereqs: []`).
3. Delegate to the existing run path with a **seed-writing runner**:
   - `pr_workflow: false` (default) → `start_run(features: [feature], runner:
     seed_runner)`.
   - `pr_workflow: true` → `run_stacked(features: [feature], executor:
     seed_executor)` (cap 1, remote/pack preflight first).
4. Return the Coordinator `on_start` tuple, or a preflight error under the PR
   workflow.

**Options** (all optional; unknown keys ignored):

| Option | Default | Meaning |
|--------|---------|---------|
| `:pr_workflow` | `Config.pr_workflow?()` | open a PR for the finished feature |
| `:owner` | caller pid | receives `{:run_complete, report}` |
| `:runner` / `:executor` | seed-writing default | test seam (bypasses real worktree/CLI) |
| `:features` | derived `[feature]` | test seam to inject a prebuilt feature |
| `:repo`, `:breakdown_dir` | `Config.*` | override where already-taken ids are scanned from (tests only — the real worktree/seed location always follows `Config.repo()`/`Config.worktree_root()`/`Config.breakdown_dir()`, matching `run/1`; to redirect a real run, override those globally, e.g. `Application.put_env(:speckit_orchestrator, :repo, ...)`) |

**Guarantees preserved** (by delegation, not reimplementation): clarify-gate
escalation, analyze-gate halt, breaker drain-not-kill, write containment, durable
transcripts, worktree kept-on-non-done, final drain report.

## 2. Seed-writing runner seam

```
seed_runner    :: (Feature.t(), notify) -> :ok      # non-PR
seed_executor  :: (Feature.t(), base :: String.t(), notify) -> :ok   # PR workflow
```

**Contract**: identical to the existing `default_runner/2` / `default_executor/3`
except that, immediately **after** `Worktree.create/2` succeeds and **before**
`FeatureRunner.run/2`, it writes the seed file to
`<worktree.path>/<breakdown_dir>/<id>-<slug>.md`.

- A seed-write failure fails the feature (`notify.(id, :failed, {:seed, reason})`)
  and does **not** run the pipeline — fail loud, no unguarded run.
- A `Worktree.create/2` error keeps the existing behavior
  (`notify.(id, :failed, {:worktree, reason})`).

## 3. Seed file format

Written to `<worktree>/<breakdown_dir>/<id>-<slug>.md`:

```markdown
# <id> — <Title derived from slug>

<the operator's description verbatim>

## Prerequisites

None
```

- MUST parse under `Backlog`'s file pattern (`NNN-slug.md`, `## Prerequisites` →
  `None`) so the format stays consistent with backlog inputs.
- Read by `specify` via `PhaseRequest.breakdown_ref/1` (unchanged).

## 4. `SingleSpec` pure module (new)

```elixir
@spec SingleSpec.build(description :: String.t(), taken_ids :: [String.t()], opts :: keyword()) ::
        {:ok, Feature.t()} | {:error, :empty_description}
@spec SingleSpec.next_id(taken_ids :: [String.t()]) :: String.t()
@spec SingleSpec.slug(description :: String.t()) :: String.t()
@spec SingleSpec.seed_body(id :: String.t(), description :: String.t()) :: String.t()
```

All four are **pure** (no IO). `build/3` composes the others and validates the
description.

## 5. Test contract (acceptance-mapped)

| Test | Asserts (spec ref) |
|------|--------------------|
| empty/whitespace description | `{:error, :empty_description}`, no side effect (FR-012, SC-005) |
| `next_id` over `["001","003"]` and `feature/002-*` | `"004"`; over `[]` → `"001"` (FR-003, non-clobber) |
| `slug` derivation + no-alphanumeric fallback | kebab-case; `"feature"` fallback (FR-003) |
| `seed_body` round-trips through `Backlog` parse | one feature, `prereqs: []` (format consistency) |
| `run_spec` with injected `:runner` + `:features` | one feature runs, wave of one, drain report accounts for exactly it (FR-001, SC-006, FR-014) |
| `run_spec` with `pr_workflow: true` + injected `:executor`/`:publisher` | cap-1, seed written, PR opened on `:done` (FR-014, Story 3) |
| seed-write failure via a runner that stubs a failing write | feature `:failed`, pipeline not run (FR containment) |
