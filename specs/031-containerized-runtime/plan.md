# Implementation Plan: Always-Containerized Runtime

**Branch**: `031-containerized-runtime` | **Date**: 2026-10-01 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/031-containerized-runtime/spec.md`

## Summary

Make a Docker container the only supported way to *operate* the orchestrator, while
`mix compile` and `mix test` keep working on the host. Two run shapes share one
multi-stage `Dockerfile`: a **dev** shape (mounted source, `iex -S mix` /
`mix phx.server` through the same `mise.toml`) and a **release** shape
(`mix release`, console served, remote console attachable). One wrapper script,
`scripts/autonomous`, is the documented entry point; it derives the instance
identity from the target repository, takes the per-target lock, picks the console
port and starts Compose.

Elixir-side changes are small and sit at the boot boundary:

- `Autonomous.ContainerGuard` refuses boot outside the image marker
  (`AUTONOMOUS_CONTAINER=1`) before the store opens; disabled only by the test
  config (FR-004/005).
- `Autonomous.Instance` derives, from the target repository identity
  (`RepoIdentity`), the per-target store directory, node name, lock path and
  cookie path; at boot it verifies that `node()`, `Config.store_dir/0` and the
  held lock match that derivation (FR-018/018a), and it guards facade calls that
  name a repository (FR-007).
- `config/runtime.exs` gains the console, state-root and instance env vars; the
  release refuses to start without `AUTONOMOUS_SECRET_KEY_BASE` (FR-022).
- `scope_guard.py` gains one narrow allowance: redirects to `/dev/null`,
  `/dev/stdout`, `/dev/stderr` (FR-027); every red-team case stays denied.

Testing capabilities (web, desktop, Android) are independent build args whose
`RUN` steps are no-ops when off (FR-023). Details: [research.md](research.md).

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28, Erlang/OTP 28.5.0.6 (both from `mise.toml`, installed inside the image by mise); POSIX shell for the entrypoint and wrapper; Python 3 for the existing hook.

**Primary Dependencies**: Existing app deps unchanged. Image tools: git, `gh` (pinned), python3, Node.js (pinned major, tool runtime for the CLI only), `@anthropic-ai/claude-code` (pinned), `util-linux` `flock`. Opt-in: Playwright browsers; Xvfb + xdotool + ImageMagick + x11vnc/noVNC; JDK 17 + Android SDK cmdline-tools/platform-tools/emulator + one pinned system image.

**Storage**: Mnesia, unchanged engine; per-target directory `<state_root>/instances/<segment>/mnesia` (new path, fresh store, FR-020).

**Testing**: ExUnit (default hermetic suite + `--include integration`); the existing `scope_guard_test` red-team matrix extended; new container smoke checks are a documented shell script (`scripts/container-smoke.sh`) run by hand / opt-in, not by the default suite.

**Target Platform**: Linux host, Docker Engine + Compose v2 (only supported engine).

**Project Type**: OTP application + LiveView console, packaged as container images.

**Performance Goals**: N/A (operational packaging). First build may be slow (Erlang compiled by mise); later builds cached.

**Constraints**: No secret in any layer (FR-015); non-root user with build-time UID/GID (FR-006); same-path mounts for target and state root (FR-017/019); no network egress restriction (FR-029); no extra container privileges by default.

**Scale/Scope**: One target per instance; several instances per host concurrently (SC-007a).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle / rule | Assessment |
|---|---|
| I. Pure core, isolated contracts | Pass. `ContainerGuard.decide/2` and `Instance.derive/2` are pure (inputs: env map, config, repo identity string); the IO (`System.get_env`, git origin read, lock probe) sits in thin `check!/0`/`verify!/0` wrappers. Pure-core modules untouched. |
| II. Fail loud at boundaries | Pass. Host start, missing lock, node/store mismatch, second instance, foreign-repo API call, release without secret, busy console port: each refuses by name. Retired-settings refusals unchanged. |
| III. Least-privilege containment | Pass. The container *is* the "container recipe" layer. `strict` hook gains only a redirect-to-device-file allowance; red-team cases unchanged (SC-010). `permissive` unchanged. Session markers unchanged. Egress stays open — recorded as an open gap (FR-029), not a relaxation of the hook. |
| IV. Cost-bounded autonomy | Pass. Ledger unchanged, per instance (FR-018b); start output states that spend sums across instances. |
| V. Human-in-the-loop | Not affected. |
| VI. Idiomatic Elixir/OTP | Pass. Boot checks are tagged-tuple functions called before `Store.Boot.start!/0`; raising only at the boot boundary, consistent with existing `check_no_retired_settings!/0`. |
| VII. Operator surfaces | Pass. Console unchanged; the Configuration view may show the served repository and instance node (mono, real identifiers). No new status colors. |
| Toolchain (`mise exec --`) | Pass. Dev image runs every Elixir command through `mise exec --` with the repository's `mise.toml` (FR-010); no second version copy. |
| Persistence: node name + dir explicit and stable | Pass, strengthened: both derived deterministically from target identity; fixed container `hostname`; verified at boot. Single-node, machine-local. Store never inside a target tree. |
| Persistence: no auto-delete, explicit schema evolution | Pass. Old `~/.autonomous/mnesia` is neither read nor deleted (FR-020). No schema change. |
| Persistence: hermetic default suite | Pass. Test config disables the guard and keeps tmp `store_dir`. |
| Frontend: no Node/npm build pipeline | Pass. Node.js in the image is a tool runtime for the coding-agent CLI (and Playwright when opted in); no JS build step for the console. Recorded in Complexity Tracking for transparency. |
| Stack: new runtime dependency | No new Hex dependency. New *image* dependencies are tools, justified per FR-011/023. |

Gate result: **PASS** (no unjustified violation). Re-check after Phase 1: **PASS** — the design added no dependency, no schema change and no new hook rule beyond the device-file allowance.

## Project Structure

### Documentation (this feature)

```text
specs/031-containerized-runtime/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── wrapper-cli.md          # scripts/autonomous commands, options, output, exit codes
│   ├── environment.md          # every env var / build arg, who reads it, defaults
│   ├── boot-guard.md           # ContainerGuard + Instance boot checks and messages
│   ├── instance-identity.md    # derivation of segment, node, store dir, lock, cookie
│   ├── compose-services.md     # services, mounts, ports, overrides
│   └── hook-allowlist.md       # scope_guard.py change + red-team matrix additions
├── checklists/
└── tasks.md                    # /speckit-tasks output (not created here)
```

### Source Code (repository root)

```text
Dockerfile                      # NEW: stages base → toolchain → [web|desktop|android] → dev / build → release
compose.yaml                    # NEW: services dev, console, release
compose.android.yaml            # NEW: /dev/kvm passthrough override (opt-in)
compose.desktop-viewer.yaml     # NEW: noVNC viewer port on 127.0.0.1 (opt-in)
compose.claude-login.yaml       # NEW: host agent-login mounts (opt-in, FR-012)
.dockerignore                   # NEW: _build, deps, .env, .git internals not needed
.env.example                    # NEW: credentials/config template; .env git-ignored
.gitignore                      # MODIFIED: .env
scripts/
├── autonomous                  # NEW: wrapper (build | shell | console | release | remote | port | test)
├── container-entrypoint.sh     # NEW: identity → lock → git/gh setup → warnings → exec
├── android-emulator            # NEW: start headless emulator or explain both options
└── container-smoke.sh          # NEW: SC checks runnable by hand
config/
├── config.exs                  # MODIFIED: :require_container default true; test block false
└── runtime.exs                 # MODIFIED: console/state-root/instance env; :prod secret refusal
mix.exs                         # MODIFIED: releases: [autonomous: [...]]
rel/
├── env.sh.eex                  # NEW: RELEASE_DISTRIBUTION=sname, RELEASE_NODE from env
└── vm.args.eex                 # NEW (if needed by release defaults)
lib/autonomous/
├── application.ex              # MODIFIED: ContainerGuard.check!/0 + Instance.verify!/0 before Store.Boot
├── container_guard.ex          # NEW
├── instance.ex                 # NEW (derive/verify/assert_served!)
├── config.ex                   # MODIFIED: store_dir resolves per-instance path when set
└── (autonomous.ex)             # MODIFIED: repo-taking facade fns call Instance.assert_served!/1
lib/mix/tasks/autonomous.instance.ex  # NEW: prints derived identity (no app start)
priv/target_pack/.claude/hooks/scope_guard.py  # MODIFIED: device-file redirect allowance
test/autonomous/
├── container_guard_test.exs    # NEW
├── instance_test.exs           # NEW
└── scope_guard_test.exs        # MODIFIED: allowance + unchanged denials
docs/
├── runbook.md                  # MODIFIED: container is the primary path
├── enforcement.md              # MODIFIED: container layer is real; egress + package-download gap
└── container.md                # NEW: capabilities, pre-fetching (FR-027a), Android modes, troubleshooting
README.md, CLAUDE.md            # MODIFIED: contributor guide points at the container
```

**Structure Decision**: Single OTP project; containerization lives at the repository
root (`Dockerfile`, `compose*.yaml`, `scripts/`), with two new boundary modules under
`lib/autonomous/` and one Mix task. No new Mix app or umbrella.

## Complexity Tracking

| Item | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Node.js runtime inside the image | The coding-agent CLI is distributed as an npm package; Playwright (opt-in) also needs it. | A native CLI binary download would avoid Node, but pinning and verifying it is less uniform than an npm version pin and Playwright still needs Node. No console build step is introduced, so the Frontend rule is unaffected. |
| `strict` hook does not deny package-manager downloads (pre-existing, kept) | Principle III requires `strict` to deny network access via download tools. The hook denies `curl`/`wget`/`WebFetch`/`WebSearch` but not `npm install`/`pip install`/`mix deps.get`/Gradle (research R12). This feature does not widen that gap: it only allows redirects to three device sinks. Registry-bound package managers are also how targets legitimately build, so a blanket denial would break existing `strict` targets. | Adding package-manager denials now would tighten `strict` beyond this feature's scope and break targets without a migration path; it belongs with egress allowlisting (FR-029), which would close the gap at the network layer for every tool at once. Recorded as an open gap in `docs/enforcement.md` (T058). |
| Shell wrapper + entrypoint (not pure Elixir) | Node name and lock must exist *before* the VM starts (`--sname`, `RELEASE_NODE`); `flock` must be held by the container's PID 1 lineage. | Deriving node name inside the VM is impossible (distribution starts with the VM). Duplicating the derivation in shell would drift — so the shell calls `mix autonomous.instance` / release `eval` for the single Elixir derivation, and the app re-verifies at boot. |
