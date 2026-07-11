# speckit_orchestrator

An autonomous, spec-driven build pipeline on the BEAM. It drives the GitHub Spec
Kit loop (`specify → clarify → plan → tasks → analyze → implement → converge`)
feature-by-feature through the Claude Code CLI, in parallel git worktrees, with
per-phase model routing, an Opus reviewer standing in for the human at
`clarify`, a deterministic `analyze` gate over the project constitution, and a
cost circuit breaker.

Control plane = Jido/OTP. Data plane = the `claude` CLI wrapped by the
`jido_harness` `:claude` provider. No UI — the operator surface is `iex`.

## Status

Phases 0–6 of `docs/speckit-orchestrator-implementation-plan.md` are built:
pure core, harness data plane, feature vertical, control plane, enforcement, and
observability. Phase 7 (the LedgerLite greenfield validation run, which needs a
paid live CLI) is the remaining gate before fleet use.

## Requirements

- Elixir **1.20.2** / OTP **28** (`.tool-versions`; `mise install`).
- Claude Code CLI, authenticated (`ANTHROPIC_API_KEY` or equivalent).
- `specify` CLI **v0.12.x**:
  ```
  uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v0.12.11
  ```
  Note the v0.10+ flag changes: bootstrap is
  `specify init . --integration claude --integration-options="--skills"` — the
  `--ai` flag family was removed. Never run `specify init --force` in a worktree
  (it clobbers `constitution.md`).

## Quick start

```elixir
iex -S mix
iex> {:ok, _} = SpeckitOrchestrator.run()
iex> SpeckitOrchestrator.print_status()
```

See **`docs/runbook.md`** to run, watch, and unblock a run (escalations, breaker,
`resolve/1`).

## Configuration

`config/config.exs`, under `:speckit_orchestrator`: `repo`, `breakdown_dir`,
`worktree_root`, per-phase `models` (aliases — see below), `max_concurrency`,
`budget_usd`, `implement_max_turns`, `speckit_version`.

Models are **aliases** (`opus`/`sonnet`), not full strings: the pinned
ClaudeAgentSDK catalog rejects `claude-opus-4-8`. Pin reproducibility with the
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` env vars.

## Docs

- `docs/speckit-orchestrator-implementation-plan.md` — the phased plan (source of truth).
- `docs/harness-contract.md` — observed jido_harness/jido_claude contract.
- `docs/enforcement.md` — scope-guard pack, install, upgrade, container recipe.
- `docs/breakdown-format.md` — the `NNN-*.md` backlog format the parser expects.
- `docs/runbook.md` — operator runbook.
- `CLAUDE.md` — architecture + build/test commands.

## Development

Run everything through mise (the bare shell PATH is a stale Elixir):

```
mise exec -- mix test
mise exec -- mix test --cover
mise exec -- mix test --include integration   # opt-in, hits the real CLI
```
