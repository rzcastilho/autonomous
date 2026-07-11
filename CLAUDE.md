# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`speckit_orchestrator` — an autonomous, spec-driven build pipeline on the BEAM.
It drives the GitHub Spec Kit loop (`/speckit.specify → clarify → plan → tasks →
analyze → implement → converge`) feature-by-feature through the Claude Code CLI.
Control plane = Jido/OTP; data plane = the `claude` CLI wrapped by the
`jido_harness` `:claude` provider. Per-phase model routing, an Opus reviewer
standing in for the human at `clarify`, a deterministic `analyze` gate,
git-worktree parallelism across features, and a cost circuit breaker.

Build follows a phased plan: **`docs/speckit-orchestrator-implementation-plan.md`**
is the source of truth for scope, sequencing, and exit criteria. As of now
**Phase 0 (env + harness contract) and Phase 1 (pure core) are done**; Phase 2+
(real harness `RunPhase`, worktrees, Coordinator, enforcement, LedgerLite
validation) are not yet built.

## Toolchain — read first

Run every Elixir command through mise; the plain shell PATH is a stale global
Elixir 1.19.5, while this repo pins **1.20.2-otp-28** in `.tool-versions`:

```bash
mise exec -- mix test          # NOT: mix test
mise exec -- iex -S mix
mise exec -- mix compile
```

`warnings_as_errors` is on — a warning fails the build. OTP 28 is system-provided
(erlang is not mise-managed; do not add an `erlang` line to `.tool-versions`).

## Commands

```bash
mise exec -- mix deps.get
mise exec -- mix compile
mise exec -- mix test                                   # full suite
mise exec -- mix test --cover                           # coverage (target >90% on core)
mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs        # one file
mise exec -- mix test test/speckit_orchestrator/pipeline_test.exs:42     # one test by line
mise exec -- mix test --include integration             # opt-in real-harness tests (Phase 2+)
```

Prefix git/gh/etc. with `rtk` per the global RTK convention (e.g. `rtk git status`).

## Architecture

The design deliberately isolates all fast-moving external contracts so the pure
logic never depends on guesses.

**Pure core (Phase 1, `lib/speckit_orchestrator/`)** — no CLI/harness/Jido
dependency, fully unit-testable:

- `Feature` — the work-unit struct + lifecycle status (`:pending → :running →`
  terminal `:done | :escalated | :halted | :failed`, plus `:blocked`).
- `Config` — typed accessors over `config :speckit_orchestrator`. Model routing
  uses **full model strings**, not CLI aliases; `model_for/1` raises on an
  unrouted phase (no silent fallback).
- `Pipeline` — the pure phase transition table. `next/3` is the whole decision
  surface: advance, or divert via the **clarify gate** (`## NEEDS HUMAN` →
  `:escalated`) or **analyze gate** (Critical finding → `:halted`). Gate signals
  are extracted upstream and passed in, keeping this module side-effect free.
- `Ledger` — cost circuit-breaker `GenServer`. `reserve` is rejected once
  `committed + reserved >= budget`; invariant: `committed < budget + max single
  reservation`. Breaker trips at `committed >= budget`.
- `Release` — pure wave policy: `(features, statuses, cap, breaker?) → next
  wave`. Releasable = `:pending` with all prereqs `:done`; wave size =
  `cap - in_flight`; tripped breaker → empty wave (drain-don't-kill lives in the
  future Coordinator).
- `Backlog` — parses `docs/breakdown/NNN-slug.md` files into the dependency DAG
  via a `## Prerequisites` section. **Fails loudly** at load on a dangling
  prereq (`MissingPrereqError`) or a cycle (`CycleError`, Kahn-style).

**Harness boundary (contract observed, code is Phase 2).** `docs/harness-contract.md`
records the *observed* jido_harness/jido_claude structs. Key facts that shape
future code:

- Providers are **not auto-discovered** — `config/config.exs` explicitly
  registers `%{claude: Jido.Claude.Adapter}` under `:jido_harness`.
- `permission_mode` / `allowed_tools` / `disallowed_tools` / `add_dirs` are
  **first-class `RunRequest` fields** (there is no `provider_options`), so
  per-phase permissions get set directly on the request.
- `run/2,3` returns `{:ok, Stream.of(Jido.Harness.Event)}` — **streaming**.
- Adapter `capabilities.usage? == false` → no cost events; `Ledger` records must
  be **config-derived per-phase estimates**, not measured spend.
- The adapter's runtime template uses `--dangerously-skip-permissions`, so
  in-tree write containment relies on the committed `.claude/settings.json` +
  PreToolUse hook (Phase 5), not the CLI's own permission prompts.

`jido_harness` and `jido_claude` are **not on Hex** — pinned to GitHub HEAD SHAs
in `mix.exs` with `override: true` on the harness. Re-check Hex monthly; bump
SHAs deliberately.

## Test fixtures

`test/fixtures/breakdown/` is the **LedgerLite** 7-feature DAG (plan §7.1) used
as golden input for the `Backlog` parser and the eventual end-to-end validation
run. `breakdown_cyclic/` and `breakdown_missing/` prove the load-time guards
fire. `docs/breakdown-format.md` is the parser's format contract, to reconcile
with real `macro-spec-breakdown` output later.
