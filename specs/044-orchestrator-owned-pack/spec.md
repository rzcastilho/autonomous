# Feature Specification: Orchestrator-Owned Target Pack

**Feature Branch**: `044-orchestrator-owned-pack`

**Created**: 2026-10-16

**Status**: Draft

**Input**: User description: "Run the orchestrator against a target repo without committing any orchestrator-owned files to it. Today `TargetPack.verify/2` refuses to start unless `.claude/autonomous-pack.json` and `.claude/settings.json` are in the target's committed tree (contract 6), and `TargetPack.install/2` writes them for the operator to commit. Sessions already get their essential configuration from the orchestrator at launch, so the committed files mostly exist so the preflight can detect an outdated pack. The orchestrator should own those files: write them into each feature worktree, keep them untracked, and stop requiring them in the committed tree."

## Context

Contract 6 (feature 039) made the target-repo pack tiny: a marker
(`.claude/autonomous-pack.json`, `{"contract": 6}`) and a `settings.json` holding
only shell-timeout `env`, `permissions.defaultMode` and an `allow` list — no hook,
no deny list. The operator runs `TargetPack.install/2` in the target, commits the
two files, and every run's preflight (`TargetPack.verify/2`, in `run/1`,
`run_spec/2`, `resume/2` and `continue_run/1`) reads the **committed** tree to
confirm the pack is current. Worktrees are built from that tree, so the files
travel into each feature's worktree.

The cost of this arrangement shows up as friction, not safety:

