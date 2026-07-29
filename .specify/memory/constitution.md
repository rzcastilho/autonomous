<!--
Sync Impact Report
Version change: 2.0.0 → 2.1.0
Bump rationale: MINOR — three clauses are materially rewritten because feature
  019-stacked-sequential-only retires their *subjects*, not because any
  governance bound is relaxed. Principle II loses the dangling-prereq/cycle
  guard (prerequisites cease to exist) and gains three explicitly named
  refusals, one of which — raise on numerically-equal feature numbers — is the
  direct replacement guard; the other two (retired settings, records predating
  a recorded clean break) are new loud failures the principle did not previously
  mandate. The Persistence subsection admits a "refusal migration" as a
  legitimate, versioned migration outcome for a recorded clean break, while
  keeping the existing ban on silently dropping state and adding an explicit
  ban on auto-deleting it at startup. The Development Workflow worktree clause
  drops the cross-feature parallelism it assumed; worktrees, branch naming,
  scaffold travel, and the `specify init` prohibition are unchanged. Net effect
  is more mandated loud failures and fewer permitted silent ones — an expansion
  of governance, so MINOR rather than MAJOR (contrast 2.0.0, which weakened an
  unconditional escalation guarantee and was MAJOR for exactly that reason).
Modified principles:
  - II. Fail Loud at Boundaries (backlog guard replaced; three named refusals
    added: ambiguous ordering, retired settings, pre-clean-break records)
Added principles: none
Removed principles: none
Modified sections:
  - Technology Stack → Persistence (schema-evolution bullet: refusal migrations
    permitted for a recorded clean break; auto-delete at startup banned)
  - Development Workflow (worktree bullet: one feature at a time)
Added sections: none
Removed sections: none
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check is principle-agnostic
  ✅ .specify/templates/spec-template.md — no principle-specific references
  ✅ .specify/templates/tasks-template.md — no principle-specific references
  ✅ .specify/templates/checklist-template.md — generic; no change
  ✅ specs/019-stacked-sequential-only/plan.md — Constitution Check conditionals
     and Complexity Tracking already cite this amendment by version
  ⚠ CLAUDE.md — describes `Feature.prereqs`, `Backlog`'s DAG validation,
     `Release.next_wave/4`, and git-worktree parallelism across features. Left
     as-is deliberately: those descriptions are accurate for the code on `main`
     today. They are updated by 019's own implementation, in the same change
     that makes them false (tracked in specs/019-stacked-sequential-only/plan.md
     § Project Structure).
  ⚠ docs/breakdown-format.md, docs/workflow.md, docs/runbook.md — same reason,
     same tracking.
Follow-up TODOs: none

Prior report (2.0.0):
  Version change: 1.3.0 → 2.0.0
  Bump rationale: MAJOR — Principle V's analyze-gate rule is redefined in a
    backward-incompatible way. The unconditional guarantee "the analyze gate MUST
    escalate to `:escalated` on a High finding" no longer holds: the gate is now
    governed by the run's severity threshold, so a run configured with threshold
    Critical advances past a High finding instead of diverting it to a human.
    Under the default threshold (High) behaviour is byte-identical to 1.3.0, but
    the *guarantee* is weakened — an operator can now configure away a
    human-facing terminal state that was previously unconditional. That is a
    relaxation of a governance bound, not an expansion of one, so it is MAJOR
    rather than MINOR (contrast 1.2.0, which only *added* a bounded pre-gate loop
    underneath an unchanged gate).
  Modified principles:
    - V. Human-in-the-Loop Escalation (analyze gate is now threshold-governed;
      Critical still unconditionally halts)
  Added principles: none
  Added sections: none
  Removed sections: none
  Templates requiring updates:
    ✅ .specify/templates/plan-template.md — Constitution Check is principle-agnostic
    ✅ .specify/templates/spec-template.md — no principle-specific references
    ✅ .specify/templates/tasks-template.md — no principle-specific references
    ✅ .specify/templates/checklist-template.md — generic; no change
    ✅ specs/017-analyze-auto-remediation/spec.md — US3 acceptance scenario 2 and
       FR-006 updated to the threshold-governed gate
  Follow-up TODOs: none

