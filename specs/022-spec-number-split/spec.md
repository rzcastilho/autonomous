# Feature Specification: Spec Number Split

**Feature Branch**: `022-spec-number-split`

**Created**: 2026-09-03

**Status**: Draft

**Input**: User description: "Separate the wave-local feature number from the repo-monotonic spec number, and add two independent nets against silent false-green phases."

## Clarifications

### Session 2026-09-03

- Q: When the spec number is added, what stays the feature's canonical identity (record key and operator-facing label)? → A: The wave-local number. The spec number is an added attribute governing only the spec directory, the branch name, and artifact resolution.
- Q: A fresh allocation computes the next spec number, but that directory already exists on the base. What happens? → A: Fail loud, naming the directory — highest-plus-one cannot legitimately collide, so a collision means the base moved or the numbering is damaged. Reuse-on-resume is unaffected.
- Q: Which phases does the empty-checkpoint net apply to? → A: `specify`, `plan`, and `tasks` — every phase whose contract is to produce a named file. `clarify`, `analyze`, `implement`, and `converge` are excluded.
- Q: A resumed phase re-runs over an artifact that already exists and commits nothing — fail it? → A: No. The net fires only when the phase's artifact was absent when the phase started; where output already existed, an unchanged tree is permitted and the artifact gate remains the judge.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A later wave's feature builds without colliding with an earlier wave's spec (Priority: P1)

An operator runs a second (or third, or fourth) wave of a backlog against a target
repository that already carries the finished specs of every earlier wave. Wave
numbering restarts at `001` for every wave, so the new wave's early features carry
numbers that earlier features already used. The operator expects each feature to
get its own spec directory, its own branch, and its own set of artifacts — and
never to touch the files of the finished feature that happens to share its number.

**Why this priority**: This is the defect. Today the numbering collision is not a
cosmetic naming clash — it silently redirects artifact resolution to another
feature's finished files, which is what turned a stalled `tasks` phase into a
misleading failure three phases downstream. Every wave after the first is exposed,
and the exposure grows with the size of wave one. Without this, waves 2+ are not
safely runnable at all.

**Independent Test**: Run a feature whose wave number is `001` against a target
repository that already contains `specs/001-<other-slug>/` with a complete set of
artifacts. Confirm the feature is given a fresh, unused spec number, that its
directory and branch carry that number, and that every phase reads and writes only
inside its own directory.

**Acceptance Scenarios**:

