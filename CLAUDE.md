# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`speckit_orchestrator` — an autonomous, spec-driven build pipeline on the BEAM.
It drives the GitHub Spec Kit loop (`/speckit.specify → clarify → plan → tasks →
analyze → implement → converge`) feature-by-feature through the Claude Code CLI.
Control plane = Jido/OTP; data plane = the `claude` CLI wrapped by the
`jido_harness` `:claude` provider. Per-phase model routing, an Opus reviewer
standing in for the human at `clarify`, a deterministic `analyze` gate, a
stacked sequential run over one feature at a time, and a cost circuit breaker.

Build follows a phased plan: **`docs/speckit-orchestrator-implementation-plan.md`**
is the source of truth for scope, sequencing, and exit criteria. As of now
**Phases 0–6 are done** (env + harness contract, pure core, real harness
`RunPhase`, feature vertical, Coordinator control plane, enforcement pack, and
observability/docs). **Phase 7 (LedgerLite greenfield validation run) is done —
every automated exit criterion met; only human PR review (an inherently manual
gate) remains.** Against the sibling target `../ledgerlite` (Python 3 stdlib) the
orchestrator drove the whole 7-feature backlog end-to-end:

- **001–006 built end-to-end**, each with working tests (109 / 202 / 260 / 220 /
  243 + 005 CSV), on branches `feature/NNN-slug`. 001 and 002 were merged to the
  target's `main` so dependents build on real code.
- **007 escalated at clarify** (the seeded month-end/proration/edit trap) with
  materiality-reasoned `## NEEDS HUMAN` — §7.2 trap 1.
- **analyze halts on a constitution Critical** — proven both injected (float in
  001's `data-model.md`) and natural (002's forced money path) — §7.2 trap 2.
- **wave shape** validated live: 001 solo → 002+005 parallel → 003/004/006
  three-vs-cap-2 contention.
- **breaker drain-not-kill** validated live: budget tripped, an in-flight feature
  finished its phase then halted between phases; report tallied correctly and
  spend stayed within budget + one reservation — §7.2 trap 3.

Driving these runs surfaced **seven orchestrator fixes** (all on `origin`): action
timeout; clarify materiality test; clarify gate marker line-anchored; clarify
gate scans `spec.md` for unresolved `## NEEDS HUMAN`; commit worktree before
teardown; plan/tasks non-interactive Bash + `plan_stack`; durable transcripts;
and analyze parser salvages truncated findings JSON. Ops guide: `docs/runbook.md`;
workflow diagram: `docs/workflow.md`; validation protocol:
`docs/phase7-ledgerlite-runbook.md`.

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
  terminal `:done | :escalated | :halted | :failed`, plus `:never_started` for
  a feature still `:pending` when a run ends). No `prereqs` field. Carries
  `number` (parsed from the `NNN` filename prefix, compared numerically — `002`
  and `0002` collide), `group` (`:backlog | :ad_hoc`), and `created_at`
  (non-nil only for `:ad_hoc`).
- `Config` — typed accessors over `config :speckit_orchestrator`. Model routing
  uses **CLI aliases** (`opus`/`sonnet`) — the pinned ClaudeAgentSDK catalog
  rejects full strings like `claude-opus-4-8`; pin reproducibility via
  `ANTHROPIC_DEFAULT_*_MODEL` env. `model_for/1` raises on an unrouted phase.
