<!--
Sync Impact Report
Version change: 1.0.0 → 1.1.0
Bump rationale: MINOR — added one new principle (VI) and one new normative
  section (Technology Stack); no existing principle removed or redefined.
Modified principles: none (I–V unchanged)
Added principles:
  - VI. Idiomatic Elixir/OTP & Functional Design
Added sections:
  - Technology Stack
Removed sections: none
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check is principle-agnostic
     ("[Gates determined based on constitution file]"); no change needed
  ✅ .specify/templates/spec-template.md — no principle-specific references; no change
  ✅ .specify/templates/tasks-template.md — no principle-specific references; no change
  ✅ .specify/templates/checklist-template.md — generic; no change
Follow-up TODOs: none

Prior report (1.0.0):
  Version change: (unversioned template) → 1.0.0
  Initial ratification — all placeholder tokens replaced with concrete,
  project-specific principles for speckit_orchestrator. Added principles I–V;
  added sections Quality & Test Discipline and Development Workflow.
-->

# speckit_orchestrator Constitution

## Core Principles

### I. Pure Core, Isolated Contracts

The pure logic layer (`Feature`, `Config`, `Pipeline`, `Ledger`, `Release`,
`Backlog`) MUST NOT depend on the CLI, the harness, or Jido. All fast-moving
external contracts (jido_harness structs, the `claude` CLI surface, model
catalog aliases) MUST be isolated behind an explicit boundary so pure logic never
encodes a guess about them. Decision surfaces MUST be side-effect free: gate
signals are extracted upstream and passed in as arguments, not read inside the
transition logic.

Rationale: The pipeline drives external tools whose contracts change without
notice. Keeping decisions pure makes the whole control plane unit-testable
without a CLI or a worktree, and confines every contract drift to one adapter.

### II. Fail Loud at Boundaries

Invalid input MUST be rejected at the edge, never carried silently inward. The
backlog loader MUST raise on a dangling prerequisite or a dependency cycle at
load time. Preflight verification (`TargetPack.verify`) MUST fail while a target
repo is unready (template constitution marker present, or uncommitted scaffold).
Parsers MAY salvage recoverable partial output, but MUST NOT invent data to
paper over a malformed contract.

Rationale: An autonomous pipeline runs unattended for long stretches. A silent
bad state compounds across phases and features; a loud early failure is cheap to
diagnose and stops waste before spend.

### III. Least-Privilege Containment (Fail-Closed)

Because the adapter runs the CLI with `--dangerously-skip-permissions`,
containment MUST live in the committed target-repo pack, not in CLI prompts. The
PreToolUse scope-guard hook MUST deny out-of-tree writes and dangerous Bash, and
MUST fail closed on malformed input. `settings.json` MUST grant least privilege,
and per-phase permissions (`PhaseRequest`) MUST further narrow tools per phase.
Enforcement MUST be layered (hook + per-phase permissions + container recipe),
never a single point of trust.

Rationale: The orchestrator executes model-authored actions against real repos.
Defense in depth that fails closed is the only safe default when the executing
agent's output is not pre-reviewed.

### IV. Cost-Bounded Autonomy (Drain, Don't Kill)

Every run MUST be governed by the `Ledger` cost circuit breaker. A reservation
MUST be rejected once `committed + reserved >= budget`; the breaker trips at
`committed >= budget`; the invariant `committed < budget + max single reservation`
MUST hold. On a tripped breaker the system MUST drain, not kill: no new work is
released, and an in-flight feature finishes its current phase then halts between
phases. Cost accounting MUST prefer actual reported spend and fall back to the
per-phase estimate only when actuals are unavailable.

Rationale: Unbounded autonomous spend is the primary financial risk. Draining
rather than killing preserves partial work and keeps the final tally honest and
within budget plus one outstanding reservation.

### V. Human-in-the-Loop Escalation

The pipeline MUST NOT fabricate resolution of ambiguity or of a quality failure.
The clarify gate MUST escalate a feature to `:escalated` on an unresolved
`## NEEDS HUMAN` marker in `spec.md`. The analyze gate MUST halt to `:halted` on
a constitution Critical finding. Escalated and halted features MUST retain their
worktree for post-mortem; only `:done` features remove it. A human resolution
path (`resolve/1`) MUST let a feature re-run on its existing branch.

Rationale: Autonomy has bounds. Materially ambiguous specs and constitution
violations are human decisions; encoding them as automatic pass-throughs would
ship wrong or non-compliant work at machine speed.

### VI. Idiomatic Elixir/OTP & Functional Design

Code MUST be written in the functional, process-oriented idiom of the BEAM, not
an imperative style transliterated into Elixir:

- **Immutability & pure transforms.** Data is immutable; logic MUST be expressed
  as pure transformations over data (`|>` pipelines, comprehensions, `Enum`/
  `Stream`), with side effects pushed to the edges. Pure decision logic MUST NOT
  be entangled with process state or I/O (this operationalizes Principle I).
- **Pattern matching over conditionals.** Prefer pattern matching, multi-clause
  functions, and guards to nested `if`/`cond`. Destructure at the function head.
- **`with` for happy-path pipelines.** Chained fallible steps SHOULD use `with`;
  functions that can fail MUST return tagged tuples (`{:ok, _}` / `{:error, _}`).
  Raising is reserved for programmer error and boundary violations (Principle II),
  not for expected control flow. A public function's contract (bang vs. tuple)
  MUST be consistent and explicit.
