# Research: Spec Number Split

Phase 0 output. Every NEEDS CLARIFICATION from Technical Context is resolved
here; each decision names the rejected alternative.

## R1 — Where the spec number is allocated from

**Decision**: allocate from `git ls-tree --name-only <base> specs/` run in the
**base repo**, before `Worktree.create/2`. The listing is parsed by the pure
`SpecNumber` module; the git call is the only IO and lives in `Worktree`
alongside the rest of the git plumbing.

**Rationale**: FR-002 defines the input as "the conforming `NNN-slug` spec
directories present on the base the feature's worktree is created from". The
base is a git ref (`main`, or the previous feature's `feature/NNN-slug` branch
in a stacked run) — it is *not* whatever the base repo happens to have checked
out, so reading the base repo's working tree would answer a different question.
`ls-tree` on the ref answers exactly the one asked, and works identically for
`HEAD`, a branch, and a sha.

**Alternatives considered**:

- *Create the worktree first, then scan its `specs/`.* The worktree's content
  **is** the base's content, so the answer would be right — but the worktree's
  branch name is composed from the spec number, so the number must exist before
  the worktree does. Circular; rejected.
- *Scan the base repo's working tree (`File.ls`).* Answers "what is checked out
  in the base repo right now", which in a stacked run is neither the base ref
  nor anything the feature will see. Rejected.
- *Track the high-water mark in the store instead of the filesystem.* Would
  drift from the target repository the moment anything is added to `specs/`
  outside a run (a human-authored spec, a merged PR from another source). The
  filesystem is the authority; rejected.

## R2 — `specs/` is not `Config.specs_root/0`

**Decision**: allocation and resolution scan the literal `specs/` directory,
matching `SpecDir`'s existing hardcoded root. `Config.specs_root/0` is
`"specs/autonomous"` — the *breakdown package* root (feature 012), a different
thing that happens to live underneath.

**Rationale**: `specs/autonomous/` is precisely the non-conforming entry FR-003
requires allocation to ignore, and the spec's Edge Cases name it. Reusing
`Config.specs_root/0` here would scan the wrong directory entirely.

## R3 — Path composition when no spec number has been allocated

**Decision**: two distinct accessors on `Feature`:

- `Feature.spec_id/1` → `String.t()`, for **path/branch composition**. Returns
  the zero-padded spec number when allocated, and falls back to `id` when not.
- `Feature.spec_label/1` → `String.t() | nil`, for **operator surfaces**.
  Returns `nil` when unallocated, so a surface renders "not yet allocated"
  rather than borrowing the wave number (spec Assumptions, FR-008).

**Rationale**: the two callers want opposite things from the same absence. Path
composition is only reached after allocation in production — the executor
allocates before `Worktree.create/2` and fails loud on refusal (FR-003a) — while
dry runs and the pure unit suite construct features with no number at all and
must keep composing the names they compose today. Wave-1 runs, where the two
numbers coincide, are byte-identical either way (spec Assumptions).

**Alternatives considered**:

- *Raise on `nil` in `spec_id/1`.* Fails loud at the wrong boundary: the real
  guard is "the executor must not create a worktree for an unallocated feature",
  and that check is cheaper, earlier, and names the feature. Raising instead
  breaks every dry-run and unit-test call site for no added safety. Recorded in
  the plan's Complexity Tracking with this mitigation.
- *One accessor returning `nil`, callers interpolate.* `"specs/#{nil}-slug"`
  silently yields `specs/-slug`. Rejected outright.

## R4 — Which resolution candidates can cross features

**Decision**: all three of `SpecDir`'s candidates are constrained to the
feature's own spec id.

1. `specs/<spec_id>-<slug>` — already exact; unchanged in shape, now composed
   from `spec_id`.
2. `.specify/feature.json`'s `feature_directory` — accepted **only when its
   basename's numeric prefix equals the feature's spec id**.
3. `specs/<spec_id>-*` — accepted **only when the glob matches exactly one
   directory**; two or more ⇒ unresolved (FR-010).

**Rationale**: candidate 2 is a live cross-feature leak that the existing
`recorded/1` guard does not close. `.specify/feature.json` is a *committed* file
— it travels into a stacked worktree carrying the **previous** feature's
`feature_directory`, and it is a plain relative path with no `..`, so every
existing check passes it. Constraining it by numeric prefix is what makes FR-009
true rather than nearly true. Candidate 3's ambiguity rule is FR-010 verbatim:
ordering (lexicographic or otherwise) is exactly how the original defect picked
the oldest feature's files.

**Alternatives considered**:

