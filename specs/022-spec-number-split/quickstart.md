# Quickstart: validating Spec Number Split

Runnable validation for feature 022. Every scenario maps to a Success Criterion.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

No target repository is needed for §1–§5; §6 needs a scratch git repo.

## 1. Full default suite (hermetic)

```bash
mise exec -- mix test
```

Expected: green. The default suite creates and tears down its own Mnesia schema
in a temp directory, so migration 5 is exercised without touching the
machine-global store.

## 2. Pure-core coverage

```bash
mise exec -- mix test --cover
```

Expected: `SpecNumber` and `Checkpoint` at 100% (both are total decision tables
with no IO); pure core stays above 90% overall.

## 3. Allocation (SC-002, SC-004, US1)

```bash
mise exec -- mix test test/speckit_orchestrator/spec_number_test.exs
```

Covers, per `contracts/spec-number-allocation.md`:

- `["001-a", … , "014-n"]` ⇒ `{:ok, 15}` (US1 scenario 1)
- `[]` and `["autonomous", "README.md"]` ⇒ `{:ok, 1}` (US1 scenario 5, FR-003)
- `["001-a", "007-b"]` ⇒ `{:ok, 8}` — gaps are never filled
- `["001-a", "0002-b", "002-c"]` — numeric comparison, `002`/`0002` equal
- a listing whose highest-plus-one already exists ⇒
  `{:error, {:spec_dir_exists, entry}}` (US1 scenario 7, FR-003a)
- `["001-core-ledger", "001-billing"]` — the damaged pair; allocation still
  proceeds from the highest present

## 4. Reuse on resume (SC-004, US1 scenario 3)

```bash
mise exec -- mix test test/speckit_orchestrator/store/writer_test.exs \
                     test/speckit_orchestrator/recovery_test.exs
```

Expected:

- `record_spec_number/3` writes once; a second call for the same feature aborts
  `{:already_allocated, id, n}` — no second directory is ever allocated.
- A feature rebuilt from a store record carries its recorded `spec_number`, so
  `Worktree.locate/2` reproduces the original branch and path.

## 5. The two nets, each alone (SC-007)

```bash
mise exec -- mix test test/speckit_orchestrator/spec_dir_test.exs \
                     test/speckit_orchestrator/checkpoint_test.exs \
                     test/speckit_orchestrator/feature_runner_test.exs
```

**Net one alone** — `spec_dir_test.exs`: with two directories sharing a numeric
prefix and an artifact present only in the other one, `SpecDir.file/3` returns
`nil`, not the other feature's file (US3 scenarios 1–2); `TaskPlan.load/2`
returns no plan, so the chunk loop dispatches instead of skipping (US3
scenario 3).

**Net two alone** — `checkpoint_test.exs` walks every cell of the decision
table; `feature_runner_test.exs` drives a `:tasks` phase that reports `:ok`,
leaves the tree unchanged, and started with `tasks.md` absent. Expected: the
feature is `:failed` with reason `{:empty_checkpoint, :tasks}`, and `:analyze`,
`:implement`, `:converge` never run (US2 scenarios 1–3).

**FR-014a** — the same runner test with `tasks.md` present at phase start and an
unchanged tree: the feature advances normally (US2 scenario 5).

**FR-015** — a `:clarify` or `:converge` phase that commits nothing advances
(US2 scenario 4).

## 6. Migration against a real store (SC-005)

```bash
mise exec -- mix test --include integration test/speckit_orchestrator/store/migrations_test.exs
```

Expected: a directory recorded at v4 boots to v5 with every row intact and each
`spec_number` equal to that row's `number`; zero rows dropped or truncated. A v1
directory still aborts by name (019's refusal migration is untouched).

## 7. Regression, end to end (FR-017, SC-001, SC-003)

```bash
mise exec -- mix test test/speckit_orchestrator/spec_number_split_regression_test.exs
```

Reproduces the production failure in one test: a feature whose **wave** number
is `001` runs against a base already carrying `specs/001-<other>/` with a
complete artifact set, and whose `:tasks` phase reports success while writing
nothing.

Expected:

- the feature is allocated a fresh spec number and builds under
  `specs/<new>-<slug>/`
- it fails at `:tasks` with `{:empty_checkpoint, :tasks}`
- no later phase runs
- `specs/001-<other>/tasks.md` is never read

## 8. Both numbers on every surface (SC-006)

```bash
mise exec -- mix test test/speckit_orchestrator/report_test.exs \
                     test/speckit_orchestrator/web \
                     test/speckit_orchestrator/design_contract_test.exs
```

Expected: the run report line, `RunDetailLive`'s feature row, and the PR body
each name the wave number and the spec number under distinguishable labels; an
unallocated feature renders `not allocated`, never a borrowed wave number. The
design contract guard stays clean — no new color, radius, font-size, or spacing
literal, and both numbers render in the mono family.

## 9. Manual smoke against a scratch repo

```bash
tmp=$(mktemp -d); cd "$tmp"
git init -q . && mkdir -p specs/001-alpha specs/autonomous && \
  touch specs/001-alpha/tasks.md README.md && \
  git add -A && git -c user.email=t@t -c user.name=t commit -qm init

mise exec -- iex -S mix
```

```elixir
{:ok, entries} = SpeckitOrchestrator.Worktree.spec_dirs("#{tmp}", "HEAD")
# => {:ok, ["001-alpha", "autonomous"]}   # "autonomous" is ignored, not fatal
SpeckitOrchestrator.SpecNumber.allocate(entries, "billing")
# => {:ok, 2}
```

Details: `contracts/spec-number-allocation.md`, `contracts/spec-dir-resolution.md`,
`contracts/empty-checkpoint.md`, `contracts/store-schema-v5.md`, `data-model.md`.
