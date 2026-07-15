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
**Phases 0–6 are done** (env + harness contract, pure core, real harness
`RunPhase`, feature vertical, Coordinator control plane, enforcement pack, and
observability/docs). **Phase 7 (LedgerLite greenfield validation run) is the
current gate**: the target repo is prepared and committed (sibling
`../ledgerlite` — `TargetPack.verify` passes) but the live spend + human PR
review remain. See `docs/phase7-ledgerlite-runbook.md`.

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
  uses **CLI aliases** (`opus`/`sonnet`) — the pinned ClaudeAgentSDK catalog
  rejects full strings like `claude-opus-4-8`; pin reproducibility via
  `ANTHROPIC_DEFAULT_*_MODEL` env. `model_for/1` raises on an unrouted phase.
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
- Adapter `capabilities.usage? == false` is conservative: the mapper **does**
  emit a `:usage` event with `cost_usd` when the CLI reports `total_cost_usd`.
  Cost is opportunistic — `Cost.for_phase/2` prefers actual, falls back to the
  per-phase config estimate.
- The adapter's runtime template uses `--dangerously-skip-permissions`, so
  in-tree write containment relies on the committed `.claude/settings.json` +
  PreToolUse hook (Phase 5), not the CLI's own permission prompts.

`jido_harness` and `jido_claude` are **not on Hex** — pinned to GitHub HEAD SHAs
in `mix.exs` with `override: true` on the harness. Re-check Hex monthly; bump
SHAs deliberately.

**Observability (Phase 6).** `FeatureRunner` wraps each phase in
`:telemetry.span([:speckit, :phase], …)` (start/stop/exception) and emits
`[:speckit, :feature, :terminal]`; `Telemetry.attach_default_logger/0` logs them.
`Transcripts` writes `<worktree>/.speckit_logs/NN-<phase>.md` per phase.
`Coordinator` tracks per-feature start times; `Report.format_status/1` renders
the snapshot as an iex table (`SpeckitOrchestrator.print_status/0`).
`SpeckitOrchestrator.resolve/1` frees a kept worktree so a human-resolved feature
re-runs on its existing branch (`Worktree.create` reuses an existing branch).
Operator flow: `docs/runbook.md`.

**Enforcement (Phase 5).** Because the adapter runs the CLI with
`--dangerously-skip-permissions`, containment is a committed **target-repo pack**
(`priv/target_pack/.claude/`), not the CLI's prompts. `scope_guard.py` is a
PreToolUse hook that denies out-of-tree writes and dangerous Bash (fails closed
on bad input); `settings.json` is least-privilege and registers it.
`TargetPack.install/2` lays the pack into a target repo without clobbering the
constitution; `TargetPack.verify/1` is the preflight (fails while the template
constitution marker is present, or if it's uncommitted). `PhaseRequest` per-phase
permissions are the second layer; a container recipe (`docs/enforcement.md`) is
the third. Red-teamed by `scope_guard_test` running the real hook.

**Control plane (Phase 4).** `SpeckitOrchestrator.run/1` (facade) loads the
backlog and starts a per-run `Coordinator`; `status/0` reports it. The
`Coordinator` is a **plain GenServer** (deliberate deviation from the plan's
"Jido agent" — it supervises Task-based runners reacting to async finish
notifications; a Jido agent would push spawning into action bodies). It holds
features/statuses/in-flight, releases dependency-and-cap waves via `Release`, and
on drain emits a final report (`done`/`escalated`/`halted`/`failed`/`blocked`/
`not_started`/`spend`). Runner spawning is an **injected seam** (`:runner`) so
wave/DAG/breaker logic is unit-tested without CLI/worktrees; the facade supplies
the real runner. A tripped `Ledger` breaker releases nothing new and
`FeatureRunner` halts in-flight features between phases (drain, not kill). App
tree: `Ledger` + `{Task.Supervisor, RunnerSup}`; the Coordinator is per-run.

**Feature vertical (Phase 3).** `Worktree` manages per-feature git worktrees
(`feature/NNN-slug`), asserting the committed `.specify/`/`.claude/` scaffold
travelled in; **never** run `specify init` inside a worktree. `FeatureAgent` is a
Jido agent that passively holds one feature's run state; `FeatureRunner` drives
it synchronously via `AgentServer.call/3` — one `"phase.run"` signal per phase —
reads the returned agent's `last_outcome`/`last_signals`, applies
`Pipeline.next/3`, and on a terminal state finalizes status, removes the worktree
on `:done` (keeps it otherwise for post-mortem), and notifies. Actions
(`InitFeature`, `RunFeaturePhase`, `FinalizeFeature`) return `{:ok, state_update}`
maps that merge into agent state. Agents run `register_global: false` until the
app's Jido instance exists (Phase 4).

## Test fixtures

`test/fixtures/breakdown/` is the **LedgerLite** 7-feature DAG (plan §7.1) used
as golden input for the `Backlog` parser and the eventual end-to-end validation
run. `breakdown_cyclic/` and `breakdown_missing/` prove the load-time guards
fire. `docs/breakdown-format.md` is the parser's format contract, to reconcile
with real `macro-spec-breakdown` output later.