- *Delete candidates 2 and 3 entirely.* Candidate 2 is the only thing that
  covers a slug drift between the branch name and what the Spec Kit CLI actually
  wrote; candidate 3 is the only thing that covers a slug drift with no
  `feature.json`. Both are load-bearing; constraining them is enough.
- *Settle an ambiguous prefix match by mtime.* Explicitly forbidden by FR-010.

## R5 — Arming the empty-checkpoint net

**Decision**: `RunFeaturePhase.classify/4` emits a new signal
`artifact_absent_at_start?` for `:specify`, `:plan`, and `:tasks`, probed with
`SpecDir.file/3` **before** the harness request is issued. The pure
`Checkpoint.verdict/3` combines it with the phase and the `Worktree.commit/2`
result at the boundary.

**Rationale**: gate signals are extracted upstream and passed into a pure
decision surface (Constitution Principle I) — the same shape as every existing
gate. Probing before the request is the only moment "absent at start" is
observable.

Retry interaction is benign: `PhaseStep` re-runs the whole action, so attempt 2
re-probes at its own start. If attempt 1 wrote the artifact and failed, attempt 2
sees it present and disarms — and the tree still carries attempt 1's uncommitted
write, so the boundary commit returns `:ok`, not `:noop`. There is no path where
a phase that actually produced a file is failed by this net.

**Alternatives considered**:

- *Probe at the boundary instead of at phase start.* Cannot distinguish "the
  phase wrote it" from "it was already there" — which is the entire content of
  FR-014a.
- *Reuse `missing_artifact`.* That signal is the artifact gate's verdict on the
  phase's **output**; FR-014 requires the net to hold independently of it, and
  `:specify` has no artifact gate at all.

## R6 — `:specify` gains a net but not an artifact gate

**Decision**: `:specify` is armed for the empty-checkpoint net
(`spec.md`) and is **not** added to `@phase_artifacts`.

**Rationale**: FR-015 names exactly three phases for FR-012. Nothing in the spec
asks for a new artifact gate, and adding one would change the retry policy of a
phase this feature is not otherwise touching.

## R7 — Failure detection order at the phase boundary

**Decision**: on a `{:cont, next}` transition the boundary now runs
`Worktree.commit/2` **before** `record_attempt/9`, and records the checkpoint
that matches the post-commit verdict.

**Rationale**: today the attempt row (and its `:in_progress` checkpoint pointing
at `next`) is written before the commit. A phase failed by FR-012 must leave the
checkpoint of a *failed* phase, not one that claims the run advanced. Moving the
commit ahead of the record keeps the existing "record before recursing"
guarantee (a crash mid-next-phase still finds the completed phase's record) while
letting one code path produce both outcomes.

**Alternatives considered**:

- *Record twice — once optimistically, once corrected.* Two writes for one
  boundary, and a crash between them leaves the optimistic row. Rejected against
  the store's one-transaction-per-boundary rule (018, R7).

## R8 — Schema evolution

**Decision**: schema version **5**, a plain append of
`feature_run.spec_number`, backfilled from the row's own `number` field.

**Rationale**: FR-007 requires an explicit versioned migration that backfills
what each feature actually built under; a pre-022 feature built in a directory
named for its wave number, so `spec_number := number` records fact rather than
inventing data. This is a transform, not a refusal migration — no v4 record is
unreadable. Structurally identical to migrations 3 and 4.

The v4 attribute list is pinned as a module literal (as `@feature_run_v3_attributes`
already is) and the `:number` position is derived from it with
`Enum.find_index/2`, never hardcoded — a later append must not silently shift
which field this migration reads.

## R9 — Wave-1 and the target repo's damaged pair

**Decision**: no cleanup, no renaming, no gap-filling. Allocation is always
highest-present + 1; wave-1 numbers coincide with spec numbers by arithmetic,
not by a special case.

**Rationale**: spec Assumptions and Edge Cases both put operator cleanup out of
scope, and R4's resolution rule already makes the collided pair unreadable across
features. Gap-filling would reuse a deleted directory's number, which the spec
forbids.

## R10 — Surfacing both numbers (FR-008)

**Decision**: every surface that names a feature renders the wave number under
its existing label and adds the spec number as a second, distinctly-labelled
field: the run report line, `RunDetailLive`'s feature row/drawer, and the PR
body's mechanical header. Both render in the mono family as machine values;
`nil` renders as the literal `not allocated`.

**Rationale**: Constitution Principle VII — machine values are mono, labels use
the system's own vocabulary (`number` / `spec_number`, the record's real field
names), and no new color or token is introduced, so
`test/support/design_contract.ex` stays clean.
