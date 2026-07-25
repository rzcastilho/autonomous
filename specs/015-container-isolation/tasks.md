---

description: "Task list for 015-container-isolation"

---

# Tasks: Container Isolation for Autonomous Runs

**Input**: Design documents from `/specs/015-container-isolation/`

**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included — plan.md's Project Structure explicitly lists the new test
files (`preflight_test.exs`, `container/env_test.exs`, `container/mount_test.exs`,
`image_info_test.exs`, `boot_test.exs`, `test/integration/container_run_test.exs`,
`test/integration/container_red_team_test.exs`) and research.md §R13 maps every
success criterion to a specific test. Pure logic lives in the default hermetic
suite; anything needing a container engine sits behind `@tag :integration`
(`mise exec -- mix test --include integration`) per the constitution's Quality &
Test Discipline.

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P4).
Packaging, environment parsing, image self-identification, and the Preflight
module are **Foundational** — no user story is independently testable without a
bootable, correctly-configured container, and `Boot` (used by every story) calls
`Preflight.run/1` unconditionally. Each user story phase then adds the
integration coverage, doc content, and shutdown-path logic specific to that
story's independent test.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- Paths are repo-root relative, matching plan.md's Project Structure exactly

## Path Conventions

Single Elixir/OTP project. Source: `lib/speckit_orchestrator/`. Tests:
`test/speckit_orchestrator/` (hermetic) and `test/integration/` (`--include
integration`). New packaging/deploy surface at the repo root: `Dockerfile`,
`.dockerignore`, `scripts/`, `.github/workflows/`.

---

## Phase 1: Setup

**Purpose**: Confirm the workspace builds before any new module lands, and land
the small standalone artifacts every later task assumes exist.

- [X] T001 Run `mise exec -- mix deps.get && mise exec -- mix compile` from repo
      root and confirm a clean compile (`warnings_as_errors` on) before starting.
      No new Elixir dependency is introduced by this feature.
- [X] T002 [P] Create `.dockerignore` at the repo root per
      `contracts/image-publishing.md` §2 — exclude at minimum `_build/`, `deps/`,
      `cover/`, `doc/`, `.git/`, `.elixir_ls/`, `.DS_Store`, `tmp/`,
      `erl_crash.dump`, `*.ez`, `specs/`. Do **not** exclude `priv/` or `config/`.
- [X] T003 [P] Create `docs/autonomous.env.example` per
      `contracts/environment.md` §7 — the reference `.env` skeleton (required
      `SPECKIT_REPO`/`ANTHROPIC_API_KEY`, required-in-container git identity,
      optional settings), with a comment noting `AUTONOMOUS_HOST_REPO`,
      `AUTONOMOUS_HOST_HOME`, `HOME`, and `RELEASE_COOKIE` are emitted by the
      launcher script, not hand-written.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The packaging, boot-environment, and preflight substrate every user
story's container needs to exist and boot correctly at all. `Boot`
(FR-029/030/031) is the entrypoint every story exercises, and it depends on
`Container.Env`, `ImageInfo`, and `Preflight` unconditionally.

**⚠️ CRITICAL**: No user story phase can be verified until this phase is complete
— none of them have anything to run against otherwise.

- [X] T004 Add a `releases:` block to `mix.exs` per research.md §R1 —
      `speckit_orchestrator` release, `include_executables_for: [:unix]`,
      `include_erts: true`, `MIX_ENV=prod mix release` producing an
      ERTS-embedded, source-free artifact (FR-003).
- [X] T005 Expand `config/runtime.exs` to cover every FR-020 setting per
      research.md §R9 and `contracts/environment.md` §1–§2: `models`
      (`SPECKIT_MODEL_<PHASE>`, validated against `Config.valid_models/0`,
      unknown phase/alias raises), `implement_max_turns`, `phase_max_retries`,
      `autonomous_root`, `specs_root`, `speckit_version`,
      `AUTONOMOUS_CONSOLE_IP`/`AUTONOMOUS_CONSOLE_PORT`, `server: true`,
      `RELEASE_DISTRIBUTION=sname` with distribution bound to loopback. Every
      required setting absent or unparseable raises naming the variable (and
      value, where numeric) — never a silent compiled-in fallback.
