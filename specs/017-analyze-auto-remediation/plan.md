# Implementation Plan: Analyze Auto-Remediation Loop

**Branch**: `017-analyze-auto-remediation` | **Date**: 2026-07-26 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/017-analyze-auto-remediation/spec.md`

## Summary

Let a feature fix its own analyze findings before the analyze gate diverts it to
a human: when an analyze run reports findings at or above a configured severity
threshold (default High), run a bounded corrective step against those findings
verbatim and re-run analyze, repeating until the run comes back clean or a
per-run attempt limit (default 2, range 1–5) is spent — then hand the feature to
the gate exactly as it is handed today.

Technical approach — two new pure modules, one new edge module, one extracted
helper, one new action, plus small extensions to nine existing modules.
`Severity` turns the finding vocabulary (`Low < Medium < High < Critical`) into
a total order with an inclusive-floor threshold test. `Remediation.next/2` is
the pure decision surface for the whole loop — remediate / gate / halt / fail —
the direct analogue of `Pipeline.next/3` and `Chunking.next/2`. `AnalyzeRunner`
is the edge that drives it, invoked from `FeatureRunner` for `phase == :analyze`
exactly the way `ChunkRunner` is invoked for `:implement`: it runs analyze,
evaluates, dispatches a remediation step, re-runs analyze, and finally returns
the agent shape carrying the **last** analyze run's outcome and signals. The
seven-phase pipeline, its ordering and its gates are untouched:
`Pipeline.next/3` still sees exactly one `:analyze` outcome, and it sees it only
once. The three launch knobs travel as four new `RunContext` fields — captured
at launch, recorded into the manifest and checkpoints, never re-read from live
config — and are validated once, by a pure function called from both `run/1`'s
preflight and the console's launch form.

Because the loop softens Principle V's "halt immediately on a constitution
Critical finding", this feature also carries the constitution amendment that
permits it (FR-017): a MINOR bump to 1.2.0 with a Sync Impact Report.

## Technical Context

**Language/Version**: Elixir `~> 1.20`, pinned `1.20.2-otp-28` via
`.tool-versions`; OTP 28 system-provided (never mise-managed). Every command
through `mise exec --`.

**Primary Dependencies**: none added. Existing: Jido `~> 2.2`, `jido_harness` +
`jido_claude` (GitHub SHA pins, `override: true` on the harness), Phoenix
`~> 1.7` / LiveView `~> 1.0` on Bandit, `phoenix_pubsub`, Jason, `:telemetry`.

**Storage**: no database. Durable state stays file-backed — the per-feature
`checkpoint.json` under the run's `%Layout{}.transcript_root` gains one optional
`analyze_remediation` key; the run manifest is unchanged in shape (it already
records the run's `RunContext` verbatim); per-attempt transcripts are additional
files under the existing durable transcript root.

**Testing**: ExUnit. Default suite hermetic — the pure modules plus the existing
injected seams (`:runner`, the LiveView `:console_test_runner`, and a scripted
fake agent for `AnalyzeRunner`, mirroring `chunk_runner_test.exs`). Real-harness
coverage behind `mix test --include integration`. `warnings_as_errors` is on;
`mix format` mandatory.

**Target Platform**: BEAM control plane on developer/CI machines (darwin +
linux), driving the `claude` CLI against a target git repo.

**Project Type**: single Elixir application (`speckit_orchestrator`) — OTP
control plane with an embedded Phoenix LiveView operator console.

**Performance Goals**: SC-004 — a feature with only below-threshold findings
takes no more time and no more spend than today (structurally: the loop's first
decision returns `{:gate, _}` before any second harness call). FR-013 — an
in-flight attempt is visible in the console within the existing 5 s window
(broadcast-on-event plus the 2 s reconcile tick; no new timer).

**Constraints**: worst-case added spend per feature is bounded by
`attempt_limit` remediation steps + `attempt_limit` analyze re-runs, all inside
the existing `Ledger` budget with no exemption (FR-009, SC-006). Per-action
timeout (`jido_action` 45 min) must keep governing one harness call, so the loop
dispatches one action per step and never wraps N sessions in one action. No JS
build step, no new runtime dependency, no new OTP process, no new
supervision-tree child.

**Scale/Scope**: 4 new lib modules + 1 new action + 1 new prompt pack,
extensions to ~11 existing modules, ~8 new/extended test files, 1 constitution
amendment. Findings observed in practice: 1–6 per analyze run, of which 1–2 are
at or above High.

## Constitution Check

*GATE: evaluated before Phase 0 research; re-evaluated after Phase 1 design.*
*Assessed against constitution v1.1.0, which FR-017 amends to v1.2.0 — see
Complexity Tracking.*

| Principle | Assessment |
|---|---|
| **I. Pure Core, Isolated Contracts** | PASS. `Severity` and `Remediation` are pure and CLI/harness/Jido-free; every signal the loop decides on (analyze outcome, parsed findings, breaker state, which step just ran) is extracted upstream in `AnalyzeRunner` and passed in as an argument, mirroring `Pipeline.next/3`. No fast-moving external contract is newly encoded: the loop reads `AnalyzeResult`, which already owns the model-authored JSON boundary. `Pipeline` itself is not modified. |
| **II. Fail Loud at Boundaries** | PASS. An invalid threshold or an out-of-range attempt limit refuses the run **at launch** with a named reason and starts no work — no clamping to the nearest bound, no silent default (FR-011). A malformed analyze report stays a phase failure and never enters the loop. An unrecognized finding severity is reported, not invented into a rank (research R3). A remediation step that fails stops the loop by name rather than burning the remaining budget (FR-008). |
| **III. Least-Privilege Containment (Fail-Closed)** | PASS. The remediation step reuses `PhaseRequest.build_remediation/3` verbatim — same `permission_mode: :accept_edits`, same `Read Write Edit Bash Grep Glob` set, same worktree `cwd`. No new tool, path, or permission is granted, and containment continues to rest on the committed target pack + scope-guard hook (FR-014). |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | PASS, and tightened. Every attempt and every re-run charges the `Ledger` through the existing `Cost.for_phase/2` path; the breaker is checked **between** loop steps so the in-flight step finishes and nothing new starts (FR-009). A dedicated `:auto_remediation` estimate guarantees no loop step is ever accounted as free (FR-009b, SC-008) — and closes a live hole where `:remediation` resolved to `0.0` (research R6). The attempt limit is itself a spend bound. |
| **V. Human-in-the-Loop Escalation** | PASS **only with the FR-017 amendment**, which this feature delivers. The loop runs strictly *before* the gate decides, so a gate diversion is still never retried (FR-007); on exhaustion the gate's existing rules produce the identical terminal state, with the reason naming exhaustion (FR-006); worktree retention, `resolve/1` and the clarify gate are untouched. The residual softening — a Critical finding is now remediated *before* halting rather than halting immediately — is real, bounded, switchable, and recorded. See Complexity Tracking and `contracts/constitution-amendment.md`. |
| **VI. Idiomatic Elixir/OTP** | PASS. Pure transforms over immutable structs; a table-driven multi-clause `next/2` with guards rather than nested conditionals; tagged tuples throughout (`{:remediate, …}` / `{:failed, reason}`), raising reserved for programmer error. **No new process**: `AnalyzeRunner` is a plain module called from the supervised `Task` `FeatureRunner` already runs in, so nothing new needs a restart strategy and no long work moves into a `GenServer` callback. `@spec` on every public function. |
| **Technology Stack** | PASS. No new runtime dependency, no database, no JS build step, no CSS framework — the launch controls reuse the existing switch/select markup and the phase sub-label slot the chunk display already established. The console stays an observability surface: it collects three settings at launch and renders attempt progress, while the run's own recorded `RunContext` and the per-attempt records stay authoritative. |

**Post-design re-check**: unchanged. Three structural risks surfaced during
Phase 1 design and were closed *inside* the design rather than deferred:
attempt transcripts must not consume pipeline step numbers or
`Recovery.Evidence`'s `07-converge.md` lookup drifts (research R9, same rule
015 learned); the per-run settings must be captured rather than read live or a
mid-run config edit changes an in-flight run (R4, the `pr_workflow` lesson);
and the default being **on** means existing analyze-gate tests must pin
`auto_remediation: false` explicitly (R16) — enumerated, not discovered as a red
suite.

## Project Structure

### Documentation (this feature)

```text
specs/017-analyze-auto-remediation/
├── plan.md                                     # This file
├── research.md                                 # Phase 0 output — R1..R16
├── data-model.md                               # Phase 1 output — E1..E7
├── quickstart.md                               # Phase 1 output — validation guide
├── contracts/                                  # Phase 1 output
│   ├── severity.md                             # ordered vocabulary + threshold floor
│   ├── remediation.md                          # pure decision table + settings + instruction
│   ├── analyze_loop.md                         # edge: loop, records, cost, breaker, PhaseStep
│   ├── checkpoint-analyze-remediation.md       # durable state + run-context extension
│   ├── telemetry-console.md                    # events + console surfaces + launch form
│   └── constitution-amendment.md               # FR-017 draft text + acceptance
├── checklists/requirements.md
├── spec.md
└── tasks.md                                    # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── severity.ex                        # NEW — pure ordered vocabulary + at_or_above?/2
├── remediation.ex                     # NEW — pure next/2, Settings.validate/1,
│                                      #       instruction/2, terminal_reason/2
├── analyze_runner.ex                  # NEW — edge: drives the loop for the analyze step
├── phase_step.ex                      # NEW — extracted run_phase + retry + transcript label
├── actions/run_auto_remediation.ex    # NEW — "auto_remediation.run"
├── analyze_result.ex                  # + max_severity/1, findings_at_or_above/2,
│                                      #   unknown_severities/1 (critical?/high? untouched)
├── feature_agent.ex                   # + "auto_remediation.run" signal route
├── feature_runner.ex                  # delegate :analyze to AnalyzeRunner; generalize
│                                      #   chunk_terminal_override/1; decorate gate reason
├── run_context.ex                     # + 4 auto-remediation fields (capture/to_map/from_map/@keys)
├── config.ex                          # + 4 accessors
├── checkpoint.ex                      # + optional analyze_remediation key
├── telemetry.ex                       # + [:speckit, :remediation, …] names + logger clause
├── console_read_model.ex              # + remediation slice + feed entries
└── web/
    ├── live/trigger_live.ex           # 3 launch controls + validation + no env write-back
    ├── live/escalations_live.ex       # attempt-history summary line
    └── components/core_components.ex  # analyze sub-label "attempt k/n" (rename chunk slot)

