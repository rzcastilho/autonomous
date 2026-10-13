# Tasks: User-Defined Persistent Volumes

**Input**: Design documents from `/specs/041-user-defined-volumes/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R14), data-model.md, contracts/ (declaration-format, wrapper-cli, applied-volumes, configuration-surface), quickstart.md

**Tests**: Included — plan.md Technical Context and Constitution "Quality & test discipline" require a hermetic default suite (stub `docker`/`mise`, temp dirs, per-test `XDG_CONFIG_HOME`). Docker-real checks are hand-run smoke only.

**Organization**: Grouped by user story. US1 and US2 are both P1; US1 (persistence) is the MVP, US2 (validation) hardens the same start path and must land before release, but each is independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4 (user-story phases only)
- Toolchain: run Elixir via `mise exec -- mix …`; prefix git/gh with `rtk`; `warnings_as_errors` is on

## Path Conventions

Single project, existing layout: host scripts in `scripts/`, Elixir in `lib/autonomous/`, tests in `test/autonomous/`, docs in `docs/`.

---

## Phase 1: Setup

**Purpose**: Skeletons and shared test helpers

- [X] T001 Create `scripts/volumes.py` skeleton (stdlib only, shebang, `main()` argparse shim with subcommands `plan|show|init|select`, pure-function stubs `parse`, `validate`, `plan`, `starter`, `select`); refuse by name when `sys.version_info < (3, 11)`: `<path> needs python3 >= 3.11 (tomllib); found <v>` (exit 2)
- [X] T002 [P] Create test helper `test/support/volumes_case.ex` (ExUnit case template): temp `XDG_CONFIG_HOME`, `run_volumes(args, ctx)` via `System.cmd("python3", ["-I", "scripts/volumes.py" | args])`, canonical `ctx` map (repo, worktree_root, state_root, segment, uid, gid, image_env), `write_declaration/2`
- [X] T003 [P] Create stub-docker test helper `test/support/stub_docker.ex` (PATH shim recording calls to a log file, scripted `volume inspect/create/rm`, `ps -a`, `image inspect`, `run`), following the pattern in `test/autonomous/container_build_options_test.exs`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Declaration parsing and the shared constants every story uses

**⚠️ CRITICAL**: no user story work before this phase is complete

- [X] T004 Implement `parse(text)` in `scripts/volumes.py`: `tomllib` load, top-level key must be only `volume` (array of tables); empty/comment-only/`volume = []` ⇒ zero entries; wrong shape or TOML error ⇒ malformed (`<path>: not valid TOML: <msg>`, exit 2); entries keep declaration order (data-model.md "Volume declaration")
- [X] T005 [P] Add constants to `scripts/volumes.py`: reserved variable list/prefixes (`AUTONOMOUS_*`, `RELEASE_*`, `PATH`, `HOME`, `SHELL`, `USER`, `MIX_ENV`, `PHX_SERVER`, `COMPOSE_PROJECT_NAME`, `DISPLAY`, `GH_TOKEN`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `CLAUDE_CONFIG_DIR`, `MISE_TRUSTED_CONFIG_PATHS`, `MISE_YES`), protected-path builder (repo, worktree root, state root, `/workspace`, `/workspace/_build`, `/workspace/deps` (redundant with `/workspace` under the equal-or-inside rule; kept so violations name the specific location), `/app`, `/home/autonomous/.claude`, `.claude.json`, `.claude.host.json`), docker naming/labels helpers (`autonomous-<segment>_vol-<name>`, `dev.autonomous.kind|segment|volume`) per research.md R4/R9; also export `ALLOWED_IMAGE_OVERRIDES` (image-set variables an entry may override, FR-008b) beside the reserved list
- [X] T006 Add declaration-path resolution to `scripts/autonomous`: `volumes_declaration_path` = `${XDG_CONFIG_HOME:-$HOME/.config}/autonomous/targets/<AUTONOMOUS_INSTANCE_SEGMENT>/volumes.toml` using the existing `lookup_identity`; `realpath` the parent and refuse (exit 2) when inside the state root, the target repo, or the orchestrator source tree (research.md R1, FR-005)
- [X] T007 [P] Add the foundational unit tests in `test/autonomous/volumes_py_test.exs`: parse (absent/empty/comments-only/`volume = []`/malformed/unknown top-level key/unknown entry key) and entry-order preservation

**Checkpoint**: declaration can be parsed and located; stories can start

---

## Phase 3: User Story 1 - Keep a target's build data across restarts (Priority: P1) 🎯 MVP

**Goal**: Declared volumes are created, writable by the container user, mounted in every shape, with variables and `PATH` visible to every session; persist across stop/start; no declaration ⇒ byte-identical behaviour.

**Independent Test**: Declare one volume with one variable, start, write a file via the variable's path from a shell, restart, file still there; worktree shows no new files (smoke `volumes`; hermetic: overlay + stub-docker tests).

### Tests for User Story 1

- [X] T008 [P] [US1] Plan/overlay tests in `test/autonomous/volumes_py_test.exs`: `plan` output shape (volumes, `docker_name`, `env` pairs, `path_dirs`), overlay for `dev|console|release` (long-syntax `volume` mounts, `external: true` named volumes), `PATH = <dirs>:<image PATH>` only when path dirs exist, `AUTONOMOUS_VOLUMES` JSON (`version: 1`), `AUTONOMOUS_VOLUME_PATH`, override notices for image variables (R8), 1/5/20-entry declarations (no count limit, FR-003)
- [X] T009 [P] [US1] `init`/`show` tests in `test/autonomous/volumes_py_test.exs`: starter file is comment-only (zero active entries, mentions reserved list + four ecosystem examples), mode `0600`/dir `0700`, second `init` refuses and leaves the file byte-identical (exit 1); `show` lists entries with present/absent/`kept, not declared`
- [X] T010 [P] [US1] Wrapper start-sequence tests in `test/autonomous/container_volumes_cli_test.exs` (stub docker): with a declaration — `volume create` with the three labels, one provisioning `docker run --user 0:0` for all volumes, overlay `-f` appended, volume lines + override notices printed; without a declaration (absent and zero-entry) — zero extra docker calls, no overlay, output byte-identical (FR-004, SC-005)
- [X] T011 [P] [US1] Entrypoint PATH test in `test/autonomous/container_volume_path_test.exs` (stub `mise`): `AUTONOMOUS_VOLUME_PATH` set ⇒ `mise exec -- env PATH="$AUTONOMOUS_VOLUME_PATH:$PATH"` used for shell and console handover; unset/empty ⇒ today's exact commands
- [X] T011a [P] [US1] Session-env inheritance test in `test/autonomous/session_env_inheritance_test.exs` (FR-014): with a declared variable and a prefixed `PATH` set in the test process env (`System.put_env`, restored in `on_exit`), build a phase `RunRequest` via `PhaseRequest` and resolve it to the SDK command (`ClaudeAgentSDK.Process.__env_vars__/1` + the `CliSubprocessCore.Command` it produces); assert `clear_env?` is `false`, that `PhaseRequest`'s env map does not set the declared variable or `PATH` (so the inherited container values win), and that the passthrough `PATH` equals the prefixed one. Repeat for the implement-chunk, remediation and describe request builders. Fails loud on a `jido_claude`/`claude_agent_sdk` SHA bump that starts clearing the env.

### Implementation for User Story 1

- [X] T012 [US1] Implement `plan(decl, ctx)` in `scripts/volumes.py`: normalized entries, docker names, ordered env pairs, image-`PATH` extraction from `ctx.image_env`, `PATH` composition (entry order, then listed order, image entries all kept), override notices (`autonomous: volume <name>: <VAR> overrides image value <old> with <new>`), `AUTONOMOUS_VOLUMES` and `AUTONOMOUS_VOLUME_PATH` values, overlay dict per contracts/applied-volumes.md
- [X] T013 [P] [US1] Implement `starter()` + `init` subcommand in `scripts/volumes.py`: commented starter (field rules, reserved list, `/var/lib/autonomous/volumes/<name>` parent, worked examples for Rust, Node + pnpm, Elixir, Python), atomic write, `0600`/`0700`, refuse when exists
- [X] T014 [P] [US1] Implement `show` subcommand in `scripts/volumes.py`: entries (name, path, variables), validation result line, per-volume `present`/`absent` from `--present <json>`, `kept, not declared — remove with: docker volume rm <name>` for labelled volumes outside the declaration
- [X] T015 [US1] Implement overlay writer in `scripts/volumes.py` `plan` command: atomic (`tmp` + rename), `0600`, to `<config>/targets/<segment>/applied.compose.json`, regenerated every start
- [X] T016 [US1] Add the `volumes --target <repo> [--init]` command to `scripts/autonomous`: arg parsing, identity lookup, `--init` → `volumes.py init` (exit 0 / exit 1 if exists), otherwise gather present volumes via `docker volume ls --filter label=…` and call `volumes.py show`; absent file ⇒ `no declaration (create one with --init)` exit 0; works running or stopped; changes nothing without `--init` (FR-005b/c)
- [X] T017 [US1] Wire the start sequence in `scripts/autonomous` for `shell|console|release` (contracts/wrapper-cli.md steps 2★/4★): when the declaration file exists, call `volumes.py plan` with context (repo, worktree root, state root, segment, UID/GID, `docker image inspect` env JSON); when ≥ 1 entry: `docker volume create` each with labels, provisioning container (`--user 0:0 --entrypoint /bin/sh`, non-recursive `chown` of mount roots only, every start; research.md R5), write overlay, append `-f <overlay>`, print `autonomous: volumes <path>` + one `autonomous: volume <name> -> <path> (N variables, M path dirs)` per volume + override notices after `print_summary`. Absent file / zero entries: no `volumes.py` call, no docker call, no output
- [X] T018 [US1] Change `scripts/container-entrypoint.sh` VM handover (dev shape, shell and console): when `AUTONOMOUS_VOLUME_PATH` is non-empty, run `mise exec -- env PATH="$AUTONOMOUS_VOLUME_PATH:$PATH" …`; otherwise today's exact commands; leave `prepare_build`, trust, agent root, identity, lock, and the release shape untouched
- [X] T019 [US1] Add the `volumes` line to the usage text in `scripts/autonomous` (exact wording in contracts/wrapper-cli.md "Usage text"); keep the no-argument/help output otherwise byte-identical
- [X] T020 [US1] Add a `volumes` subcommand to `scripts/container-smoke.sh` (hand-run): throwaway git repo target + temp `XDG_CONFIG_HOME`; persistence across restart: (a) marker file written via the variable's path survives; (b) a tiny `make` project in the worktree whose objects go to `$BUILD_DIR` (a declared variable pointing into the volume) builds once, then after `stop` + start a second `make -q` exits 0 and `make` prints `Nothing to be done` (up-to-date build does no rebuild work, SC-001); (c) `git -C <worktree> status --porcelain --ignored` is empty and no object file exists under the worktree or host repo (SC-002); across an image rebuild: `stop`, `scripts/autonomous build`, start again — marker file and the up-to-date `make` state from (b) both survive (FR-012); one real `claude -p` session (or `scripts/autonomous shell` → `iex` driving a describe session) runs `printenv CARGO_TARGET_DIR` and `command -v <tool in a path dir>` and the transcript shows both (FR-014, end to end); 1, 5 and 20 entries; isolation across two targets with the same volume name (FR-011)

**Checkpoint**: US1 complete — volumes persist and are visible; no declaration is byte-identical

---

## Phase 4: User Story 2 - A bad declaration never half-starts an instance (Priority: P1)

**Goal**: Every invalid declaration is refused before any container or volume exists, reporting all violations with entry + reason.

**Independent Test**: For each invalid class, start ⇒ non-zero exit, message naming the entry, no new container or volume.

### Tests for User Story 2

- [X] T021 [P] [US2] Validator tests in `test/autonomous/volumes_py_test.exs`, one case per rule: duplicate name; non-slug name (space, `/`, uppercase, > 63 chars); relative path; non-normalized path (`..`, `//`, trailing `/`); forbidden characters (`:`, `,`, control, newline); path equal to/inside/parent of every protected path (repo, worktree root, state root, `/workspace*`, `/app`, agent config, `/`, `/home`, `/home/autonomous`); two entries equal or nested; reserved variable (each class: `AUTONOMOUS_*`, `RELEASE_*`, `PATH`/`HOME`/`SHELL`/`USER`, start-sequence list); invalid variable name; two entries setting one variable; path dir relative or outside its own mount; non-string env value / NUL / newline; unknown keys; **all violations reported together** (FR-009); image-set variable (e.g. `MISE_DATA_DIR`) allowed (FR-008b); **reserved-list drift guard**: extract every variable name assigned or exported in `scripts/container-entrypoint.sh` and every `environment:` key in `compose.yaml` (all services), and assert each is either in `volumes.py`'s reserved list/prefixes or in the explicit `ALLOWED_IMAGE_OVERRIDES` allow-list (e.g. `MISE_DATA_DIR`, `MIX_HOME`, `HEX_HOME`, `PLAYWRIGHT_BROWSERS_PATH`) — a new start-sequence variable left in neither fails the suite naming it (FR-008 "fixed, documented list")
- [X] T022 [P] [US2] Wrapper refusal tests in `test/autonomous/container_volumes_cli_test.exs`: invalid declaration ⇒ exit 2, violation lines on stderr, `nothing was started; fix the declaration and retry`, and the stub-docker log shows no `volume create`, no `run`, no `up`; malformed file ⇒ names file + parser message; python3 < 3.11 refusal (stub `python3`) only when a declaration exists; `XDG_CONFIG_HOME` inside state root/repo ⇒ exit 2