Prior report (1.3.0):
  Version change: 1.2.0 → 1.3.0
  Bump rationale: MINOR — the Technology Stack section is materially expanded with a
    new normative "Persistence (run state)" subsection adopting Mnesia, and its
    previous "there is no database" clause is replaced. No principle was removed,
    redefined, or made backward-incompatible; Principles I–VI are unchanged in text
    and in force. Treated as MINOR rather than MAJOR by the same reasoning that made
    1.1.0 (which introduced the Technology Stack section) a MINOR bump: the section is
    normative stack guidance, not a governance principle.
  Modified principles: none (I–VI unchanged)
  Added principles: none
  Added sections:
    - Technology Stack → Persistence (run state)
  Modified sections:
    - Technology Stack → Backend: "there is no database — run/checkpoint state is
      file-backed" replaced with a pointer to the Persistence subsection
    - Technology Stack → Frontend: console authority clause now names persisted run
      state rather than file-backed run state
  Removed sections: none
  Templates requiring updates:
    ✅ .specify/templates/plan-template.md — Constitution Check is principle-agnostic
       ("[Gates determined based on constitution file]"); no change needed
    ✅ .specify/templates/spec-template.md — no stack-specific references; no change
    ✅ .specify/templates/tasks-template.md — no stack-specific references; no change
    ✅ .specify/templates/checklist-template.md — generic; no change
    ✅ CLAUDE.md — contains no no-database claim; no change
    ⚠ Historical artifacts NOT rewritten (deliberate): specs/008, 014, 015, 016, 017
       plan.md/data-model.md state "no database — durable state is file-backed". Those
       are accurate records of what those features shipped against and are left as-is;
       specs/018-unified-run-persistence supersedes them going forward.
  Follow-up TODOs: none

Prior report (1.2.0):
  Version change: 1.1.0 → 1.2.0
  Bump rationale: MINOR — Principle V materially expanded to permit a bounded,
    pre-gate auto-remediation loop with a halt-on-exhaustion guarantee; no
    principle removed or made backward-incompatible.
  Modified principles:
    - V. Human-in-the-Loop Escalation (bounded pre-gate loop + guarantees)
  Added principles: none
  Added sections: none
  Removed sections: none
  Templates requiring updates:
    ✅ .specify/templates/plan-template.md — Constitution Check is
       principle-agnostic; no change needed
    ✅ .specify/templates/spec-template.md — no principle-specific references
    ✅ .specify/templates/tasks-template.md — no principle-specific references
    ✅ .specify/templates/checklist-template.md — generic; no change
  Follow-up TODOs: none

Prior report (1.1.0):
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

Invalid input MUST be rejected at the edge, never carried silently inward.
Preflight verification (`TargetPack.verify`) MUST fail while a target repo is
unready (template constitution marker present, or uncommitted scaffold).
Parsers MAY salvage recoverable partial output, but MUST NOT invent data to
paper over a malformed contract.

Three refusals are named explicitly because each guards an input that would
otherwise be carried inward silently:

- **Ambiguous ordering.** The backlog loader MUST raise at load time when two
  features claim numerically equal numbers, naming every conflicting file.
  Execution order has exactly one input — the operator's numbering — so an
  ambiguity in it MUST NOT be resolved by picking a file arbitrarily.
- **Retired settings.** A setting the system no longer honours (a run-mode
  flag, a concurrency limit) MUST be refused on every surface that can supply
  it — start options, environment variables, and stored configuration alike —
  rather than accepted and ignored. Accepting a value the system will not act
  on is indistinguishable, to an operator, from acting on it.
- **Records predating a recorded clean break.** A persisted record written
  under a superseded contract MUST be refused by name rather than interpreted
  under the current one.

Rationale: An autonomous pipeline runs unattended for long stretches. A silent
bad state compounds across phases and features; a loud early failure is cheap to
diagnose and stops waste before spend. The three named refusals are the cases
where the wrong input is *plausible* — a renumbered backlog, a habitual export,
an upgraded install — and therefore the cases where silence is most costly.

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

The pipeline MUST NOT fabricate resolution of ambiguity or of a quality
failure. The clarify gate MUST escalate a feature to `:escalated` on an
unresolved `## NEEDS HUMAN` marker in `spec.md`.

The analyze gate MUST halt to `:halted` on a constitution Critical finding.
Critical outranks every threshold, so this halt is unconditional and MUST NOT
be configurable away. The gate MUST escalate to `:escalated` on a High finding
**when the run's configured severity threshold is High or lower** — the same
single threshold that decides when auto-remediation runs. A run configured
with threshold Critical therefore advances past a High finding rather than
diverting it to a human; that is an explicit, recorded operator choice, and
the default threshold (High) preserves the escalation. Lowering the threshold
below High MUST NOT create a terminal state for a severity that has none
(Low and Medium never divert).

A **bounded, pre-gate auto-remediation loop** MAY attempt to fix findings at
or above that same severity threshold before the gate is evaluated, subject to
all of:

- it runs **strictly before** the gate decides, never after — a gate
  diversion is still never retried;
- it is bounded by a per-run attempt limit (1–5, default 2) that MUST NOT be
  exceeded within one feature run;
- on exhaustion the gate decides the outcome from the **final** analyze run
  under the rules above, unchanged, with a recorded reason naming exhausted
  auto-remediation;
- every attempt and every analyze re-run is subject to the cost breaker of
  Principle IV and is individually recorded;
- it is switchable per run, and disabling it MUST restore fail-fast behaviour
  exactly.