lib/speckit_orchestrator.ex            # run/1 preflight validates the settings (FR-011)

config/config.exs                      # + auto_remediation{,_threshold,_attempt_limit,_model};
                                       #   cost_estimates gains :auto_remediation and :remediation

priv/prompts/analyze_remediation.md    # NEW — corrective-instruction framing pack

.specify/memory/constitution.md        # AMENDED (FR-017) — 1.1.0 → 1.2.0
CLAUDE.md                              # analyze-gate description gains the loop

test/speckit_orchestrator/
├── severity_test.exs                  # NEW
├── remediation_test.exs               # NEW — decision table, validate/1, instruction, reason
├── analyze_runner_test.exs            # NEW — scripted fake agent; attempt counts; transcripts
├── phase_step_test.exs                # NEW — extraction is behaviour-preserving
├── analyze_result_test.exs            # + severity accessors, unknown severities
├── feature_runner_test.exs            # + loop delegation; existing gate tests pin loop off
├── run_context_test.exs               # + 4-field capture/round-trip/merge precedence
├── checkpoint_test.exs                # + analyze_remediation round-trip, pre-017 compat
├── console_read_model_test.exs        # + remediation fold, no double-count
├── resume_test.exs                    # + fresh attempt budget on resume (FR-015)
└── web/
    ├── trigger_live_test.exs          # + 3 controls, defaults, field-level rejection
    └── escalations_live_test.exs      # + exhausted-attempts summary

