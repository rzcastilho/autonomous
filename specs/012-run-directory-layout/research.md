# Phase 0 Research: Standardized Run Directory Layout

**Feature**: 012-run-directory-layout | **Date**: 2026-07-22

All Technical Context unknowns are resolved below. No `NEEDS CLARIFICATION`
remained after the spec's clarification session (repo-identity form and
breakdown-slug source were both settled there).

## Current layout (what changes)

| Root | Today (`Config`) | New (this feature) |
|------|------------------|--------------------|
| Worktree | `../.speckit-worktrees` (sibling of repo) | `~/.autonomous/worktrees/<segment>` |
| Transcript | `<repo>/.speckit-transcripts/<feature_id>` (in-repo) | `~/.autonomous/transcripts/<segment>/<scope>/<feature_id>` |
| Breakdown files | `<repo>/docs/breakdown` (flat) | `<repo>/specs/autonomous/breakdown/<slug>` |
| Ad-hoc files | *(written into breakdown_dir)* | `<repo>/specs/autonomous/ad-hoc` |

`<segment>` = repository identity `<repo-name>-<shorthash>`; `<scope>` = the
breakdown slug for a breakdown run, or the literal `ad-hoc` for an ad-hoc run.

## Decision 1 — Repository identity derivation (`<repo-name>-<shorthash>`)

**Decision**: A pure `RepoIdentity` module. `canonicalize/1` reduces an origin
URL to `host/owner/repo` (strip scheme, `git@` SSH user, `.git` suffix, trailing
slash; normalize `git@host:owner/repo` and `https://host/owner/repo` to the same
string). `segment/1` returns `"#{repo}-#{shorthash}"` where `shorthash` is the
first 6 hex chars of `:crypto.hash(:sha256, canonical)`. Reading the origin URL
is an IO boundary function `resolve/1` (`git -C <repo> remote get-url origin`).

**Rationale**:
- Canonicalizing before hashing makes equivalent SSH/HTTPS URLs for the same
  repo yield one segment (FR-001, Acceptance Scenario 1.2 — re-clone stability).
- Identity follows the *remote*, not the local path, so a re-clone to a new
  directory resolves to the same segment.
- The human-readable `repo` prefix keeps folders scannable (SC-005); the short
  hash disambiguates same-named repos from different owners/hosts.
- `:crypto.hash/2` is deterministic and pure — it is **not** one of the banned
  nondeterministic calls, so canonicalize+segment stay unit-testable with no IO
  and no mock (Constitution I). Only `resolve/1` touches git.
- Mirrors the existing origin-read pattern already in `TargetPack.check_remote/3`
  (`git remote get-url`), so the boundary style is consistent.

**Shorthash length**: 6 hex (24 bits, ~16M space). Collision risk across the
handful of repos one operator drives is negligible; keeps the folder name short.
Overridable is unnecessary — the hash is an internal disambiguator, not tuned.

**Alternatives rejected**:
- *Hash the raw URL* — SSH and HTTPS forms of one repo would diverge, breaking
  re-clone stability (Scenario 1.2).
- *Full hash / no name prefix* — unscannable; fails SC-005.
- *Local path hash* — breaks identity-follows-remote; two clones of one repo
  would collide-avoid instead of unify.

## Decision 2 — No `origin` is a hard error (FR-002)

**Decision**: `RepoIdentity.resolve/1` returns `{:error, :no_origin}` when
`git remote get-url origin` is non-zero; the facade refuses to start the run at
preflight with a message naming the missing `origin` remote. Non-`origin`
remotes never participate.

**Rationale**: Aligns with Constitution II (fail loud at boundaries) and the
spec's stated assumption — no silent fall-back to a local-path identity. Failing
at preflight means zero work begins (SC-004).

**Alternatives rejected**: fall back to local-path or first-available remote —
both reintroduce the collision the feature exists to prevent, and silently.

## Decision 3 — Single resolution surface: a `Layout` value (FR-011)

**Decision**: A `Layout` struct holding the four resolved roots, built **once**
per run at the IO boundary from `(repo, segment, scope)` and threaded through the
run (Coordinator → FeatureRunner → Transcripts / Checkpoint / RunManifest /
Describe). Given `segment` and `scope` as arguments, the four path computations
are pure.

**Rationale**:
- FR-011 requires the four roots resolve through one surface so they stay
  mutually consistent and an operator reasons about placement in one place.
- Resolving once avoids re-reading git origin per phase/feature.
- Passing the resolved `Layout` (not `Config` calls) into the deep writers keeps
  the transcript/checkpoint/manifest writers free of the identity IO —
  side-effect-free given their inputs (Constitution I: signals extracted upstream
  and passed in).