- [X] T006 [P] Update `config/config.exs` so the console's bind address and
      `check_origin` are derived from the same env-derived port/IP values T005
      introduces (matches `localhost` and `127.0.0.1` at the configured port),
      keeping dev/test defaults unchanged (research.md §R12).
- [X] T007 [P] Create `lib/speckit_orchestrator/container/env.ex` —
      `SpeckitOrchestrator.Container.Env` struct and parse/validate function per
      data-model.md §4 and `contracts/environment.md` §1–§5: every field/env var
      in the table, `autostart/0` type (`:none | {:breakdown, slug} | :ad_hoc`),
      path-identity fields (`host_repo`, `host_home`), git-identity requiredness.
      A required var absent raises naming the variable; an unparseable numeric
      var raises naming the variable and value; an unknown
      `SPECKIT_MODEL_<PHASE>` alias or unknown `<PHASE>` raises listing the
      accepted set.
- [X] T008 [P] Create `test/speckit_orchestrator/container/env_test.exs` —
      required/optional/invalid/absent matrix for every `Container.Env` field:
      each required var absent raises with its name; each numeric var given a
      non-numeric value raises naming var+value; unknown model alias and unknown
      phase both raise listing the accepted set; `AUTONOMOUS_AUTOSTART` unset/`""`
      → `:none`, `ad-hoc` → `:ad_hoc`, an unrecognised value raises.
- [X] T009 [P] Create `lib/speckit_orchestrator/container/mount.ex` —
      `SpeckitOrchestrator.Container.Mount` per data-model.md §5:
      `mount_point?(mountinfo_lines, path) :: boolean()`, a pure parse of
      `/proc/self/mountinfo`-shaped text taking file *contents*, not a path.
- [X] T010 [P] Create `test/speckit_orchestrator/container/mount_test.exs` and
      fixtures under `test/fixtures/mountinfo/` — a durable-bind-mount fixture,
      a tmpfs-only `$HOME` fixture, and a fixture with `$HOME` on tmpfs plus a
      nested bind at `$HOME/.autonomous` (the real nested-mount shape from
      research.md §R6), asserting `mount_point?/2` distinguishes each correctly.
- [X] T011 [P] Create `lib/speckit_orchestrator/image_info.ex` —
      `SpeckitOrchestrator.ImageInfo` per data-model.md §1: reads and parses
      `/etc/autonomous/image.json` (`source_revision`, `orchestrator_version`,
      `image_ref`, `built_at`, `tools`, `elixir`, `otp`, `base_digests`). Missing
      or unparseable file returns `{:error, :not_containerized}` rather than
      inventing values; a present-but-empty `tools` map is treated as invalid.
- [X] T012 [P] Create `test/speckit_orchestrator/image_info_test.exs` and
      fixtures under `test/fixtures/image_json/` — a valid manifest, a malformed
      one, and an absent-file case, asserting the three outcomes T011 requires.
- [X] T013 Create `lib/speckit_orchestrator/preflight/check.ex` —
      `SpeckitOrchestrator.Preflight.Check` per data-model.md §2:
      `id`/`category`/`status`/`detail`/`expected`/`observed`/`fix` fields, and
      the invariant `status != :ok ⇒ fix` present and non-empty.
- [X] T014 Create `lib/speckit_orchestrator/preflight/report.ex` —
      `SpeckitOrchestrator.Preflight.Report` per data-model.md §3 and
      `contracts/preflight-report.md` §1–§2: `status` derived
      (`:fail` if any check fails, else `:warn` if any warns, else `:pass`),
      `checks` sorted by `category` then `id` (deterministic, byte-identical for
      identical input), pretty-printed JSON serialization matching the schema in
      §1, `image` field `nil` outside a container.
- [X] T015 Create `lib/speckit_orchestrator/preflight.ex` — the full FR-032 check
      inventory (all 11 checks from data-model.md §2 /
      `contracts/preflight-report.md` §3: `tool_git`, `tool_gh`, `tool_claude`,
      `tool_specify`, `tool_python3`, `tool_mise`, `credential_agent`,
      `credential_gh`, `repo_mounted`, `repo_path_identity`, `home_path_identity`,
      `run_state_writable`, `run_state_durable`, `target_pack`, `image_identity`,
      `unprivileged`) and the four functions from `contracts/preflight-report.md`
      §5: `collect/1` (IO, accepts injected probe seams — tool lookup,
      mountinfo contents, file stat, `TargetPack.verify/1`), `evaluate/1` (pure,
      `map() -> Report.t()`), `persist/2` (writes to
      `<run_state_root>/preflight/<iso8601>-<status>.json` and copies to
      `latest.json`), `run/1` (collect → evaluate → persist, `{:ok, Report.t()}
      | {:error, Report.t()}`). Credential checks record **source** only
      (`:env`/`:mounted_config`/`:absent`) — never a value, prefix, or length
      (FR-035).