test/fixtures/analyze/                 # NEW — findings JSON: high-then-clean, persistent-high,
                                       #   worsening (high→critical), medium-only,
                                       #   unknown-severity, malformed
```

**Structure Decision**: single Elixir application, unchanged. The two new pure
modules sit alongside the existing pure core (`Pipeline`, `Release`, `Ledger`,
`Backlog`, `Chunking`); the new edge module sits alongside `FeatureRunner` and
`ChunkRunner`, which call it. No new supervision-tree children, no new directory
conventions, and no change to the `specs/`, worktree, or transcript layouts
established by feature 012.

## Complexity Tracking

One deliberate deviation, recorded per the Governance section.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| **Principle V** — the analyze gate no longer halts *immediately* on a Critical finding; a bounded pre-gate loop may attempt to fix it first | The most common unattended analyze outcome is a mechanically fixable High finding about an incomplete `plan.md`/`tasks.md`. Stopping the feature dead for it is what makes an unattended run supervised (SC-001, SC-002). The softening is bounded (1–5 attempts, default 2), switchable per run, fully recorded, and preserves the identical terminal state on exhaustion (FR-006/FR-007) | *Remediate High but never Critical*: rejected — it splits one rule into two and leaves the ordered-severity contract (FR-001a) half-honoured; a Critical finding about a missing artifact is as mechanically fixable as a High one, and the terminal state is unchanged either way. *Leave the constitution alone and record a silent deviation*: rejected — Governance requires an amendment for a principle change, and a permanent standing deviation in a plan file is exactly the drift the amendment procedure exists to prevent. *Ship the loop off by default*: rejected — SC-001/SC-002 measure the default path; a default-off loop delivers none of the feature's value and FR-002/FR-010 fix the default as on |

The amendment (`contracts/constitution-amendment.md`) is delivered **by this
feature**, not deferred: MINOR bump 1.1.0 → 1.2.0 with a Sync Impact Report, no
other principle weakened.

## Notable design decisions carried from Phase 0

Recorded here because they constrain implementation and are easy to get wrong:

1. **The loop lives inside the analyze step, below `Pipeline.next/3`** — that is
   what makes "never retried past the human" structural rather than a promise
   (R1).
2. **Unrecognized severities match no threshold, including Low** — a deliberate
   reading of FR-001a, with the alternatives (unknown → Critical, unknown → Low)
   both worse (R3). The one item `/speckit-analyze` should confirm.
3. **Settings are captured into `RunContext`, never read live** — a mid-run
   config edit must not reach an in-flight run, and a launch choice must not
   become the next run's default (R4; the `pr_workflow` toggle already paid for
   this lesson).
4. **`auto_remediation_model` ≠ `remediation_model`** — 013 already owns the
   latter for the operator-supplied pre-phase step (R5).
5. **A distinct `:auto_remediation` cost tag, and `:remediation` gets an
   estimate it never had** — `config/config.exs` replaces the whole
   `cost_estimates` map and omits `:remediation`, so 013's step is accounted as
   free today. Fixed here, and called out as adjacent scope (R6).
6. **Attempt records are `-a<k>`-labelled and never consume step numbers**; the
   roll-up keeps the plain `NN-analyze.md` name so `Recovery.Evidence` and the
   transcript views are untouched (R9).
7. **The checkpoint's `attempts_used` is provenance, never budget** — every new
   feature run, including a human resume, starts at zero (R10, FR-015).
8. **Exhaustion decorates the terminal reason; the gate is untouched** —
   `{:high_findings, :auto_remediation_exhausted}`, and a bare atom whenever the
   loop did not run (R11, SC-007a).
9. **The default is on, so existing analyze-gate tests must pin it off** — two
   assertions in `feature_runner_test.exs`; `pipeline_test.exs` is unaffected
   because the transition table does not change (R16).
