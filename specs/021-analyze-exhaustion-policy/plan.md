# Implementation Plan: Auto-Remediation Exhaustion Policy

**Branch**: `021-analyze-exhaustion-policy` | **Date**: 2026-07-31 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/021-analyze-exhaustion-policy/spec.md`

## Summary

Today an exhausted auto-remediation loop always hands a residual High finding to
a human, so one stubborn finding stops an unattended backlog run cold. This
feature adds a per-run **exhaustion policy** with two values — *escalate*
(default, today's behaviour) and *proceed* — read at exactly one moment: when
the attempt limit is reached with residual findings at or above the run's
severity threshold. Under *proceed* the analyze gate advances instead of
escalating, the pipeline continues normally, and the residual findings are
recorded and surfaced in three places (the run's report, the console, and the
feature's PR body) rather than fed forward to any downstream phase. Critical
still halts unconditionally, at every policy and every threshold.

**Technical approach**: the policy is a fifth field on the existing
`Remediation.Settings` and a ninth field on `RunContext`, so it inherits the
lifetime, validation, capture, resume-replay, and console plumbing the other
three loop knobs already have. It reaches the gate as two flat
`Pipeline.signals` members (`:exhausted?` from the loop, `:exhaustion_policy`
from the run's settings), injected exactly where `:gate_threshold` already is,
and the gate gains one row. The "advanced past findings" fact is an annotation
on `speckit_feature_run` (schema v4, an append transform), never a new lifecycle
status; the terminal `:done` **reason** is decorated so the run report can index
it without touching the status enum. The constitution amendment that permits all
of this (Principle V, **2.2.0 → 3.0.0**) is in scope and lands with the code.

## Technical Context

**Language/Version**: Elixir `1.20.2-otp-28` (pinned in `.tool-versions`; every
command via `mise exec --`)

**Primary Dependencies**: Jido `~> 2.2`; `jido_harness` / `jido_claude` (GitHub
SHAs, `override: true`); Phoenix `~> 1.7` + LiveView `~> 1.0` on Bandit;
`phoenix_pubsub`; `jason`. **No new dependency is added by this feature.**

**Storage**: Mnesia (ships with OTP), single-node, machine-local. This feature
adds **one attribute** to one existing table via schema **version 4** — a plain
`:mnesia.transform_table` append, not a clean break. No new table, no external
service, no ORM.

**Testing**: ExUnit. The default suite is hermetic (its own temp Mnesia schema,
injected `:runner` / `:executor` / `:publisher` / `:console_test_runner` seams);
real-harness work stays behind `--include integration`. Pure core coverage must
stay above 90%. `warnings_as_errors` is ON.

**Target Platform**: BEAM control plane on macOS/Linux; the operator console is
server-rendered LiveView with no Node/npm/bundler.

**Project Type**: Single Elixir/OTP application (`speckit_orchestrator`) with an
embedded Phoenix LiveView console — the existing tree, extended.

**Performance Goals**: none new. SC-006 is a *no-cost* goal, satisfied
structurally: the policy is read only on the exhaustion branch, so a feature
that never exhausts its attempts executes an identical instruction sequence and
issues no additional harness call, no additional analyze run, and no additional
store write.

**Constraints**:

- Critical MUST halt at every policy and every threshold (FR-005, SC-003) —
  enforced by clause order in `Pipeline`, not by a conditional.
- The `:escalate` path MUST be byte-identical to today (FR-003, SC-002) —
  enforced by defaults on absent signals, so there is no parallel legacy path.
- Residual findings MUST NOT reach any downstream phase's input (FR-004a).
- No new terminal lifecycle status (FR-008a).
- No new color/radius/font-size/spacing literal in the console, and no status
  color on a non-status element (Principle VII; mechanically guarded).
- `String.to_atom/1` on form- or file-sourced content stays banned.

**Scale/Scope**: ~10 modules touched, all existing. One new pure function
(`Remediation.exhaustion_advance/2`), one new pure renderer
(`Remediation.pr_note/1`), one new parser clause, one gate row, one schema
migration, one console control, one console block, one constitution amendment.

## Constitution Check

*GATE: evaluated against `.specify/memory/constitution.md` **2.2.0** before Phase
0, and re-evaluated after Phase 1 design (below).*

| Principle | Verdict | Basis |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | ✅ PASS | The gate change is data-in/data-out on `Pipeline.next/3`; the mark decision is a new pure function; the PR section is a pure renderer. No CLI, harness, or Jido reference is added to any pure module. Both new gate signals are extracted upstream and passed in — `:exhausted?` by `AnalyzeRunner`, `:exhaustion_policy` by `FeatureRunner.gate_signals/3`, exactly as `:gate_threshold` already is. |
| **II. Fail Loud at Boundaries** | ✅ PASS | An unrecognized policy is refused at every surface that can supply it — `run/1` preflight, `resume/2`, the console form — with no clamping and no silent default substitution (FR-010, SC-007). A recorded-but-invalid value raises in `remediation_settings!/1` as a corrupt manifest. The parser never invents a value and never calls `String.to_atom/1`. |
| **III. Least-Privilege Containment** | ✅ PASS | No change to the target pack, the scope-guard hook, `settings.json`, or per-phase `PhaseRequest` permissions. |
| **IV. Cost-Bounded Autonomy** | ✅ PASS | No new spend: the policy is read after the attempt budget is already consumed and issues no additional harness call. The breaker keeps precedence — a tripped breaker halts between phases regardless of policy (FR-006; `Remediation.next/2` row 4 is untouched and sits above the exhaustion row). |
| **V. Human-in-the-Loop Escalation** | ⚠️ **REQUIRES AMENDMENT — in scope (FR-016)** | Principle V currently guarantees "on exhaustion the gate decides the outcome from the final analyze run under the rules above, **unchanged**". *Proceed* changes it. See Complexity Tracking. |
| **VI. Idiomatic Elixir/OTP** | ✅ PASS | Multi-clause functions and pattern matching for the gate rows and the parser; tagged tuples (`{:ok, _}`/`{:error, _}`, `{:mark, _}`/`:none`) for every fallible or branching function; raising reserved for the corrupt-manifest boundary; `@spec` on every new public function; no new process, no new supervision concern, no blocking work in a callback. |
| **VII. Operator Surfaces Tell the Truth** | ✅ PASS | The launch control and the feature marker reuse existing classes and the `:root` token set — no new literal. Labels are the real identifiers (`auto_remediation_exhaustion_policy`, `escalate`, `proceed`). No status color on the new block (it is not a status), no second accent hue, no motion on a resting element, no emoji. Every rendered value traces to the stored annotation. `design_contract_test.exs` guards this mechanically in the default suite. |
| **Technology Stack** | ✅ PASS | No new dependency, no database service, no ORM, no JS build step. Persistence stays in Mnesia; the addition is a versioned transform migration, all writes stay transactional, no `:mnesia.dirty_*` write, no auto-delete of recorded state, and the record stays exportable without Mnesia. |
| **Quality & Test Discipline** | ✅ PASS | All new logic is pure enough to test in the hermetic default suite; the live end-to-end stays behind `--include integration`. The `:escalate` regression pins live in the pre-existing test files so a leak fails a test that predates the feature. |
| **Development Workflow** | ✅ PASS | Spec-driven, one feature, one worktree, `feature/021-*` branch; scaffold travels; no `specify init` in a worktree. |

### Post-Phase-1 re-evaluation

Re-checked against the design in `research.md`, `data-model.md`, and
`contracts/`. **No new violation.** Two things the design deliberately hardened:

- **Principle V's absolute bound is preserved structurally.** The Critical halt
  is `Pipeline`'s first `:analyze` clause, matched before any policy is read
  (`contracts/exhaustion-policy.md` §4.1 row 1), and invariant I1 property-tests
  it across every threshold × policy pair. The amendment relaxes the High rule
  only.
- **Principle II gained a surface rather than losing one.** Rejecting an
  unrecognized policy at launch on *every* surface is precisely the "retired /
  unhonoured settings must be refused, not accepted and ignored" refusal the
  principle names.

The single ⚠️ above is unchanged and is resolved by the in-scope amendment
recorded in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/021-analyze-exhaustion-policy/
├── spec.md                          # input (clarified)
├── plan.md                          # this file
├── research.md                      # Phase 0 — R1..R11
├── data-model.md                    # Phase 1 — setting, signals, annotation
├── contracts/
│   ├── exhaustion-policy.md         # setting, validation, signals, gate, launch control
│   └── advanced-record.md           # the record, storage, and its three surfaces
├── quickstart.md                    # Phase 1 — runnable validation scenarios
└── tasks.md                         # Phase 2 — /speckit-tasks, NOT created here
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── pipeline.ex                      # MODIFIED — gate row 3; two new signals + defaults
├── remediation.ex                   # MODIFIED — Settings.exhaustion_policy + parser;
│                                    #   NEW exhaustion_advance/2, pr_note/1
├── analyze_runner.ex                # MODIFIED — exhaustion_signals/3 emits :exhausted?;
│                                    #   carries residual findings on the exhaustion branch
├── feature_runner.ex                # MODIFIED — gate_signals injects the policy;
│                                    #   marks the advance; threads `marks`; decorates :done
├── coordinator.ex                   # MODIFIED — build_report/2 gains advanced_with_findings
├── report.ex                        # MODIFIED — one conditional line
├── run_context.ex                   # MODIFIED — ninth field (capture/to_map/from_map/@keys)
├── config.ex                        # MODIFIED — auto_remediation_exhaustion_policy/0
├── speckit_orchestrator.ex          # MODIFIED — run/1 opt docs; pr_text/2 appends pr_note
├── store/
│   ├── schema.ex                    # MODIFIED — feature_run.advanced_with_findings
│   ├── records.ex                   # MODIFIED — FeatureRun struct + typespec
│   ├── migrations.ex                # MODIFIED — version 4 append transform
│   ├── writer.ex                    # MODIFIED — record_phase_attempt/2 optional key
│   └── query.ex                     # MODIFIED — annotation into the feature slice
└── web/live/
    ├── trigger_live.ex              # MODIFIED — policy control, event, validation, opt
    └── run_detail_live.ex           # MODIFIED — data-advanced-with-findings block

config/config.exs                    # MODIFIED — :auto_remediation_exhaustion_policy default

test/speckit_orchestrator/
├── pipeline_test.exs                # gate matrix + I1/I2/I3/I4 invariants
├── remediation_test.exs             # Settings validation, exhaustion_advance/2, pr_note/1
├── analyze_runner_test.exs          # signal emission, residual findings verbatim
├── feature_runner_test.exs          # exhaust → advance → annotate → decorated :done
├── coordinator_test.exs             # advanced_with_findings ⊆ done
├── run_context_test.exs             # capture/round-trip/merge of the ninth field
├── store/{writer,migrations,query}_test.exs   # v4 transform, one-transaction, slice
├── web/{trigger_live,run_detail_live}_test.exs
└── design_contract_test.exs         # unchanged — guards the new markup mechanically

.specify/memory/constitution.md      # MODIFIED — 2.2.0 → 3.0.0 + Sync Impact Report
CLAUDE.md, docs/workflow.md, docs/runbook.md   # MODIFIED — describe the policy
```

