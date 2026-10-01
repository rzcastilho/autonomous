---

description: "Task list for 031-containerized-runtime"
---

# Tasks: Always-Containerized Runtime

**Input**: Design documents from `/specs/031-containerized-runtime/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R15), data-model.md, contracts/ (wrapper-cli, environment, boot-guard, instance-identity, compose-services, hook-allowlist), quickstart.md

**Tests**: Included only where the plan names them (`container_guard_test`, `instance_test`, `scope_guard_test` additions, config precedence test) plus `scripts/container-smoke.sh` for container-level checks. Elixir commands run through `mise exec --` (CLAUDE.md); `warnings_as_errors` is on; prefix git/gh with `rtk`.

**Organization**: Grouped by user story. The container image/entrypoint skeleton needed by every story lives in Foundational; each story adds its own increment on top.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US6 (spec.md); Setup/Foundational/Polish carry no label

## Path Conventions

Single OTP project. New container files at repo root (`Dockerfile`, `compose*.yaml`, `scripts/`, `rel/`), Elixir under `lib/autonomous/`, tests under `test/autonomous/`, docs under `docs/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Ignore files, templates and script skeleton directories.

- [x] T001 [P] Add `.env` to `/.gitignore` (FR-015); keep `.env.example` tracked
- [x] T002 [P] Create `/.dockerignore` excluding `_build`, `deps`, `.env`, `.git`, `.elixir_ls`, `*.beam`, `specs/`, `docs/` build noise (never `mise.toml`, `mix.exs`, `mix.lock`, `config/`, `lib/`, `priv/`, `rel/`)
- [x] T003 [P] Create `/.env.example` listing every operator-supplied variable from `contracts/environment.md` ("Operator-supplied" table) with comments, no real values; note that `AUTONOMOUS_REPO`/`AUTONOMOUS_ROOT` are ignored and `AUTONOMOUS_PR_WORKFLOW`/`AUTONOMOUS_MAX_CONCURRENCY` must be absent
- [x] T004 [P] Create empty executable `scripts/autonomous`, `scripts/container-entrypoint.sh`, `scripts/container-smoke.sh` (`#!/bin/sh`, `set -eu`, usage stub) so later tasks edit existing files

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure identity/guard logic, config wiring and the dev image/compose skeleton. No story can run in a container until this is done.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Elixir boot boundary (R1, R2, R3, R9)

- [x] T005 [P] Write `test/autonomous/instance_test.exs`: `derive/3` determinism; SSH vs HTTPS origin ⇒ same identity; two repos ⇒ distinct `segment`/`node_name`/`store_dir`; `store_dir` never inside `repo`; property test that `node_name` is a valid short node name for arbitrary repo names (dots, unicode); `verify!/0` error terms (`{:instance_unlocked, _}`, `{:instance_mismatch, :node|:store_dir, _, _}`) and no-op when not containerized; container-mode branches tested through the pure `verify/2` and `served?/2` cores with explicit env/identity inputs, never by flipping global config (contracts/instance-identity.md, boot-guard.md)
- [x] T006 [P] Write `test/autonomous/container_guard_test.exs`: `decide/2` matrix (marker `"1"`/other/nil × required true/false), the `containerized?/0` truth table (marker `"1"` + `require_container: false` ⇒ `false`, so `mix test` inside the image behaves like the host suite), and exact refusal message from contracts/boot-guard.md
- [x] T007 [P] Create `lib/autonomous/container_guard.ex`: pure `decide/2`, `check!/0` (reads `AUTONOMOUS_CONTAINER` + `:require_container`), `containerized?/0` = `require_container and marker == "1"` (never the marker alone), refusal text exactly per contract; `@spec` on every public function
- [x] T008 Create `lib/autonomous/instance.ex`: `%Autonomous.Instance{}`, pure `derive/3`, `current/0` (`RepoIdentity.partition(Config.repo())`, `Config.autonomous_root()`), `print_env/0`, pure `verify/2` (env map + derived identity ⇒ `:ok | {:error, term}`) wrapped by `verify!/0` (lock → node → store_dir order), pure `served?/2` wrapped by `assert_served!/1`, both no-op unless `ContainerGuard.containerized?/0`; `@spec` on every public function; `Autonomous.Instance.NotServedError` (messages per contracts/boot-guard.md)
- [x] T009 [P] Create `lib/mix/tasks/autonomous.instance.ex`: `--repo`, `--root`, `--format env|segment|json`; `@requirements []` (does not start the app); exit 1 with message when `--repo` is not a git repository
- [x] T010 Wire `lib/autonomous/application.ex` `start/2`: call `ContainerGuard.check!/0` first, then `check_no_retired_settings!/0`, then `Instance.verify!/0`, then `Store.Boot.start!/0` (contracts/boot-guard.md order)
- [x] T011 Edit `config/config.exs`: default `config :autonomous, require_container: true`; in the `:test` block set `require_container: false` (the only override, FR-004)
- [x] T012 Edit `config/runtime.exs` (non-test): read `AUTONOMOUS_REPO` → repo, `AUTONOMOUS_ROOT` → `:autonomous_root`, `AUTONOMOUS_STORE_DIR` → `:store_dir`, `AUTONOMOUS_CONSOLE_IP`/`PORT`/`HOST`, `PHX_SERVER=true` → endpoint `server: true`, `check_origin: ["//localhost", "//127.0.0.1"]`; in `:prod` raise naming `AUTONOMOUS_SECRET_KEY_BASE` when unset or < 64 bytes (message per contracts/boot-guard.md); keep retired-env refusals ahead of everything
- [x] T013 [P] Edit `lib/autonomous/config.ex` docs for `store_dir/0` to state that `AUTONOMOUS_STORE_DIR` yields `<state_root>/instances/<segment>/mnesia` (default path unchanged for host/test)

