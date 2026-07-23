# Phase 1 Data Model: Standardized Run Directory Layout

**Feature**: 012-run-directory-layout | **Date**: 2026-07-22

This feature adds no persisted database entities — it governs **where** existing
artifacts are placed. The "entities" below are value objects and the directory
grammar they resolve to.

## Value Objects

### RepoIdentity segment (`<repo-name>-<shorthash>`)

A stable string derived from a repository's `origin` remote.

| Field | Type | Rule |
|-------|------|------|
| `canonical` | `String.t()` | `host/owner/repo`; scheme, `git@` user, `.git`, trailing `/` stripped. SSH and HTTPS forms of one repo → same value (FR-001). |
| `name` | `String.t()` | The `repo` segment of `canonical` (human-readable prefix). |
| `shorthash` | `String.t()` | First 6 hex of `:crypto.hash(:sha256, canonical)`. |
| `segment` | `String.t()` | `"#{name}-#{shorthash}"`, e.g. `ledgerlite-a3f9c2`. |

Validation / failure:
- No `origin` remote → `{:error, :no_origin}` at the IO boundary (FR-002); run
  refused at preflight (SC-004).
- Two different repos → different `segment` (different `canonical` → different
  hash). Same repo re-cloned → same `segment` (Scenario 1.2).

### Run scope

Which run-partition a run writes under. Set once at `run/1`/`run_spec/1`.

| Variant | Shape | Transcript segment | Feature-file root |
|---------|-------|--------------------|-------------------|
| Breakdown | `{:breakdown, slug}` | `slug` | `<repo>/specs/autonomous/breakdown/<slug>` |
| Ad-hoc | `:ad_hoc` | `ad-hoc` | `<repo>/specs/autonomous/ad-hoc` |

Rules:
- `slug` is the package directory name under `specs/autonomous/breakdown/`
  (FR-007, folder name is source of truth).
- A breakdown package named literally `ad-hoc` is rejected (fail loud, FR-010) —
  it would collide with the ad-hoc transcript segment.

### Layout (single resolution surface, FR-011)

The four resolved roots for one run. Built once from `(repo, segment, scope)`.

| Field | Value |
|-------|-------|
| `worktree_root` | `<autonomous_root>/worktrees/<segment>` |
| `transcript_root` | `<autonomous_root>/transcripts/<segment>/<scope-segment>` |
| `breakdown_root` | `<repo>/specs/autonomous/breakdown/<slug>` *(breakdown scope only)* |
| `ad_hoc_root` | `<repo>/specs/autonomous/ad-hoc` *(ad-hoc scope only)* |

- `autonomous_root` = `Config.autonomous_root/0` (default `~/.autonomous`,
  overridable).
- All four resolve through this one value → mutual consistency (FR-011).
- Given `segment` and `scope` as arguments, every field is a pure path join
  (Constitution I). Identity IO happens once, upstream, to obtain `segment`.

#### Base-repo roots vs. worktree-relative suffix (containment, resolves I1)

`worktree_root` and `transcript_root` are **machine-global absolute** paths under
`autonomous_root` — outside both the base repo and any worktree — so writers use
them verbatim. The two **in-repo** roots are subtler: phases execute with
`cwd = <worktree>`, not the base repo, so an *absolute base-repo* path is the
wrong thing to hand a phase.

- `breakdown_root` / `ad_hoc_root` (base-repo absolute) are for **load and
  inspection only**: `Backlog.load!/1` over an already-committed breakdown
  package, and the DAG / Trigger / Transcripts LiveViews reading committed
  content for `Config.repo/0`.
- `Layout.in_repo_rel/1` returns the **repo-relative suffix** for the run's scope
  — `"specs/autonomous/breakdown/<slug>"` or `"specs/autonomous/ad-hoc"`. Phase
  execution and the ad-hoc seed write use this, joined onto the **worktree**:
  - `PhaseRequest.breakdown_ref/2` → `Path.join(in_repo_rel(layout), basename(feature.path))`
    (relative → the CLI resolves it under `cwd = <worktree>`).
  - the single-spec seed → `Path.join([worktree.path, in_repo_rel(layout), basename])`
    — **inside the worktree only** (Principle III containment, unchanged from 001).

Breakdown packages are pre-committed inputs, so they already exist at the
relative path inside every worktree. The ad-hoc seed is generated into the
worktree at the same relative path and becomes committed content on the feature
branch — satisfying FR-006 ("inside the target repository") without a base-repo
write.

## Directory Grammar (resolved paths)

