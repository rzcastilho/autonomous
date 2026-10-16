# Implementation Plan: Orchestrator-Owned Target Pack

**Branch**: `044-orchestrator-owned-pack` | **Date**: 2026-10-16 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/044-orchestrator-owned-pack/spec.md`

## Summary

Stop requiring the orchestrator pack in the target's committed tree. The orchestrator
supplies it into every feature worktree itself — the contract marker
(`.claude/autonomous-pack.json`) and the pack settings as `.claude/settings.local.json`
— and keeps both untracked through a marked block in the target's common-dir
`info/exclude`, which every linked worktree and the checkout share. A new
`TargetPack.supply/1`, called from `Worktree.create/2` and `Worktree.restore/1`, checks
the worktree's tracked tree (refusing a tracked outdated pack or a tracked
`settings.local.json`, never modifying a tracked file), writes the exclude block, then
runs the reworked `install/2`, which now writes `settings.local.json` (the pack settings
minus any `env` key the tracked `settings.json` sets) and never `settings.json`.
`verify/2` stops requiring the files; a committed pack is still checked against contract
6 and refused with both remedies. Contract stays 6. Configuration gains a "target pack"
row (`supplied` / `committed` / refused). Constitution 7.1.0 → 7.2.0.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (mise-pinned), Erlang/OTP 28.5.0.6

**Primary Dependencies**: existing only — Jason, Phoenix LiveView (console), `git` CLI
via `System.cmd`; Claude Code CLI settings layering (research R1). No new dependency.

**Storage**: N/A — no Mnesia change, no schema bump; files in worktrees and the
target's `info/exclude`

**Testing**: ExUnit (`mise exec -- mix test`), temp git repos with linked worktrees;
design guard unchanged

**Target Platform**: Linux container (supported runtime) and macOS host (dev)

**Project Type**: OTP application + LiveView console (single project)

**Performance Goals**: supply adds ≤ 5 `git` invocations per worktree create/restore;
Configuration row computed off the LiveView process

**Constraints**: never modify a tracked target file (FR-005); never write into the
target checkout (FR-016); idempotent; refusals before any session and before any run
flip (FR-012)

**Scale/Scope**: ~3 lib modules changed (`TargetPack`, `Worktree`, `Report`), 1 new
pure view (`Web.PackView`), `ConfigLive` row, 2 test files extended, 4 docs + CLAUDE.md,
constitution amendment

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Pure Core | `local_settings/2`, `PackView` pure; git/file I/O stays in `TargetPack`/`Worktree` boundary modules, not in `Pipeline`/`Release`/`Feature` | PASS |
| II. Fail Loud | Preflight still fails loud on template/uncommitted constitution; outdated committed pack, tracked `settings.local.json` and invalid tracked `settings.json` refused by name; supply failure tears down the worktree and fails the feature with a named reason | PASS |
| III. Container-Bounded | Session config unchanged (`bypass_permissions`, full tool set, launch env, `--settings`); no session can meet a removed hook/deny (preflight on target `HEAD` + supply on the worktree's own tracked tree); supplied files never in the checkout, so human sessions unaffected | PASS — wording amended (below) |
| IV. Cost / Drain | No cost or drain path touched | PASS |
| V. Human-in-the-Loop | No gate touched | PASS |
| VI. Idiomatic OTP | `with` chains, tagged tuples, `@spec` on public fns; console git reads in a `Task`, not a callback | PASS |
| VII. Operator Surfaces | New row uses real identifiers (`.claude/settings.local.json`, contract number), mono values, `data-pack-source` name only, no new tokens, no `inspect/1` | PASS |
| Technology Stack | No dependency, no database, no frontend build step | PASS |
| Development Workflow | `.specify/` + target `.claude/skills` still travel by commit; the pack half of `.claude/` is supplied — requires the wording amendment | PASS — amendment |

**Amendment required (FR-018)**: 7.1.0 → 7.2.0 MINOR via `/speckit-constitution`, as
the first implementation task, rewording Principle III bullets 3–4 and the Development
Workflow worktree bullet (research R11). The current text is not violated by the design
(a committed outdated pack is still refused; scaffold still travels), but it describes a
committed pack as the only source, which the amendment corrects in the same change.

**Post-design re-check (after Phase 1)**: unchanged — PASS. No Complexity Tracking entry.

## Project Structure

### Documentation (this feature)

```text
specs/044-orchestrator-owned-pack/
├── plan.md              # This file
├── research.md          # Phase 0 — R1–R11
├── data-model.md        # Phase 1 — files, exclude block, pack source, reasons
├── quickstart.md        # Phase 1 — validation scenarios
├── contracts/
│   ├── target-pack.md       # supply/install/verify/source/Worktree contract + G1–G10
│   └── operator-surfaces.md # Configuration row, Report clauses, docs
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/autonomous/
├── target_pack.ex          # supply/1, source/1 (new); install/2, verify/2, check_pack_contract/2,
│                           #   local_settings/2 (replaces merge_settings/2), @outdated_hint changed
├── worktree.ex             # @scaffold_files drops settings.json; create/2 + restore/1 call supply
├── report.ex               # format_reason clauses: :pack_local_tracked, :invalid_settings, :pack_supply
└── web/
    ├── pack_view.ex        # new — pure view state for the "target pack" row
    └── live/config_live.ex # row + Task-loaded assign

priv/target_pack/.claude/   # bytes unchanged (settings.json is the local-file template)

test/autonomous/
├── target_pack_test.exs    # three target states, local_settings, idempotence, refusals, hints
├── worktree_test.exs       # supply on create/restore, untracked through commit/squash, exclude dedupe
├── report_test.exs         # new clauses
└── web/
    ├── pack_view_test.exs  # new
    └── config_live_test.exs # row per state

docs/enforcement.md, docs/runbook.md, docs/container.md, CLAUDE.md
.specify/memory/constitution.md   # 7.2.0 via /speckit-constitution
```

**Structure Decision**: single OTP project; the change lives at the existing target-repo
boundary (`TargetPack`) and git boundary (`Worktree`), with one pure console view.
`autonomous.ex` preflight call sites (`:2366`, `:2654`) and `resume_worktree/2` need no
edit — they reach supply through `Worktree`.

## Complexity Tracking

None — no constitution violation to justify.
