# Implementation Plan: Permissive Containment Profile

**Branch**: `030-permissive-containment` | **Date**: 2026-09-28 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/030-permissive-containment/spec.md`

## Summary

Today the pack blocks the same actions for everyone who opens Claude Code in
a target repository, the operator included. Headless phases are also
narrowed per phase. This feature adds two containment profiles:

- `strict`: the default. Behaviour is byte-identical to today.
- `permissive`: an opt-in, per-run profile. Under it the pack keeps no deny
  list and every phase gets the full tool set.

The operator's own interactive sessions are never denied by the pack.

The approach (see [research.md](research.md)):

1. **Move every denial into the hook.** Today `settings.json` deny rules
   apply to every session, human sessions included, so they must go (R1).
   The hook takes over the union of the old settings rules and the old hook
   rules, with the same decision for every input under `strict` (R4).
2. **Origin comes from the environment.** The orchestrator marks every
   session it starts with `SPECKIT_ORCHESTRATED=1` and
   `SPECKIT_CONTAINMENT_PROFILE`, passed through `RunRequest.metadata`.
   A session is treated as human only when there is no marker and
   `CLAUDE_CODE_ENTRYPOINT=cli`. Anything else resolves to `strict` (R3).
3. **Per-phase permissions follow the profile.** The real SDK path passes
   `--permission-mode`, not `--dangerously-skip-permissions` (R2). So under
   `permissive`, `PhaseRequest` uses `:bypass_permissions`, adds
   `WebFetch`/`WebSearch`, and keeps only the FR-008 tool exclusions (R5).
4. **The profile is recorded once, then locked.** It is the thirteenth
   `RunContext` key. A missing key decodes to `"strict"`, so a recorded run
   never falls back to a changed live default. Resume and continue refuse a
   different profile (R6).
5. **Preflight checks the committed pack.** A `permissive` run needs the
   committed hook at pack contract 2 and a committed `settings.json` with no
   deny list. A `strict` run needs nothing new (R7).
6. **Surfaces show a marker only under `permissive`.** The marker appears on
   the report, the status, the topbar, Run Detail, the Configuration page,
   and the PR note. It uses a neutral chip and no new colour (R8).
7. **Governance first.** Constitution 6.0.0 amends Principle III before the
   implementation merges (R11, FR-014).

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28 (via `mise exec --`). The hook is Python 3 stdlib (unchanged runtime).

**Primary Dependencies**: `jido_harness` / `jido_claude` (`:claude` adapter; `RunRequest.metadata["claude"][:env]` passthrough) and `claude_agent_sdk` (`--permission-mode` mapping, subprocess env merge). Phoenix LiveView for the console. No new dependency and no SHA bump.

**Storage**: Mnesia, with no schema change. The profile is one key in the existing free-form `RunSettings.settings` map and in the checkpoint's `run_context` map.

**Testing**: ExUnit.
- The real-hook red-team (`scope_guard_test`) runs with a pinned env, plus a new origin × profile matrix and a parity test against the old settings deny list.
- Pure tests for `Containment`, `RunContext` and `PhaseRequest`.
- `TargetPack.verify/2` tests against real temp git repos.
- Seam-injected facade tests for the preflight and the resume lock.
- LiveView and report tests for strict byte-identity and permissive markers.
- The design guard.

**Target Platform**: A single-node BEAM host on macOS or Linux. It drives target repos through git worktrees and the `claude` CLI.

**Project Type**: OTP control plane (library + LiveView console) plus the target-repo pack (`priv/target_pack/`).

**Performance Goals**: None new. The hook stays a single short-lived Python process per guarded tool call.

**Constraints**:
- `warnings_as_errors`.
- `strict` must be byte-identical on the pack decision set, the per-phase permissions and every run-describing surface (FR-002, SC-003).
- The existing red-team assertions stay unedited.
- Malformed input fails closed under every origin (FR-010).
- No `String.to_atom/1` on stored values.
- The design guard stays green.

**Scale/Scope**:
- About 18 modules touched, 1 new pure module (`Containment`), 2 pack files and 3 docs.
- 1 constitution amendment.
- No new process type, table or status.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|---|---|
| I. Pure Core, Isolated Contracts | ✅ The profile → permissions map is pure (`PhaseRequest`), and so are the `Containment` helpers and `RunContext`. The harness env passthrough uses the documented `RunRequest.metadata` field, and the adapter is not changed. `docs/harness-contract.md` records the observed `--permission-mode` path (R2). |
| II. Fail Loud at Boundaries | ✅ An unknown profile is refused at preflight, in config and on the Trigger form. A permissive run against an outdated pack is refused with `{:pack_outdated, …}`. A profile change on resume is refused by name (`{:containment_profile_locked, recorded}`), not ignored. The hook cannot refuse, so it maps unknown values to `strict`. |
| III. Least-Privilege Containment (Fail-Closed) | ✅ **Compliant with 6.0.0** (amended 2026-09-28, FR-014). Against 5.0.0 this was a deliberate violation. `permissive` removes the hook's deny list and per-phase narrowing. The mitigations: `strict` stays default and decision-identical; fail-closed on malformed input is kept under every origin; an undecided origin resolves to `strict`; the layered model is kept for `strict`, and the container recipe is recommended for `permissive`. The 6.0.0 text encodes each of these as a MUST. See Complexity Tracking for the history. |
| IV. Cost-Bounded Autonomy | ✅ Unchanged. The breaker, drain and session deadlines do not read the profile (FR-009). |
| V. Human-in-the-Loop Escalation | ✅ Unchanged. The clarify and analyze gates decide exactly as today. An analyze session's edits under `permissive` do not feed the gate (spec edge case). |
| VI. Idiomatic Elixir/OTP | ✅ The profile is threaded through agent state like `layout`, with multi-clause `permissions/2` and tagged-tuple refusals. No new process. |
| VII. Operator Surfaces Tell the Truth | ✅ Every relaxation is visible on every listed surface and in the PR body. The marker shows the machine value in mono. No status colour is borrowed, so there is no design-constitution amendment. |
| Technology Stack / Persistence | ✅ No new dependency, no migration. The data rides the existing free-form maps. |

**Result: PASS against 6.0.0.** Principle III was the only conflict with
5.0.0. Constitution 6.0.0 (2026-09-28) resolves it: it ratifies `strict` and
`permissive`, the resume lock, strict-on-undecided origin, and the visibility
obligation. The amendment commit must land before or with the
implementation.

**Post-design re-check (after Phase 1): PASS.**
- The contracts add no process type, table, status or dependency.
- The strict path differs from today in two places only: the env markers on
  the `RunRequest` and the denial-message prefix. Neither changes a decision.
  The prefix is required by FR-016.
- FR-016 is read as scoped to pack-emitted denials (R9). This is flagged for
  analyze.

## Project Structure

### Documentation (this feature)

```text
specs/030-permissive-containment/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── scope-guard.md
│   ├── run-options.md
│   ├── pack-preflight.md
│   └── operator-surfaces.md
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
.specify/memory/constitution.md            # 6.0.0: Principle III profiles (FR-014) — FIRST
priv/target_pack/.claude/
├── settings.json                          # drop permissions.deny; widen matcher (+WebFetch|WebSearch)
└── hooks/scope_guard.py                   # origin/profile decision, strict union rules, PACK_CONTRACT=2, --contract, FR-016 reasons
lib/speckit_orchestrator/
├── containment.ex                         # NEW pure: normalize/1, permissive?/1, session_env/1, pr_note/1, report_line/1
├── config.ex                              # containment_profile/0 (default :strict)
├── run_context.ex                         # 13th key; from_map missing ⇒ "strict"
├── phase_request.ex                       # :containment opt on build/3, build_remediation/3; permissive set; env metadata
├── target_pack.ex                         # verify/2 profile: opt, check_pack_contract/2 (HEAD:)
├── feature_agent.ex                       # containment state field
├── actions/init_feature.ex                # seed containment
├── actions/run_feature_phase.ex           # pass containment (covers implement chunks)
├── actions/run_auto_remediation.ex        # pass containment
├── actions/run_remediation.ex             # pass containment
├── describe.ex                            # containment opt → PhaseRequest
├── feature_runner.ex                      # read run_context profile → init + Describe
├── coordinator.ex                         # containment_profile key in snapshot/report (permissive only)
├── report.ex                              # containment line (permissive only)
└── web/
    ├── components/layouts.ex              # topbar chip (permissive only)
    └── live/{trigger,run_detail,config,mission_control}_live.ex