### Implementation for User Story 2

- [X] T023 [US2] Implement `validate(decl, ctx) -> [violation]` in `scripts/volumes.py` covering every rule in data-model.md "Volume entry" and "Protected paths" (`{entry, field, reason, detail}`; `#<index>` when name missing/invalid); pure, no early return — collect all
- [X] T024 [US2] Implement violation rendering in `scripts/volumes.py` per contracts/declaration-format.md "Validation output": `autonomous: <path>: N problems`, one `autonomous:   entry <name>: <reason>` (or `entries a, b: …`) per violation, trailing `nothing was started; fix the declaration and retry`; exit 2; `plan` calls `validate` before producing any output
- [X] T025 [US2] Ensure `scripts/autonomous` aborts the start on a non-zero `volumes.py plan` strictly before step 3/4 (no live-instance check side effects, no port choice, no `docker volume create`, no provisioning container, no overlay write) and propagates exit 2; surface Python-version and malformed-file refusals unchanged
- [X] T026 [US2] Extend the `volumes` smoke subcommand in `scripts/container-smoke.sh`: one rejected declaration per class (name, path, variable, path dir, malformed file) asserting exit 2, no container, no `autonomous-<segment>_vol-*` volume (SC-003)

**Checkpoint**: US1 + US2 — safe, persistent start

