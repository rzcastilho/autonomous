# Implementation Plan: Remove Cost Budget Breaker and Strict Containment Profile

**Branch**: `039-remove-budget-strict-profile` | **Date**: 2026-10-09 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/039-remove-budget-strict-profile/spec.md`

## Summary

Two removals, one amendment (research R1–R14):

1. **Cost is informational (US1).** `Ledger` shrinks to a cost accumulator
   (`record/3`, `spent/1`, `restore/2`, `snapshot/1` → `%{committed}`);
   `reserve`, `set_budget`, `breaker_tripped?` and the budget state go. Every
   cost-breaker branch on the session path (FeatureRunner, PhaseStep,
   SessionRetry, Chunking/ChunkRunner, Remediation, AnalyzeRunner,
   InteractiveClarify) is deleted, leaving the supersession-drain branch beside
   it untouched. `Release.next/3`'s third argument becomes `blocked?`
   (persistence breaker only). Cost is still measured (`Cost.for_phase/2`,
   estimates) and shown everywhere as a plain figure.
2. **One containment behaviour (US2).** The former `permissive` set is the
   only set: every phase gets `bypass_permissions` + the full tool set +
   headless exclusions. `Containment`, the profile in `RunContext`/agents/
   Coordinator/Report/PR body/console, the resume profile lock, the strict
   per-phase table, the strict-only untrusted-workspace gate and the
   `scope_guard.py` hook (with its sudo grammar) are deleted. The pack moves
   to **contract 6** (`.claude/autonomous-pack.json`), checked on every run;
   an older committed pack fails preflight with reinstall instructions. A
   non-container start logs a loud warning and proceeds. Agent root keeps
   markers, prompt note and install logging.
3. **Refusal + governance (US3).** `:budget_usd` / `:containment_profile`
   join 019's retired-setting refusal on every surface (options, app env,
   env vars, LiveConfig). Stored records need no migration (values live in an
   untyped settings map; legacy keys ignored and hidden). Constitution
   6.1.0 → **7.0.0** (MAJOR); docs, scripts, smoke checks follow.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28.5.0.6 (`mise.toml`; `mise exec --`); Python 3 only in the deleted hook

**Primary Dependencies**: Jido ~> 2.2, jido_harness/jido_claude (SHA-pinned), Phoenix LiveView ~> 1.0, Jason — no new dependency, none removed

**Storage**: Mnesia, schema **v7 unchanged** (no column holds budget/profile; R10)

**Testing**: ExUnit, `Phoenix.LiveViewTest`, `ExUnit.CaptureLog`; hermetic default suite; `design_contract_test.exs`; `scripts/container-smoke.sh` by hand

**Target Platform**: single-node BEAM in the `scripts/autonomous` container (supported runtime); host for `mix compile|test`

**Project Type**: OTP application (control plane) + embedded LiveView console + target-repo pack

**Performance Goals**: N/A — removal; one fewer `python3` fork per tool call (hook gone)

**Constraints**: `warnings_as_errors`; supersession drain and `Store.Health` release block unchanged (FR-019); legacy records readable (FR-017); refusals happen before any side effect (feature 035 atomic-continue preserved)

**Scale/Scope**: ~45 lib files touched, 1 module deleted (`Containment`), 1 added (`RuntimeNotice`), pack hook deleted, ~40 test files touched, ~10 docs, 3 scripts

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

This feature **amends** the constitution (FR-018). Gate is evaluated against
7.0.0 as amended by this change (R12); the amendment itself is the recorded
deviation from 6.1.0 (Complexity Tracking).

| Principle | Assessment |
|---|---|
| I. Pure Core, Isolated Contracts | ✅ Decision tables shrink (`Release`, `Remediation`, `Chunking`, `SessionRetry`) and stay pure; new `RuntimeNotice.container_warning/1` is pure with the `ContainerGuard` read at the edge. `Ledger` stays listed as the cost accumulator. |
| II. Fail Loud at Boundaries | ✅ Retired-settings refusal extended to both keys on every surface (R4); outdated pack fails preflight loudly with a fix (R6); legacy records are *read*, not refused — they are not a clean break (R10). |
| III. (7.0.0) Container-Bounded Execution | ✅ Single behaviour, container as supported runtime + loud non-container warning, pack contract enforced every run, human sessions never denied. **Deviation from 6.1.0 III** → amendment. |
| IV. (7.0.0) Cost Transparency; Drain, Don't Kill | ✅ Cost measured per attempt (actual → estimate), rolled up, shown, never gating; drain-don't-kill kept for supersession/persistence. **Deviation from 6.1.0 IV** → amendment. |
| V. Human-in-the-Loop | ✅ Gates unchanged; only the breaker exit is removed from the clarify-wait exit list and the remediation loop. |
| VI. Idiomatic OTP | ✅ Ledger stays a thin GenServer; no new processes. |
| VII. Operator Surfaces Tell the Truth | ✅ Spend stays primary and plain; no surface claims a budget that no longer exists. 7.0.0 drops the gauge/breaker requirement; `docs/design-constitution.md` §185 amended in the same change; guard stays green. |
| Persistence | ✅ No schema change; no dirty writes added. |
| Quality | ✅ Breaker tests deleted with the code; drain tests unchanged; new refusal/legacy/large-spend tests (R14). Hook red-team bullet removed with the hook. |

**Result**: PASS with the recorded amendment. Post-design re-check: PASS —
design adds no dependency, table, or supervised process; removes one module
and one hook.

## Project Structure

### Documentation (this feature)

```text
specs/039-remove-budget-strict-profile/
├── plan.md              # This file
├── research.md          # Phase 0 (R1–R14)
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── run-start.md          # retired options/config, preflight order, container notice
│   ├── target-pack.md        # pack contract 6, sessions, agent root
│   └── operator-surfaces.md  # what each surface drops/keeps
├── checklists/
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
lib/autonomous.ex                    # @retired_opts += budget_usd, containment_profile; drop preflight_containment,
                                     # guard_containment_profile, warn_agent_root_pack, profile arg of preflight_stacked,
                                     # pr containment note; container notice in preflight; docs
