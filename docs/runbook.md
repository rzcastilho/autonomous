# Operator runbook

How to run the orchestrator, watch a run, and unblock it — without having built
it. The operator surface is `iex` plus `SpeckitOrchestrator.{run,status,
print_status,resolve}`.

## Prerequisites

- Elixir 1.20.2 / OTP 28 (`mise install`; the repo pins `.tool-versions`).
- Claude Code CLI installed and authenticated; one of `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_API_KEY` in the environment.
- `specify` CLI at the pinned tag (`docs/…implementation-plan.md` §2).
- A **target repo** bootstrapped and enforced (once):
  ```
  specify init . --integration claude --integration-options="--skills"
  # in iex, against the repo path:
  SpeckitOrchestrator.TargetPack.install("/path/to/target")
  # write a real constitution with checkable MUSTs, then:
  git add .specify .claude && git commit -m "spec kit + enforcement pack"
  SpeckitOrchestrator.TargetPack.verify("/path/to/target")   # => :ok
  ```
  Point `config :speckit_orchestrator, :repo` at the target repo; put the feature
  breakdown files under its `:breakdown_dir` (`docs/breakdown/NNN-*.md`).

## Start a run

```elixir
iex -S mix
iex> SpeckitOrchestrator.Telemetry.attach_default_logger()   # optional: log events
iex> {:ok, _coord} = SpeckitOrchestrator.run()
```

`run/0` loads the backlog, validates the DAG (raises on cycles / dangling
prereqs), and releases the first wave. Features run in dependency-and-cap waves
(`config :max_concurrency`). The caller receives `{:run_complete, report}` when
the run drains.

## Watch a run

```elixir
iex> SpeckitOrchestrator.print_status()
FEATURE  STATUS    ELAPSED
001      done      12.4s
002      running   3.1s
003      pending   -

totals: done=1  running=1  pending=1
spend:  $4.20
state:  running
```

- Per-phase transitions are logged (attach the default logger) and telemetry is
  emitted under `[:speckit, :phase, …]` and `[:speckit, :feature, :terminal]`.
- Per-phase transcripts land in `<worktree>/.speckit_logs/NN-<phase>.md` for any
  feature whose worktree was kept (non-`:done` terminal).

## Respond to an escalation

A feature that hits `## NEEDS HUMAN` at `clarify` ends `:escalated`; its worktree
is **kept** for inspection. The final report lists it under `escalated`, and its
dependents under `blocked`.

1. Open the kept worktree (`config :worktree_root` + `NNN-slug`). Read
   `.speckit_logs/02-clarify.md` and the spec's `## NEEDS HUMAN` section.
2. Make the product decision: edit the spec to resolve the ambiguity and
   **commit it on the feature branch** (`feature/NNN-slug`).
3. Free the worktree for a re-run (the branch, with your commit, is preserved):
   ```elixir
   iex> SpeckitOrchestrator.resolve("007")
   ```
4. Re-run: `SpeckitOrchestrator.run()`. The feature reuses its branch and
   re-runs the pipeline (v1: from the start; mid-pipeline resume is v2). With the
   ambiguity now resolved in the committed spec, `clarify` should pass and its
   dependents unblock.

## Cost breaker

If spend reaches `config :budget_usd`, the breaker trips: no new features are
released and in-flight features **drain** (finish the current phase, then halt) —
they are never killed mid-phase. The report shows `breaker_tripped: true` and
lists drained features under `not_started`. Raise the budget and re-run to
continue.

## When a feature fails

`:failed` means a phase errored, the runner crashed/timed out, or the worktree
couldn't be created (missing scaffold — run `TargetPack.verify/1`). The worktree
is kept; inspect `.speckit_logs/`. Fix the cause and re-run (`resolve/1` first if
a worktree/branch is in the way).
