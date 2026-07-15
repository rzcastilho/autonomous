# Phase 7 — LedgerLite validation run (runbook)

Gate before fleet mode. This runbook takes the prepared **LedgerLite** target
(sibling `../ledgerlite`, already scaffolded + committed) through the live
orchestrator run, exercises the seeded traps, and checks the exit criteria.

Plan source of truth: `docs/speckit-orchestrator-implementation-plan.md` §7.
Operator surface: `docs/runbook.md`.

## 0. Precondition — what's already prepared

The target repo `../ledgerlite` exists and its preflight passes:

```bash
mise exec -- mix run --no-start -e \
  'IO.inspect(SpeckitOrchestrator.TargetPack.verify("../ledgerlite"))'
# => :ok
```

It carries: `specify init` scaffold (`.specify/`, Spec Kit skills under
`.claude/skills/`), the enforcement pack (`.claude/settings.json` +
`hooks/scope_guard.py`), the real constitution (5 checkable MUSTs), and
`docs/breakdown/001..007` (the 7-feature DAG). All committed on `main`.

## 1. Point the orchestrator at the target

Set `config :speckit_orchestrator, repo:` to the target path. Do NOT hardcode a
second copy of the breakdown — the orchestrator reads
`repo/docs/breakdown` (`Config.repo() |> Path.join(Config.breakdown_dir())`).

For the run, override in `config/runtime.exs` or an env-specific config:

```elixir
config :speckit_orchestrator,
  repo: "/Users/castilho/code/github.com/rzcastilho/ledgerlite"
  # worktree_root defaults to "../.speckit-worktrees" relative to repo →
  #   /Users/castilho/code/github.com/rzcastilho/.speckit-worktrees
```

Also confirm the model pin env vars are set (aliases → full models), per
`docs/harness-contract.md`:

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
```

## 2. Run protocol (plan §7.2)

### 2a. Sequential happy path first — `max_concurrency: 1`, small budget

Confirms 001 → 002 end-to-end before any parallelism.

```elixir
# iex -S mix, with max_concurrency temporarily 1 and budget ~2 features (~9.40)
{:ok, _} = SpeckitOrchestrator.run(features: seq_subset)  # 001, 002 only
SpeckitOrchestrator.print_status()
```

Expect: 001 (solo wave) → `:done`, worktree removed; 002 releases after 001,
→ `:done`. No crashes. Every phase transition logged (Phase 6 telemetry);
transcripts under `<worktree>/.speckit_logs/NN-<phase>.md`.

### 2b. Full backlog — `max_concurrency: 2`

```elixir
{:ok, _coord} = SpeckitOrchestrator.run()   # loads all 7 from breakdown
SpeckitOrchestrator.print_status()          # re-run to watch waves
```

**Expected wave shape** (cap 2):
- Wave 1: **001 alone** (no prereqs, solo).
- Wave 2: **002 + 005** run in parallel worktrees; **007 waits** behind the cap.
- Wave 3: **003, 004, 006** all releasable once 002 is `:done` → three-way
  contention against cap of 2 (one queues).

## 3. Seeded traps — hard pass/fail checklist

| # | Trap | Where | Expected outcome | Pass check |
|---|------|-------|------------------|-----------|
| 1 | **Clarify** | `007-recurring-expenses.md` — month-end/proration/edit semantics unspecified | Opus clarify reviewer emits `## NEEDS HUMAN` → feature `:escalated`, **worktree kept** for inspection | 007 status `:escalated`; `## NEEDS HUMAN` in its clarify transcript. If it invents an answer instead → **rubber-stamp risk measured; record it.** |
| 2 | **Analyze** | Constitution Principle 1 (integer cents) | A floating-point money path in spec/plan/tasks → Critical finding → feature `:halted` | Analyze gate halts at least once. If no natural violation, **inject** a planted `float` money path on a fixture branch (see §4) and re-run that feature to prove the gate fires. |
| 3 | **Breaker** | `budget_usd` set to ~5 features' worth | Breaker trips mid-run; in-flight features **drain** (finish current phase, then halt), not killed; final report accounts done/halted/blocked | Per-feature estimate ≈ **$14.82** (sum of `cost_estimates`, recalibrated 2026-07-15 from a live smoke — `specify` measured at $0.63, rest scaled ×3.15, provisional). `budget_usd` defaults to **$74.0** (~5 features) so the 6th can't reserve. Verify drain-not-kill + correct final tallies. |
| 4 | **Blocking** (optional 2nd run) | Move the 007 ambiguity into **002** | 003, 004, 006 all **block** behind the escalation; `resolve/1` releases them after human resolution | After escalating 002: dependents `:blocked`. Then `SpeckitOrchestrator.resolve("002")` + re-run → they release. |

## 4. Injecting the analyze trap (if no natural violation)

On a throwaway branch of the target, plant a float money path the analyze gate
should flag as Critical — e.g. a task or plan line computing a total as
`amount * 1.0 / 100` or storing `balance :: float`. Re-run only that feature's
pipeline and confirm `analyze` → `:halted`. Discard the branch after.

## 5. Human PR review (non-negotiable)

Review **every** LedgerLite feature branch. The rubber-stamp risk is real — two
same-family models review each other; the analyze gate is the backstop, not a
substitute. Review cost is low because the product is trivial. Each merged
feature must have working tests.

## 6. Tune from evidence

Per-phase `max_turns`, timeouts, the clarify prompt (**measure NEEDS HUMAN
rate** — too low is as suspicious as too high), the analyze JSON schema.

## 7. Exit criteria (ALL must hold)

- [ ] All 7 features reach a terminal state — no orchestrator crashes.
- [ ] 007 escalates at `clarify` with `## NEEDS HUMAN` (worktree kept).
- [ ] Analyze gate halts on a constitution Critical at least once (natural or
      injected).
- [ ] Wave releases match the DAG and concurrency cap exactly (001 solo;
      002+005 parallel while 007 waits; 3-way wave-3 contention).
- [ ] Breaker drains cleanly with a correct final report.
- [ ] Total spend within `budget + one reservation`.
- [ ] Every merged feature passes human PR review with working tests.

Keep the LedgerLite repo as a **permanent regression fixture** — re-run it after
any dependency pin bump (`jido_harness` / `jido_claude` SHAs, Spec Kit tag).

## 8. Only after LedgerLite passes

Repeat the pilot on **one** real feature from the real product backlog, in a
branch-protected repo, before raising concurrency for fleet mode.
