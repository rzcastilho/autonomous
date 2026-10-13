# Feature Specification: User-Defined Persistent Volumes

**Feature Branch**: `041-user-defined-volumes`

**Created**: 2026-10-13

**Status**: Draft

**Input**: User description: "Let the operator declare any number of named, persistent, per-instance volumes for a target container, so data a target's sessions need to keep (toolchains, dependency caches, build output, database data dirs) survives restarts without hand-editing compose.yaml. Desired behaviour: (1) a list of entries — name, container mount path, optional environment variables exported to every session — read at start, unbounded; (2) per instance, persistent across stop/start, writable by the container user, never touching host paths or other instances; (3) validation at start: safe unique names, absolute non-colliding mount paths, reserved variables refused, a violation aborts naming the entry, no partial setup; (4) `scripts/autonomous reset-cache --target <repo> [--volume <name>]...` removes declared volumes, refuses while running, only this project's, unknown name refused listing declared ones, idempotent; (5) no declaration = today's behaviour exactly; (6) Configuration page lists active declared volumes (name, mount path, env, present/absent); (7) hand-run smoke checks for persistence, isolation, rejected declaration and reset. Out of scope: host bind mounts, shared volumes, size quotas, automatic detection."

## Context

The container persists only the orchestrator's own state. Everything a
target's sessions install or build inside the container — language
toolchains, dependency caches, virtual environments, build output — is either
lost on every restart (it lives in the container layer or the unpersisted
home) or written through the bind-mounted worktree, where it mixes with the
operator's host builds and is slow through the host's file sharing.

Observed on mod-player (Rust), run r000003: an 81 GB build-output directory
shared between macOS and container builds, host disk 97% full, and the
toolchain reinstalled after every restart. The only workaround today is to
hand-edit the orchestrator's container definition, which no reset command and
no console surface knows about.