- the operator must commit two orchestrator-owned files into a project that is not
  the orchestrator, and open a pull request to land them (observed on
  `binance-auto-trader`, PR #2);
- the files carry no configuration the orchestrator does not already supply itself:
  every session is launched with `bypass_permissions`, the full tool set, the
  shell-timeout environment (delivered through the launch environment and
  `--settings`, precisely so a target's own settings cannot drop them) and the
  agent-root markers;
- their only run-time job is to let the preflight detect an outdated pack — a
  version check the orchestrator can do without involving the target's git history;
- a contract bump (5 → 6) forced every target to reinstall and commit again.

The target's **own** content is different and stays committed: the constitution,
`.claude/skills` and `.specify/` are the project's, worktrees are built from the
committed tree, and the preflight keeps checking them.

## Clarifications

### Session 2026-10-16

- Q: Should `TargetPack.install/2` stay an optional operator step, or run on its own? → A: The orchestrator runs install itself, always as needed — automatically, on every run/resume/continue, for each worktree, whenever the pack is missing or not current. It is idempotent, so a current pack makes it a no-op. The operator never has to call it.
- Q: When the target commits an outdated pack (old scope-guard hook or `permissions.deny`), what does the automatic install do? → A: Refuse before any session, naming the file and both remedies; the install never touches tracked files.
- Q: Where does the orchestrator-supplied settings content go, so the operator's tracked `settings.json` can stay exactly as it is? → A: Into `.claude/settings.local.json` in each worktree (untracked), which the Claude Code settings layering applies over the tracked `settings.json`. `TargetPack.install/2` writes the pack's settings there, not into `settings.json`; the tracked `settings.json` is never written, merged into or replaced. The operator's own tracked `env` entries still win over the pack's: the supplied local file does not restate any key the tracked `env` already sets.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a run on a repo that carries no orchestrator files (Priority: P1)

An operator points the orchestrator at a Spec Kit repo that has a committed
constitution, skills and `.specify/` scaffold but has never had the pack installed
and has no `.claude/autonomous-pack.json` or orchestrator `settings.json`. They
start a run and it works, without the operator committing, installing or opening a
pull request for anything.

**Why this priority**: This is the whole feature. Everything else is about making it
safe and compatible.

**Independent Test**: Take a target whose committed tree has the constitution,
`.claude/skills` and `.specify/` but neither pack file; start a run on one backlog
feature. The preflight passes, the feature's sessions run with the same permissions,
tools and timeouts as before, the feature completes, and its commits and pull
request contain no orchestrator-owned file.

**Acceptance Scenarios**:

1. **Given** a target with no pack files in its committed tree, **When** the
   operator starts a run, **Then** the preflight passes and no reinstall, commit or
   pull request is asked of the operator.
2. **Given** that run, **When** a feature's worktree is created, **Then** the
   worktree contains the pack marker and the pack settings as `.claude/settings.local.json`, and a session started in it
   behaves exactly as under contract 6 today (same permission mode, tool set,
   timeouts, agent-root markers).
3. **Given** the worktree's pack files, **When** the orchestrator commits the
   worktree after a phase, squashes at completion, pushes the branch and opens the
   pull request, **Then** none of those commits, the diff or the pull request body
   contains `.claude/autonomous-pack.json` or `.claude/settings.local.json`.
4. **Given** the same target, **When** the operator runs `git status` in the target
   repo itself, **Then** the pack files do not appear as untracked changes.

---

### User Story 2 - A target that still commits a pack keeps working (Priority: P1)

Existing targets already carry a committed pack: some at contract 6, some older
(with the removed scope-guard hook registration or a `permissions.deny`). Upgrading
the orchestrator must not break the current ones, must not silently run under the
old rules, and must not overwrite the operator's own settings.

**Why this priority**: Every target set up so far is in this state. Breaking them
on upgrade would be a regression for everyone who has used the tool.

**Independent Test**: Three targets — a committed current pack, a committed older
pack, and a current pack whose tracked `settings.json` also holds the operator's own
`env` entries. Start a run on each.

**Acceptance Scenarios**:

1. **Given** a committed pack that meets the current contract, **When** a run
   starts, **Then** it starts, the tracked files, including `settings.json`, are left
   byte-identical in the worktree, and the operator's own `env` entries in a tracked
   `settings.json` still win over the pack's (the same precedence as today), because
   the supplied `settings.local.json` does not restate a key the tracked `env` sets.
2. **Given** a committed pack older than the current contract (scope-guard hook or
   `permissions.deny`), **When** a run starts, **Then** it is refused before any
   session, naming the offending file and giving both ways out: update the tracked
   file to the current contract and commit, or remove the pack files from version
   control so the orchestrator supplies them. It never runs a session under the old
   hook or deny list.
3. **Given** any committed pack, **When** the worktree is created, **Then** the
   orchestrator does not modify a tracked file (a modification to a tracked file
   would be committed by the normal worktree commit and would leak into the pull
   request).
4. **Given** the operator removes the committed pack files in a later commit,
   **When** the next run starts, **Then** it behaves as in User Story 1 with no
   other change.

---

### User Story 3 - Resume and continue across the change (Priority: P2)

A run was started before this feature, with worktrees that were built from a
committed pack (or that have none). The operator resumes or continues it after
upgrading.

**Why this priority**: Runs are long and are parked or interrupted routinely (a
parked run was resumed several times in the session that motivated this feature);
an upgrade between a park and a continue must not strand it.

**Independent Test**: Park a run under the previous behaviour with a worktree that
holds the committed pack, upgrade, and call `continue_run/1`; repeat with a
worktree that has neither file.

**Acceptance Scenarios**:

1. **Given** a parked or interrupted run whose worktree holds the committed pack,
   **When** the operator continues or resumes it, **Then** the run restarts at its
   checkpointed phase and no pack file becomes a new change in the worktree.
2. **Given** an existing worktree that lacks the pack files, **When** the run is
   resumed, **Then** the pack files are supplied to the worktree before the first
   session and stay untracked.
3. **Given** a refused continue (for example an outdated committed pack), **Then**
   the run stays parked, byte-identical, with the same reason term, as for every
   other refused continue.

---

### User Story 4 - Operator can see and manage the pack state (Priority: P3)

An operator wants to know which pack a target is running under, and `install/2`
should no longer be a required step.

**Why this priority**: Visibility and docs. The feature works without it, but an
invisible mechanism is hard to trust and hard to debug.

**Independent Test**: Open Configuration for a target in each of the three states
(no committed pack, current committed pack, outdated committed pack) and read the
runbook.

**Acceptance Scenarios**:

1. **Given** a target in any of the three states, **When** the operator opens the
   console Configuration page, **Then** it shows the pack source (orchestrator-supplied
   or committed) and the contract in effect.
2. **Given** a run, resume or continue, **When** a worktree's pack is missing or not
   current, **Then** the orchestrator runs the install itself with no operator step;
   **And** when an operator calls `TargetPack.install/2` by hand it still works as
   before.
3. **Given** the runbook, `docs/enforcement.md` and `CLAUDE.md`, **When** read,
   **Then** they describe the orchestrator-supplied pack as the default and committed
   packs as supported-but-optional.

---

### Edge Cases

- Linked worktrees share one exclude list with the main checkout, so the exclusion
  must live where every worktree of the target reads it; a target that already has
  its own exclude entries keeps them.
- A target whose tracked `.gitignore` already ignores `.claude/settings.local.json`
  (Claude Code projects commonly do) — the pack files must still be supplied to the
  worktree and still never be committed; the shared exclude entry is harmless
  alongside it.
- A target that commits `.claude/settings.json` with its own non-orchestrator keys
  (not an orchestrator pack at all): the orchestrator must not overwrite it and must
  not treat it as an outdated pack merely because it lacks the pack's keys.
- A target that **tracks** `.claude/settings.local.json` (unusual): the orchestrator
  cannot supply its settings there without modifying a tracked file, so the run is
  refused before any session, naming the file and the remedy (stop tracking it).
- An operator's own untracked `settings.local.json` in the target checkout does not
  travel into worktrees (worktrees are built from the committed tree), so the
  orchestrator's supplied file cannot collide with it; the operator's personal local
  overrides apply only to their interactive sessions in the checkout.
- The operator excludes or tracks the files by hand in between runs: the next run
  re-checks and does not duplicate exclude entries.
- A non-git target, or a target on a detached HEAD: behaviour is the same as the
  worktree features today (the existing preflight and worktree guards apply).
- An interactive Claude Code session a human starts in the target repo is not an
  orchestrator session; it must not pick up orchestrator-owned settings: the
  supplied files exist only in feature worktrees, never in the target checkout.
- Two orchestrator instances against two targets must never write into each
  other's repositories.
- A worktree that is kept after a failure (`keep_for_inspection`) holds the pack
  files; they must not be mistaken for work product when the operator inspects or
  resolves it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The preflight MUST NOT require the orchestrator pack files
  (`.claude/autonomous-pack.json` and the pack settings) to exist in the target's
  committed tree. A tracked `.claude/settings.json`, if present, is examined only for
  the removed constructs of FR-007, never required.
- **FR-002**: The preflight MUST keep checking the target's own content exactly as
  today: the constitution is customized and committed, and `.claude/skills`
  and `.specify/` are present and committed.
- **FR-003**: On creating a feature worktree (and on every resume or continue into an
  existing one), the orchestrator MUST run the pack install itself, as needed, so the
  pack marker (`.claude/autonomous-pack.json`) and the pack settings
  (`.claude/settings.local.json`) are present in the worktree carrying the current
  contract and the same content contract 6 defines. The install MUST be idempotent: when the
  worktree's pack is already current it changes nothing, and it never requires an
  operator action.
- **FR-004**: The orchestrator MUST keep the files it supplies untracked in a way
  that holds for every worktree of the target and for the target checkout itself, so
  they never appear in `git status`, in any worktree commit or squash, in a pushed
  branch, in a pull request diff, or in the pull request body.
- **FR-005**: The orchestrator MUST NOT modify any tracked file of the target in
  order to supply the pack. In particular it MUST NOT write to, merge into or replace
  a tracked `.claude/settings.json`; the operator's tracked file stays exactly as it is
  and the pack's settings reach sessions through `.claude/settings.local.json`.
- **FR-006**: When the target already commits a pack that meets the current
  contract, the orchestrator MUST use it as is, leave the tracked files byte-identical
  in every worktree, and preserve the operator's own `env` entries with the same
  precedence as today: the supplied `settings.local.json` MUST omit any `env` key the
  tracked `settings.json` already sets, so the operator's value is the one in effect.
- **FR-007**: When the target commits a pack older than the current contract
  (removed hook registration or a deny list), a run MUST be refused before any
  session starts, naming the file and offering both remedies (update and commit it,
  or remove it from version control). The automatic install MUST NOT repair, override
  or hide a tracked file; refusing is the only response. No session may ever run under a hook or deny
  list the current contract has removed.
- **FR-008**: A committed `.claude/settings.json` that is not an orchestrator pack
  (no marker, none of the removed constructs) MUST NOT be overwritten and MUST NOT
  be refused for lacking the pack's keys. A tracked `.claude/settings.local.json`
  MUST be refused (edge case above) because the pack cannot be supplied without
  modifying it.
- **FR-009**: The session launch MUST continue to supply the permission mode, tool
  set, shell-timeout environment and agent-root markers itself, so that a session's
  effective configuration is identical whether the pack came from the repo or from
  the orchestrator.
- **FR-010**: Pack contract detection MUST work from the orchestrator's own stamp on
  the worktree (and the committed marker when one exists), so an outdated pack is
  still detected on every run, resume, continue and `run_spec/2`, with the same
  refusal behaviour as today.
- **FR-011**: `resume/2`, `resume_run/1` and `continue_run/1` MUST work for runs
  whose worktrees predate this feature, whether those worktrees hold a committed pack
  or none, without turning any pack file into a worktree change.
- **FR-012**: A refused start or continue MUST leave the persistent run record
  unchanged, with the same reason term as other refusals (feature 035).
- **FR-013**: `TargetPack.install/2` MUST be invoked by the orchestrator itself, as
  needed (FR-003), and MUST keep its present behaviour (never clobbering the
  constitution, honouring the operator's tracked `env`, removing a stale hook), except
  that its settings output now goes to `.claude/settings.local.json` and it never
  writes `.claude/settings.json`. It MUST also
  remain callable by an operator, who is then never required to; the documentation
  MUST describe it as automatic.
- **FR-014**: Commit messages and pull request descriptions the orchestrator writes
  MUST NOT mention or include the supplied pack files, and the pull request
  description MUST NOT list them in any changed-files summary.
- **FR-015**: The console Configuration page MUST show, per target, where the pack
  comes from (orchestrator-supplied or committed) and which contract is in effect.
- **FR-016**: The change MUST NOT alter what a human-started interactive session in
  the target repo sees: the supplied files MUST NOT take effect there.
- **FR-017**: The runbook, `docs/enforcement.md`, `docs/container.md` where it
  mentions the pack, and `CLAUDE.md` MUST be updated to describe the new default and
  the compatibility rules.
- **FR-018**: **Constitution.** This change MUST be accompanied by a constitution
  amendment, because it rewrites two normative statements: Principle III's "a run
  MUST NOT start against a **committed** target-repo pack that does not meet the
  current pack contract", and the Development Workflow statement that the committed
  `.specify/`/`.claude/` scaffold MUST travel into each worktree (the pack half of
  `.claude/` no longer travels by commit). The amendment is a MINOR bump (7.1.0 →
  7.2.0): the contract-6 guarantee itself is unchanged, and what changes is who
  supplies the pack and where the preflight looks. It is made through
  `/speckit-constitution`, with a Sync Impact Report, before or with the plan that
  implements this feature. This specify step does not edit the constitution.

### Key Entities

- **Orchestrator pack**: the marker (contract number) and the settings
  (`settings.local.json`) the orchestrator needs in a worktree. Owned by the orchestrator, versioned by the
  contract number, supplied per worktree.
- **Pack source**: where a given target's pack comes from — `supplied` (the
  orchestrator wrote it into the worktree) or `committed` (the target tracks it).
  Shown in Configuration.
- **Target content**: the constitution, skills and `.specify/` scaffold. Always
  committed in the target; checked by the preflight; never supplied by the
  orchestrator.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can start a run on a target that has never had the pack
  installed with zero manual steps beyond the target's own constitution and scaffold
  being committed — no reinstall, no commit, no pull request for orchestrator files.
- **SC-002**: Across a full multi-feature run, zero commits, zero pushed branches and
  zero pull requests in the target contain an orchestrator pack file, unless the
  operator themselves committed one.
- **SC-003**: A session started under a supplied pack and one started under a
  committed contract-6 pack have identical effective permission mode, tool set,
  timeouts and markers in 100% of the phase types (specify through converge,
  remediation and describe).
- **SC-004**: 100% of runs against a committed pack older than the current contract
  are refused before the first session, with a message naming the file and both
  remedies; none start a session.
- **SC-005**: 100% of parked or interrupted runs created before the upgrade can be
  resumed or continued afterwards without a new tracked-file change in their
  worktrees.
- **SC-006**: An operator can tell from the console, without reading files, which
  pack source and contract a target is using.
- **SC-007**: The default test suite and the existing pack-contract tests continue to
  pass, with new tests covering each of the three target states (no pack, current
  committed, outdated committed) and the untracked guarantee.

## Assumptions

- The two supplied files are the marker and `settings.local.json`; the operator's
  tracked `settings.json` is no longer part of the pack; the
  `.claude/skills` content under the pack is Spec Kit scaffolding that the target
  already owns and stays committed.
- A shared exclude list in the target's git directory is acceptable as the mechanism
  for keeping the supplied files untracked, because it applies to every worktree and
  does not alter any tracked file or require the operator to edit `.gitignore`; if
  planning finds a mechanism that is more robust, the requirement (FR-004) is about
  the outcome, not the mechanism.
- Claude Code layers `settings.local.json` over the project `settings.json`, and the
  session launch's own `--settings` still outranks both, so the orchestrator's launch
  values (timeouts, permissions) keep winning exactly as in contract 6. The contract
  number stays 6 unless planning finds the settings location change needs a bump.
- Worktrees are created and resumed only by the orchestrator, so it can always supply
  the files before the first session; a human who creates a worktree by hand is out
  of scope.
- The install target is each feature **worktree** (and the shared exclude list of the
  target's git directory), never the target's committed tree or working checkout, so
  the automatic install cannot dirty the operator's checkout.
- The settings the orchestrator needs are fully determined by the contract, so the
  supplied copy can be regenerated at any time and never needs to be preserved across
  worktree restores.
- Pre-existing runs, stores and records need no migration: the persistent run record
  does not store the pack.
- The container remains the supported runtime and outer boundary; this change does
  not touch containment, permissions or the tool set.