### Image and compose skeleton (R7, R13)

- [x] T014 Create `/Dockerfile` stages `base` (debian:bookworm-slim, git, python3, util-linux, ca-certificates, `ENV AUTONOMOUS_CONTAINER=1`, `ENV AUTONOMOUS_CONSOLE_IP=0.0.0.0`, `ARG UID/GID` user `autonomous`, `git config --system safe.directory '*'`, pinned `gh` via `ARG GH_VERSION`, Node via `ARG NODE_MAJOR`, pinned `@anthropic-ai/claude-code` via `ARG CLAUDE_CODE_VERSION`) and `toolchain` (build deps, mise, copy only `mise.toml`, `mise install`) — no Erlang/Elixir version restated (FR-010, FR-011, FR-006)
- [x] T015 Add `dev` stage to `/Dockerfile` (from `toolchain`; mise data baked in; `WORKDIR /workspace`; entrypoint `scripts/container-entrypoint.sh`; source is bind-mounted, not copied) — depends on T014
- [x] T016 Create `scripts/container-entrypoint.sh` core sequence per contracts/compose-services.md: step 0 (dev shape) runs `mise exec -- mix deps.get` when the `deps/` marker does not match the current `mix.lock` hash, then `mise exec -- mix compile` (`MIX_ENV=test` for `test`), exiting non-zero with Mix's message on failure; then derive identity (`mise exec -- mix autonomous.instance --format env`) and export; `mkdir -p` instance dir; `exec 9>"$AUTONOMOUS_INSTANCE_LOCK"; flock -n 9` else read `instance.json` and exit 75 with "target … is already served by …" (skipped for `test`); write `instance.json`; create `cookie` 0600 if absent; export `AUTONOMOUS_INSTANCE_LOCKED`; dispatch `segment` (print `mix autonomous.instance --format segment` and exit: no lock, no `instance.json`, no VM), `shell`/`console`/`test …` with `--sname`/`--cookie` and `exec` (fd 9 inherited) — depends on T009
- [x] T017 Create `/compose.yaml` services `dev` and `console` (image target `dev`, explicit `image: autonomous-dev:local` so every per-target project reuses one build; `hostname: autonomous`, `user: ${UID}:${GID}`, `env_file: .env` optional, `shm_size: 1gb`, `init: true`, entrypoint script; same-path mounts for `${AUTONOMOUS_REPO}` and `${AUTONOMOUS_ROOT}`; `/workspace` bind mount; named volumes `autonomous-build`, `autonomous-deps` declared **without** `name:` so Compose scopes them per project (no shared `_build` between concurrent instances); port `127.0.0.1:${AUTONOMOUS_HOST_PORT:-}:4000`; `PHX_SERVER=true`; no privileged/caps/host network) — depends on T015, T016