- `Pipeline` — the pure phase transition table. `next/3` is the whole decision
  surface: advance, or divert via the **clarify gate** (`## NEEDS HUMAN` →
  `:escalated`) or **analyze gate** (Critical finding → `:halted`; High →
  `:escalated` when the run's severity threshold is High or lower — either,
  **unless** the loop exhausted its attempts on that finding and the run's
  exhaustion policy is `:proceed`, in which case it advances instead). The
  clarify gate is the one that has no knobs at all: `## NEEDS HUMAN` escalates
  unconditionally, which is why a run configured with `:proceed` still stops
  there. The analyze gate is threshold-governed as of
  constitution 2.0.0: one knob (`auto_remediation_threshold`, signalled as
  `gate_threshold`, default `:high`) decides both when auto-remediation runs
  and when the gate diverts, so a run pinned to `:critical` advances past a
  High finding instead of escalating. Constitution 3.0.0 (feature 021) adds a
  second knob, `auto_remediation_exhaustion_policy` (signalled as
  `:exhaustion_policy`, default `:escalate`), consulted only on the exhaustion
  branch — with the loop absent or `:escalate` chosen the gate is
  byte-identical to before 021. Constitution 4.0.0 brings **Critical** under
  that same policy: no threshold can reach it (Critical is the ceiling of the
  severity order), and only an exhausted loop plus an explicit `:proceed`
  advances past one — every default run still halts. Gate signals are extracted upstream and
  passed in, keeping this module side-effect free. `Pipeline` still sees
  exactly one `:analyze` outcome per feature run.
