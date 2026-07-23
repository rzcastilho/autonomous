# Feature Specification: Standardized Run Directory Layout

**Feature Branch**: `012-run-directory-layout`

**Created**: 2026-07-22

**Status**: Draft

**Input**: User description: "Let's standardize some directories to avoid collision, organize, and keep history: (1) worktree_root: ~/.autonomous/worktrees/<repo-remote-hash>; (2) transcript_root: ~/.autonomous/transcripts/<repo-remote-hash>/<breakdown-slug> or ~/.autonomous/transcripts/<repo-remote-hash>/ad-hoc; (3) breakdown_root: <repo_dir>/specs/autonomous/breakdown/<breakdown-slug>; (4) ad_hoc_root: <repo_dir>/specs/autonomous/ad-hoc. Breakdown packages identified by breakdown slug, ad-hoc runs generate files in ad_hoc_root separated from breakdown, and repo directories must have a remote configured for identification."

## Clarifications

### Session 2026-07-22

- Q: Where does a run's `<breakdown-slug>` come from? → A: It is the name of the
  breakdown package directory under `<repo>/specs/autonomous/breakdown/`; the
  on-disk folder name is the single source of truth for the slug (no separate
  operator input, no derived/manifest name).
- Q: What form is the `<repo-remote-hash>` directory segment? → A: A human-readable
  repository name plus a truncated hash of the canonical `origin` URL, joined as
  `<repo-name>-<shorthash>` (e.g. `ledgerlite-a3f9c2`); the name makes the folder
  scannable, the short hash keeps same-named repos from different owners/hosts
  distinct.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Isolate working data per target repository (Priority: P1)

An operator drives the orchestrator against several distinct target repositories
over time (and, on the same machine, concurrently). Today all runs share one
sibling worktree directory and one in-repo transcript directory, so working data
from different repositories can land under the same path and be mistaken for one
another. The operator wants each target repository's worktrees and transcripts to
live under a location uniquely keyed to that repository's identity, so two
repositories never share a directory and their histories never mix.

**Why this priority**: Cross-repository collision is the root failure the whole
feature exists to prevent. Isolating by repository identity is the foundation the
other stories build on; without it, organizing by breakdown or separating ad-hoc
runs would still let two repositories overwrite each other.

**Independent Test**: Configure two target repositories with different remotes,
run one feature in each, and confirm their worktrees and transcripts resolve to
two different roots with no shared subpath. Delivers value on its own: safe
multi-repository operation from a single machine.

**Acceptance Scenarios**:

1. **Given** two target repositories with different configured remotes, **When**
   the orchestrator resolves worktree and transcript locations for each, **Then**
   each repository's roots sit under a distinct repository-identity segment and
   share no common run subpath.
2. **Given** a target repository whose remote is later re-cloned to a new local
   path, **When** the orchestrator runs against the new clone, **Then** it
   resolves to the same repository-identity segment as the original clone (the
   identity follows the remote, not the local path).
3. **Given** a target repository with no `origin` remote, **When** the
   orchestrator preflights a run, **Then** it refuses to start and reports that an
   `origin` remote is required for repository identification.

---

### User Story 2 - Organize runs by breakdown package (Priority: P2)

An operator runs multiple breakdown packages (each a numbered set of feature
files produced from a macro-spec) against the same repository. Today breakdown
feature files live in one flat directory and transcripts are keyed only by
feature id, so `001/` from one breakdown package overwrites `001/` from another.
The operator wants each breakdown package identified by its own slug, with its
feature files and its transcripts grouped under that slug, so two packages with
overlapping feature numbers stay separate and each package's history is
self-contained.

**Why this priority**: Breakdown-level organization is the primary way operators
reason about a body of work. It depends on repository isolation (P1) but adds the
grouping that makes multi-breakdown history legible and non-overwriting.

**Independent Test**: Place two breakdown packages with overlapping feature ids
under distinct slugs, run one feature from each, and confirm their feature files
and transcripts resolve under separate slug segments with no collision.

**Acceptance Scenarios**:

1. **Given** a breakdown package with slug `alpha` and another with slug `beta`,
   both containing a feature `001`, **When** the orchestrator resolves their
   breakdown and transcript locations, **Then** each resolves under its own slug
   segment and neither overwrites the other.
2. **Given** a breakdown package identified by a slug, **When** the orchestrator
   writes durable transcripts for its features, **Then** those transcripts are
   grouped under that breakdown's slug within the repository's transcript root.