What a target needs to keep differs per ecosystem (Rust build output, Node
package caches, Python environments, Gradle/Maven caches, Go module cache, a
local database's data directory), so a fixed set of built-in volumes cannot
cover it. The operator declares what to keep.

## Clarifications

### Session 2026-10-13

- Q: Where does the volume declaration live? → A: An operator-owned file per target; agent sessions never see or edit it, and it does not travel with the target repo (location refined by the next answer).
- Q: The state root is bind-mounted read-write into the container, so how is the declaration kept out of sessions' reach? → A: It lives outside the state root, in a host-only per-target config location that is never mounted into any container; the wrapper reads it on the host at start and turns it into mounts and variables.
- Q: How does the operator find and create a target's declaration file? → A: `scripts/autonomous volumes --target <repo>` prints the file's path and its entries; `--init` writes a commented starter file only if none exists (never overwrites); the operator edits it by hand.
- Q: Every applied volume is mounted in the running instance, so present/absent cannot vary — what does Configuration show per volume? → A: Name, mount path, variables, and space used (measured when the page loads), labelled as applied at start.
- Q: Can an entry add directories to `PATH`? → A: `PATH`, `HOME`, `SHELL` and `USER` are reserved; an entry may list path directories, each absolute and inside its own mount path, prepended to the image's `PATH` in declaration order.
- Q: Where does the volume quickstart live? → A: Not in the spec; the plan's `quickstart.md` and the operator docs walk through three real targets end to end — mod-player, fretboard-master and autonomous (FR-028).
- Q: Can an entry override variables the image already sets (e.g. `MISE_DATA_DIR`, `MIX_HOME`, `HEX_HOME`, `PLAYWRIGHT_BROWSERS_PATH`)? → A: Allowed (unless reserved); start output prints one notice line per overridden image variable naming the image value and the declared value; docs explain the image's copy is hidden.
- Q: How do FR-027's examples (Rust, Node, Python) align with the quickstart's projects? → A: The three real projects are the full worked examples — Rust (mod-player), Node + pnpm (fretboard-master), Elixir (autonomous) — plus a short Python snippet (virtual environment / pip cache).
- Q: Is the worktree affected — does it become, or move into, a declared volume? → A: No. Worktrees stay host directories under the bind-mounted state root, unchanged: their contents persist between phases, chunks and restarts and remain inspectable on the host. Declared volumes hold only data outside the worktree (FR-025a).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Keep a target's build data across restarts (Priority: P1) 🎯 MVP

The operator of a Rust target declares two volumes: one for toolchains
(mounted at a container path, with the toolchain-home variables pointing into
it) and one for build output (with the build-output variable pointing into
it). They start the instance. Sessions install the toolchain and build into
those locations. The operator stops and restarts the instance; the next
session finds the toolchain installed and the previous build output reused.
Nothing appears in the worktree's build-output directory, and the operator's
host builds are untouched.

**Why this priority**: This is the incident: lost toolchains on every restart
and container build output filling the host disk through the bind mount.
Persisting declared data is the core value; everything else supports it.

**Independent Test**: Declare one volume with one variable, start the
instance, write a file through the variable's path from a session shell,
restart, and find the file still there; the worktree shows no new files.

**Acceptance Scenarios**:

1. **Given** a declaration with a volume `cargo-target` mounted at
   `/var/lib/autonomous/volumes/cargo-target` and the variable
   `CARGO_TARGET_DIR` set to that path, **When** the instance starts, **Then**
   the path exists, is writable by the container user, and every session sees
   `CARGO_TARGET_DIR` with that value.
2. **Given** data written into a declared volume, **When** the instance is
   stopped and started again, **Then** the data is still there.
3. **Given** a session builds with the build-output variable pointing into a
   declared volume, **When** the build finishes, **Then** no build-output
   directory was created or changed in the worktree or the target repo on the
   host.
4. **Given** no declaration for a target, **When** the operator runs
   `scripts/autonomous volumes --target <repo> --init`, **Then** a commented
   starter file is created at the printed path, and running it again refuses
   and leaves the file unchanged.
5. **Given** any number of declared entries (for example 1, 5 or 20), **When**
   the instance starts, **Then** every entry is mounted and its variables are
   exported; no count limit applies.

---

### User Story 2 - A bad declaration never half-starts an instance (Priority: P1)

The operator mistypes a declaration: a duplicate name, a relative mount path,
a mount path inside the target repo, or a variable that the orchestrator owns.
The start is refused with a message naming the offending entry and the reason.
No container is started, no volume is created, and nothing runs.

**Why this priority**: A mount path that shadows the target repo, the worktree
root or the orchestrator's own directories could hide the code sessions work
on or the orchestrator itself; a variable that overrides an orchestrator
setting could change how sessions run. These must fail loud at the boundary
(Principle II) before anything starts.

**Independent Test**: For each invalid case, start the instance and observe a
refusal naming the entry, a non-zero exit, and no new container or volume.

**Acceptance Scenarios**:

1. **Given** two entries with the same name, **When** the instance starts,
   **Then** it is refused naming the duplicate name.
2. **Given** an entry whose name is not a safe slug (for example contains a
   space, a slash or uppercase letters), **When** the instance starts, **Then**
   it is refused naming the entry and the allowed form.
3. **Given** an entry whose mount path is relative, equal to, inside, or a
   parent of the target repo, the worktree root, the orchestrator state root,
   the orchestrator's own source/build directories or the container home's
   agent configuration, **When** the instance starts, **Then** it is refused
   naming the entry and the path it collides with.
4. **Given** two entries whose mount paths are equal or nested inside each
   other, **When** the instance starts, **Then** it is refused naming both.
5. **Given** an entry that sets a reserved variable (any `AUTONOMOUS_*`
   variable, `PATH`, `HOME`, `SHELL`, `USER`, or a variable the container
   start sequence owns), **When** the
   instance starts, **Then** it is refused naming the entry and the variable.
6. **Given** two entries that set the same variable, **When** the instance
   starts, **Then** it is refused naming both entries and the variable.
7. **Given** an entry whose path directory is relative or outside that
   entry's own mount path, **When** the instance starts, **Then** it is
   refused naming the entry and the directory.
8. **Given** any refusal above, **When** the operator inspects the host,
   **Then** no container for the target is running and no declared volume was
   created by this attempt.

---

### User Story 3 - Reset what an instance has kept (Priority: P2)

A toolchain in a kept volume is corrupt, or build output has grown too large.
With the instance stopped, the operator runs `scripts/autonomous reset-cache
--target <repo> --volume cargo-target` and that one volume is removed; the
next start recreates it empty. With no `--volume`, every declared volume of
that instance is removed. While the instance is running the command refuses
and removes nothing.

**Why this priority**: Kept data must be recoverable without the operator
learning the container engine's volume naming, and without touching anything
else. Valuable once persistence exists, but not needed for the first restart.

**Independent Test**: Write data into two declared volumes, stop the instance,
reset one by name, start again, and find only that volume empty.

**Acceptance Scenarios**:

1. **Given** a stopped instance with declared volumes `a` and `b` holding data,
   **When** the operator resets `--volume a`, **Then** `a` is removed, `b` is
   unchanged, and the command reports `a` removed.
2. **Given** a stopped instance, **When** the operator resets with no
   `--volume`, **Then** every declared volume of that instance is removed and
   each is reported.
3. **Given** a running instance, or one whose container exited but was not
   removed, **When** the operator resets, **Then** the
   command refuses naming the running instance and how to stop it, exits
   non-zero, and removes nothing.
4. **Given** a name that is not declared, **When** the operator resets it,
   **Then** the command refuses listing the declared names and removes nothing.
5. **Given** a declared volume that does not exist yet (never started, or
   already reset), **When** the operator resets it, **Then** the command
   reports it as not present and exits successfully.
6. **Given** two targets, **When** the operator resets one, **Then** the other
   target's volumes, the orchestrator's own volumes and every host path are
   untouched.

---

### User Story 4 - See what an instance keeps (Priority: P3)

On the console Configuration page the operator sees the instance's declared
volumes as applied at start: each name, mount path, the variables it exports,
and the space it uses. With no declaration the page shows no such group.

**Why this priority**: Operator surfaces must tell the truth about the running
system (Principle VII), and a declaration that silently did nothing should be
visible. Useful but not required to keep data.

**Independent Test**: Start an instance with two declared volumes and open
Configuration; both are listed with their path, variables and space used.
Start
one without a declaration; no volume group renders.

**Acceptance Scenarios**:

1. **Given** an instance started with declared volumes, **When** the operator
   opens Configuration, **Then** each declared volume is listed with its name,
   mount path, exported variables, path directories and space used, using the
   same identifiers the operator wrote in the declaration, and the group states
   that it shows what was applied at start.
2. **Given** data is written into a declared volume, **When** the operator
   reloads Configuration, **Then** that volume's space used reflects the new
   size.
3. **Given** an instance started without a declaration, **When** the operator
   opens Configuration, **Then** no declared-volumes group is rendered and the
   page is otherwise unchanged.

---

### Edge Cases

- **Declaration changed while the instance runs**: the change takes effect on
  the next start only; the running instance and Configuration keep showing
  what was applied at start.
- **Entry removed from the declaration**: the volume it named is no longer
  mounted on the next start, but its data is not deleted automatically;
  `reset-cache` only acts on currently declared names, so the operator is told
  how to remove a no-longer-declared volume (documented).
- **Entry renamed**: treated as one entry removed and one added; the old data
  stays under the old name until removed.
- **Mount path changed for the same name**: the same data appears at the new
  path on the next start.
- **Declaration missing, empty, or unreadable**: missing or empty means no
  declared volumes (today's behaviour); present but unreadable or malformed
  refuses the start naming the file and the problem.
- **Variable value that is not inside any declared volume**: allowed (a
  variable may point elsewhere, e.g. a cache path relative to a declared
  volume's parent); only reserved variable names are refused.
- **Entry overrides an image-set variable** (e.g. `MISE_DATA_DIR`): allowed;
  the image's own data at the old location is hidden from sessions, so the
  first start may reinstall toolchains into the volume; a notice line in the
  start output names the override (FR-008b).
- **Volume storage fills up**: the session's own tool fails with its own
  error; the orchestrator does not add quotas (out of scope).
- **Path containing characters the container engine cannot mount** (for
  example `:` or a newline): refused at start naming the entry.
- **Release and dev instances of the same target**: both see the same declared
  volumes for that instance.

## Requirements *(mandatory)*

### Functional Requirements

**Declaration**

- **FR-001**: The operator MUST be able to declare, per target, a list of
  volume entries. Each entry has a name, a container mount path, and zero or
  more variables (name and value) to export to every session.
- **FR-002**: The declaration MUST be read once at instance start; changes
  take effect on the next start.
- **FR-003**: The number of entries MUST NOT be limited by the system.
- **FR-004**: With no declaration (absent or empty), instance behaviour MUST
  be identical to before this feature: no extra volumes, no extra variables,
  no new output.
- **FR-005**: The declaration MUST be an operator-owned file, one per target,
  kept in a host-only configuration location outside the target repo, every
  worktree, the orchestrator state root and the orchestrator source tree, and
  never mounted into any container. It MUST be read on the host by
  `scripts/autonomous` at start; agent sessions MUST NOT be able to read or
  write it. Its path MUST be printed by `scripts/autonomous volumes --target
  <repo>` (FR-005b) whether or not it exists, by the start output when a
  declaration with at least one entry is applied (FR-024), and documented. With
  no declaration the start output stays unchanged (FR-004).
- **FR-005b**: `scripts/autonomous volumes --target <repo>` MUST print the
  target's declaration path and, when the file exists, its entries (name,
  mount path, variables) and the validation result; it MUST work whether or
  not the instance is running and MUST change nothing. Like every
  target-scoped command it needs the built image (identity lookup); without
  it, it refuses with the wrapper's existing "image not built" error (exit 5).
- **FR-005c**: `scripts/autonomous volumes --target <repo> --init` MUST write a
  commented starter declaration (no active entries, with worked examples) when
  none exists, print its path, and refuse without changing anything when one
  already exists.
- **FR-005a**: The container MUST receive only the applied result (mounts and
  variables, plus the applied volume set needed by FR-023), never the
  declaration file itself.

**Validation (before anything starts)**

- **FR-006**: An entry name MUST be a lowercase slug (letters, digits, `-`,
  starting with a letter or digit) and unique within the declaration.
- **FR-007**: A mount path MUST be absolute, MUST contain no character the
  container engine cannot mount, and MUST NOT be equal to, inside, or a parent
  of: the target repo, the worktree root, the orchestrator state root, the
  orchestrator's source and build locations, the application install
  location, or the container home's agent configuration. Mount paths of two
  entries MUST NOT be equal or nested.
- **FR-008**: A variable name MUST be a valid environment variable name and
  MUST NOT be reserved. Reserved: every `AUTONOMOUS_*` variable, `PATH`,
  `HOME`, `SHELL`, `USER`, and every variable the container start sequence
  sets or relies on (a fixed, documented list). Two entries MUST NOT set the
  same variable.
- **FR-008a**: An entry MAY list path directories. Each MUST be absolute and
  equal to or inside that entry's own mount path. They MUST be prepended to
  the image's `PATH` in declaration order (entry order, then listed order),
  ahead of the image's own directories, so kept tools are found by name; the
  image's `PATH` entries MUST all remain.
- **FR-008b**: An entry MAY set a variable the image already sets (for
  example `MISE_DATA_DIR`, `MIX_HOME`, `HEX_HOME`, `PLAYWRIGHT_BROWSERS_PATH`)
  unless it is reserved under FR-008. The declared value wins for every
  session and the operator shell, and the start output MUST print one notice
  line per overridden image variable naming the variable, the image's value
  and the declared value.
- **FR-009**: Any validation failure MUST refuse the start before any
  container or volume is created, naming the declaration, the offending
  entry, and the reason, with a non-zero exit. Validation MUST report all
  violations found, not only the first.
- **FR-010**: A malformed or unreadable declaration MUST refuse the start
  naming the file and the problem.

**Volumes**

- **FR-011**: Each declared volume MUST be scoped to the target's instance: two
  targets declaring the same name get separate volumes.
- **FR-012**: A declared volume MUST persist across instance stop and start,
  and across image rebuilds.
- **FR-013**: A declared volume MUST be writable by the container user at its
  mount path on every start, including the first.
- **FR-014**: Declared variables MUST be visible to every session the instance
  runs (phases, implement chunks, remediation, PR description) and to the
  operator shell, with the declared values, and the same `PATH` (FR-008a).
- **FR-015**: The feature MUST NOT mount or modify any host path; declared
  volumes live only in the container engine's storage.
- **FR-016**: Declared volumes MUST be mounted in every instance shape that
  serves the target (dev shell, console, release).
- **FR-017**: Stopping an instance normally MUST NOT remove declared volumes.
  The existing full purge MUST also remove them, and say so in its usage text.

**Reset**

- **FR-018**: `scripts/autonomous reset-cache --target <repo> [--volume
  <name>]...` MUST remove the named declared volumes of that target's
  instance, or all declared volumes when no `--volume` is given.
- **FR-019**: Reset MUST refuse while any container of that instance exists —
  running, or exited but not removed (it still pins the volume) — naming it
  and the stop command, and remove nothing.
- **FR-020**: Reset MUST refuse a name that is not declared, listing the
  declared names, and remove nothing.
- **FR-021**: Reset MUST report each volume as removed or not present, and
  succeed when every selected volume is absent (idempotent).
- **FR-022**: Reset MUST NOT touch another target's volumes, the
  orchestrator's own volumes, or any host path.

**Visibility**

- **FR-023**: The console Configuration page MUST list the volumes applied at
  start: name, mount path, exported variables, path directories, and space
  used, measured when
  the page loads, and MUST state that the list is as applied at start (edits
  to the declaration since then are not shown). A volume whose size cannot be
  measured MUST show that it is unknown, not zero. It MUST render nothing for
  this group when none are declared.
- **FR-024**: The instance start output MUST list each declared volume mounted
  (one line per volume), so the operator sees what was applied, followed by
  the override notices of FR-008b.

**Unchanged**

- **FR-025**: Session tool set, permission mode, headless exclusions, session
  deadlines, the non-container warning, workspace trust and agent-root
  behaviour MUST be unchanged.
- **FR-025a**: Worktrees MUST stay host directories under the bind-mounted
  state root, exactly as before: their contents persist between phases,
  implement chunks and instance restarts and remain visible on the host. A
  declared volume MUST NOT contain or replace a worktree (enforced by FR-007's
  worktree-root collision rule); declared volumes hold only data a session
  places outside the worktree. Operator documentation MUST state this.

**Verification**

- **FR-026**: Hand-run smoke checks MUST cover: persistence across restart,
  per-instance isolation, each class of rejected declaration (name, path,
  variable, malformed file) leaving nothing started, and reset (by name, all,
  running refusal, unknown name, idempotence).
- **FR-027**: Operator documentation MUST describe the declaration format,
  the validation rules and reserved variables, reset, and full worked
  examples for Rust (mod-player: toolchains + build output), Node + pnpm
  (fretboard-master: package store) and Elixir (autonomous: toolchain-manager
  data, Mix/Hex caches, deps and build output), plus a short Python snippet
  (virtual environment / pip cache).
- **FR-028**: The plan's `quickstart.md` and the operator documentation MUST
  include a quickstart that walks through three existing targets on different
  stacks — mod-player, fretboard-master and autonomous — each end to end:
  `volumes --init`, edit the declaration, start, verify the volumes and
  variables (start output and Configuration), restart and confirm persistence,
  and `reset-cache`.

### Key Entities

- **Volume declaration**: the per-target list of volume entries, an
  operator-owned host-only file (never mounted), read by the wrapper at start. Absent or
  empty means none.
- **Volume entry**: name (slug, unique), mount path (absolute, non-colliding),
  variables (name → value, none reserved, none shared with another entry),
  path directories (absolute, inside its own mount path; prepended to `PATH`).
- **Instance volume**: the container-engine volume backing one entry for one
  target's instance; exists on the host's container storage or not (reported
  by `reset-cache` and `volumes`); removed only by reset or full purge.
- **Applied volume set**: what the instance mounted at start; shown on
  Configuration and in start output.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a restart, a session finds data a previous session wrote
  into a declared volume, and re-running a build that was up to date before
  the restart does no rebuild work, in 100% of smoke runs.
- **SC-002**: A container build pointed at a declared volume writes 0 bytes of
  build output into the worktree or the host target repo.
- **SC-003**: 100% of invalid declarations in the smoke set are refused before
  any container or volume exists, each naming the offending entry.
- **SC-004**: The operator can reset one kept volume with a single command
  without knowing the container engine's volume names, and no other target's
  data changes.
- **SC-005**: An instance with no declaration behaves identically to before
  this feature: the full default test suite passes unchanged and start output
  is byte-identical apart from timestamps.
- **SC-006**: Declaring a new ecosystem's cache requires editing only the
  declaration — zero changes to orchestrator files.

## Assumptions

- Container engine named volumes are the storage; they live outside host bind
  mounts and survive container removal.
- A declared volume's mount path is under a location the image does not
  otherwise use; documentation recommends `/var/lib/autonomous/volumes/<name>`.
- Toolchain installers and build tools honour the variables the operator
  declares (e.g. toolchain home, cache dir, build-output dir); choosing them is
  the operator's job, helped by the documented examples.
- The image keeps its own toolchains where they are today; a declared volume
  that redirects a toolchain manager's data directory is the operator's
  choice; the override is announced at start (FR-008b) and its interaction
  with image-provided tools is documented, not managed.
- Volumes are created by the container engine on first start of an instance;
  no separate create step exists.
- Constitution Principle II (fail loud at boundaries), III (container is the
  boundary) and VII (operator surfaces tell the truth) apply; no constitution
  amendment is expected.
