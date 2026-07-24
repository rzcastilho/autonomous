# Implementation Plan: Recovery State Reconciliation

**Branch**: `014-recovery-reconciliation` | **Date**: 2026-07-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/014-recovery-reconciliation/spec.md`

## Summary

Recovery today blindly resets any `running` feature to re-run from scratch
(`RunManifest.reconstruct_status/1` maps `"running" → :pending`), because the
manifest is trusted as truth even when it is stale. This feature adds a
**repository-as-source-of-truth reconciliation layer**: on operator-initiated
recovery, before any work is released, each feature's manifest status is
reconciled against durable ground truth outside the manifest — the durable PR
record (`pr.json`), the feature's git branch and its per-phase boundary commits,
its checkpoint, and its phase transcripts. A feature the repository shows as
finished is corrected to `done` (unblocking dependents, no re-run); a genuinely
incomplete feature is resumed from the phase after its **latest committed git
boundary**; human gates stay held; self-contradictory evidence is surfaced as a
conflict held like a gate. Corrected statuses are rewritten to the manifest
immediately. No datastore is added; git + the existing JSON pointer files remain
the only persistence, and reconciliation is offline-first (a live remote PR query
is a fallback only).

Approach (per [research.md](./research.md)): a pure `Recovery.Reconcile` decision
table + an edge-level `Recovery.Evidence` collector + a thin `Recovery`
orchestrator that rewrites the manifest and feeds reconciled statuses into the
Coordinator through its existing `:statuses` seam.

## Technical Context

**Language/Version**: Elixir `~> 1.20` on OTP 28, pinned `1.20.2-otp-28` via
`.tool-versions`; all commands via `mise exec --`.

**Primary Dependencies**: OTP (Coordinator/Ledger GenServers, Task.Supervisor);
Jido `~> 2.2` + `jido_harness`/`jido_claude` (data plane, unchanged here); `git`
and the `gh` CLI (git-log boundary parse; `gh` remote PR query is fallback-only,
behind a seam). No new dependency is introduced.

**Storage**: Files only — the run manifest (`run.json`), per-feature
`checkpoint.json`, `pr.json`, and `NN-<phase>.md` transcripts under the 012
`Layout` roots, plus git branches/commits. **No datastore** (FR-016).

**Testing**: ExUnit via `mise exec -- mix test`; pure `Recovery.Reconcile` unit
tests (>90%, hermetic); integration/real-git recovery tests reusing the
`resume_run_test`/`resume_crash_test`/`resolve_test` conventions (tmp dirs,
FakeSDK, `async: false`).

**Target Platform**: Local operator machine / BEAM control plane driving the
`claude` CLI against a target git repo.

**Project Type**: Single Elixir project (control plane + data plane in one app).

**Performance Goals**: Not latency-bound. Reconciliation is O(features) local
file reads + one `git log` per feature branch; must complete a whole-run reconcile
in well under a phase's runtime. No performance NEEDS CLARIFICATION.

**Constraints**: **Offline-first** — must reconcile from local durable state with
the remote unreachable (FR-018/SC-009). **Read-only w.r.t. work** — spends no
budget, runs no phase; the only write is the status-only manifest rewrite
(FR-009/FR-010). **Corrupt-tolerant** — any single per-feature artifact absent or
corrupt falls back to remaining evidence (FR-011).

**Scale/Scope**: One repo slot, one run at a time (single-slot-per-repo manifest,
009); a wave is the LedgerLite/quickpoll 7-feature scale. Two run shapes:
breakdown wave and single ad-hoc spec (FR-012).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution v1.1.0 (principles I–VI + Technology Stack).

| Principle | Assessment |
|-----------|------------|
| **I. Pure Core, Isolated Contracts** | ✅ The reconcile decision table is a pure module (`Recovery.Reconcile`) taking evidence as arguments; all git/PR/file I/O is isolated in `Recovery.Evidence` behind seams. No CLI/harness/Jido dependency enters the decision surface. Gate/done signals extracted upstream and passed in. |
| **II. Fail Loud at Boundaries** | ✅ A missing/corrupt **manifest** and a true **conflict** surface loudly (never silently resolved into an unsafe continuation — FR-014/edge cases). Per-feature single-artifact corruption is *recoverable partial output*, so it falls back to other evidence rather than inventing a status — matches "salvage but never invent." |
| **III. Least-Privilege Containment** | ✅ Reconciliation adds no new tool grants and no out-of-tree writes. Its only write is the existing status-only manifest rewrite via `RunManifest.write/1`; it never touches repository artifacts. |
| **IV. Cost-Bounded Autonomy** | ✅ Reconciliation spends no budget and releases no work on its own; committed spend is preserved verbatim (`Ledger.restore`, FR-013) and the original budget bounds continuation. Drain-don't-kill semantics of the breaker are untouched. |
| **V. Human-in-the-Loop Escalation** | ✅ `escalated`/`halted` features stay held (FR-007); recovery never advances past a human gate. A conflict is held gate-like with dependents blocked while the rest of the DAG runs (FR-014). |
| **VI. Idiomatic Elixir/OTP & FP** | ✅ Pure transforms + multi-clause pattern matching for the resolution table; tagged-tuple returns from the collector; reuse of existing OTP seams (Coordinator `:statuses`, injected `:evidence`/`:remote`) rather than new processes. `@spec` on public core funcs; `mix format`; warnings-as-errors. |

**Technology Stack**: No new runtime dependency, no frontend build step, no
database. Console surfacing of reconciliation is explicitly out of scope
(spec Assumptions) — file-backed run state stays authoritative.

**Result: PASS** — no violations. Complexity Tracking below is empty.

**Post-Phase-1 re-check**: The Phase 1 design (data-model + contracts) introduces
no datastore, no new process, and no new external contract; the pure/edge split is
preserved. Constitution Check still **PASS**.

## Project Structure

### Documentation (this feature)

```text
specs/014-recovery-reconciliation/
├── plan.md              # This file (/speckit-plan output)
├── research.md          # Phase 0 output — 8 design decisions
├── data-model.md        # Phase 1 output — reconciliation entities
├── quickstart.md        # Phase 1 output — validation scenarios
├── contracts/           # Phase 1 output — reconcile table, evidence, report
│   ├── reconcile.md
│   ├── evidence.md
│   └── recovery-report.md
├── checklists/
│   └── requirements.md  # already present, all items checked
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── recovery/
│   ├── reconcile.ex        # NEW — pure: recorded × evidence × shape → reconciled status
│   └── evidence.ex         # NEW — edge: gather %Evidence{} per feature (pr.json, git, checkpoint, transcript); remote seam
├── recovery.ex             # NEW — thin orchestrator: collect → reconcile → rewrite manifest → report
├── run_manifest.ex         # CHANGED — keep reconstruct/1 as dumb parser; expose corrected-status write path
├── speckit_orchestrator.ex # CHANGED — resume_run/2 & resumable_run/0 call Recovery instead of raw reconstruct
├── report.ex               # CHANGED — render reconciled whole-run picture (per-feature corrected status + next runnable)
├── worktree.ex             # CHANGED (small) — git-log boundary-commit read helper for the last committed phase
├── checkpoint.ex           # reused as-is (read/2 three-way)
├── describe.ex             # reused as-is (read_pr/2)
├── coordinator.ex          # reused — :statuses seam receives reconciled statuses
└── feature.ex              # reused — :blocked status carries the conflict-held state

test/speckit_orchestrator/
├── recovery/
│   ├── reconcile_test.exs  # NEW — pure decision table, hermetic, >90%
│   └── evidence_test.exs   # NEW — collector over tmp fixtures + fake git log + remote-off
├── recovery_test.exs       # NEW — orchestrator: reconcile → manifest rewrite → reconciled report
└── recovery_quickpoll_test.exs # NEW — SC-001 regression: manifest 001:running + PR pushed → 001 done, 002 next
```

**Structure Decision**: Single Elixir project (Option 1), matching the existing
`lib/speckit_orchestrator/` layout. New code lands in a `recovery/` submodule
folder mirroring the pure-core/edge split used elsewhere (pure `Reconcile` beside
edge `Evidence`, thin top-level `Recovery` orchestrator), reusing the existing
`Checkpoint`/`Describe`/`Worktree`/`Coordinator`/`Feature`/`RunManifest` surfaces
rather than adding parallel machinery.

## Complexity Tracking

> No Constitution Check violations — no entries required.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| _(none)_  | —          | —                                    |