---

### User Story 3 - Keep ad-hoc runs separate from breakdown packages (Priority: P3)

An operator occasionally runs a single ad-hoc feature that is not part of any
breakdown package. Today the ad-hoc seed is written into the same directory as
breakdown feature files, mixing throwaway one-offs with curated backlog packages.
The operator wants ad-hoc runs to write their feature files to a dedicated ad-hoc
location and their transcripts under a dedicated ad-hoc segment, so ad-hoc work
never pollutes a breakdown package and stays easy to find and prune.

**Why this priority**: Ad-hoc separation is a quality-of-life cleanup that keeps
the curated breakdown space uncluttered. It is valuable but the least critical of
the three — the system is usable without it, just messier.

**Independent Test**: Run one ad-hoc feature and one breakdown feature in the same
repository, and confirm the ad-hoc feature file and transcripts resolve under the
dedicated ad-hoc location while the breakdown feature resolves under its slug.

**Acceptance Scenarios**:

1. **Given** an ad-hoc single-feature run, **When** the orchestrator writes its
   feature file, **Then** the file lands under the repository's dedicated ad-hoc
   location, not under any breakdown package.
2. **Given** an ad-hoc single-feature run, **When** the orchestrator writes its
   transcripts, **Then** they land under a dedicated ad-hoc transcript segment
   for the repository, distinct from every breakdown slug segment.

---

### Edge Cases

- **Repository has multiple remotes**: identity is derived from the `origin`
  remote only; other remotes are ignored. A repository with remotes but no
  `origin` is treated as having no usable remote for identification (hard error,
  per FR-002).
- **Existing runs in the old layout**: worktrees under `../.speckit-worktrees`,
  transcripts under `<repo>/.speckit-transcripts`, and breakdown files under
  `docs/breakdown` predate this feature. The new layout applies to new runs only;
  pre-existing data is not migrated and is left in place. An in-flight run whose
  resume checkpoint lives in the old transcript location cannot be resumed after
  upgrading to the new layout — operators drain in-flight runs before upgrading.
- **Breakdown slug collision within one repository**: two breakdown packages given
  the same slug would map to the same segment; the system MUST fail loud rather
  than silently merge them.
- **Ad-hoc feature id collision**: two ad-hoc runs may pick the same auto-assigned
  id; the shared ad-hoc location MUST avoid silently overwriting a prior ad-hoc
  feature file.
- **User home directory unavailable or unwritable**: the machine-global root
  under the user home is unavailable; the system MUST fail loud at preflight
  rather than silently fall back to a repository-internal path.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST derive a stable repository-identity segment
  (`<repo-remote-hash>`) from the target repository's `origin` remote URL,
  canonicalized to `host/owner/repo` form (scheme, `git@` user, `.git` suffix, and
  any trailing slash stripped) before hashing, such that equivalent SSH and HTTPS
  URLs for the same repository yield the same segment and two different
  repositories yield different segments. The segment MUST take the human-readable
  form `<repo-name>-<shorthash>` — the repository name (the `repo` part of the
  canonical path) followed by a truncated hash of the canonical URL — so the
  folder is scannable while the short hash keeps same-named repositories from
  different owners or hosts distinct.
- **FR-002**: The system MUST refuse to start a run against a target repository
  that has no `origin` remote, reporting that an `origin` remote is required for
  repository identification.
- **FR-003**: The system MUST place per-feature git worktrees under a
  machine-global worktree root keyed by repository identity:
  `~/.autonomous/worktrees/<repo-remote-hash>`.
- **FR-004**: The system MUST place durable transcripts under a machine-global
  transcript root keyed by repository identity and then by run scope:
  `~/.autonomous/transcripts/<repo-remote-hash>/<breakdown-slug>` for breakdown
  runs and `~/.autonomous/transcripts/<repo-remote-hash>/ad-hoc` for ad-hoc runs.
- **FR-005**: The system MUST place breakdown feature files inside the target
  repository, grouped by breakdown slug:
  `<repo_dir>/specs/autonomous/breakdown/<breakdown-slug>`.
- **FR-006**: The system MUST place ad-hoc feature files inside the target
  repository under a dedicated ad-hoc location separate from breakdown packages:
  `<repo_dir>/specs/autonomous/ad-hoc`.
- **FR-007**: The system MUST identify each breakdown package by a breakdown slug
  taken directly from the package directory name under
  `<repo>/specs/autonomous/breakdown/` (the folder name is the source of truth),
  and use that same slug for both its in-repository feature files (FR-005) and its
  machine-global transcripts (FR-004).