```text
~/.autonomous/                                  # Config.autonomous_root (machine-global)
├── worktrees/
│   └── <repo-name>-<shorthash>/                # FR-003: worktree_root, per repo identity
│       └── <feature_id>-<slug>/                # one git worktree per feature
└── transcripts/
    ├── run.json                                # RunManifest — SINGLE GLOBAL SLOT (see below)
    └── <repo-name>-<shorthash>/                # FR-004: transcript_root, per repo identity
        ├── <breakdown-slug>/                   #   breakdown run scope
        │   └── <feature_id>/
        │       ├── NN-<phase>.md               #   durable per-phase transcripts
        │       ├── checkpoint.json             #   crash-recovery checkpoint (009)
        │       └── pr.json                     #   Describe PR payload
        └── ad-hoc/                             #   ad-hoc run scope
            └── <feature_id>/ ...

<repo_dir>/specs/autonomous/                    # Config.specs_root (in-repo, committed)
├── breakdown/
│   └── <breakdown-slug>/                       # FR-005: breakdown package feature files
│       ├── 001-....md
│       └── 002-....md
└── ad-hoc/                                     # FR-006: ad-hoc feature files
    └── NNN-....md
```

### RunManifest locality — single global slot (resolves I2)

`checkpoint.json` and `pr.json` are **per-feature** and move under the
scope-partitioned grammar above; a run holds a `%Layout{}`, so their write side
is fully resolved. `run.json` is different: it is **run-level, single-slot**
(009), and its read callers have no `%Layout{}` — `resume_run/0`,
`resumable_run/0`, and the LiveViews read it on a fresh boot with no active run
and therefore no known segment/scope.

Decision: keep `run.json` at a **fixed machine-global path**,
`<autonomous_root>/transcripts/run.json` — *not* partitioned by segment/scope —
so any reader locates it with zero identity IO. This preserves 009's
one-active-run model (a single named `Coordinator`; `guard_active_run/1`) and
fresh-boot readability. To let a resume then reach the scope-partitioned
per-feature checkpoints/transcripts, the manifest **self-describes**:

| Added field | Value | Used by |
|-------------|-------|---------|
| `segment` | the run's `<repo-name>-<shorthash>` | LiveView overlay match; resume Layout rebuild |
| `scope` | `{"breakdown": slug}` or `"ad-hoc"` | resume Layout rebuild to locate checkpoints |

- `resume_run/0` / `resume/2` read the global manifest (or checkpoint), take
  `segment` + `scope`, and rebuild a `%Layout{}` to locate each feature's
  scope-partitioned `checkpoint.json` — never a bare `Config.transcript_root()`.
- A LiveView overlays last-known statuses **only when** `manifest["segment"]`
  matches the segment it resolves for `Config.repo/0` (a stale manifest from a
  different repo must not paint the viewed repo's DAG).

`run.json` / `checkpoint.json` field content is otherwise unchanged (009) — only
the manifest's fixed location and its two new locator fields, plus the
checkpoint's scope-partitioned **location**, change.

## State transitions

None. This feature is stateless path resolution; the lifecycle state machine
(`Feature.status`, `Pipeline`) is unchanged.

## Impacted modules (placement only, no content change)

| Module | Change |
|--------|--------|
| `RepoIdentity` *(new)* | pure `canonicalize/1`, `segment/1`; IO `resolve/1` |
| `Layout` *(new)* | resolve four roots + `in_repo_rel/1` from `(repo, segment, scope)` |
| `Config` | add `autonomous_root/0`, `specs_root/0`; retire/repoint old root defaults |
| `Worktree` | `:worktree_root` from `Layout` |
| `Transcripts` | write under `Layout.transcript_root` (scope-keyed) |
| `Checkpoint` / `Describe` | per-feature paths from `Layout.transcript_root` (scope-keyed) |
| `RunManifest` | fixed global `run.json`; record `segment` + `scope` (resolves I2) |
| `Backlog` | load a per-package dir (`breakdown/<slug>`) not a flat dir |
| `PhaseRequest.breakdown_ref` | **worktree-relative** `in_repo_rel/1` + basename (resolves I1) |
| facade `run/1` / `run_spec/1` | resolve identity + build `Layout` at preflight; select package by slug; write ad-hoc seed **into the worktree** at `in_repo_rel` (resolves I1) |
| facade `resume*/0,2` | rebuild `Layout` from manifest `segment`+`scope` to locate checkpoints (resolves I2) |
| `transcripts_live` / `pipeline_dag_live` / `trigger_live` | resolve new layout for `Config.repo/0`; overlay manifest only on `segment` match (FR-012, resolves U2) |