1. **Given** a target repository whose `specs/` holds `001-…` through `014-…`, **When** a run starts a wave-2 feature numbered `001`, **Then** the feature is assigned spec number `015`, its spec directory is `specs/015-<slug>/`, and its branch carries the same `015-<slug>` name.
2. **Given** that same feature, **When** any phase resolves one of its artifacts, **Then** resolution stays inside `specs/015-<slug>/` and never returns a file from `specs/001-<other-slug>/`.
3. **Given** a feature that has already been assigned a spec number, **When** the run is resumed, retried, or restarted at any phase, **Then** the original spec number is reused and no second spec directory is created for that feature.
4. **Given** a run whose features stack (each branching from the previous feature's branch), **When** the second feature's spec number is allocated, **Then** it accounts for the spec directory the first feature created, and the two features never share a number.
5. **Given** a target repository with no conforming spec directories, **When** the first feature is allocated, **Then** it receives spec number `001`.
6. **Given** run records written before this change, **When** the system starts, **Then** those records remain readable and each existing feature reports the spec number it actually built under.
7. **Given** a base whose spec root already holds a directory at the number a fresh allocation computes, **When** the feature is allocated, **Then** the run refuses before the first phase runs and names the offending directory, rather than advancing to the next free number.

---

### User Story 2 - A phase that writes nothing fails at that phase (Priority: P2)

An operator watches a feature whose `specify`, `plan`, or `tasks` phase ends its
session while reporting success but leaves the working tree untouched. The operator
expects the run to stop right there, naming that phase, rather than advancing
through later phases that have nothing to work from and failing later for an
unrelated-sounding reason.

**Why this priority**: This is the independent net. It needs no knowledge of how
artifacts are resolved: a phase whose entire contract is "produce a file" cannot
have succeeded if the tree is unchanged. It would have caught the observed failure
at `tasks`, before roughly twenty minutes of `analyze`, auto-remediation, and a
zero-length `implement` ran on an empty task list. It also catches future variants
of the same class that artifact resolution alone would miss.

**Independent Test**: Drive a `tasks` phase that reports success without writing
anything, with artifact resolution left entirely alone. Confirm the feature fails
at `tasks` with a reason that names `tasks` and the unchanged tree, and that no
later phase runs.

**Acceptance Scenarios**:

1. **Given** a `tasks` phase that reports success and leaves the tree unchanged, **When** the phase boundary is reached, **Then** the feature fails at `tasks` and no later phase is started.
2. **Given** that failure, **When** the operator reads the reported reason, **Then** it names the phase and states that the phase committed no change, and is distinguishable from the reason used for a plainly absent artifact.
3. **Given** a `specify`, `plan`, or `tasks` phase whose artifact gate passed, **When** the tree is nonetheless unchanged at the boundary and the artifact was absent when the phase started, **Then** the phase still fails — the gate's verdict does not suppress this check.
4. **Given** a phase that is not contractually required to change the tree, **When** it legitimately commits nothing, **Then** it advances normally and is never failed by this check.
5. **Given** a feature resumed at a phase whose artifact already exists, **When** that phase re-runs and commits nothing, **Then** it advances normally — the check fires only where the artifact was absent when the phase started.

---

### User Story 3 - Artifact resolution never crosses into another feature (Priority: P3)

An operator inspects a run in a stacked worktree that necessarily carries every
earlier feature's spec directory. They expect a question about *this* feature's
artifact to be answered from *this* feature's directory, or answered "not found" —
never answered with another feature's file.

**Why this priority**: The second independent net, and the direct repair of the
mechanism that produced the observed failure. Story 1 removes the collision that
made this reachable; this story makes the resolution safe even when a collision
exists anyway — for example in a target repository already carrying the damaged
pair of directories from the run that exposed the bug.

**Independent Test**: With two directories sharing a numeric prefix and differing
slugs, ask for an artifact that exists only in the *other* one. Confirm the answer
is "unresolved", not the other feature's file.

**Acceptance Scenarios**:

1. **Given** two spec directories sharing a numeric prefix, **When** an artifact is requested for the feature whose own directory lacks it, **Then** resolution reports the artifact unresolved rather than returning the other directory's copy.
2. **Given** an unresolved artifact, **When** a gate that fails loud on absence evaluates it, **Then** the gate treats it as missing and fails.
3. **Given** an unresolved task list, **When** the implementation step loads its plan, **Then** it falls back to its unstructured plan and dispatches the work, rather than inheriting another feature's completed list and dispatching nothing.

---

### Edge Cases

- **Non-conforming entries under `specs/`.** A target repository may hold directories that do not match the `NNN-slug` shape (a real target carries `specs/autonomous/`). Allocation ignores them and must not fail on them.
- **Gaps in existing numbering.** Numbering may be non-contiguous. Allocation takes one past the highest number present; it never fills a gap, so a number is never reused after a directory is deleted.
- **A target already holding a collided pair.** The run that exposed this defect left two `specs/001-*` directories in a real target. Allocation still proceeds from the highest number present, and Story 3's resolution rule keeps the damaged pair from being read across.
- **The computed number is already taken.** A fresh allocation whose directory already exists refuses by name rather than advancing to the next free number: highest-plus-one cannot collide unless the base moved beneath the run or the numbering is already damaged, and quietly stepping over it would leave both conditions undiagnosed.
- **A feature that already has a spec number.** Resume, retry, restart, and human resolution all reuse it. Re-allocating would orphan the directory and branch the feature already owns, so an existing directory here is expected, not a collision.
- **Records written before this change.** Features recorded under the previous identity built in a directory named for their wave number; their spec number is that number, and it is backfilled as fact rather than invented.
- **The same number recurring across waves.** Legal and expected. It is only a conflict within a single wave.
- **A re-run that confirms existing output.** A resumed `specify`, `plan`, or `tasks` phase may find its artifact already present and correct and write nothing. That is a success, not an empty phase, and must not be failed — which is why the empty-checkpoint check is armed only when the artifact was absent at phase start.
- **A wave-1 run.** Wave numbers and spec numbers coincide by coincidence in wave 1; the change must leave that run's observable naming unchanged.

## Requirements *(mandatory)*

### Functional Requirements

**Identity — separating the two numbers**

- **FR-001**: A feature MUST carry a spec number that is distinct from its wave-local number, and both MUST be available wherever a feature is described. The wave-local number remains the feature's canonical identity — the key its durable record is stored and looked up under, and the label an operator uses to name it; the spec number is an added attribute whose authority extends only to the spec directory, the branch name, and artifact resolution.
- **FR-002**: The spec number MUST be allocated before the feature's first phase runs, as one greater than the highest number among the conforming `NNN-slug` spec directories present on the base the feature's worktree is created from. A base with no conforming directories MUST allocate `001`.
- **FR-003**: Allocation MUST ignore entries under the spec root that do not match the `NNN-slug` shape, and MUST NOT fail because of them.
- **FR-003a**: If a *fresh* allocation's computed directory already exists on the base, the system MUST refuse before the feature's first phase runs, naming the offending directory. Highest-plus-one cannot legitimately collide, so a collision means the base moved beneath the run or the existing numbering is damaged, and neither may be carried inward. This MUST NOT apply to a feature reusing a recorded spec number under FR-004, where an existing directory is the expected case.
- **FR-004**: The spec number MUST be recorded durably at allocation, and every later phase, retry, resume, restart, and human-resolution re-run of that feature MUST reuse the recorded number. The system MUST NOT allocate a second number for a feature that already has one.
- **FR-005**: The spec directory pinned for the feature and the feature's branch name MUST both be composed from the spec number and the same slug, and MUST remain identical to each other — preserving the existing guarantee that a phase cannot drift onto a differently-named directory.
- **FR-006**: The wave-local number MUST remain the sole input to release ordering and MUST continue to identify the feature's breakdown file; it MUST NOT appear in the spec directory name or the branch name.
- **FR-007**: Records written under the previous identity MUST be migrated explicitly under a new recorded schema version, backfilling each feature's spec number with the number it actually built under. Unknown or newer schema versions MUST still fail loud, and no recorded state may be dropped, truncated, or auto-deleted.
- **FR-008**: Every operator-facing surface that identifies a feature — console, run report, and the feature's pull request body — MUST present the wave number and the spec number under names that distinguish them, so a wave `001` that built as spec `015` is unambiguous to a reader.

**Net one — resolution must not cross features**

- **FR-009**: Resolution of a named artifact for a feature MUST return only a file inside that feature's own spec directory, and MUST NOT return a file belonging to a different feature under any fallback.
- **FR-010**: When a numeric-prefix fallback is consulted and matches more than one directory, the result MUST be unresolved. An ambiguous match MUST NOT be settled by ordering (lexicographic, creation time, or otherwise).
- **FR-011**: An unresolved artifact MUST read as missing to every gate that fails loud on absence, and MUST cause the implementation step to fall back to its unstructured plan rather than adopt any other feature's task list.

**Net two — a phase that claims an artifact must change the tree**

- **FR-012**: At the checkpoint boundary of a phase that is contractually required to produce an artifact, a checkpoint that commits nothing MUST fail that phase rather than advance the feature.
- **FR-013**: The recorded failure reason MUST name the phase and state that it committed no change, and MUST be distinguishable from the reason recorded for a plainly absent artifact.
- **FR-014**: FR-012 MUST hold independently of artifact resolution: a passing artifact gate MUST NOT suppress it.
- **FR-014a**: FR-012 MUST fire only when the phase's artifact was absent at the moment the phase started. A phase re-running over output that already existed — the ordinary resume, retry, and human-resolution case — MUST be allowed to commit nothing, and its output remains judged by the artifact gate, which tests substance rather than mere presence.
- **FR-015**: The check applies to exactly the three phases whose contract is to produce a named file — `specify`, `plan`, and `tasks`. `clarify`, `analyze`, `implement`, and `converge` MUST NOT be failed by FR-012: the first two may legitimately leave the tree unchanged, and `implement` is already judged by its own roll-up.

**Wave numbering**

- **FR-016**: The backlog loader MUST continue to refuse two features claiming numerically equal numbers within one breakdown package, naming every conflicting file, and MUST NOT treat the same number recurring in a different package as a conflict.

**Regression**

- **FR-017**: The observed production failure MUST be covered by a regression test: a feature whose wave number collides with an existing spec directory, whose artifact-producing phase reports success while writing nothing, fails at that phase, naming it — never reaching later phases and never resolving the colliding feature's files.

### Key Entities

- **Feature**: the unit of work. Carries a wave-local number (ordering, breakdown filename, wave labels) and, as of this feature, a separate spec number (spec directory, branch name, artifact resolution). The wave-local number is the canonical identity: durable records are keyed by it and operators name features by it. The spec number is an attribute of the feature, never its key.
- **Breakdown package (wave)**: the set of features an operator runs together. Numbering restarts at `001` in each package; uniqueness is required within a package and not across packages.
- **Spec directory**: the per-feature directory of specification artifacts inside the target repository, named for the spec number and slug. Repo-monotonic and never shared between features.
- **Feature branch**: the per-feature branch, named identically to the spec directory so a phase cannot drift between the two.
- **Recorded feature state**: the durable record of a feature within a run, including its spec number, governed by a recorded schema version.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A feature whose wave number matches an existing spec directory's number completes the whole pipeline with zero reads of any other feature's artifacts.
- **SC-002**: A wave whose numbers fully overlap an earlier wave's produces zero colliding spec directories and zero colliding branch names.
- **SC-003**: When a phase reports success while producing nothing, the reported failure names that phase in 100% of cases; zero later phases run after the fault.
- **SC-004**: A feature resumed or restarted at any phase reuses its original spec directory 100% of the time; zero orphaned second directories are created.
- **SC-005**: Every run recorded before the change remains readable afterwards, with zero recorded records dropped or truncated.
- **SC-006**: An operator reading any surface that names a feature can state both its wave number and its spec number without consulting the filesystem.
- **SC-007**: Each of the two nets, exercised alone with the other disabled, catches the observed failure at the phase that caused it.

## Assumptions

- A run loads exactly one breakdown package, so the loader's existing numeric-uniqueness refusal is already per-wave. This feature confirms and tests that property rather than changing it; no governance amendment is required for it.
- Features run one at a time and stack, each branching from the previous feature's branch, so spec-number allocation is serial within a run and an earlier feature's newly created spec directory is visible on the next feature's base.
- Features recorded before this change built in a directory named for their wave number, so backfilling their spec number with that value records what actually happened rather than inventing data.
- Spec numbers are allocated as one past the highest present, never by filling gaps, so a deleted directory's number is not reused.
- Both `:backlog` and `:ad_hoc` features are allocated spec numbers by the same rule; nothing in the rule depends on the group.
- Renaming, merging, or cleaning up spec directories that already exist in a target repository — including the collided pair left by the run that exposed this defect — is an operator action outside this feature's scope.
- Wave-1 runs, where the two numbers coincide, keep their current observable directory and branch naming.
- A feature that has not yet started has no spec number, so surfaces render it as explicitly not yet allocated rather than guessing, blanking, or borrowing the wave number. The exact presentation is a design decision for planning, bounded by that rule.
