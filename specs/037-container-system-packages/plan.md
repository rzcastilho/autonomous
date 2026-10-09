# Implementation Plan: Container System Packages

**Branch**: `037-container-system-packages` | **Date**: 2026-10-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/037-container-system-packages/spec.md`

## Summary

A native target dependency (mod-player's `alsa-sys`) could not build because
the container had no way to get OS packages. Three layers blocked it: the image
build could not take extra packages, sessions run non-root with no `sudo`, and
the strict hook denied every `sudo`. The fix has three parts.

1. **Build-time packages (US1)**. `scripts/autonomous build --apt "…"` validates
   the names in the wrapper (exit 2 on anything that is not a Debian package
   name) and passes them as build arg `EXTRA_APT_PACKAGES`. A no-op-when-empty
   block at the end of the `base` stage installs them, so both the `dev` and
   `release` images carry them. It writes `/etc/autonomous/apt-packages` only
   when the list is non-empty, so a no-option build adds no files. Containment
   is unchanged.
2. **Opt-in agent root (US2)**.
   - **Image.** `--agent-root` (`WITH_AGENT_ROOT=1`) installs `sudo` with a
     user-agnostic `NOPASSWD` drop-in and an apt `Remove "false"` drop-in.
   - **Start.** The entrypoint first unsets any inherited
     `AUTONOMOUS_AGENT_ROOT`. It exports the variable only when
     `sudo -n true` succeeds.
   - **Session request.** `AgentRoot.advertised?/0` reads that variable and
     `PhaseRequest` acts on it. It puts the container and agent-root markers
     on the launch env, and it appends a short note to the implement and
     converge prompts saying that missing system packages may be installed.
   - **Hook.** `scope_guard.py` moves to **pack contract 5**. Under `strict`,
     with both markers, the `bash_sudo` rule is skipped only when every `sudo`
     segment matches a closed grammar: `apt-get`/`apt` `update`/`install`
     (allowlisted options, package-name tokens) and `dpkg` queries. No
     substitutions, `-o`, local `.deb` files, removal or upgrade are allowed.
     Every other rule still applies.
   - **Preflight.** It warns but still starts the run when agent root is
     advertised and the committed pack is below contract 5. Permissive
     preflight moves from "contract == 4" to "contract ≥ 4", so its behaviour
     does not change.
   - **Logging.** Each allowed install produces one `Logger.info` line naming
     the feature and the packages. The line is built from `PhaseResult` tool
     events, and nothing is persisted.
3. **Operator surfaces (US3)**.
   - **Docs:** `docs/container.md` gets a "System packages" section,
     `docs/enforcement.md` gets the exception and the boundary it relies on,
     and `docs/runbook.md` gets a recovery for "tests not run: missing system
     package".
   - **Console:** the Configuration page gets an agent-root row.
   - **Smoke:** a new `container-smoke.sh sysdeps` check.
   - **Constitution:** a MINOR amendment (6.0.2 → 6.1.0) to Principle III.

With neither flag, the image content, container start output, session
requests and hook decisions are byte-identical to today.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28.5.0.6 (mise-pinned). Python 3
stdlib (the hook). POSIX `sh` (wrapper, entrypoint, smoke). Dockerfile on
Debian bookworm-slim.

**Primary Dependencies**: Debian `apt`/`dpkg`/`sudo`. Python's `shlex` (stdlib).
Existing `jido_harness`/`jido_claude`, whose `metadata["claude"][:env]` is the
launch env. Claude Code CLI 2.1.286 PreToolUse hooks.

**Storage**: No store change. Image files: `/etc/autonomous/apt-packages`,
`/etc/sudoers.d/autonomous-agent-root`,
`/etc/apt/apt.conf.d/99autonomous-no-remove`. One process env var,
`AUTONOMOUS_AGENT_ROOT`.

**Testing**:
- ExUnit hermetic suite. `scope_guard_test` runs the real hook across
  origin × profile × markers × command shape (contract rows 1–20).
- `target_pack_test` covers contract thresholds and the warning.
- A new `agent_root_test` (pure) and `phase_request_test` cover the
  byte-identical `false` path.
- A new `container_agent_root_step_test` runs the real entrypoint
  `agent-root` subcommand with a stub `sudo` on `PATH`, in the style of
  `container_trust_step_test`.
- Docker checks run by hand: `container-smoke.sh sysdeps`.

**Target Platform**: Debian bookworm container (dev and release). Linux host
with Docker Engine and Compose v2.

**Project Type**: OTP application, container runtime scripts and target pack.

**Performance Goals**: Start step under 100 ms (one `sudo -n true`). The hook
adds one `shlex` pass only when both markers are present. Build time grows
only by the declared packages.

**Constraints**:
- `warnings_as_errors`.
- The hook stays stdlib-only and fails closed.
- No new deny or allow under permissive or for interactive sessions.
- The curl/wget rules are unchanged (FR-014).
- A no-flag image adds no files (FR-002).
- Agent root is never advertised without a positive probe.

**Scale/Scope**:
- 1 Dockerfile stage tail (2 blocks), 2 compose build args, 2 wrapper
  options, 1 entrypoint step and subcommand.
- Hook grammar of about 80 lines and a contract bump.
- `TargetPack` threshold refactor and 1 new function.
- 1 new module (`AgentRoot`) and 1 prompt pack.
- `PhaseRequest` option, 4 call sites for the log line, 2 preflight
  call sites, 1 Configuration-page row.
- Docs (container, enforcement, runbook, CLAUDE.md), 1 smoke section, and the
  constitution amendment.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment | Status |
|---|---|---|
| I. Pure core, isolated contracts | `AgentRoot` keeps a single env read (`advertised?/1`, with env injectable) and pure helpers. `Pipeline`/`Release`/`Ledger` are untouched. The apt/dpkg grammar lives only in the hook (the containment boundary). Elixir's `installs/1` only mirrors already-allowed calls for logging and decides nothing | PASS |
| II. Fail loud at boundaries | Invalid package names are refused in the wrapper before any build (exit 2). An unknown package fails the build and names it. The hook fails closed on unparseable input and on shlex errors. A failed elevation probe is reported, never advertised silently. Preflight warns rather than fails, by explicit Clarification, and that is safe because the older pack keeps denying | PASS |
| III. Least-privilege containment | **Deviation until amended**: Principle III currently says strict "MUST deny … dangerous Bash", and `sudo` is in that list. The feature carves out one cell (strict + in-container + verified agent root + install-only grammar). FR-017 amends III (MINOR, 6.1.0) as the first task (research R11). Layering holds: the hook grammar, the apt no-remove config and the container boundary. Permissive, interactive and marker-less strict sessions are unchanged. Denials still name profile and rule | PASS (with amendment; see Complexity Tracking) |
| IV. Cost-bounded autonomy | No new sessions, retries or cost paths | PASS (n/a) |
| V. Human-in-the-loop | No gate is touched | PASS (n/a) |
| VI. Idiomatic OTP | No new processes. Logging happens at the existing post-session sites | PASS |
| VII. Operator surfaces tell the truth | The capability shows at container start, at preflight (warning) and on the Configuration page. Every allowed install is logged with feature and packages. A no-flag instance's surfaces are byte-identical. The design guard is respected (existing tokens/classes, no `inspect/1`) | PASS |
| Technology Stack | No new runtime dependency (`sudo` is an opt-in image package, `shlex` is stdlib) | PASS |
| Quality & test discipline | The real hook is red-teamed under a pinned env, with the new markers cleared because the suite runs inside the image where `AUTONOMOUS_CONTAINER=1` (R12). The real entrypoint step runs in tests. Docker checks are opt-in smoke | PASS |
| Development workflow | Spec Kit loop. Earlier features' contracts are amended by this feature's own contracts, not edited in place | PASS |

**Post-design re-check (after Phase 1)**: unchanged. The only flagged item is
the Principle III deviation, justified below and resolved by the FR-017
amendment landing first.

## Project Structure

### Documentation (this feature)

```text
specs/037-container-system-packages/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── build-options.md          # wrapper --apt / --agent-root, Dockerfile, compose args
│   ├── container-start.md        # entrypoint agent_root step + agent-root smoke subcommand
│   ├── scope-guard-exception.md  # contract 5 grammar + red-team rows
│   └── session-request.md        # AgentRoot, PhaseRequest, preflight, log line, console row
└── tasks.md                      # /speckit-tasks
```

### Source Code (repository root)

```text
Dockerfile                                   # base tail: EXTRA_APT_PACKAGES block, WITH_AGENT_ROOT block
compose.yaml                                 # dev/release build args
scripts/
├── autonomous                               # build --apt (validated) / --agent-root
├── container-entrypoint.sh                  # agent_root step + `agent-root` subcommand
└── container-smoke.sh                       # sysdeps section (+ in `all`)
priv/
├── prompts/agent_root.md                    # new prompt pack
└── target_pack/.claude/hooks/scope_guard.py # PACK_CONTRACT 5, agent_root_active, sudo_allowed
lib/autonomous/
├── agent_root.ex                            # new: advertised?/session_env/prompt_note/installs/log_installs
├── prompts.ex                               # embed agent_root
├── phase_request.ex                         # :agent_root option → env + implement/converge note
├── target_pack.ex                           # contract 5, permissive ≥4, agent_root_warning/1
├── actions/run_feature_phase.ex             # log_installs after session
├── actions/run_remediation.ex               # log_installs after session
├── actions/run_auto_remediation.ex          # log_installs after session
├── chunk_runner.ex                          # log_installs per chunk
└── web/live/config_live.ex                  # agent-root row (+ pure view helper)
lib/autonomous.ex                            # preflight warning in preflight_stacked/2, spec_run_opts/3
.specify/memory/constitution.md              # 6.1.0, Principle III exception
docs/{container,enforcement,runbook}.md      # System packages / exception / recovery
CLAUDE.md                                    # feature 037 paragraph
test/autonomous/
├── scope_guard_test.exs                     # env_clear + contract 5 + matrix rows
├── target_pack_test.exs                     # thresholds, agent_root_warning
├── agent_root_test.exs                      # new
├── phase_request_test.exs                   # agent_root true/false
└── container_agent_root_step_test.exs       # new: real entrypoint subcommand with stub sudo
```

**Structure Decision**: The existing single OTP project. Container-side changes
sit next to the 031/034/036 scripts, the hook stays the only containment
boundary, and the Elixir side adds one small module plus options at existing
seams.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Principle III (6.0.2): strict "MUST deny … dangerous Bash" (`sudo`). The feature lets a narrow `sudo apt-get/apt install` through under strict | US2 / FR-008. Without it, an agent cannot fix an unpredicted missing system package, and the feature reports "tests not run" (the incident) | (a) Permissive-only agent root: the Clarifications chose strict + exception, and permissive drops every other strict guard just to install a package. (b) US1 only: it cannot cover packages the operator did not predict. Resolved by the MINOR amendment (FR-017, R11), committed before the hook change |
| sudoers grant is `NOPASSWD: ALL`, not apt-only | The start probe and smoke need `sudo -n true`. apt-only sudoers is not a boundary (`apt-get -o …Pre-Invoke`, maintainer scripts) | An apt-only sudoers line gives false assurance. The real per-command policy is the hook grammar, inside the container boundary (R3) |