lib/speckit_orchestrator.ex                # run/1 preflight (invalid value, pack contract), resume/continue lock, pr_text note
priv/static/assets/console.css             # chip rule using existing tokens only
docs/enforcement.md, docs/runbook.md, docs/harness-contract.md, CLAUDE.md   # FR-017

test/speckit_orchestrator/
├── containment_test.exs                   # NEW pure
├── scope_guard_test.exs                   # pinned env helper; origin×profile matrix; settings-deny parity; SC-002 probe
├── phase_request_test.exs, run_context_test.exs, target_pack_test.exs
├── coordinator_test.exs, report_test.exs, pull_request_test.exs, resume_test.exs
└── web/{trigger,run_detail,config,mission_control}_live_test.exs, design_contract_test
```

**Structure Decision**: This is the existing single-project OTP layout with
one new pure module beside `Remediation`/`InteractiveClarify`. The profile
is threaded exactly like `layout` (facade → `FeatureRunner` →
`InitFeature` → agent state → actions → `PhaseRequest`). The pack stays one
committed pair of files.

## Delivery order

1. **Governance.** ✅ Constitution 6.0.0 written (Principle III profiles,
   R11). Commit it on its own. Nothing below merges before it.
2. **Foundation.**
   - Add the `Containment` pure module.
   - Add `Config.containment_profile/0`.
   - Add the `RunContext` key.
   - Add `PhaseRequest` `:containment`, with env markers under both profiles.
3. **US1 (P1, MVP): human sessions.**
   - Rewrite the hook: origin detection, the strict union and FR-016
     reasons.
   - Drop the `settings.json` deny list.
   - Pin the red-team helper env and add the parity and matrix tests.
   - Add the `TargetPack` install and contract probe.
   - This slice ships value alone: strict orchestrator decisions are
     unchanged, and the operator stops being blocked.
4. **US2 (P2): permissive runs.**
   - Thread the profile through `FeatureRunner` → agent → the 4 call sites.
   - Add the `run/1` preflight (invalid value, `pack_outdated`).
   - Add the resume, continue and publish-only lock.
   - Add the Trigger control.
5. **US3 (P3): visibility.** Must ship in the same release as US2.
   - Coordinator snapshot and report key.
   - `Report` line.
   - Topbar chip.
   - Run Detail block and settings-chip filter.
   - Config row.
   - PR note.
6. **Docs (FR-017).**
   - `enforcement.md`: both profiles, correct the stale
     `--dangerously-skip-permissions` claim, recommend the container for
     `permissive`.
   - `runbook.md`: operator flow, pack upgrade, and the `cli`-only
     entrypoint limitation.
   - `harness-contract.md`: the permission-mode path.
   - `CLAUDE.md`: the Enforcement paragraph.
7. **Live validation.** Run [quickstart.md](quickstart.md) §3–§6 against a
   scratch target.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Principle III: `permissive` removes the hook deny list and per-phase narrowing, with no floor | This is the spec's core ask (FR-005–FR-007), with the floor explicitly declined (Clarifications Q1, Q2) | A partial relaxation (keeping a host-destroying floor, or keeping analyze and clarify read-only) was offered and rejected by the operator in clarify. The risk is bounded by opt-in, strict default, the visible marker, fail-closed parsing, strict-on-undecided origin, and the recommended container. Ratified via 6.0.0 |
| Denials move from `settings.json` to the hook | Human sessions must not be denied (FR-011). Project settings apply to every session | A second settings file cannot re-allow what a deny rule blocks, and it does not travel into worktrees (R1). Two swapped packs would break FR-013 and dirty the worktree |
| `:bypass_permissions` for headless permissive sessions | Headless `acceptEdits` refuses out-of-cwd writes and tools that are not pre-approved (R2) | Adding tools alone leaves out-of-tree writes refused, which fails FR-005 |
