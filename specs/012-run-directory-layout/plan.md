# Implementation Plan: Standardized Run Directory Layout

**Branch**: `012-run-directory-layout` | **Date**: 2026-07-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/012-run-directory-layout/spec.md`

## Summary

Standardize the four run roots so working data never collides across target
repositories, breakdown packages, or ad-hoc runs, and history stays scannable.
Machine-global worktrees and transcripts move under `~/.autonomous/`, keyed by a
repository-identity segment `<repo-name>-<shorthash>` derived from the `origin`
remote; in-repo feature files move under `specs/autonomous/breakdown/<slug>` and
`specs/autonomous/ad-hoc`. Approach: a pure `RepoIdentity` (canonicalize + hash)
with a thin git-origin IO boundary, and a single `Layout` value resolving all
four roots once per run and threaded into the writers — no writer performs
identity IO. No `origin` is a hard preflight error; migration is new-runs-only.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (pinned via `.tool-versions`; run
through `mise exec --`). `warnings_as_errors` ON.

**Primary Dependencies**: Jido/OTP (control plane), `jido_harness`/`jido_claude`
(data plane, GitHub-pinned), Phoenix LiveView + Bandit (operator console).
`:crypto` (stdlib) for the identity hash.

**Storage**: Filesystem only. Machine-global working data under `~/.autonomous/`
(worktrees, durable transcripts, `run.json`, `checkpoint.json`, `pr.json`);
in-repo committed content under `<repo>/specs/autonomous/`.

**Testing**: ExUnit (`mise exec -- mix test`); pure units hermetic, git/fs side
effects behind `--include integration`; core coverage > 90%.

**Target Platform**: BEAM on the operator's local machine (darwin/linux); user
home directory is the machine-global base.

**Project Type**: Single Elixir project (pure core + harness boundary + Phoenix
console). No new project.

**Performance Goals**: N/A — path resolution. Identity origin read happens once
per run (not per phase/feature).

**Constraints**: Pure core must not do IO (Constitution I); fail loud at
boundaries (II); no silent fallback on missing origin / unwritable home /
reserved slug (FR-002, FR-010).

**Scale/Scope**: A handful of target repos and breakdown packages per operator;
6-hex shorthash disambiguation is ample.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| I. Pure Core, Isolated Contracts | **PASS.** `RepoIdentity.canonicalize/1` + `segment/1` and all `Layout` path resolution are pure (`:crypto.hash` is deterministic). The one git dependency is isolated in `RepoIdentity.resolve/1`; the resolved `%Layout{}` (a signal) is extracted upstream and passed into the writers, which stay side-effect-free given inputs. |
| II. Fail Loud at Boundaries | **PASS.** No `origin` → refused at preflight (FR-002); reserved `ad-hoc` package name → loud error (FR-010); unwritable machine-global root → loud, never a repo-internal fallback (FR-010). |
| III. Least-Privilege Containment | **PASS.** No containment change. In-repo writes (breakdown/ad-hoc seeds) stay inside the worktree/repo tree the scope-guard already governs; machine-global roots are operator working data outside the target tree. |
| IV. Cost-Bounded Autonomy | **PASS.** `Ledger` untouched. |
| V. Human-in-the-Loop Escalation | **PASS.** Gates untouched. Note: an old-layout checkpoint is unreadable post-upgrade (FR-014) — operators drain first; not a gate change. |
| Quality & Test Discipline | **PASS.** mise-only; warnings=errors; new pure modules > 90%; git/fs behind `--include integration`; hermetic default suite. |

**Result**: No violations. Complexity Tracking below is empty.

*Post-Phase-1 re-check*: design introduces two new modules (`RepoIdentity`,
`Layout`) and threads a `%Layout{}` through existing signatures — no new
principle tension. Still PASS.

*Post-analyze re-check (resolves I1/I2)*: two design points were sharpened after
`/speckit-analyze` — neither adds principle tension, both remove a latent one:

- **I1 — in-repo roots vs. worktree cwd.** Phases run with `cwd = <worktree>`, so
  `breakdown_root`/`ad_hoc_root` (base-repo absolute) are load/inspection-only;
  phase execution and the single-spec seed use `Layout.in_repo_rel/1` joined onto
  the **worktree** (`data-model.md` → "Base-repo roots vs. worktree-relative
  suffix", `contracts/layout.md` → `in_repo_rel/1`). This keeps the seed write
  inside the worktree — **strengthens** Principle III containment (the 001
  invariant), rather than weakening it.
- **I2 — RunManifest locality.** `run.json` stays a single machine-global slot at
  `<autonomous_root>/transcripts/run.json` (not scope-partitioned), so its
  scope-less read callers (`resume_run/0`, `resumable_run/0`, LiveViews) locate it
  with zero identity IO; the manifest records `segment` + `scope` so a resume
  rebuilds a `%Layout{}` to reach the scope-partitioned checkpoints. Preserves
  009's one-active-run model and keeps reads **fail-loud, never silent-wrong**
  (Principle II) — see `data-model.md` → "RunManifest locality".

## Project Structure

### Documentation (this feature)

```text
specs/012-run-directory-layout/
├── plan.md              # This file
├── spec.md              # Feature spec (input)
├── research.md          # Phase 0 — decisions
├── data-model.md        # Phase 1 — value objects + directory grammar
├── quickstart.md        # Phase 1 — validation scenarios
├── contracts/
│   ├── repo-identity.md # RepoIdentity canonicalize/segment/resolve
│   └── layout.md        # Layout build/ensure + threading
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/speckit_orchestrator/
├── repo_identity.ex          # NEW — pure canonicalize/1, segment/1; IO resolve/1
├── layout.ex                 # NEW — %Layout{}, build/3, ensure/1, in_repo_rel/1 (FR-011)
├── config.ex                 # + autonomous_root/0, specs_root/0; retire old root defaults
├── worktree.ex               # :worktree_root ← Layout
├── transcripts.ex            # write under Layout.transcript_root (scope-keyed)
├── checkpoint.ex             # per-feature paths ← Layout.transcript_root (scope-keyed)
├── run_manifest.ex           # FIXED global run.json; record segment + scope (I2)
├── describe.ex               # per-feature paths ← Layout.transcript_root
├── backlog.ex                # load a per-package breakdown/<slug> dir
├── phase_request.ex          # breakdown_ref ← worktree-relative in_repo_rel/1 (I1)
├── feature_runner.ex         # thread :layout alongside worktree/ledger/notify/run_context
├── coordinator.ex            # hold + pass the run's %Layout{}
└── web/live/
    ├── transcripts_live.ex   # browse <segment>/<scope>/<feature_id> (FR-012)
    ├── pipeline_dag_live.ex  # per-package breakdown/<slug>; overlay on segment-match (FR-012)
    └── trigger_live.ex       # select breakdown package by slug (FR-012)

lib/speckit_orchestrator.ex   # run/1 & run_spec/1: resolve identity + Layout at
                              # preflight; select package by slug; ad-hoc seed → ad_hoc_root

test/speckit_orchestrator/
├── repo_identity_test.exs    # NEW — pure canonicalize/segment; resolve (integration)
├── layout_test.exs           # NEW — build/ensure, reserved-slug, home-unavailable
└── …                         # update path assertions in existing writer tests
```

**Structure Decision**: Single-project layout unchanged. Two new pure-core
modules (`RepoIdentity`, `Layout`) sit alongside the existing pure core
(`Feature`/`Config`/`Pipeline`/…); the git-origin read is the only new IO and is
confined to `RepoIdentity.resolve/1`, matching the existing `TargetPack` origin
read. Everything else is a placement change threaded through the already-present
run seam (`FeatureRunner` opts).

## Complexity Tracking

> No Constitution Check violations — nothing to justify.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
