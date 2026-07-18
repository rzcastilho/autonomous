<!--
Sync Impact Report
Version change: (unversioned template) → 1.0.0
Bump rationale: Initial ratification — all placeholder tokens replaced with
  concrete, project-specific principles for speckit_orchestrator.
Modified principles: none (first adoption)
Added principles:
  - I. Pure Core, Isolated Contracts
  - II. Fail Loud at Boundaries
  - III. Least-Privilege Containment (Fail-Closed)
  - IV. Cost-Bounded Autonomy (Drain, Don't Kill)
  - V. Human-in-the-Loop Escalation
Added sections:
  - Quality & Test Discipline
  - Development Workflow
Removed sections: none
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check is principle-agnostic
     ("[Gates determined based on constitution file]"); no change needed
  ✅ .specify/templates/spec-template.md — no principle-specific references; no change
  ✅ .specify/templates/tasks-template.md — no principle-specific references; no change
  ✅ .specify/templates/checklist-template.md — generic; no change
Follow-up TODOs: none
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

**Version**: 1.0.0 | **Ratified**: 2026-07-11 | **Last Amended**: 2026-07-18
