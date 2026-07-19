# Quickstart: Single-Spec Run Mode

Validates that one feature can be built end-to-end from a description alone. See
[contracts/run_spec.md](./contracts/run_spec.md) and [data-model.md](./data-model.md)
for the interface and entities.

## Prerequisites

- Toolchain via mise (`mise exec --`; Elixir 1.20.2-otp-28).
- A configured target repo (`config :speckit_orchestrator, repo: …`) with the
  committed Spec Kit scaffold (`.specify/`, `.claude/`) and a committed
  constitution — same preconditions as a backlog run (`docs/runbook.md`).
- `mise exec -- mix deps.get && mise exec -- mix compile` clean (no warnings).

## Unit validation (no CLI, no worktree)

Proves the pure logic and the facade wiring through injected seams.

```bash
mise exec -- mix test test/speckit_orchestrator/single_spec_test.exs
mise exec -- mix test test/speckit_orchestrator/run_spec_test.exs
mise exec -- mix test --cover        # >90% on lib/speckit_orchestrator/single_spec.ex
```

Expected:
- empty/whitespace description → `{:error, :empty_description}`, nothing started.
- `next_id`/`slug`/`seed_body` behave per the contract table.
- `run_spec` with an injected `:runner` runs exactly one feature and drains a
  report accounting for it.

## End-to-end validation (real harness — opt-in)

Runs the real pipeline against the configured target. Start `iex`:

```bash
mise exec -- iex -S mix
```

```elixir
# One feature from a description only — no breakdown file authored.
{:ok, _coord} = SpeckitOrchestrator.run_spec("""
Add a health-check endpoint that returns service status and version.
""")

# Watch it drive specify -> clarify -> plan -> tasks -> analyze -> implement -> converge.
SpeckitOrchestrator.print_status()
```

**Expected outcomes**:
- The orchestrator prints an auto-assigned id (e.g. `001`) and a derived slug
  (e.g. `add-a-health-check-endpoint`), and runs on branch `feature/<id>-<slug>`.
- A seed file `<breakdown_dir>/<id>-<slug>.md` appears in the worktree and is
  committed onto the feature branch alongside `specs/…/spec.md`, `plan.md`,
  `tasks.md`, and the implementation.
- On clean completion the feature reaches `:done`, its worktree is removed, and
  the drain report shows one `done` feature with total spend within budget.

**Guarantee checks** (each should behave exactly as a backlog run):
- Feed an intentionally ambiguous description → the feature **escalates** at
  clarify and its worktree is **kept**.
- Point at a target whose constitution would be violated → the feature **halts**
  at analyze and its worktree is **kept**.
- Set a tiny `budget_usd` → the run **drains** (finishes the in-flight phase, then
  halts between phases); spend stays within budget + one reservation.

## PR workflow (optional)

```elixir
{:ok, _coord} = SpeckitOrchestrator.run_spec("…description…", pr_workflow: true)
```

Expected: remote/pack preflight runs first; on `:done` the branch is pushed and a
single PR is opened against `pr_base`. A failed preflight returns
`{:error, {:preflight, problems}}` and runs nothing.

## Re-run after human resolution

Re-invoking `run_spec` with the **same description** derives the same id/slug, so
`Worktree.create/2` reuses the existing `feature/<id>-<slug>` branch (keeping any
human clarifications committed there) and re-runs the pipeline — matching the
existing `resolve/1` flow.