**Checkpoint**: `mise exec -- mix test` green on host; image builds; identity task prints env.

---

## Phase 3: User Story 1 - Operator runs the orchestrator only inside a container (Priority: P1) 🎯 MVP

**Goal**: One documented command opens the operator shell in the container against a sibling target; direct host starts are refused.

**Independent Test**: `scripts/autonomous build` then `shell --target <sibling repo>`; run one backlog feature, PR opened. Separately `iex -S mix` on host is refused with no store written.

### Implementation for User Story 1

- [x] T018 [US1] Implement `scripts/autonomous` core: arg parsing (`--target`, `--port`, `--with-login`, `--viewer`, `--android`), `realpath` target, exit 2/3/4 per contracts/wrapper-cli.md (Compose v2 check, git-repo check), export `AUTONOMOUS_REPO`, `AUTONOMOUS_ROOT=$HOME/.autonomous`, `UID`/`GID`, `AUTONOMOUS_HOST_PORT`; warn if `.env` sets `AUTONOMOUS_REPO`/`AUTONOMOUS_ROOT`
- [x] T019 [US1] Implement wrapper commands `build`, `shell`, `test`, `stop [--purge]` in `scripts/autonomous` per contracts/wrapper-cli.md: segment lookup via `docker compose -p autonomous-bootstrap run --rm --no-deps -T dev segment` with `AUTONOMOUS_REPO`/`AUTONOMOUS_ROOT` exported (never shell-computed); Compose project `autonomous-<segment>`; `build` tags `autonomous-dev:local` (and `autonomous-release:local` with `--release`); instance commands never build and exit 5 naming `scripts/autonomous build` when the image is missing; `stop --purge` adds `down -v`; `shell` uses `run --rm --service-ports dev shell`; `test` runs `dev mise exec -- mix test …`)
- [x] T020 [US1] Print start summary (target, instance node, console address via `docker compose port`, per-instance budget note — FR-018b) in `scripts/autonomous`; translate Docker's busy-port failure to exit 76 `console port <n> is already in use on 127.0.0.1` (FR-021)
- [x] T021 [P] [US1] Add credentials/identity setup to `scripts/container-entrypoint.sh`: `gh auth setup-git` when `GH_TOKEN` set; `git config --global url."https://github.com/".pushInsteadOf git@github.com:`; warnings when neither `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` nor mounted login, and when model pins unset (FR-012–FR-016)
- [x] T022 [P] [US1] Create `/compose.claude-login.yaml` mounting host `~/.claude` and `~/.claude.json` into `/home/autonomous/` (opt-in, FR-012); wrapper adds it on `--with-login`
- [x] T023 [P] [US1] Add a test (new `describe` in `test/autonomous/worktree_test.exs`, or the nearest existing Worktree test file) asserting `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env take precedence over the `-c user.*` that `Worktree.commit/2` passes (R8, FR-014)
- [x] T024 [US1] In `lib/autonomous.ex` add private `served_repo(opts)` (reads `:repo` with `Config.repo()` default, calls `Instance.assert_served!/1`, returns it) and replace every `Keyword.get(opts, :repo, Config.repo())` with it (covers `find_parked_run/1`, `build_prune_plan/1`, `guard_repo_id/1`, `gather_taken_ids/1`, and inline reads in `pending_questions/1`, `answer/4`, `run_history/1`, `export_run/3`, `run_detail/2`, `record_pr/3`); add direct `assert_served!/1` at the top of `workers/1`, `current_run_id/1`, `resumable/1`. Guarded surface per contracts/boot-guard.md table: `run/1`, `run_spec/2`, `preview_single_spec/2`, `workers/1`, `current_run_id/1`, `resumable/1`, `pending_questions/1`, `answer/4`, `continue_run/1`, `end_run/1`, `resume/2`, `resume_run/1`, `run_history/1`, `run_detail/2`, `export_run/3`, `recover_record/1`, `prune_preview/1`, `prune/1`, `record_pr/3`, `resolve_escalation/2` (FR-007, R5)
- [x] T025 [US1] Add `served?/2`/`assert_served!/1` cases to `test/autonomous/instance_test.exs` (path and partition-string forms, mismatch raises `NotServedError` naming both, no-op when guard off) and a facade test `test/autonomous/facade_served_test.exs`: one case per function in the T024 list passing a foreign repo in container mode (via an injected served identity, not global config) expecting `NotServedError`, plus a source check that `Keyword.get(opts, :repo` appears in `lib/autonomous.ex` only inside `served_repo/1` — depends on T024
- [x] T026 [US1] Add `scripts/container-smoke.sh` checks for US1: host start refused (`iex -S mix` / `mix phx.server` exit non-zero with the contract message and no `instances/` or `mnesia` written), host `mix test`/`mix compile` still run, in-container `mix test` passes (SC-002, SC-003). Also: `claude --version` resolves on `PATH` as user `autonomous` and `System.find_executable("claude")` is non-nil inside the VM (FR-011); one orchestrated `strict` hook call made with the session env the orchestrator sets (`AUTONOMOUS_ORCHESTRATED`, `AUTONOMOUS_CONTAINMENT_PROFILE=strict`) on an out-of-tree write is denied naming profile and rule (FR-009); agent auth smoke for SC-011/FR-012: one sample `claude -p` call succeeds with token only, with `--with-login` only, and with both present the CLI-reported auth source is the token
- [x] T027 [US1] Update `docs/runbook.md`: container is the primary run path (build, shell, credentials, same-path rule, `--with-login`, state note, budget-per-instance note); keep host section for compile/test only (FR-030)

**Checkpoint**: US1 independently usable and testable (SC-001, SC-002, SC-003; SC-004 manual per quickstart).

---

## Phase 4: User Story 2 - Run state survives container restarts and recreation (Priority: P1)

**Goal**: Stable node identity and store across stop/remove/recreate/rebuild; worktrees valid from host; second instance for the same target refused.

**Independent Test**: Start a run, halt a feature, `stop`, rebuild image, start again: history listed, feature resumes; `git -C <target> worktree list` valid from host.

### Implementation for User Story 2

- [x] T028 [US2] Verify and harden the entrypoint lock/ownership path in `scripts/container-entrypoint.sh`: lock held by the VM lineage (fd 9 inherited via `exec`), `instance.json` fields per data-model.md (segment, repo, compose_project, service, started_at, console_port, image), exit 75 message names target and live instance (FR-018a)
- [x] T029 [P] [US2] Verify `hostname: autonomous` on every service in `/compose.yaml` and that `Instance.verify!/0` refuses an ad hoc `--sname` with `{:instance_mismatch, :node, …}` before Mnesia opens; add that case to `test/autonomous/instance_test.exs` (spec edge case)
- [x] T030 [P] [US2] Audit live write paths for `cwd`-relative roots inside the container (legacy `worktree_root` default `../.speckit-worktrees`, R6): `grep -rn 'speckit-worktrees\|File.cwd' lib/`; fix any live path or record in `docs/container.md` that none exists
- [x] T031 [US2] Extend `scripts/container-smoke.sh` for US2: recreate instance from rebuilt image and assert no `schema_node_mismatch`, history listed; second instance for same target exits 75 naming the live instance; two different targets run concurrently with distinct ports (SC-005, SC-007a); worktree validity via `git -C <target> worktree list` from host (SC-006)
- [x] T032 [P] [US2] Document the fresh-store behaviour (FR-020: old `~/.autonomous/mnesia` neither read nor deleted; worktrees/exports stay), the `flock`-on-local-filesystem limit (R4), and same-path rule in `docs/container.md` (new file; later phases append sections)

**Checkpoint**: US1 + US2 both work; resume after recreation verified.

---

## Phase 5: User Story 3 - Operator watches the run from the web console (Priority: P2)

**Goal**: Console reachable from the operator's machine only, port chosen or random and printed.

**Independent Test**: `scripts/autonomous console --target <repo>`; open printed address; second machine refused.

### Implementation for User Story 3

- [x] T033 [US3] Implement wrapper commands `console` (detached `up -d console`) and `port` in `scripts/autonomous`; print address after start; support `--port`/random (R9)
- [x] T034 [P] [US3] Finish the `console` dispatch in `scripts/container-entrypoint.sh` (`elixir --sname … --cookie … -S mix phx.server`) — confirm `PHX_SERVER=true` reaches the endpoint via `runtime.exs` (T012)
- [x] T035 [P] [US3] Show served repository and instance node in the Configuration view (mono, real identifiers; no new colors — Principle VII): edit the Configuration LiveView under `lib/autonomous/web/` and keep `test/autonomous/design_contract_test.exs` green
- [x] T036 [US3] Extend `scripts/container-smoke.sh`: console responds on printed loopback address; published binding is `127.0.0.1` (not `0.0.0.0`); busy `--port` yields exit 76 (SC-007, FR-021); second-machine reachability stays a manual step in `quickstart.md`

**Checkpoint**: US3 verified independently.

---

## Phase 6: User Story 4 - Self-contained release image (Priority: P2)

**Goal**: `mix release` image, no toolchain at runtime, console served, remote console attachable, history persists.

**Independent Test**: Build release, start with `.env`, `remote`, check status, restart, check status.

### Implementation for User Story 4

- [x] T037 [US4] Add `releases: [autonomous: [include_executables_for: [:unix], applications: [autonomous: :permanent]]]` to `mix.exs`
- [x] T038 [P] [US4] Create `rel/env.sh.eex` (`RELEASE_DISTRIBUTION=sname`, `RELEASE_NODE=$AUTONOMOUS_NODE_NAME`, `RELEASE_COOKIE=$(cat $AUTONOMOUS_COOKIE_PATH)`) and `rel/vm.args.eex` only if release defaults need it (R10)
- [x] T039 [US4] Add `build` and `release` stages to `/Dockerfile`: `build` compiles `MIX_ENV=prod mix release` from `toolchain`; `release` copies the release onto `base` (+ tools/capabilities, not `toolchain`): no mise, no Elixir sources at runtime — depends on T014, T037, T038
- [x] T040 [US4] Add service `release` to `/compose.yaml` (image target `release`, `image: autonomous-release:local`, command `release`, same hostname/user/mounts minus `/workspace`, same port mapping) — depends on T039
- [x] T041 [US4] Add `release` dispatch to `scripts/container-entrypoint.sh` (derive identity via `bin/autonomous eval 'Autonomous.Instance.print_env()'`, then `exec bin/autonomous start`; `segment` command via `eval`, used by the wrapper's lookup against the release image) and wrapper commands `release` and `remote` (`exec release bin/autonomous remote`) in `scripts/autonomous`
- [x] T042 [US4] Extend `scripts/container-smoke.sh`: release refuses without `AUTONOMOUS_SECRET_KEY_BASE` naming it (US3 scenario 3, FR-022); release starts, `remote` attaches, restart keeps history with no node mismatch (SC-008)
- [x] T043 [P] [US4] Document release shape, secret generation (`openssl rand -base64 48`) and remote console in `docs/container.md` and `docs/runbook.md`

**Checkpoint**: US4 verified independently.

---

## Phase 7: User Story 5 - Orchestrated sessions test web and desktop applications (Priority: P2)

**Goal**: Opt-in web (3 engines) and desktop (Xvfb + xdotool + screenshots + optional viewer) capabilities usable from `strict` sessions.

**Independent Test**: Build with `--web --desktop`; run sample Playwright test in 3 engines and a sample click+screenshot, both from a `strict` orchestrated session; build without options and confirm components absent.

### Tests for User Story 5

- [ ] T044 [P] [US5] Extend `test/autonomous/scope_guard_test.exs` (real hook, origin `orchestrated`, profile `strict`, tool `Bash`) with the full matrix from `contracts/hook-allowlist.md`: allow `emulator … > /dev/null 2>&1 &`, `npx playwright test 2>/dev/null`, `xvfb-run -a npm test &>/dev/null`, `> /dev/stdout`/`> /dev/stderr`, `adb shell input tap 10 10`, `import -window root shot.png`, `./gradlew connectedAndroidTest`; deny `> /dev/sda`, `> /dev/nullx`, `> /dev/null/../../etc/passwd`, `> /tmp/x` (`bash_redirect_outside_worktree`) and `curl http://x > /dev/null` (`bash_curl`); all existing cases unchanged; `permissive`/`interactive` rows allow (SC-010)

### Implementation for User Story 5

- [ ] T045 [US5] Edit `priv/target_pack/.claude/hooks/scope_guard.py` `check_bash/2`: add `DEVICE_SINKS = {"/dev/null", "/dev/stdout", "/dev/stderr"}`; skip a redirect whose captured target matches exactly, before `within(root, target)`; no other rule/order/profile change; `PACK_CONTRACT` stays 3 (R12) — makes T044 pass
- [ ] T046 [P] [US5] Add `WITH_WEB` block to `/Dockerfile`: `ARG PLAYWRIGHT_VERSION`; `RUN if [ "$WITH_WEB" = 1 ]; then npx playwright@… install --with-deps chromium firefox webkit; fi` into `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` (world-readable); `ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` (FR-024)
- [ ] T047 [US5] Add `WITH_DESKTOP` block to `/Dockerfile` (after T046, same file): `xvfb`, `xdotool`, `imagemagick`, `x11vnc`, `novnc`, `websockify`, `dbus-x11`, fonts, Electron libs (`libnss3`, `libgtk-3-0`, `libasound2`, `libgbm1`, `libxss1`) behind `if [ "$WITH_DESKTOP" = 1 ]`; no-op when off (FR-023)
- [ ] T048 [US5] Add display handling to `scripts/container-entrypoint.sh`: `AUTONOMOUS_DISPLAY=1` starts `Xvfb :99` and exports `DISPLAY=:99`; `AUTONOMOUS_DISPLAY_VIEWER=1` starts x11vnc + websockify/noVNC on 6080 (FR-025)
- [ ] T049 [P] [US5] Create `/compose.desktop-viewer.yaml` (`127.0.0.1:${AUTONOMOUS_VIEWER_PORT:-}:6080`, `AUTONOMOUS_DISPLAY_VIEWER=1`); wrapper `--viewer` adds it; `shm_size: 1gb` already in base compose
- [ ] T050 [US5] Wire `build --web --desktop` options in `scripts/autonomous` to `--build-arg WITH_WEB/WITH_DESKTOP`
- [ ] T051 [US5] Extend `scripts/container-smoke.sh`: with all capabilities off, listed binaries (`xvfb-run`, `xdotool`, `playwright` browsers dir, `emulator`) absent (SC FR-023/US5-5); with web on, sample test in 3 engines passes offline; with desktop on, sample click + screenshot written (SC-009)
- [ ] T052 [P] [US5] Document in `docs/container.md`: capability→build-option map, Playwright version match, Chromium sandbox workaround (`chromiumSandbox: false`, no extra privileges), dependency pre-fetch procedure (FR-027a), iOS/macOS/Windows on external runner (FR-028)

**Checkpoint**: US5 verified; `scope_guard_test` green with unchanged denials.

---

## Phase 8: User Story 6 - Orchestrated sessions test Android applications (Priority: P3)

**Goal**: Headless in-container emulator with `/dev/kvm`, or host adb fallback; clear failure naming both options.

**Independent Test**: Build `--android`; start emulator with kvm override and run a sample instrumented test; repeat with host fallback; with neither, see the two-option message.

### Implementation for User Story 6

- [ ] T053 [US6] Add `WITH_ANDROID` block to `/Dockerfile`: JDK 17, Android cmdline-tools, `platform-tools`, `emulator`, `ARG ANDROID_SYSTEM_IMAGE` (pinned), AVD created at build time under `/opt/android`, `ENV ANDROID_HOME=/opt/android`; no-op when off
- [ ] T054 [P] [US6] Create `scripts/android-emulator` (on `PATH`): with `/dev/kvm` start `emulator -no-window -no-audio -accel on`, wait `adb wait-for-device` + `sys.boot_completed`; else use `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037`; with neither, exit non-zero naming both options (FR-026)
- [ ] T055 [P] [US6] Create `/compose.android.yaml` (`devices: ["/dev/kvm"]`, `group_add` kvm gid, `extra_hosts: ["host.docker.internal:host-gateway"]`); wrapper `--android` at start adds it, `build --android` sets `WITH_ANDROID=1`
- [ ] T056 [US6] Extend `scripts/container-smoke.sh`: emulator boots with kvm; host-adb fallback works; neither ⇒ message naming both options (SC-009 Android modes)
- [ ] T057 [P] [US6] Document Android modes, kvm group id, host adb fallback and image-size note in `docs/container.md`

**Checkpoint**: All six stories independently functional.

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T058 [P] Update `docs/enforcement.md`: container layer is now real; record open gaps — no egress restriction (FR-029), package-manager downloads (`npm install`/`pip install`/`mix deps.get`) not denied by the hook, `bash_curl`/`bash_wget` anchored at command start (R12 recorded gap)
- [ ] T059 [P] Update `README.md` and `CLAUDE.md`: contributor guide points at the container for operation, host remains valid for `mise exec -- mix compile|test`; correct Phase list/status lines as needed
- [x] T060 Align spec FR-027 and the edge-case wording ("the download is denied by the hook") with the R12 finding in `specs/031-containerized-runtime/spec.md`, and record the package-manager gap in plan.md Complexity Tracking (done during `/speckit-analyze` remediation)
- [ ] T061 Implement secret scan (R15, SC-012) in `scripts/container-smoke.sh`: `docker history --no-trunc`, `docker save | tar -x` + grep for values from local `.env` (never printed), `git grep` for the same values
- [ ] T062 Run full host suite: `mise exec -- mix test` and `mise exec -- mix test --cover`; confirm warnings-as-errors clean and `design_contract_test` green
- [ ] T063 Run `quickstart.md` end to end (including manual SC-004 smoke run and SC-007 second-machine check) and record outcome

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (1)**: none.
- **Foundational (2)**: after Setup; blocks all stories.
- **US1 (3)** and **US2 (4)**: after Foundational (both P1). US2 hardens pieces US1 first lays down (entrypoint lock), so run US1 → US2 sequentially unless one person owns the entrypoint.
- **US3 (5)**: after Foundational; independent of US1/US2 except shared wrapper/entrypoint files.
- **US4 (6)**: after Foundational; independent of US3.
- **US5 (7)**: after Foundational; hook work (T044, T045) has no container dependency and can start any time after Setup.
- **US6 (8)**: after Foundational; shares `/Dockerfile` with US5 (different `RUN` blocks) — coordinate edits.
- **Polish (9)**: after desired stories.

### Within Foundational

T005/T006 (tests) before/alongside T007/T008; T008 → T009 → T016; T007+T008 → T010; T014 → T015 → T017; T016 → T017.

### Shared-file conflicts (do not mark [P] across these)

`scripts/autonomous` (T018–T020, T033, T041, T050, T055), `scripts/container-entrypoint.sh` (T016, T021, T028, T034, T041, T048), `/Dockerfile` (T014, T015, T039, T046, T047, T053), `/compose.yaml` (T017, T029, T040), `scripts/container-smoke.sh` (T026, T031, T036, T042, T051, T056, T061), `docs/container.md` (T032, T043, T052, T057), `test/autonomous/instance_test.exs` (T005, T025, T029), `lib/autonomous.ex` (T024).

---

## Parallel Example: Foundational

```bash
# Independent files, can run together after Setup:
Task: "T005 test/autonomous/instance_test.exs"
Task: "T006 test/autonomous/container_guard_test.exs"
Task: "T007 lib/autonomous/container_guard.ex"
Task: "T013 lib/autonomous/config.ex docs"
```

## Parallel Example: US5

```bash
Task: "T044 test/autonomous/scope_guard_test.exs matrix"
Task: "T046 Dockerfile WITH_WEB block"
Task: "T049 compose.desktop-viewer.yaml"
```

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US1.
2. **STOP and VALIDATE**: host start refused; shell opens in container; `mix test` passes in both places; one sibling-target feature opens a PR (SC-001–SC-004).

### Incremental Delivery

1. Setup + Foundational → image builds, identity derives.
2. US1 (MVP) → US2 (state survives; completes both P1s) → US3 (console) → US4 (release) → US5 (web/desktop + hook) → US6 (Android) → Polish.
3. Each story adds value without breaking earlier ones; hook change (US5) only removes a `strict` denial for three device sinks.

### Notes

- Elixir identity derivation lives only in Elixir (`Instance`); shell never recomputes it (plan Complexity Tracking).
- No Mnesia schema change; old `~/.autonomous/mnesia` is never opened or deleted (FR-020).
- Commit after each task or logical group; stop at any checkpoint to validate.