---

## Phase 5: User Story 3 - Reset what an instance has kept (Priority: P2)

**Goal**: `reset-cache` removes selected declared volumes of a stopped instance; `stop --purge` removes all of the segment's user volumes.

**Independent Test**: Write data into two volumes, stop, reset one by name, restart, only that one is empty.

### Tests for User Story 3

- [X] T027 [P] [US3] `select` tests in `test/autonomous/volumes_py_test.exs`: no names ⇒ all declared; named subset in declaration order; unknown name ⇒ exit 2 listing declared names; mount-path/variable violations do **not** block selection, but malformed file and invalid names do (R11 step 3)
- [X] T028 [P] [US3] Wrapper tests in `test/autonomous/container_volumes_cli_test.exs` (stub docker): reset by name (`removed`), reset all, any container of the project (running or exited) ⇒ exit 75 naming it + stop command, nothing removed; unknown name ⇒ exit 2 + declared list; absent volume ⇒ `not present` exit 0 (idempotent); volume without our labels ⇒ exit 1, never removed; no declaration ⇒ `no declared volumes` exit 0; `--volume=<name>` form; `--volume` rejected on other commands; other segment's volumes never matched; `stop --purge` removes exactly labelled `kind=user-volume` + `segment=<segment>` volumes and prints each, plain `stop` touches none