**Threading impact** (signatures that gain the layout / a resolved dir):
`Transcripts.write`, `Checkpoint.{write,read,delete}`, `Describe`,
`RunManifest`, `Worktree.{locate,create}` (`:worktree_root`),
`PhaseRequest.breakdown_ref`. `FeatureRunner` already carries `worktree`,
`ledger`, `notify`, `run_context` — `layout` joins that set.

**Alternatives rejected**:
- *Keep zero-arg `Config.transcript_root/0` etc. and read git inside each* —
  scatters identity IO across writers, re-reads origin repeatedly, and buries a
  decision surface in IO (violates Constitution I).
- *Put the four roots on the `Feature` struct* — a feature is a work-unit, not a
  placement policy; would duplicate the scope on every feature and leak run-level
  config into the pure work-unit.

## Decision 4 — Run scope: breakdown slug vs ad-hoc

**Decision**: A run carries a `scope`: `{:breakdown, slug}` or `:ad_hoc`. For a
breakdown run the slug is the package directory name under
`<repo>/specs/autonomous/breakdown/` (FR-007 — folder name is the source of
truth; `run/1` selects a package by slug). For an ad-hoc run the scope is
`:ad_hoc`; feature files go to `<repo>/specs/autonomous/ad-hoc` (FR-006) and
transcripts under the `ad-hoc` segment (FR-004).

**Rationale**: Scope is a run-level property (a whole run is one package or
ad-hoc), so it is resolved at `run/1`/`run_spec/1` and baked into the `Layout`.
Backlog loading changes from a flat dir to a per-package dir named by slug.

**Reserved-name guard (edge case → FR-010)**: the transcript scope segment for
ad-hoc runs is the literal `ad-hoc`. A breakdown package whose directory is
literally named `ad-hoc` would map its transcripts onto the ad-hoc segment. The
system MUST reject a breakdown package named `ad-hoc` (fail loud) rather than let
breakdown and ad-hoc transcripts merge. (Within one repo the filesystem already
guarantees breakdown dir names are unique, so the only real slug↔segment
collision is this reserved name.)

**Alternatives rejected**: derive scope per feature — a feature has no say in
which package launched it; overloads the work-unit.

## Decision 5 — Migration policy: new runs only (FR-013/014)

**Decision**: Nothing under the old paths (`../.speckit-worktrees`,
`<repo>/.speckit-transcripts`, `docs/breakdown`) is moved, copied, or deleted.
The new layout applies only to runs started after the change. An in-flight run
whose resume checkpoint lives in the old transcript location cannot be resumed
post-upgrade — operators drain in-flight runs before upgrading.

**Rationale**: Migration is out of scope and risky; leaving old data in place is
the safe default. Documented in the runbook as an upgrade note.

**Alternatives rejected**: auto-migrate old trees — unbounded IO over
operator working data with no rollback; explicitly declined by the spec.

## Decision 6 — `~/.autonomous` base + fail-loud on unwritable home (FR-010)

**Decision**: `Config.autonomous_root/0` defaults to `Path.expand("~/.autonomous")`.
`Config.specs_root/0` defaults to `specs/autonomous` (in-repo). Both overridable
(tests point them at tmp). When the user home cannot be resolved or the resolved
root cannot be created/written, preflight fails loud rather than falling back to
a repo-internal path.

**Rationale**: FR-003/004 fix the machine-global base at `~/.autonomous`;
FR-009/010 require create-if-missing but fail-loud (never silent fallback). The
in-repo `specs/autonomous/` is committed/inspectable project content; the
machine-global roots are uncommitted operator working data (spec Assumptions).

## Observability continuity (FR-012)

The three LiveViews that reference run artifacts must resolve the new layout for
the configured repo:
- `transcripts_live` — browses `<transcript_root>/<segment>/<scope>/<feature_id>`
  instead of `<transcript_root>/<feature_id>`.
- `pipeline_dag_live` / `trigger_live` — list/read breakdown packages under
  `specs/autonomous/breakdown/<slug>` instead of the flat `docs/breakdown`.

These resolve identity for `Config.repo/0` at mount (they operate on the single
configured target). No behavior change beyond path resolution.

## Testing approach (Constitution: Quality & Test Discipline)

- `RepoIdentity` canonicalize/segment and `Layout` path resolution: pure unit
  tests, >90% coverage, no IO.
- `RepoIdentity.resolve/1` (git origin read) and any filesystem create/write:
  behind `--include integration`, so the default suite stays hermetic.
- Fail-loud paths (no origin, reserved `ad-hoc` package name, unwritable home)
  get explicit assertion tests.
