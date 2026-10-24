# Tasks: Container Engine Sidecar for Agent Sessions

**Input**: Design documents from `/specs/046-docker-sidecar/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R10), data-model.md, contracts/ (build-and-compose, wrapper-cli, entrypoint-step, orchestrator, configuration-surface), quickstart.md

**Tests**: Included. plan.md "Testing" and quickstart.md §1 mandate a hermetic ExUnit suite (stub `docker` scripts, stub CLI module). Docker-dependent checks are the by-hand smoke section (`container-smoke.sh engine`).

**Organization**: Grouped by user story. Within a story: tests first (must fail), then implementation.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4, from spec.md
- All commands run through mise: `mise exec -- mix …`. `warnings_as_errors` is on. Prefix git with `rtk`.

## Path Conventions

Single OTP project. Elixir in `lib/autonomous/`, tests in `test/autonomous/`, container runtime in `Dockerfile`, `compose*.yaml`, `scripts/`. Prompt packs in `priv/prompts/`.

---

## Phase 1: Setup

**Purpose**: Governance record and version pins that everything else depends on.

- [X] T001 Amend `.specify/memory/constitution.md` 7.2.0 → 7.3.0 (MINOR, research R10): add one Principle III bullet — an opt-in container-engine sidecar MAY hold elevated privileges; the agent container MUST NOT gain any; the host engine socket MUST NEVER be mounted; the engine sessions control MUST run rootless. Update the Sync Impact Report header and the version line; check `.specify/templates/*` for references needing sync. **Lands first.**
- [X] T002 Choose and verify the pins: current stable `DOCKER_VERSION` (both the `download.docker.com/linux/static/stable/<arch>/docker-<v>.tgz` tarball for x86_64 and aarch64 AND the `docker:<v>-dind-rootless` tag must exist), `COMPOSE_VERSION`, `BUILDX_VERSION` (release assets for both arches). Record the three values in a scratch note for T003/T004 (verify with `curl -fsI` / `docker manifest inspect`).

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Image content, compose overlays and wrapper plumbing shared by every story.

**⚠️ CRITICAL**: No user story starts until this phase is done.

- [X] T003 Add the `WITH_DOCKER` / `DOCKER_VERSION` / `COMPOSE_VERSION` / `BUILDX_VERSION` ARGs and a no-op-unless-`WITH_DOCKER=1` `RUN` block at the end of the `base` stage of `Dockerfile` (after the agent-root block): static `docker` CLI → `/usr/local/bin/docker`, `docker-compose` and `docker-buildx` → `/usr/local/lib/docker/cli-plugins/` (0755), `/etc/autonomous/container-engine` with `docker=`/`compose=`/`buildx=` lines; arch via `uname -m`; no `|| true` (contracts/build-and-compose.md).
- [X] T004 Add the `engine` stage as the last stage of `Dockerfile`: `FROM docker:${DOCKER_VERSION}-dind-rootless AS engine`, `ARG UID`/`GID`, user+group (reuse if existing), `/etc/subuid` + `/etc/subgid` ranges, data-root dir owned `UID:GID`, `USER ${UID}`. Building `dev`/`release` must never build it. (Same file as T003 — after it.)
- [X] T005 [P] Add `WITH_DOCKER: "${WITH_DOCKER:-0}"` to `build.args` of `dev` and `release` in `compose.yaml`. Nothing else changes.
- [X] T006 [P] Create `compose.engine.yaml` per contracts/build-and-compose.md: `engine` service (image `autonomous-engine:local`, `pull_policy: never`, `build` target `engine`, `privileged: true`, `hostname: autonomous`, command `--host=tcp://127.0.0.1:2375 --tls=false`, `DOCKER_TLS_CERTDIR: ""`, sysctl `net.ipv4.ip_unprivileged_port_start=0`, `host.docker.internal:host-gateway`, port `127.0.0.1:${AUTONOMOUS_HOST_PORT:-}:4000`, same-path mounts of `${AUTONOMOUS_REPO}` and `${AUTONOMOUS_ROOT}`, storage volume at the data root, healthcheck `docker -H tcp://127.0.0.1:2375 info` @1s); agent anchor for `dev`/`console`/`release` (`network_mode: "service:engine"`, `hostname`/`ports`/`extra_hosts` `!reset`, `depends_on` engine healthy, `DOCKER_HOST`, `TESTCONTAINERS_HOST_OVERRIDE`, `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` = rootless socket path in sidecar, `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`); top-level volume `autonomous-engine` labelled `dev.autonomous.kind=engine-storage`, `dev.autonomous.segment=${AUTONOMOUS_INSTANCE_SEGMENT}`, no `name:`. No `docker.sock`, no `cap_add`/`devices`/`security_opt` on agents, 2375 never under `ports`.
- [X] T007 [P] Create `compose.engine-viewer.yaml`: `127.0.0.1:${AUTONOMOUS_VIEWER_PORT:-}:6080` on `engine`; `AUTONOMOUS_DISPLAY` and `AUTONOMOUS_DISPLAY_VIEWER` on the agent services (mirror `compose.desktop-viewer.yaml`).
- [X] T008 Wrapper plumbing in `scripts/autonomous`: parse `--docker` (valid on `build`, `shell`, `console`, `release`) and `--engine` (valid only on `reset-cache`); anywhere else → exit 2 unknown option. Define exit codes 77/78 constants and a `compose_at_least 2.24.4` helper (exit 3). `build --docker`: pass `WITH_DOCKER=1`, add `compose.engine.yaml`, also build the `engine` service (`autonomous-engine:local`). Without the flag, docker calls/output unchanged.
- [X] T009 Create `test/autonomous/container_engine_cli_test.exs`: harness that runs the real `scripts/autonomous` against a recording stub `docker` on a private `PATH` (follow `container_volumes_cli_test.exs`). Cases: `build --docker` args (`WITH_DOCKER=1`, engine image built); `--docker` on `stop`/`port` → exit 2; `--engine` outside `reset-cache` → exit 2; no-flag `build`/`console` recorded calls identical to baseline. (Depends on T008.)

**Checkpoint**: Image, overlays and flag parsing exist; no story behaviour yet.

---

## Phase 3: User Story 1 — Sessions can build and run containers (P1) 🎯 MVP

**Goal**: With `--docker`, a session reaches a ready engine through standard `DOCKER_HOST`; compose stacks work; refusal paths are loud; prompts mention the engine.

**Independent Test**: quickstart §2 steps 1–5 and 14 (client present, engine version, worktree mount round-trip, published port reachable, two-service compose stack; no-flag instance unchanged).

### Tests for US1 (write first, must fail)

- [X] T010 [P] [US1] Create `test/autonomous/container_engine_step_test.exs`: drive the real `scripts/container-entrypoint.sh container-engine` hook with a stub `docker` on a private `PATH` — not requested ⇒ silent, `AUTONOMOUS_CONTAINER_ENGINE=0 VERSION=`, **zero** docker calls; requested + reachable ⇒ `=1 VERSION=<v>` and sweep calls; requested + unreachable (`AUTONOMOUS_ENGINE_TIMEOUT=1`) ⇒ exit 78; requested + no `docker` on PATH ⇒ exit 78; inherited `AUTONOMOUS_CONTAINER_ENGINE=1` is ignored; stdout clean (follow `container_agent_root_step_test.exs`).
- [X] T011 [P] [US1] Create `test/autonomous/container_engine_test.exs` (first part): `advertised?/1` true iff `AUTONOMOUS_CONTAINER=1` and `AUTONOMOUS_CONTAINER_ENGINE=1`; `requested?/1` likewise with `…_REQUESTED`; `prompt_note(false) == ""`, `prompt_note(true)` starts `"\n\n"` and contains the `DOCKER_HOST`, worktree-staging and cleanup statements; `probe/1` ok/error/timeout with a stub CLI module.
- [X] T012 [P] [US1] Extend `test/autonomous/phase_request_test.exs`: `container_engine: true` appends the note on `:implement` and `:converge` only (after the agent-root note, before resume/clarify/background-retry); `false` and the default (no env) are byte-identical to pre-046; `build_remediation/3` never carries it; launch env unchanged.
- [X] T013 [US1] Extend `test/autonomous/container_engine_cli_test.exs`: `console --docker` start order (preconditions → `up -d --no-build --pull never --wait --wait-timeout <bound> engine` → agent `up`); image without client ⇒ exit 5 before any container/volume; engine image missing ⇒ 5; Compose < 2.24.4 ⇒ 3; sidecar `up` fails with "privileged"/"operation not permitted" ⇒ `rm -sf engine` then exit 77 naming cause+remedy; unhealthy past bound ⇒ `rm -sf engine` then 78 with last log lines; agent exits 78 after start ⇒ `down` (no `-v`) and code passed through; `shell --docker` runs `run --rm` without exec and `rm -sf engine` on every exit path; `port`/`viewer` iterate project containers (single-container output unchanged); `--viewer` swaps in `compose.engine-viewer.yaml`.

### Implementation for US1

- [X] T014 [US1] Add the `container_engine` step (4e, right after `agent_root`, before warnings) and the `container-engine` smoke hook to `scripts/container-entrypoint.sh` per contracts/entrypoint-step.md: unset advertisement vars first; silent no-op unless `AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`; missing client ⇒ exit 78; poll `docker version --format '{{.Server.Version}}'` up to `${AUTONOMOUS_ENGINE_TIMEOUT:-60}`s ⇒ 78 on timeout; sweep (`rm -f -v` all containers, `network prune -f`, `volume prune -af`; sweep failure only warns); export `AUTONOMOUS_CONTAINER_ENGINE=1` + `_VERSION`; one stderr line. Hook prints `AUTONOMOUS_CONTAINER_ENGINE=<1|0> VERSION=<v>`. Makes T010 pass.
- [X] T015 [US1] Wrapper start sequence for `console`/`release --docker` in `scripts/autonomous` (contracts/wrapper-cli.md): overlay-free `lookup_identity`; preconditions (Compose ≥ 2.24.4, `autonomous-engine:local` present, `docker run --rm --entrypoint sh <image> -c 'command -v docker && docker compose version && docker buildx version'`); existing volume validation / 75 check / port choice; append `compose.engine.yaml` (and `compose.engine-viewer.yaml` instead of `compose.desktop-viewer.yaml` with `--viewer`); `up -d --no-build --pull never --wait --wait-timeout ${AUTONOMOUS_ENGINE_TIMEOUT:-60} engine`; classify failures (case-insensitive match `privileged|operation not permitted|rootless|cannot be run in` ⇒ 77, else/unhealthy ⇒ 78 with last 20 log lines); on failure `rm -sf engine` (keep storage volume); then agent `up`; on agent early exit run `down` without `-v`. (Depends on T008.)
- [X] T016 [US1] `shell --docker` in `scripts/autonomous`: steps as T015, then `compose … run --rm <tty> dev shell` **without `exec`**, `EXIT` trap running `rm -sf engine`, exit with the `run` status.
- [X] T017 [US1] Change `port` and `viewer` in `scripts/autonomous` to iterate the project's running containers and print the first published `4000/tcp` / `6080/tcp` mapping (output unchanged for a single container).
- [X] T018 [P] [US1] Create `priv/prompts/container_engine.md` (contracts/orchestrator.md): engine via `DOCKER_HOST` (`docker`, `docker compose`, `docker buildx`); bind-mount only paths under the worktree/target repo, never `/tmp`/`$HOME`/`/workspace`; published ports on `localhost`, reserved 2375/4000/4369/6080; everything but images/build cache removed at phase end.
- [X] T019 [US1] Add `"container_engine"` to the allow-list in `lib/autonomous/prompts.ex`. (Depends on T018.)
- [X] T020 [P] [US1] Create `lib/autonomous/container_engine/cli.ex`: `@behaviour` with `@callback run([String.t()], timeout_ms :: pos_integer()) :: {:ok, String.t()} | {:error, {:exit, integer(), String.t()}}`; default impl `System.cmd("docker", args, stderr_to_stdout: true)` honoring the timeout, env inherited.
- [X] T021 [US1] Create `lib/autonomous/container_engine.ex` (first part): `advertised?/1`, `requested?/1` (default `System.get_env()`, the only env reads), `prompt_note/1`, `probe/1` (`docker version --format '{{.Server.Version}}'`, 5 s bound, options `:cli`, `:timeout_ms`), `@spec` on all public functions. Makes T011 pass. (Depends on T019, T020.)
- [X] T022 [P] [US1] Add `container_engine_cli/0` (default `Autonomous.ContainerEngine.Cli`) and `container_engine_cleanup_timeout_ms/0` (`120_000`) to `lib/autonomous/config.ex`.
- [X] T023 [US1] Add the `:container_engine` option to `lib/autonomous/phase_request.ex` `build/3`: boolean, lazy default `ContainerEngine.advertised?/0`; appends `ContainerEngine.prompt_note(true)` on `:implement`/`:converge` after the agent-root note and before resume/clarify/background-retry; `false` ⇒ byte-identical. Makes T012 pass. (Depends on T021.)
- [X] T024 [US1] Create the `engine` section of `scripts/container-smoke.sh` with steps 1–5 (client/compose/buildx present; engine reachable + time to ready; worktree mount round-trip with operator-owned file; published port reachable; two-service compose stack with name resolution, relative bind mount, published port and a `build:` service, `up -d --wait`/probe/`down`, nothing left). Prints PASS/FAIL/SKIP per step, names the failing step; honours `SMOKE_IMAGE`.

**Checkpoint**: US1 independently works — `mise exec -- mix test` for T009–T013 green; smoke steps 1–5 pass on a Docker host.

---

## Phase 4: User Story 2 — The host stays out of reach (P1)

**Goal**: Enabling the engine never exposes the host engine, host paths or extra agent privileges.

**Independent Test**: guard test green; smoke steps 6–8.

- [X] T025 [P] [US2] Create `test/autonomous/container_engine_guard_test.exs`: no `docker.sock` string in any `compose*.yaml`, `Dockerfile`, or `scripts/*`; in `compose.engine.yaml` `dev`/`console`/`release` have no `privileged`, `cap_add`, `devices`, `security_opt`; only `engine` has `privileged: true`; `2375` appears under no `ports`; engine mounts only repo, state root and storage volume (no `/workspace`, no `$HOME`); the storage volume has no `name:`.
- [X] T026 [US2] Review `compose.engine.yaml` and `scripts/autonomous` against T025 and fix any violation (FR-004/005/006/007). Makes T025 pass. (Depends on T006, T015, T025.)
- [X] T027 [US2] Add smoke steps 6–8 to the `engine` section of `scripts/container-smoke.sh`: `docker ps -a` from a session lists none of the host's containers; host-side `docker inspect` of the agent shows `Privileged=false`, no `CapAdd`, no `Devices` (same as an instance without `--docker`); `docker run --rm -v /:/host alpine ls /host/home` shows the sidecar filesystem; `--privileged` container cannot mount a host disk; on the host `docker port <engine>` lists only the console port (2375 absent). (After T024.)

**Checkpoint**: US1 + US2 hold together; SC-002 verifiable.

---

## Phase 5: User Story 3 — Lifecycle, persistence and cleanup (P2)

**Goal**: Sidecar follows instance lifecycle; storage persists/purges/resets; per-phase cleanup removes containers/networks/volumes but keeps images and cache.

**Independent Test**: quickstart §2 steps 9–12; hermetic cleanup tests.

### Tests for US3 (write first, must fail)

- [X] T028 [P] [US3] Extend `test/autonomous/container_engine_test.exs` with `cleanup/1`/`after_boundary/3` cases (stub CLI module): not advertised ⇒ `:skipped` with **zero** CLI calls and no log/telemetry; empty listings ⇒ `:clean` (debug log + `[:speckit, :engine, :cleanup]` telemetry); non-empty verification ⇒ `{:residue, counts, cause}`; non-zero exit per `step`; `:timeout` (hung stub) ⇒ residue with unknown (`-1`) counts; stub crash ⇒ `{:crash, reason}`; command order `ps -aq` → `rm -f -v <ids>` (only if non-empty) → `network prune -f` → `volume prune -af` → verification; stub never receives `image prune`/`builder prune`/`system prune`/`rmi`; error log names feature label, phase and residue; `after_boundary/3` returns `:ok`.
- [X] T029 [P] [US3] Create `test/autonomous/feature_runner_engine_test.exs`: exactly one cleanup per phase boundary; `:implement` across N chunks ⇒ one cleanup after the whole chunk loop; also around pre-phase remediation (`:remediation`) and the describe session (`:describe`); cleanup runs when the step raises (then re-raises into the existing catch), on gate divert/fail/deadline/session-death values and under supersession drain; phase outcome identical with clean, residue and crashed cleanup; `engine: [advertised?: false]` ⇒ zero cleanup calls; default suite (no env) ⇒ zero calls.
- [X] T030 [US3] Extend `test/autonomous/container_engine_cli_test.exs`: `stop` adds `compose.engine.yaml` to `down` only when a container labelled `com.docker.compose.project=<project>` + `com.docker.compose.service=engine` exists (running or exited), otherwise recorded calls byte-identical; `stop --purge` additionally removes volumes labelled `dev.autonomous.kind=engine-storage` + segment, printing `<name> removed`; `reset-cache --engine` refuses 75 while a project container exists, prints `engine storage not present` (exit 0) when absent, otherwise removes only that volume and prints `engine storage removed` (failure ⇒ 1), combines with `--volume`, and without `--engine` is unchanged.

### Implementation for US3

- [X] T031 [US3] Implement `cleanup/1` and `after_boundary/3` in `lib/autonomous/container_engine.ex` per contracts/orchestrator.md: command sequence above; whole sequence in `Task.Supervisor.async_nolink(Autonomous.SessionSup, …)` collected with `Task.yield(t, timeout) || Task.shutdown(t, :brutal_kill)`; options `:advertised?`, `:cli`, `:timeout_ms`; result type `:skipped | :clean | {:residue, residue, cause}`; never raises; `Logger.error` text per contract; telemetry `[:speckit, :engine, :cleanup]` (`%{duration}`, `%{feature_id, phase, result, residue}`). Makes T028 pass.
- [X] T032 [P] [US3] Register `[:speckit, :engine, :cleanup]` in the default logger of `lib/autonomous/telemetry.ex`.
- [X] T033 [US3] Wire `FeatureRunner` in `lib/autonomous/feature_runner.ex`: resolve `engine = Keyword.get_lazy(opts, :engine, fn -> [advertised?: ContainerEngine.advertised?()] end)` once in `run/2`; wrap `run_step/8` in `loop/12` with `try … after ContainerEngine.after_boundary(feature, phase, engine) end`; same around the `remediation.run` call in `run_remediation/5` (phase `:remediation`) and the describe call in `commit_message_and_pr` (phase `:describe`). Wrapped return value unchanged; `ChunkRunner`/`Chunking` untouched. Makes T029 pass. (Depends on T031.)
- [X] T034 [US3] Wrapper `stop` in `scripts/autonomous`: detect the engine container by compose labels and add `compose.engine.yaml` to `down`; not found ⇒ byte-identical. (Depends on T015.)
- [X] T035 [US3] Wrapper `stop --purge` in `scripts/autonomous`: after `down -v`, remove every volume labelled `dev.autonomous.kind=engine-storage` + `dev.autonomous.segment=<segment>`, print `<name> removed`. (Same file — after T034.)
- [X] T036 [US3] Wrapper `reset-cache --engine` in `scripts/autonomous` per contracts/wrapper-cli.md (75 guard, label lookup, `engine storage not present` / `engine storage removed`, exit 1 on failure, composable with `--volume`). Makes T030 pass. (After T035.)
- [X] T037 [US3] Add smoke steps 9–12 to `scripts/container-smoke.sh engine`: cleanup boundary with a compose stack up (no containers/networks/volumes left, images kept); pull → `stop` → start keeps the image with no download; `stop --purge` → start is empty; two targets with `--docker` are isolated; `reset-cache --engine` on a stopped instance removes only the storage volume. (After T027.)

**Checkpoint**: US1–US3 independently verifiable; SC-003, SC-005b covered.

---

## Phase 6: User Story 4 — The operator can see it and check it (P3)

**Goal**: Truthful "container engine" row on Configuration; smoke passes for dev and release images.

**Independent Test**: `config_live_test` cases; smoke steps 13–14 and release-image run.

### Tests for US4 (write first, must fail)

- [X] T038 [P] [US4] Create `test/autonomous/web/container_engine_view_test.exs`: `state/1` (`:hidden` when not requested), `summary/1` text — `checking…`, `available — engine <v>`, `unreachable — <cause>`; no `inspect/1` output (G-inspect). Model on `agent_root_view_test.exs`.
- [X] T039 [P] [US4] Extend `test/autonomous/web/config_live_test.exs`: not requested ⇒ no `dt`/`dd`, no probe started, markup byte-identical to the pre-046 rendering; requested ⇒ row shows `checking…` then `available — engine <v>` or `unreachable — <cause>`; probe task crash ⇒ `unreachable — the engine probe crashed — reload to retry`; row placed right after "agent root"; a re-mount re-probes (never a cached healthy value).

### Implementation for US4

- [X] T040 [P] [US4] Create `lib/autonomous/web/container_engine_view.ex` (pure): `state/1`, `summary/1`, `@type state` per data-model.md. Makes T038 pass.
- [X] T041 [US4] Add the row to `lib/autonomous/web/live/config_live.ex` after the "agent root" `<dt>/<dd>` (reuse `config-instance-id`, add `data-container-engine`): assign `:container_engine` from `refresh/1` (`:hidden` unless `ContainerEngine.requested?/0`, else `:checking` + `start_async(:container_engine, fn -> ContainerEngine.probe([]) end)`); `handle_async` mapping ok/error/exit to the states. No new CSS tokens. Makes T039 pass. (Depends on T021, T040.)
- [X] T042 [US4] Finish the `engine` section of `scripts/container-smoke.sh`: steps 13–14 (Configuration row available → `docker stop <engine>` → unreachable; instance without `--docker` has no `engine` container, no `DOCKER_HOST`, no client in an image built without it); confirm the section runs against both images (`SMOKE_IMAGE=autonomous-release:local`) and lists it in the script's usage/help. (After T037.)
- [X] T043 [US4] Run `design_contract_test.exs` to confirm the row introduces no token/literal violations (G-input, G-inspect, G-contrast): `mise exec -- mix test test/autonomous/design_contract_test.exs`.

**Checkpoint**: all four stories independently verifiable.

---

## Phase 7: Polish & Cross-Cutting

- [X] T044 [P] Update `docs/container.md`: the `--docker` build/start options, architecture (privileged rootless sidecar sharing the netns, never the host socket), reserved ports, same-path mount limitation (stage under worktree), rootless limits (non-root file ownership, overlay2 kernel ≥ 5.11, cgroup limits), storage (`stop --purge`, `reset-cache --engine`), exit codes 77/78, `AUTONOMOUS_ENGINE_TIMEOUT`, smoke (FR-016).
- [X] T045 [P] Update `docs/enforcement.md`: Principle III amendment, privileged-sidecar trade-off, rootless rationale, guard test.
- [X] T046 [P] Update `docs/runbook.md`: operator flow for refusal 77/78, residue log line and recovery, storage management, Configuration row meanings.
- [X] T047 [P] Update `/Users/castilho/code/github.com/rzcastilho/autonomous/CLAUDE.md`: new "Container engine sidecar (feature 046)" section in the style of the 037/041 sections; bump constitution reference to 7.3.0.
- [X] T048 Verify FR-017/SC-004: no store schema or persisted record changed (`git diff --stat` shows none under `lib/autonomous/store*`); run full suite `mise exec -- mix test` and `mise exec -- mix compile --warnings-as-errors`; all pre-046 tests pass unchanged.
- [X] T049 Run quickstart.md §1 hermetic list, then §2 smoke on dev and release images (`scripts/autonomous build --docker --release`; `scripts/container-smoke.sh engine`; `SMOKE_IMAGE=autonomous-release:local …`), including the two refusal-path spot checks (exit 5 for client-less image, exit 78 with `AUTONOMOUS_ENGINE_TIMEOUT=1`). (macOS: needs GNU `timeout` + util-linux `script` PATH shims.)
- [X] T050 Tick the checklist in `specs/046-docker-sidecar/checklists/requirements.md` if still open and record SC-001 end-to-end acceptance (quickstart §3) result.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (1)** → **Foundational (2)** → user stories → **Polish (7)**.
- T001 (amendment) lands before any implementation task; T002 before T003/T004.
- Foundational: T003 → T004 (same file); T005, T006, T007 parallel; T008 → T009.

### Story dependencies

- **US1 (P1)**: after Phase 2. MVP.
- **US2 (P1)**: after Phase 2; T026 needs T015 (wrapper start). Guard test T025 can be written immediately after T006.
- **US3 (P2)**: after Phase 2; `cleanup` (T031) needs T021 (module exists); wrapper tasks need T015; `FeatureRunner` wiring needs T031.
- **US4 (P3)**: after Phase 2; T041 needs T021 (`probe/1`).

### Same-file serialization

- `scripts/autonomous`: T008 → T015 → T016 → T017 → T034 → T035 → T036.
- `scripts/container-smoke.sh`: T024 → T027 → T037 → T042.
- `container_engine_cli_test.exs`: T009 → T013 → T030.
- `container_engine_test.exs`: T011 → T028. `container_engine.ex`: T021 → T031.
- `Dockerfile`: T003 → T004.

### Parallel opportunities

- Phase 2: T005 ‖ T006 ‖ T007.
- US1 tests: T010 ‖ T011 ‖ T012; impl: T018 ‖ T020 ‖ T022 (then T019, T021, T023).
- US2: T025 can run alongside US1 impl.
- US3 tests: T028 ‖ T029; T032 ‖ others. US3 Elixir track (T031→T033) ‖ wrapper track (T034→T036).
- US4: T038 ‖ T039 ‖ T040.
- Polish: T044 ‖ T045 ‖ T046 ‖ T047.
- Stories can proceed in parallel after Phase 2 if the same-file serialization above is respected.

### Parallel example: User Story 1

```bash
# Tests together:
Task: "container_engine_step_test.exs (entrypoint hook, stub docker)"      # T010
Task: "container_engine_test.exs advertised?/requested?/prompt_note/probe" # T011
Task: "phase_request_test.exs container_engine option cases"               # T012
# Independent implementation files together:
Task: "priv/prompts/container_engine.md"                                   # T018
Task: "lib/autonomous/container_engine/cli.ex"                             # T020
Task: "lib/autonomous/config.ex accessors"                                 # T022
```

## Implementation Strategy

### MVP first (US1)

1. Phase 1 (amendment first) → Phase 2 → Phase 3 (US1).
2. **Stop and validate**: hermetic tests T009–T013 green; smoke steps 1–5 on a Docker host.
3. Add US2 (guard + security smoke) before any release use — it is P1 because it protects the Principle III boundary.

### Incremental delivery

1. Setup + Foundational → image/overlays ready.
2. US1 → engine usable. US2 → boundary proven. US3 → lifecycle + cleanup. US4 → operator visibility. Polish → docs + full verification.
3. Each story adds value without changing the engine-off path (SC-004); re-run the full suite after each story.

## Notes

- Engine-off behaviour must stay byte-identical: every task touching the wrapper, entrypoint, `PhaseRequest`, `FeatureRunner` and `ConfigLive` has a "no flag ⇒ unchanged" test.
- Cleanup never changes a phase outcome and never removes images or build cache.
- Behaviour/semantic changes beyond this spec go through a new `/speckit-specify`, not edits here.
- Commit per task or logical group (`rtk git …`).