lib/autonomous/
├── application.ex                   # @retired_app_env += both keys; Ledger child comment
├── ledger.ex                        # → cost accumulator only (R1)
├── config.ex                        # delete budget_usd/0, containment_profile/0
├── containment.ex                   # DELETE
├── runtime_notice.ex                # NEW pure: container_warning/1
├── run_context.ex                   # drop budget_usd, containment_profile
├── live_config.ex                   # :budget_usd → retired-field error
├── release.ex                       # third arg breaker_tripped? → blocked?
├── coordinator.ex                   # blocked? = store_unwritable?; drop breaker/containment keys
├── feature_runner.ex                # drop breaker branches, containment threading, untrusted clause
├── phase_step.ex / session_retry.ex # drop breaker?; keep drain?
├── chunking.ex / chunk_runner.ex    # drop Row 7, Row U, breaker?
├── remediation.ex / analyze_runner.ex / interactive_clarify.ex  # drop breaker rows/clauses
├── pipeline.ex                      # drop :untrusted_workspace gate
├── workspace_trust.ex               # settle/… warn-only, no profile arg
├── phase_request.ex                 # one permission set; no containment opt/env
├── describe.ex / feature_agent.ex / actions/init_feature.ex      # drop containment
├── actions/run_feature_phase.ex, run_auto_remediation.ex, run_remediation.ex  # drop containment arg
├── agent_root.ex                    # drop denied?/scope_guard filter; docs
├── target_pack.ex                   # contract 6 always-on check; install writes marker, removes stale hook
├── report.ex                        # drop BREAKER/containment lines; retired-option renderers; keep historic renderers
├── cost.ex / telemetry.ex / workers.ex / store/health.ex          # doc wording
├── coordinator_probe.ex             # drop ledger/2
├── console_projection.ex / console_read_model.ex                  # drop ledger probe; merge/3 → merge/2
└── web/
    ├── components/core_components.ex   # delete cost_gauge/1
    ├── components/layouts.ex (+ app.html.heex)  # plain spend; no gauge/breaker/containment chips
    ├── config_diff.ex                  # drop budget clauses, parse_cents/1
    ├── run_settings_view.ex            # hide legacy keys
    ├── agent_root_view.ex              # hidden | available
    ├── start_confirm.ex                # container notice line
    └── live/{config,trigger,run_detail,mission_control,pipeline_dag,escalations}_live.ex

priv/target_pack/.claude/
├── settings.json                    # drop hooks key
├── autonomous-pack.json             # NEW {"contract": 6}
└── hooks/scope_guard.py             # DELETE
priv/prompts/agent_root.md           # grammar line → guidance
priv/static/assets/console.css       # delete gauge, .breaker-chip, .containment-chip rules

config/config.exs, config/runtime.exs  # delete budget_usd; retire both env vars
scripts/autonomous, scripts/container-entrypoint.sh, scripts/container-smoke.sh, Dockerfile  # R13

.specify/memory/constitution.md      # 7.0.0 (R12)
docs/design-constitution.md          # §185
docs/{enforcement,runbook,container,workflow,harness-contract}.md, README.md, CLAUDE.md

test/autonomous/
├── scope_guard_test.exs, containment_test.exs        # DELETE
├── runtime_notice_test.exs                            # NEW
├── retired_options_039_test.exs                       # NEW (all entry points + app env + LiveConfig)
├── legacy_records_039_test.exs                        # NEW (old settings/reasons through Report, Run Detail, resume, continue)
├── ledger_test.exs, target_pack_test.exs, phase_request_test.exs, untrusted_gate_test.exs  # rewrite
└── (breaker/profile cases in ~30 others — R14)       # delete/modify
```

**Structure Decision**: Single OTP app. Everything is a deletion inside
existing modules except one new pure module (`RuntimeNotice`) and one new pack
marker file. Order for tasks: (1) retired-option refusal + RunContext/Config
(blocks callers), (2) breaker removal core → runners → console, (3) profile
removal core → pack/hook → runners → console, (4) constitution + docs +
scripts, (5) sweep tests.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Constitution 6.1.0 Principles III and IV (and VII's gauge rule) no longer hold — amended to 7.0.0 in this change | The operator decided cost is informational and the container-run permissive model is the only one (spec input + Clarifications 2026-10-09). Keeping the 6.1.0 text would make future clarify/analyze/converge runs enforce a breaker and a strict profile that no longer exist (spec US3). | Leaving the constitution as-is and documenting a "deviation" per feature: every later feature's analyze gate would flag the missing breaker/strict profile as a Critical constitution violation. Amending first in a separate change: the project rule is that semantic changes flow through a spec, and the amendment must land with the code that makes it true. |
| Pack contract moves out of the hook into `autonomous-pack.json` | The hook that carried `PACK_CONTRACT` is deleted (R5), but FR-012 needs a bumped, checkable contract | A version key in `settings.json` risks Claude Code's settings validation; keeping an allow-all hook just to carry a number keeps a per-call `python3` fork and a dead red-team suite. |
| `Ledger` kept (slimmed) instead of deriving spend from the store | Preserves today's `report.spend` meaning and keeps store-free Coordinator/console unit tests (R1) | Store-derived spend changes reported numbers — a behaviour change outside this feature's scope. |