### Implementation for User Story 3

- [X] T029 [US3] Implement `select(decl, names)` + `select` subcommand in `scripts/volumes.py` (R11 steps 3–4; prints selected names, one per line)
- [X] T030 [US3] Add `reset-cache --target <repo> [--volume <name>]...` to `scripts/autonomous` (R11): identity lookup → project `autonomous-<segment>`; refuse exit 75 if `docker ps -a --filter label=com.docker.compose.project=…` returns any container; call `volumes.py select`; per name `docker volume inspect` → absent ⇒ `autonomous: <name> not present`; labels match exactly (name + 3 labels) ⇒ `docker volume rm` ⇒ `autonomous: <name> removed`; labels differ ⇒ exit 1 naming it. Never prefix-match. Add the `reset-cache` line to the usage text (exact wording in contracts/wrapper-cli.md "Usage text")
- [X] T031 [US3] Extend `stop --purge` in `scripts/autonomous` (R12): after `down -v`, `docker volume ls` by labels `dev.autonomous.kind=user-volume` + `dev.autonomous.segment=<segment>`, remove each, print `autonomous: <volume> removed`; update the `stop` usage line to "also removes build volumes and declared volumes"
- [X] T032 [US3] Extend the `volumes` smoke subcommand in `scripts/container-smoke.sh`: reset by name, reset all, running refusal, unknown name, idempotence, other target untouched, purge (FR-026)