- **FR-008**: The system MUST keep ad-hoc runs' files and transcripts separate
  from every breakdown package's files and transcripts, so neither can overwrite
  the other.
- **FR-009**: The system MUST create any missing directory in a resolved path
  before writing to it, and MUST NOT overwrite an unrelated run's directory when
  doing so.
- **FR-010**: The system MUST fail loud (refuse to proceed with a clear error)
  when a resolved root cannot be created or written — including an unavailable
  user home and a within-repository breakdown-slug collision — rather than
  silently falling back to a different location.
- **FR-011**: The system MUST resolve all four roots (worktree, transcript,
  breakdown, ad-hoc) through a single configuration surface so operators can
  reason about placement in one place and the four roots stay mutually
  consistent.
- **FR-012**: The system's operator-facing views and reports that reference run
  artifacts (transcripts, worktrees) MUST locate them using the standardized
  layout so existing observability keeps working after the change.

- **FR-013**: The system MUST apply the standardized layout to new runs only. It
  MUST NOT migrate, move, or delete data written under the pre-existing layout
  (old worktree, transcript, or breakdown locations); such data is left in place.
- **FR-014**: The system MAY leave an in-flight run's pre-existing resume
  checkpoint unreadable after the layout change; operators are expected to drain
  in-flight runs before upgrading. Post-upgrade runs resume only from checkpoints
  written under the new transcript layout.

### Key Entities

- **Repository identity (`<repo-remote-hash>`)**: a stable segment derived from a
  target repository's `origin` remote, in the form `<repo-name>-<shorthash>`; the
  top-level partition that keeps every repository's working data isolated from
  every other repository's while staying human-scannable.
- **Breakdown package (`<breakdown-slug>`)**: a named, numbered set of feature
  files produced from a macro-spec; the unit of organization grouping feature
  files (in-repository) and transcripts (machine-global) under one slug. The slug
  is the package directory name under `<repo>/specs/autonomous/breakdown/`.
- **Ad-hoc run**: a single-feature run not belonging to any breakdown package;
  routed to dedicated ad-hoc file and transcript locations.
- **Worktree root**: the machine-global base under which per-feature git
  worktrees are created, partitioned by repository identity.
- **Transcript root**: the machine-global base under which durable transcripts are
  written, partitioned by repository identity and then by run scope
  (breakdown slug or ad-hoc).
- **Breakdown root / Ad-hoc root**: the in-repository bases for breakdown package
  feature files and ad-hoc feature files, respectively.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Running the same feature against two different target repositories
  produces worktrees and transcripts that share no common run directory — 0
  cross-repository path collisions across any number of repositories.
- **SC-002**: Two breakdown packages with overlapping feature ids run against one
  repository produce 0 overwritten feature files and 0 overwritten transcripts.
- **SC-003**: 100% of ad-hoc feature files and transcripts resolve outside every
  breakdown package location; no ad-hoc artifact is ever written into a breakdown
  package directory.
- **SC-004**: Attempting a run against a repository with no configured remote is
  refused before any work begins, 100% of the time, with a message that names the
  missing remote as the cause.
- **SC-005**: An operator can locate any run's transcripts by scanning the
  human-readable `<repo-name>-<shorthash>` segment and its breakdown slug (or
  "ad-hoc"), without searching across unrelated repositories or packages.

## Assumptions

- The machine-global base `~/.autonomous/` (expanding `~` to the operator's home
  directory) is the intended parent for both worktrees and transcripts, moving
  them out of the sibling-of-repo and inside-repo locations used today.
- "Remote configured" means the target repository has an `origin` remote; a
  repository with no `origin` is a hard error (aligns with the project's
  fail-loud-at-boundaries principle), not a fall-back-to-local case. Non-`origin`
  remotes do not participate in identity.
- Breakdown slugs and ad-hoc feature slugs continue to be derived/assigned by the
  existing mechanisms; this feature governs where their outputs are placed, not
  how the names themselves are generated.
- In-repository placement under `specs/autonomous/…` is committed/inspectable
  project content, while the machine-global worktree and transcript roots are
  operator working data that need not be committed.
- The four roots are configuration-overridable (for tests and non-standard
  setups) but default to the standardized paths described here.
- This feature standardizes directory placement only; it does not change what
  worktrees, transcripts, breakdown files, or ad-hoc files contain.