- **"Let it crash" under supervision.** Processes MUST run under a supervision
  tree with an intentional restart strategy; do not defensively rescue what a
  supervisor should restart. Choose the right OTP abstraction for the job —
  `GenServer` for stateful serialization, `Task`/`Task.Supervisor` for
  concurrent one-shot work, `Registry` for process lookup — and document any
  deliberate deviation (as the Coordinator-vs-Jido-agent choice already is).
- **Process state ≠ business logic.** A `GenServer` MUST stay a thin shell:
  message handling and state custody only, delegating decisions to pure functions
  so they remain testable without the process (e.g. `Ledger`/`Release`/`Pipeline`).
- **No blocking the scheduler.** Long or blocking work MUST NOT run inside a
  `GenServer` callback that other callers await; offload it (Task, dedicated
  process) so the owning process stays responsive.
- **Typespecs & Credo.** Public functions on core modules MUST carry `@spec`, and
  `mix format` is mandatory. Compiler warnings are build failures (see Quality &
  Test Discipline); Credo, where configured, MUST pass clean.

Rationale: This project *is* a BEAM control plane; its reliability, testability,
and cost guarantees rest on OTP supervision and pure-core separation. Idiomatic
functional/OTP design is what makes Principles I–V mechanically enforceable
rather than aspirational.

## Technology Stack

The stack below is normative: adding a runtime dependency, a frontend build step,
or a database MUST be justified against these choices and recorded per the
Governance amendment procedure.

**Toolchain.** Elixir `~> 1.20` on OTP 28, pinned to `1.20.2-otp-28` via
`.tool-versions`; every command runs through `mise exec --` (Quality & Test
Discipline). Erlang/OTP is system-provided and MUST NOT be mise-managed.

**Backend (control plane + data plane).**

- **OTP** is the control plane: a per-run `Coordinator` (plain `GenServer`)
  supervises `Task`-based feature runners; `Ledger` is the cost-breaker
  `GenServer`; the app tree runs `Ledger` + a `Task.Supervisor`.
- **Jido** (`~> 2.2`) provides the agent framework; `jido_harness` and
  `jido_claude` are the data-plane harness wrapping the `claude` CLI. Both are
  pinned to GitHub SHAs with `override: true` on the harness — they are NOT on
  Hex; re-check Hex monthly and bump SHAs deliberately (never float to HEAD).
- New backend work MUST prefer OTP primitives already in the tree over new
  external dependencies; there is no database — run/checkpoint state is
  file-backed (run manifest + per-phase checkpoints).

**Frontend (control-plane console, feature 008).**

- **Phoenix `~> 1.7` + Phoenix LiveView `~> 1.0`** served by **Bandit `~> 1.0`**;
  realtime updates flow over **`phoenix_pubsub`**. Server-rendered LiveView is the
  default; reach for client-side JS only when LiveView genuinely cannot express
  the interaction.
- **No Node/npm build pipeline.** There is deliberately no esbuild, no Tailwind,
  and no bundler: JS is vendored (`priv/static/vendor/…`), CSS is hand-authored
  (`console.css`), and fonts (IBM Plex Sans/Mono) are self-hosted `woff2`. Any
  proposal to introduce a JS build step or a CSS framework MUST clear the
  Governance bar and justify the added toolchain surface.
- The console is an observability/operator surface over run state — it MUST NOT
  become a second source of truth. It reads run manifests/checkpoints; the
  file-backed run state remains authoritative.

## Quality & Test Discipline

- All Elixir commands MUST run through mise (`mise exec -- …`); the pinned
  toolchain is `1.20.2-otp-28` per `.tool-versions`, and the bare PATH is stale.
- `warnings_as_errors` is ON: a compiler warning is a build failure and MUST be
  fixed, not suppressed.
- The pure core MUST hold test coverage above 90%. Wave, DAG, and breaker logic
  MUST be tested through injected seams (e.g. the `:runner` seam) with no CLI or
  worktree dependency.
- Real-harness and out-of-tree side effects MUST sit behind opt-in
  (`--include integration`) so the default suite stays hermetic.
- Enforcement code (the scope-guard hook) MUST be tested against the real hook,
  red-team style, not a mock.

## Development Workflow

- Work is spec-driven and feature-by-feature through the Spec Kit loop:
  `specify → clarify → plan → tasks → analyze → implement → converge`.
- The clarify gate (human stand-in) and the deterministic analyze gate are
  mandatory quality gates; a phase MAY auto-retry a transient failure, but a gate
  diversion (`:escalated` / `:halted`) MUST NOT be retried past the human.
- Parallelism across features uses git worktrees on `feature/NNN-slug` branches;
  the committed `.specify/`/`.claude/` scaffold MUST travel into each worktree,
  and `specify init` MUST NEVER be run inside a worktree.
- The implementation plan (`docs/speckit-orchestrator-implementation-plan.md`) is
  the source of truth for scope, sequencing, and exit criteria.

## Governance

This constitution supersedes ad-hoc practice for the speckit_orchestrator
control plane and its enforcement pack. Amendments MUST be committed with a Sync
Impact Report (prepended to this file) and a semantic version bump: MAJOR for a
backward-incompatible governance or principle change, MINOR for a new principle
or materially expanded section, PATCH for clarifications. Any deviation from a
principle MUST be recorded in the plan's Complexity Tracking with the need and
the rejected simpler alternative — as the deliberate Coordinator-vs-Jido-agent
deviation already is. Reviews and PRs MUST verify compliance with these
principles; the constitution and the implementation plan together are the
runtime guidance for autonomous and human contributors alike.

**Version**: 1.1.0 | **Ratified**: 2026-07-11 | **Last Amended**: 2026-07-24