Escalated and halted features MUST retain their worktree for post-mortem;
only `:done` features remove it. A human resolution path (`resolve/1`) MUST
let a feature re-run on its existing branch.

Rationale: Autonomy has bounds. Materially ambiguous specs and constitution
violations are human decisions; encoding them as automatic pass-throughs would
ship wrong or non-compliant work at machine speed. A bounded, fully-recorded,
switchable pre-gate remediation loop does not relax that bound — it only
delays a still-mandatory human handoff by a capped number of self-fix
attempts, and restores today's exact behaviour when disabled.

Making the gate threshold-governed *does* relax it, deliberately and only for
High: one knob now answers one question — "how severe must a finding be before
a human is involved?" — instead of splitting that answer between a remediation
threshold and a separate hardcoded gate. The bound that remains absolute is
Critical: a constitution Critical finding always halts, at every threshold, so
no configuration can ship a constitution violation unattended. Raising the
threshold to Critical is a recorded, per-run decision to accept High findings
automatically; operators who want the old guarantee keep the default.

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
  external dependencies. Durable run state lives in **Mnesia** — see Persistence
  below. There is no external database service and no ORM (no Ecto).

**Persistence (run state).** All durable run state — runs, features, phase
attempts, checkpoints, escalations, run settings, cost entries, and transcripts —
is held in **Mnesia**, which ships with Erlang/OTP.

- Mnesia MUST NOT be supplemented by an external database service, a Hex
  persistence dependency, or an ORM. It is chosen because it is already in the
  runtime: no new operational surface, no separate process to install or babysit.
- Deployment is **single-node and machine-local**. Distributed Mnesia,
  replication, and multi-node clustering are out of scope; run state does not
  cross machines.
- The Mnesia directory MUST live under the orchestrator's own machine-global
  root, never inside a target repository's working tree, so recorded state is
  never committed to, or destroyed by, target-repo operations.
- The Erlang **node name** and the Mnesia directory MUST be configured
  explicitly and be stable across restarts — the schema is keyed to both.
  Startup that finds a schema belonging to a different node MUST fail loud
  (Principle II); it MUST NOT silently create an empty schema and present a
  repository as having no history.
- Every state mutation MUST run inside a Mnesia **transaction** — that is what
  makes an update all-or-nothing under interruption and makes parallel feature
  writers safe without new locking (Principle IV's accounting depends on it).
  `:mnesia.dirty_*` MUST NOT be used for writes, nor for any read whose result
  feeds a resume, a gate, or a cost decision; it MAY be used for
  non-authoritative observability reads.
- Per-table storage type MUST be a deliberate, recorded choice. Small, hot
  run-control tables use `disc_copies`. Bulk content — phase transcripts above
  all — MUST use `disc_only_copies` so stored volume does not grow the BEAM
  heap, and MUST NOT be loaded by a history or summary listing. The DETS
  per-table size ceiling that `disc_only_copies` inherits MUST be handled
  explicitly (fragmentation or operator pruning) and MUST NEVER be handled by
  silently dropping or truncating recorded state.
- Schema evolution MUST be explicit and versioned: a recorded schema version
  plus migrations applied at startup, ordered by version. An unrecognized or
  newer-than-known schema version MUST fail loud, never be auto-coerced. A
  migration's usual outcome is a `:mnesia.transform_table` transform; a
  **recorded clean break** MAY instead register a *refusal migration* — an
  ordinary, ordered, versioned entry whose outcome is a loud incompatibility
  error naming the superseded version (Principle II). A clean break MUST be
  recorded in the feature's plan with the reason no transform exists. Neither
  form may silently drop, truncate, or auto-delete recorded state: reclaiming
  an incompatible store is an explicit operator action, never a startup side
  effect.
- Mnesia MUST be started and its schema verified **before** any state consumer
  starts; failure at that point MUST abort startup rather than let a run begin
  spending money it cannot record.
- A run's record MUST be exportable in a format readable without Mnesia.
  Mnesia's own backup facility is an operations tool, not the export contract.
- The pure core MUST NOT depend on Mnesia. Persistence sits behind an explicit
  boundary exactly as the harness does (Principle I), so decision tables and
  pure logic stay unit-testable with no schema and no running node.
- The default test suite MUST NOT depend on a developer's machine-global Mnesia
  directory: tests create and tear down their own schema in a temporary
  directory (Quality & Test Discipline — the default suite stays hermetic).

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
  become a second source of truth. It reads the persisted run state; that
  persisted state remains authoritative.

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
- Each feature runs in its own git worktree on a `feature/NNN-slug` branch, one
  feature at a time; the committed `.specify/`/`.claude/` scaffold MUST travel
  into each worktree, and `specify init` MUST NEVER be run inside a worktree.
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

**Version**: 2.1.0 | **Ratified**: 2026-07-11 | **Last Amended**: 2026-07-29