- [X] T016 [P] Create `test/speckit_orchestrator/preflight_test.exs` — core
      pure-logic coverage: `evaluate/1` status derivation for each of
      pass/warn/fail; deterministic check ordering; the
      `status != :ok ⇒ fix present` invariant enforced across every check the
      collector can emit; `collect/1`'s injected seams each independently
      fakeable with no container or CLI; `persist/2` writes pretty-printed JSON
      to the correct path and updates `latest.json`.
- [X] T017 Modify `lib/speckit_orchestrator/application.ex` — call
      `SpeckitOrchestrator.Telemetry.attach_default_logger/0` at boot so phase
      and terminal-state events reach stdout unconditionally (FR-028), and
      supervise the new `Boot` child (T018) last in the children list.
- [X] T018 Create `lib/speckit_orchestrator/boot.ex` — a supervised
      `SpeckitOrchestrator.Boot` child per research.md §R11: idle by default
      (starts no run); its work happens in `handle_continue` (never blocks
      `init`); calls `Preflight.run/1`; on `:pass`/`:warn` with
      `AUTONOMOUS_AUTOSTART` set, launches the named run via the facade; on
      `:fail`, logs and stays idle without starting a run and without reporting
      success (FR-031); never stops the VM when a run drains (FR-030).
- [X] T019 [P] Create `test/speckit_orchestrator/boot_test.exs` — idle-by-default
      boot (no `AUTONOMOUS_AUTOSTART`, no run started); autostart launches the
      named run once preflight passes; a failing preflight leaves the container
      idle with no run and no success signal; `Boot` never blocks its
      supervisor's `init`.