**Checkpoint**: US3 complete

---

## Phase 6: User Story 4 - See what an instance keeps (Priority: P3)

**Goal**: Configuration lists the applied volumes (name, mount path, variables, path dirs, space used measured async) and nothing when none.

**Independent Test**: Start with two volumes, open Configuration — both listed with path/variables/size; without a declaration no group renders and the page is unchanged.

### Tests for User Story 4

- [X] T033 [P] [US4] `test/autonomous/applied_volumes_test.exs`: `parse/1` — `nil`/`""` ⇒ `{:ok, [], nil}`; valid v1 JSON ⇒ ordered `Volume` structs with env pairs; unknown `version`, bad JSON, bad shape ⇒ `{:error, reason}`
- [X] T034 [P] [US4] `test/autonomous/volume_usage_test.exs`: temp dir sizes via `du -sk -x`, missing path ⇒ `{:unknown, "not mounted"}`, injected slow command ⇒ `{:unknown, "timed out"}`, `du` failure ⇒ `{:unknown, "du failed: …"}`; never `{:ok, 0}` for unknown
- [X] T035 [P] [US4] `test/autonomous/web/volumes_view_test.exs`: state `:hidden` / `{:refused, reason}` / `{:rows, declaration, rows}`; usage text for `:measuring`, `{:ok, bytes}` (human size + exact KiB), `{:unknown, r}` ⇒ `unknown (<r>)`
- [X] T036 [P] [US4] `test/autonomous/web/config_live_volumes_test.exs`: render with `AUTONOMOUS_VOLUMES` set (group, `data-volume=<name>`, "as applied at start" note, mono identifiers, `data-volume-usage` transitions `measuring → known|unknown`), without it (page byte-identical, no `data-volumes`), malformed value ⇒ `form_refusal` "AUTONOMOUS_VOLUMES unreadable"; reload re-measures

### Implementation for User Story 4

- [X] T037 [P] [US4] Create `lib/autonomous/applied_volumes.ex`: `Autonomous.AppliedVolumes` with nested `Volume` struct (`name`, `path`, `env`, `path_dirs`), `@type`s, `@spec` on every public function (constitution VI), pure `parse/1` (decode with `Jason`, already used in `lib/autonomous/describe.ex`) and the single env read `current/0`
- [X] T038 [P] [US4] Create `lib/autonomous/volume_usage.ex`: `Autonomous.VolumeUsage.measure(path, timeout_ms \\ 30_000)` running `du -sk -x` under a `Task` with timeout ⇒ `{:ok, bytes} | {:unknown, reason}`, with `@spec`
- [X] T039 [P] [US4] Create `lib/autonomous/web/volumes_view.ex`: pure `Autonomous.Web.VolumesView.state/2` and size/label formatting per data-model.md "Configuration view state", `@spec` on every public function
- [X] T040 [US4] Edit `lib/autonomous/web/live/config_live.ex`: load `AppliedVolumes.current/0` on mount, assign view state, `start_async(:volume_usage, …)` per volume on connected mount, `handle_async` updates rows; render the `<fieldset class="config-volumes form-panel" data-volumes>` group per contracts/configuration-surface.md (shared `form-panel`/`data-table` classes, tokens only, no animation, no raw `inspect/1`); render nothing when `:hidden`
- [X] T041 [US4] Add CSS to `priv/static/assets/console.css` only if a new class is needed (tokens only, no literals); run `test/autonomous/design_contract_test.exs` and fix any guard hit

