# Quickstart: validating 039

Prerequisites: `mise trust mise.toml` done; deps fetched
(`mise exec -- mix deps.get`). Container checks need Docker and
`scripts/autonomous build`.

## 1. Automated suite (FR-020, SC-006)

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix test test/autonomous/design_contract_test.exs
```

Expected: all green, zero warnings. Key new/rewritten files to watch:
`ledger_test.exs` (accumulator), `target_pack_test.exs` (contract 6),
`phase_request_test.exs` (one permission set), retired-option tests,
legacy-record tests, `runtime_notice_test.exs`, Coordinator large-spend test.

## 2. Spend never halts (US1, SC-001)

Covered by the Coordinator test driving several features through the
`:runner` seam with a stub runner that records very large costs: every
feature reaches `:done`, the final report has no `breaker_tripped` key and its
`spend` equals the recorded sum. Manually, in `iex -S mix`:

```elixir
Autonomous.Ledger.record(Autonomous.Ledger, nil, 10_000.0)
Autonomous.Ledger.snapshot()   # => %{committed: 10000.0, …} — no budget key
```

## 3. Removed options are refused (US1 #3, US2 #3, SC-005)

```elixir
Autonomous.run(budget_usd: 10)
# => {:error, {:preflight, [{:retired_option, :budget_usd}]}}
Autonomous.run(containment_profile: "strict")
# => {:error, {:preflight, [{:retired_option, :containment_profile}]}}
```

```bash
AUTONOMOUS_BUDGET_USD=5 mise exec -- iex -S mix              # boot aborts naming the variable
AUTONOMOUS_CONTAINMENT_PROFILE=strict mise exec -- iex -S mix # boot aborts naming the variable
```

Contract: [contracts/run-start.md](contracts/run-start.md).

## 4. Pack contract 6 (FR-012)

Against a scratch target with the **old** pack committed:

```elixir
Autonomous.TargetPack.verify(target)
# => {:error, [{:pack_outdated, ".claude/autonomous-pack.json", hint}]}  hint names contract 6 + TargetPack.install/2
Autonomous.TargetPack.install(target)    # removes hooks/scope_guard.py, writes autonomous-pack.json
# commit in the target, then:
Autonomous.TargetPack.verify(target)     # => :ok
```

Contract: [contracts/target-pack.md](contracts/target-pack.md).

## 5. Operator surfaces (US2 #2, SC-003)

`mise exec -- iex -S mix`, open the console: topbar shows state, subject, a
plain spend figure — no gauge, no breaker chip, no containment chip.
Configuration and Trigger have no budget or profile controls. Run Detail of a
pre-039 run (with `budget_usd`/`containment_profile` in its settings) opens
without error and shows neither key. Contract:
[contracts/operator-surfaces.md](contracts/operator-surfaces.md).

## 6. Non-container warning (FR-014)

On the host with `require_container: false`, start a run against a scratch
target: the log shows the container warning (text per run-start.md §4) and the
run proceeds.

## 7. Container smoke checks (US3 #3)

```bash
scripts/autonomous build --agent-root
scripts/container-smoke.sh            # all remaining subcommands
scripts/container-smoke.sh sysdeps    # agent root still advertised, sudo works
scripts/container-smoke.sh trust      # workspace trust still seeded
```

Expected: pass; `us-trust-hook` no longer exists; no check sets
`AUTONOMOUS_CONTAINMENT_PROFILE` or a budget.

## 8. Documentation sweep (SC-002, SC-007)

```bash
rtk grep -n -i -E "budget|breaker|strict|permissive|containment_profile" \
  lib config priv scripts docs/runbook.md docs/enforcement.md docs/container.md \
  docs/workflow.md README.md CLAUDE.md .specify/memory/constitution.md
```

Expected hits only: historical renderers (`:breaker` clauses), retired-setting
refusal code/messages, the constitution Sync Impact Report history, and
unrelated uses (`strict` in other senses, LedgerLite fixture names).