- [X] T020 Create `Dockerfile` at the repo root per
      `contracts/image-publishing.md` §1 and research.md §R2–§R3: two-stage
      build — `builder` (`hexpm/elixir:1.20.2-erlang-<otp28.x>-debian-bookworm-<date>`,
      digest-pinned) producing `MIX_ENV=prod mix release`; `runtime`
      (`debian:bookworm-slim`, digest-pinned, same Debian release as the
      builder) carrying the release plus `git`, `gh`, `python3`, `claude`,
      `specify`, `uv`, `mise` each at a pinned `ARG` version (research.md §R3
      table), OCI labels (`org.opencontainers.image.{source,revision,version,
      created,title}`), `/etc/autonomous/image.json` written from build args
      and probed tool versions, a build-time assertion that
      `/app/lib/speckit_orchestrator-*/ebin` exists and `mix` does **not**
      resolve on `PATH` in the runtime stage (FR-003). Entrypoint: copies a
      read-only-mounted `/run/secrets/claude` into the ephemeral
      `$HOME/.claude` when present, sets `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/
      `GIT_CONFIG_VALUE_0` for `safe.directory=*` trust (FR-015, research.md
      §R4), sets `MISE_DATA_DIR`/`MISE_CACHE_DIR`/`MISE_TRUSTED_CONFIG_PATHS`/
      `MISE_YES` (research.md §R5), then `exec bin/speckit_orchestrator start`.
- [X] T021 [P] Create `scripts/autonomous-container.sh` — the launcher per
      `contracts/container-run.md` §1: derives `$REPO`/`$HOME` from the host
      environment and emits the canonical `docker run` invocation verbatim
      (`--user`, `--read-only`, `--cap-drop ALL`, `--security-opt
      no-new-privileges`, `--pids-limit`, `--stop-timeout`, `--tmpfs /tmp`,
      `--tmpfs $HOME`, `-v $REPO:$REPO`, `-v $HOME/.autonomous:$HOME/.autonomous`,
      optional `-v $HOME/.claude:/run/secrets/claude:ro`,
      `-p 127.0.0.1:$PORT:$PORT`, `--env-file`, and
      `AUTONOMOUS_HOST_REPO`/`AUTONOMOUS_HOST_HOME`/`RELEASE_COOKIE`) so the
      two path-identity assertions can never drift from the two `-v` flags;
      supports `start`/`stop` subcommands and an `--autostart <slug>` flag.

**Checkpoint**: the image builds, the release boots idle, and `Boot` correctly
gates on `Preflight`. Every user story phase below builds on this substrate.

---

## Phase 3: User Story 1 - Run a backlog inside a container with unchanged outcomes (Priority: P1) 🎯 MVP

**Goal**: An operator starts the orchestrator as a container against a prepared
target repository and credentials, launches a run, and the run produces the same
per-feature terminal statuses, branches, and artifacts as an on-machine run.

**Independent Test**: Run the same backlog twice against a fixture target
repository — once on-machine, once containerized — and diff per-feature
terminal statuses, produced branches, and artifacts.

- [ ] T022 [US1] Create `test/integration/container_run_test.exs`
      (`@tag :integration`) covering: **SC-001 run parity** — the reference
      backlog run in-container reaches the same per-feature terminal statuses
      and the same `feature/NNN-slug` branch set as an on-machine run against the
      same fixture target; **US1 AS4** — both credential paths (direct
      `ANTHROPIC_API_KEY` and mounted `~/.claude` via `/run/secrets/claude`)
      independently succeed with no credential value in any artifact or log;
      **SC-008** — a fixture target pinning a runtime different from the
      orchestrator's own resolves and uses **its** pinned version, verified via
      `resolved_versions.target_toolchain` in `preflight/latest.json`; **US1
      AS5** — with `AUTONOMOUS_AUTOSTART` set and preflight passing, the run
      launches with no operator action and the container stays up after it
      drains, with the report/transcripts/worktrees inspectable from the host.
- [ ] T023 [US1] Create `docs/container.md` — the FR-036 start-to-finish
      operator path (pull, start, preflight, run, observe, stop) for a
      first-time operator on a Linux host with only a container engine and
      credentials, matching quickstart.md Scenario A exactly; separately
      document the local build path (`docker build --build-arg
      SOURCE_REVISION=... -t autonomous:dev .`) for development; include the
      FR-038 disk-reclaim table (`mise/cache` always safe, `mise/data` safe at
      the cost of re-fetching, `preflight/*.json` safe except `latest.json`,
      `transcripts/<segment>/…` safe once post-mortem is done,
      `worktrees/<segment>/…` **not** safe while a feature is
      escalated/halted).

**Checkpoint**: a containerized run against a real backlog matches its
on-machine counterpart — the MVP is deliverable on its own.

---

## Phase 4: User Story 2 - Bound the blast radius to the mounted repository (Priority: P2)

**Goal**: With the in-repo guard hook deliberately disabled, every hostile
command the OS layer can refuse is refused, and the host filesystem outside the
two declared mounts is untouched.

**Independent Test**: Execute a red-team command set (out-of-tree writes,
privilege escalation, home-directory writes, system-path package installs)
inside the container with the guard hook disabled, and confirm every attempt
fails and the host filesystem is unchanged.

- [ ] T024 [US2] Create `test/integration/container_red_team_test.exs`
      (`@tag :integration`) — checksum the host tree outside the two declared
      mounts before the run; with the in-repo guard hook removed, execute ≥10
      hostile commands (write outside `$SPECKIT_REPO` and
      `$HOME/.autonomous`, write to `$HOME` outside `.autonomous`, `sudo`,
      setuid-escalation attempt, write to `/etc`, write to `/usr`, a
      system-path package install, a privileged bind mount attempt, a raw
      device write attempt, a capability-requiring syscall); assert **100%**
      fail (SC-002) and the host checksum is byte-for-byte unchanged
      afterwards; assert the container is still healthy afterwards (US2 AS1,
      AS2, AS4).
- [ ] T025 [US2] Extend `test/integration/container_run_test.exs` (T022) — after
      a normal (non-hostile) run, assert every file it created under `$REPO` is
      owned on the host by the invoking UID/GID (`stat -c %u:%g`) and requires
      no elevation to edit or delete (SC-004, US2 AS3).
- [ ] T026 [US2] Modify `docs/enforcement.md` — replace the current advisory
      "Container isolation (optional)" section with an accurate one per FR-037:
      state plainly that the container is the **third**, outermost containment
      layer (never a replacement for the scope-guard hook or per-phase
      permissions, FR-017), enumerate exactly what it protects (filesystem
      writes, privileges, process scope) and what it explicitly does **not**
      (network egress, FR-016) — removing the current "drop network egress
      except the Anthropic API host" line, which was never implemented and
      overstates the guarantee.

**Checkpoint**: the isolation guarantee holds independently of the in-repo hook
— User Stories 1 and 2 together deliver the core value proposition.

---

## Phase 5: User Story 3 - Operate and observe the containerized run (Priority: P3)

**Goal**: The operator retains the full on-machine operator surface (console,
remote session, transcripts, resolve/resume) against a containerized run, and a
run survives the container being stopped and restarted without corrupting cost
accounting or the run manifest.

**Independent Test**: Start a containerized run, reach the operator surface from
the host while in flight, stop and restart the container, and confirm run state
and transcripts are intact and the run can be resumed.

- [ ] T027 [US3] Modify `lib/speckit_orchestrator/coordinator.ex` — `trap_exit`
      and a `terminate/2` callback that flushes the run manifest on shutdown; an
      in-flight phase that does not finish within the stop grace period is
      recorded as `interrupted` with its `Ledger` reservation left intact, so
      the manifest never misreports spend (FR-027).
- [ ] T028 [US3] Modify `lib/speckit_orchestrator/ledger.ex` — `trap_exit` and a
      `terminate/2` callback that flushes the committed/reserved cost tally on
      shutdown, so a `docker stop` never loses or double-counts spend (FR-027,
      Constitution IV).
- [ ] T029 [P] [US3] Extend `test/speckit_orchestrator/coordinator_test.exs` —
      unit tests for `terminate/2`: a normal drain flushes the manifest as
      today; a forced shutdown mid-phase records that feature `interrupted`
      with its reservation intact.
- [ ] T030 [P] [US3] Extend `test/speckit_orchestrator/ledger_test.exs` — unit
      tests for `terminate/2`: shutdown flushes the current committed/reserved
      totals; the invariant `committed < budget + max_single_reservation`
      still holds on the flushed value.
- [ ] T031 [US3] Extend `test/integration/container_run_test.exs` (T022) with
      three more scenarios: **SC-006 stop/restart** — `docker stop --time
      900` mid-run then `docker start`; transcripts, run manifests,
      checkpoints, and per-feature worktrees from that run are all present and
      readable from the host, and recorded spend after restart equals spend
      before the stop; **US3 AS1/AS2** — the console (`http://127.0.0.1:<port>/`)
      loads and reflects live state while a run is in flight, and
      `docker exec -it autonomous bin/speckit_orchestrator remote` reaches
      `SpeckitOrchestrator.print_status/0`, `resolve/1`, and `resume/2`
      behaving as on-machine; **FR-028** — `docker logs -f autonomous` carries
      `[:speckit, :phase, ...]` and `[:speckit, :feature, :terminal]` events
      with no interactive session required.
- [ ] T032 [US3] Modify `docs/runbook.md` — add a containerized-operation
      cross-reference: console URL and loopback-only exposure, the remote
      console command and its `print_status`/`resolve`/`resume` usage,
      `docker logs -f` for following a run headlessly, and stop/restart
      guidance (`--stop-timeout`, preferring a console-driven drain over a hard
      stop).

**Checkpoint**: the full operator surface — console, remote session, resolve,
resume, stop/restart — works identically against a containerized run.

---

## Phase 6: User Story 4 - Verify the environment before spending money (Priority: P4)

**Goal**: Every preflight failure mode names the specific missing item and its
single fix, stops the run before any agent spend, and a successful preflight
records the resolved versions for later diagnosis.

**Independent Test**: Start the container with each required piece omitted in
turn and confirm preflight fails, names the missing piece and its fix, and does
not begin any feature work.

- [ ] T033 [US4] Extend `test/speckit_orchestrator/preflight_test.exs` (T016) —
      the SC-007 completeness matrix: one test per check id's `:fail` condition
      (and `:warn` condition where one exists) from data-model.md §2 /
      `contracts/preflight-report.md` §3, asserting the message names the
      specific missing item and the single action that fixes it (FR-033); and a
      cross-cutting assertion that no `detail`/`expected`/`observed`/`fix`
      value ever contains a credential value, prefix, suffix, or length —
      credential checks record `source` only (FR-035).
- [ ] T034 [US4] Extend `test/speckit_orchestrator/preflight_test.exs` (T016) —
      FR-034: a `:pass`/`:warn` report's persisted JSON includes
      `resolved_versions` for every resolved tool/runtime; two `evaluate/1`
      calls over identical collected facts produce byte-identical `checks`
      ordering (category then id), proving the report is reproducible and later
      drift diagnosable.
- [ ] T035 [US4] Extend `docs/container.md` (T023) with the full FR-033/SC-007
      rejection-matrix table from quickstart.md Scenario G (omit each
      requirement in turn → named check id, message, and fix), so an operator
      resolves any seeded failure without reading source code.

**Checkpoint**: every preflight failure mode is proven to name its own fix, and
the report is a trustworthy, reproducible diagnostic artifact.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: The automated publishing path (not required by any single story's
independent test, since every story validates against a locally-built image)
and final end-to-end verification.

- [ ] T036 [P] Create `.github/workflows/image.yml` per
      `contracts/image-publishing.md` §6 — triggers on `v*` tag push and
      `workflow_dispatch`; derives and validates the `v<semver>` version;
      **immutability guard** (`docker buildx imagetools inspect
      ghcr.io/rzcastilho/autonomous:v<semver>` — fail the job if it already
      resolves, FR-009/SC-010); Buildx build with `SOURCE_REVISION`/`BUILT_AT`/
      `IMAGE_REF` and the pinned tool-version build args, registry-backed layer
      caching; **secret scan** (`trivy image --scanners secret --exit-code 1`,
      SC-005); **smoke test** (start with a fixture repo mount, assert a
      preflight report is produced and `/etc/autonomous/image.json` matches the
      build args); push `v<semver>`, `sha-<short-sha>`, and `latest`; record the
      digest in the job summary and release notes (FR-008, SC-011).
- [ ] T037 [P] Verify the local build path documented in T023 against the same
      `Dockerfile`/build-args T020/T036 use (`docker build --build-arg
      SOURCE_REVISION="$(git rev-parse HEAD)" -t autonomous:dev .`); confirm
      `autonomous:dev` carries no version identity and `docs/container.md`
      states it is not reproducible across machines (FR-036, `image-publishing.md`
      §7).
- [ ] T038 Run `mise exec -- mix test` (hermetic suite) and `mise exec -- mix
      test --include integration` end to end, confirm `warnings_as_errors`
      stays clean, then manually walk quickstart.md Scenarios A–I once against
      a real Linux container engine, recording and fixing any documentation gap
      found (SC-003's "no undocumented step" bar).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — can start immediately.
- **Foundational (Phase 2)**: depends on Setup (T002/T003 land alongside it;
  order among Phase 1/2 tasks is not load-bearing). **Blocks every user story**
  — `Boot` (T018), which every story's integration test boots, depends on
  `Container.Env` (T007), `ImageInfo` (T011), and `Preflight` (T013–T015).
- **User Stories (Phase 3–6)**: all depend on Foundational completion.
  - US1 (P1) has no dependency on US2–US4.
  - US2 (P2) can run in parallel with US1 — it extends US1's integration test
    file (T025) but that extension is independent of T022's content.
  - US3 (P3) can run in parallel with US1/US2 — its `terminate/2` work
    (T027–T030) touches different files than US1/US2, and its integration
    extension (T031) is additive to T022.
  - US4 (P4) depends only on Foundational's `Preflight` module (T013–T016), not
    on US1–US3 — it can run fully in parallel with all three.
- **Polish (Phase 7)**: depends on Foundational (needs the Dockerfile, T020)
  but not on any user story landing first; T038's manual quickstart walk is most
  useful once US1–US4 are all in.

### Within Foundational

- T004 (releases block) and T005 (runtime.exs) before T017 (application.ex —
  needs `server: true` wiring to make sense) and before T020 (Dockerfile builds
  the release T004 defines).
- T007 (`Container.Env`) before T008 (its test), T015 (`Preflight.collect/1`
  reads env-derived facts), and T018 (`Boot` reads `autostart/0`).
- T009 (`Container.Mount`) before T010 (its test) and T015 (the
  `run_state_durable` check).
- T011 (`ImageInfo`) before T012 (its test) and T015 (the `image_identity`
  check).
- T013 → T014 → T015 (Check struct, then Report struct, then the module that
  produces both) before T016 (its test) and T018 (`Boot` calls `Preflight.run/1`).
- T017 and T018 before T019 (`boot_test.exs`).
- T020 (Dockerfile) and T021 (launcher) are independent of each other and of
  every other Foundational task except T004 (the release the Dockerfile copies
  in) — both can run in parallel with T005–T019 once T004 lands.

### User Story Dependencies

- **US1 (P1)**: after Foundational — no dependency on US2/US3/US4.
- **US2 (P2)**: after Foundational — extends US1's T022 file but is otherwise
  independent; independently testable via its own red-team run (T024).
- **US3 (P3)**: after Foundational — independent of US1/US2/US4; its
  `terminate/2` tasks (T027–T030) are self-contained, and T031 is additive to
  T022's file.
- **US4 (P4)**: after Foundational only — fully independent of US1–US3.

---

## Parallel Example: Foundational Phase

```bash
# Once T004/T005 land, these can run together (different files):
Task: "Create lib/speckit_orchestrator/container/env.ex"                 # T007
Task: "Create lib/speckit_orchestrator/container/mount.ex"               # T009
Task: "Create lib/speckit_orchestrator/image_info.ex"                    # T011
Task: "Create Dockerfile"                                                # T020
Task: "Create scripts/autonomous-container.sh"                           # T021

# Their tests, once each module lands:
Task: "test/speckit_orchestrator/container/env_test.exs"                 # T008
Task: "test/speckit_orchestrator/container/mount_test.exs + fixtures"    # T010
Task: "test/speckit_orchestrator/image_info_test.exs + fixtures"         # T012
```

## Parallel Example: User Stories (post-Foundational)

```bash
# US1, US2, US3, US4 can be staffed in parallel once Foundational is done:
Task: "US1 — test/integration/container_run_test.exs (run parity)"       # T022
Task: "US2 — test/integration/container_red_team_test.exs"               # T024
Task: "US3 — coordinator.ex terminate/2"                                 # T027
Task: "US4 — preflight_test.exs SC-007 matrix"                           # T033
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (image, release, env config, `Boot`,
   `Preflight`) — **critical path**, blocks everything.
3. Complete Phase 3: User Story 1 — run parity proven.
4. **STOP and VALIDATE**: run the fixture backlog on-machine and containerized,
   diff outcomes per T022.
5. This alone is adoptable: an operator can stop running agent-authored
   commands on their own machine even before US2–US4 land.

### Incremental Delivery

1. Setup + Foundational → a bootable, correctly-configured, idle container.
2. Add US1 → run parity proven → deployable MVP.
3. Add US2 → the isolation guarantee is proven independently of the in-repo
   hook → the feature's actual value proposition is now provable.
4. Add US3 → full operator surface + safe stop/restart → viable for
   long-running unattended backlogs.
5. Add US4 → preflight completeness → the common failure modes become
   two-second, self-explanatory stops instead of mid-run surprises.
6. Add Polish (Phase 7) → automated publishing, so the normal operator path
   (pull, not build) is live.

### Parallel Team Strategy

With multiple developers, once Foundational is done: Developer A takes US1,
Developer B takes US2 (extends US1's test file — coordinate on T022/T024/T025),
Developer C takes US3 (self-contained `terminate/2` work), Developer D takes
US4 (fully independent, only needs `Preflight` from Foundational).

---

## Notes

- [P] tasks touch different files and have no completed-task dependency within
  their phase.
- [Story] labels map every Phase 3–6 task to its spec.md user story for
  traceability; Setup, Foundational, and Polish tasks carry no story label by
  convention.
- `test/integration/container_run_test.exs` is deliberately reused and extended
  across US1/US2/US3 (T022 → T025 → T031) rather than forked, matching
  research.md's framing of the container as one long-lived process under test —
  coordinate edits to avoid clobbering another story's scenario when working in
  parallel.
- Every container-dependent test carries `@tag :integration` and runs only under
  `mise exec -- mix test --include integration`, per the constitution.
- Verify `mix test` stays green (warnings-as-errors) after each task, not just
  at the end of a phase.