- `Severity` / `Remediation` (feature 017; exhaustion policy, feature 021) — a
  bounded, switchable **auto-remediation loop** sits strictly *below* the
  analyze gate, inside the `:analyze` step: when analyze reports findings at
  or above a configured severity threshold (default High), a corrective step
  runs against them verbatim and analyze re-runs, up to a per-run attempt
  limit (default 2) before the gate ever decides. `Severity` is the pure
  `:low < :medium < :high < :critical` order; `Remediation.next/2` is the
  loop's own decision table (remediate / gate / halt / fail), the direct
  analogue of `Pipeline.next/3`. On exhaustion the gate decides from the
  **final** analyze run under the rules above *and* the run's
  `exhaustion_policy` — `:escalate` (default) reproduces today's outcome
  byte-for-byte; `:proceed` advances the feature past a residual High finding
  instead of escalating, and `Remediation.exhaustion_advance/2` records what
  it advanced past (an `advanced_with_findings` annotation on
  `speckit_feature_run`, schema v4) so the run's report, the console
  (`RunDetailLive`'s `data-advanced-with-findings` block), and the feature's
  PR body (`Remediation.pr_note/1`) all surface it to a human reviewer — the
  advance is never a new terminal status, only a decoration on `:done`.
  Disabling the loop, or leaving the policy at `:escalate`, restores today's
  fail-fast behaviour byte-for-byte. Every attempt is Ledger-accounted and
  individually recorded — see `docs/speckit-orchestrator-implementation-plan.md`,
  `specs/017-analyze-auto-remediation/` (the loop), and
  `specs/021-analyze-exhaustion-policy/` (the policy).
- `Ledger` — cost circuit-breaker `GenServer`. `reserve` is rejected once
  `committed + reserved >= budget`; invariant: `committed < budget + max single
  reservation`. Breaker trips at `committed >= budget`.
- `Release` — pure single-run policy: `next/3` takes features, statuses, and a
  breaker flag and returns `{:release, feature} | :none | {:stopped, id,
  status}`. One-feature-at-a-time is structural, not a configured cap: any
  `:running` feature ⇒ `:none`; a tripped breaker ⇒ `:none`
  (drain-don't-kill lives in the Coordinator); any non-`:done` terminal
  feature ⇒ `{:stopped, id, status}`, which is what lets the Coordinator tell
  "the chain broke here" from "nothing left to release" — both used to be an
  empty wave. `order/1` is the total order every release walks: numbered
  backlog features ascending by `number`, then the `:ad_hoc` group ascending
  by `{created_at, number}`. No `cap` parameter anywhere.
- `Backlog` — parses `docs/breakdown/NNN-slug.md` files, sorts them by
  `number` ascending. A `## Prerequisites` section is inert prose — ordering
  has exactly one input, the filename's `NNN`. Gaps in numbering are legal.
  **Fails loudly** at load only on `Backlog.DuplicateNumberError` — two files
  whose numbers are numerically equal (`002` vs `0002`).

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

**Console (Phase 8, feature 020 reconciliation).** A Phoenix LiveView operator
console (`lib/speckit_orchestrator/web/`) — Mission Control, Pipeline Chain,
Escalations, Runs/Run Detail, Transcripts, Trigger, Configuration — served
alongside the control plane, hand-authored CSS with no Node/npm/bundler
(constitution Technology Stack → Frontend). Every color, radius, font-size,
and spacing literal lives once, in `priv/static/assets/console.css`'s single
`:root` token block, governed by `docs/design-constitution.md` (constitution
2.2.0 Principle VII / Operator Surface Design); status color travels from
Elixir as a `data-status` name only, never a value (`CoreComponents.status_class/1`).
`test/support/design_contract.ex` is a pure mechanical guard in the default
test suite (`design_contract_test.exs`) that fails loud, naming file and line,
if a color/radius/font-size/spacing literal, a duplicated status value, an
unlisted keyframe, or a prohibited inline style returns —
`specs/020-reconcile-console-design/compliance-inventory.md` records the
judgment calls (mono-vs-sans role, recovery-path ranking, empty-state wording,
…) the guard cannot decide.

**Observability (Phase 6).** `FeatureRunner` wraps each phase in
`:telemetry.span([:speckit, :phase], …)` (start/stop/exception) and emits
`[:speckit, :feature, :terminal]`; `Telemetry.attach_default_logger/0` logs them.
`Transcripts` writes `<worktree>/.speckit_logs/NN-<phase>.md` per phase.
`Coordinator` tracks per-feature start times; `Report.format_status/1` renders
the snapshot as an iex table (`SpeckitOrchestrator.print_status/0`).
`SpeckitOrchestrator.resolve/1` frees a kept worktree so a human-resolved feature
re-runs on its existing branch (`Worktree.create` reuses an existing branch).
`SpeckitOrchestrator.resume/2` is the shipped checkpoint-driven restart path —
resumes a halted/escalated feature at its checkpointed phase (or an earlier
`:from` phase), optionally injecting operator `:prompt` guidance — for the local,
single-phase-fix case; `resolve/1` remains the tool when upstream artifacts must
be regenerated or the checkpoint is missing/corrupt. Operator flow:
`docs/runbook.md`.

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
features/statuses/in-flight (never more than one), releases the next feature in
`Release.order/1` via `Release.next/3`, and on drain emits a final report
(`done`/`escalated`/`halted`/`failed`/`not_started`/`stopped_by`/`spend`). No
`cap` field, no `set_cap/2` — how many features run at once is a structural
property, not a live-tunable one. When `Release.next/3` returns
`{:stopped, id, status}` with nothing in flight, the Coordinator parks the run
(`Store.Writer.park_run/2`) instead of draining silently, recording
`stopped_by`. Runner spawning is an **injected seam** (`:runner`) so the
release/breaker logic is unit-tested without CLI/worktrees; the facade supplies
the real runner. A tripped `Ledger` breaker releases nothing new and
`FeatureRunner` halts the in-flight feature between phases (drain, not kill).
App tree: `Ledger` + `{Task.Supervisor, RunnerSup}`; the Coordinator is
per-run. A parked run refuses new work for that repository until an operator
resolves it with an explicit `:continue` or `:end` decision
(`SpeckitOrchestrator.continue_run/1` / `end_run/1`) — see `docs/runbook.md`.

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

`test/fixtures/breakdown/` is the **LedgerLite** 7-feature backlog (plan §7.1)
used as golden input for the `Backlog` parser and the eventual end-to-end
validation run. `breakdown_duplicate/` proves the one remaining load-time
guard fires: two files whose `NNN` prefixes are numerically equal raise
`Backlog.DuplicateNumberError`. `docs/breakdown-format.md` is the parser's
format contract, to reconcile with real `macro-spec-breakdown` output later.