**Checkpoint**: all four stories complete

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T042 [P] Update `docs/container.md`: declaration location/format, validation rules, reserved variable list, `PATH` prepending, image-variable override consequence (e.g. `MISE_DATA_DIR` reinstall on first start), worktrees unchanged (FR-025a), reset, purge, removing a no-longer-declared volume, three worked examples + Python snippet (FR-027)
- [X] T043 [P] Update `docs/runbook.md`: operator flow and the three-target quickstart (copy/condense `specs/041-user-defined-volumes/quickstart.md`, FR-028)
- [X] T044 [P] Add a "User-defined volumes (feature 041)" paragraph to `CLAUDE.md` (host-only `volumes.toml`, `scripts/volumes.py`, overlay, `reset-cache`, `AUTONOMOUS_VOLUMES`, Configuration group)
- [X] T045 [P] Update `docs/enforcement.md` only where the container boundary text mentions mounts (declared volumes are container-engine storage, no host path; FR-015/FR-025)
- [X] T046 Run the full hermetic suite: `mise exec -- mix test` (all pre-existing tests unchanged and green — SC-005; the existing `PhaseRequest`, `AgentRoot`, `ShellTimeouts`, `WorkspaceTrust` and `RuntimeNotice` tests are the FR-025 "unchanged" guard — none may be edited by this feature) and `mise exec -- mix compile --warnings-as-errors`
- [X] T047 Walk `specs/041-user-defined-volumes/quickstart.md` sections A–C and "Rejections" by hand with `scripts/container-smoke.sh volumes` (GNU-tool PATH shim per the macOS smoke recipe) and record the result in `specs/041-user-defined-volumes/checklists/requirements.md` notes

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (1)** → **Foundational (2)** → user stories → **Polish (7)**
- US1 and US2 touch the same start path in `scripts/autonomous` and `scripts/volumes.py`; do US1 first (MVP), then US2. US1's `plan` calls `validate`: until T023 lands, `validate` returns `[]` (stub from T001) — US1 is testable with well-formed input.
- US3 depends on Foundational and on US1's `docker` naming/label helpers (T005, T017); independent of US2.
- US4 depends only on the `AUTONOMOUS_VOLUMES` format fixed by T012; Elixir work (T033–T041) can run in parallel with US1–US3 shell/Python work.

### Within a story

- Tests before implementation (write, see red, then implement)
- `volumes.py` pure functions → wrapper wiring → smoke subcommand
- T015/T017/T019/T025/T030/T031 all edit `scripts/autonomous` — sequential; T012/T013/T014/T023/T024/T029 all edit `scripts/volumes.py` — sequential unless noted [P] (separate functions; merge carefully)

### Story completion order

US1 (P1, MVP) → US2 (P1) → US3 (P2) → US4 (P3; may start any time after T012).

---

## Parallel Examples

**Setup/Foundational**: T002 ∥ T003; T005 ∥ T007 after T004.

**US1 tests**: T008 ∥ T009 ∥ T010 ∥ T011 ∥ T011a (five different test files / sections), then T012; T013 ∥ T014 once T012 settles the module layout.

**US4 (whole story, parallel to US1–US3)**: T033 ∥ T034 ∥ T035 ∥ T036, then T037 ∥ T038 ∥ T039, then T040 → T041.

**Polish**: T042 ∥ T043 ∥ T044 ∥ T045.

---

## Implementation Strategy

### MVP first (US1)

1. Phases 1–2, then US1 (T008–T020, incl. T011a) — stop and validate: persistence across restart, no-declaration byte-identity.
2. Do **not** ship US1 alone: US2 (validation) is the safety half of P1 — land it before the first real use.

### Incremental delivery

1. Setup + Foundational → US1 (persist) → US2 (refuse bad input) → release candidate
2. US3 (reset/purge) → US4 (Configuration visibility) → Polish
3. Each story leaves `mise exec -- mix test` green and keeps the no-declaration path byte-identical.

---

## Notes

- 48 tasks: Setup 3, Foundational 4, US1 14, US2 6, US3 6, US4 9, Polish 6
- Behaviour must stay unchanged for FR-025 items (tool set, permission mode, deadlines, trust, agent root): touch no `PhaseRequest`/`Pipeline` code
- Declaration contents must never reach a container, a log, or `AUTONOMOUS_VOLUMES` beyond the applied set (FR-005a)