**Structure Decision**: single Elixir/OTP project — the existing tree. Every
path above already exists; this feature adds no new module and no new directory.
That is deliberate: the spec's own Key Entities frame the policy as a fourth
sibling of three knobs that already have a home, and every lifetime, validation,
capture, resume, and console guarantee it needs is already implemented for those
siblings. The two genuinely new behaviours — deciding when the mark applies, and
rendering it for a human — are pure functions on `Remediation`, the module that
already owns the loop's decision surface.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| **Principle V's exhaustion guarantee is relaxed** — "on exhaustion the gate decides the outcome … unchanged" no longer holds unconditionally; a run may configure the escalation away for a residual **High** finding. | This is the feature (FR-016). Without it an unattended overnight run stops on the first non-mechanically-fixable finding and wastes the remaining window (US1). The relaxation is bounded to exactly one cell of the exhaustion matrix — residual High, no Critical, threshold High or lower — is opt-in per run, defaults to today's behaviour, and is paired with a compensating control: the findings are recorded and surfaced to the PR reviewer, the last remaining human gate (FR-008b). | Doing it **without** amending the constitution was rejected outright: a principle that says "unchanged" while the code changes it is exactly the drift Principle II and Governance exist to prevent. A **MINOR** bump was rejected by the 2.0.0 precedent — that amendment set the test ("an operator can now configure away a human-facing terminal state that was previously unconditional … MAJOR rather than MINOR"), and this is the same shape. Amending **after** shipping was rejected: Governance requires the amendment to be committed with the change, and FR-016 requires it to land together with the behaviour it permits. |
| **A new attribute on `speckit_feature_run` (schema v4)** rather than reusing an existing field. | FR-007 requires the residual findings **verbatim** plus the attempts consumed and the policy, durable and readable by three separate surfaces (report, console, PR publisher). No existing field can carry a structured map without overloading its meaning. | A **new table** was rejected: cardinality is 0-or-1 per feature run and every reader already reads the feature row — a join for nothing. Reusing **`speckit_escalation`** was rejected emphatically: the defining property of this record is that the feature was *not* escalated, and putting it there would fill `/escalations` with rows that need no human, corrupting the one surface that answers "what is waiting on me". Stuffing it into **`terminal_reason`** was rejected: it must survive a downstream failure that overwrites the reason, and it must be queryable without parsing a tuple. |
| **`FeatureRunner.loop/*` threads a `marks` map** across phases. | The advance is decided at `:analyze` but must be reflected on the terminal the feature reaches at `:converge`, so the fact has to travel. | **Agent state** was rejected: `AnalyzeRunner.patch/2` merges into the *returned* agent copy, not the `AgentServer`'s state, so the fact does not survive the next phase. **Changing `notify/4`'s arity** to carry it was rejected: that is the `Coordinator`'s public contract and the `:runner` seam every control-plane test injects; decorating the existing `reason` reuses the precedent `Remediation.terminal_reason/2` already set and touches no contract. **Re-reading the store at terminal** was rejected: it would make the in-memory report depend on persistence, which non-store-backed runs (most unit tests) do not have. |
