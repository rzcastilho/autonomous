# Implementation Plan: Container Isolation for Autonomous Runs

**Branch**: `015-container-isolation` | **Date**: 2026-07-24 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/015-container-isolation/spec.md`

## Summary

Ship the orchestrator as a registry-published, immutably version-tagged container
image so an operator can drive a full backlog without ever executing
agent-authored commands on their own machine — with unchanged run outcomes.

Technical approach: a two-stage build (`hexpm/elixir` builder → `debian:bookworm-slim`
runtime) produces an ERTS-embedded `mix release`, so the runnable image carries no
orchestrator source and no build tooling. The runtime stage carries the pipeline's
external tools (`git`, `gh`, `claude`, `specify`, `python3`) plus `mise`, which
resolves each *target* repository's own pinned runtimes at run time. Isolation is
OS-layer: unprivileged `--user <uid>:<gid>`, `--read-only` root filesystem,
`--cap-drop ALL`, `--security-opt no-new-privileges`, and exactly two durable
writable bind mounts — the target repository and the run-state root — each mounted
at its **identical host absolute path**, so every recorded path and every
per-feature worktree is valid on both sides with no translation. The container
boots idle (supervision tree + console) and launches a run only when an auto-start
setting is present, staying up after the run drains. A new preflight verifies
tools, credentials, mounts, path identity, and target-repo readiness, persists a
report into the run-state root, and refuses to spend when anything is missing.
Publishing is a GitHub Actions workflow to GHCR with an immutability guard on the
version tag.

Network egress is deliberately **not** restricted (FR-016); the guarantee covers
filesystem writes, privileges, and process scope only.

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28 (`.tool-versions`, run via `mise exec --`)

**Primary Dependencies**: no new Elixir runtime dependencies. Existing tree —
Jido `~> 2.2`, `jido_harness`/`jido_claude` (GitHub SHA-pinned), Phoenix `~> 1.7`
+ LiveView `~> 1.0` on Bandit. New **build/deploy** surface only: `Dockerfile`,
`.dockerignore`, a launcher shell script, and a GitHub Actions workflow

**Storage**: file-backed, as today — run manifests, per-phase checkpoints,
transcripts, and the new preflight report under `Config.autonomous_root/0`
(`~/.autonomous`). No database

**Testing**: ExUnit. Pure logic (preflight evaluation, env parsing, mountinfo
parsing, image-manifest parsing) in the default hermetic suite; anything needing a
container engine behind `--include integration`, per the constitution

**Target Platform**: **Linux container engine only** (FR-014). macOS desktop
engines and other hosts are explicitly unsupported and unverified. Base images:
builder `hexpm/elixir:1.20.2-erlang-<otp28.x>-debian-bookworm-<date>`, runtime
`debian:bookworm-slim`, both digest-pinned

**Project Type**: single Elixir/OTP application (control plane + LiveView console),
now additionally packaged as a container image

**Performance Goals**: containerized end-to-end wall-clock within 110% of the
on-machine run on the reference backlog (SC-009), measured on the supported Linux
platform. First-run target-toolchain acquisition is amortised by caching mise data
into the durable run-state mount

**Constraints**: exactly two durable writable areas (FR-012); mounts at identical
host paths, no path translation (FR-018/FR-019); no credential in any image layer
(FR-005) and none in any message (FR-035); an existing version tag is never
overwritten (FR-009); container exit is operator-initiated only (FR-030)

**Scale/Scope**: one container per target repository at a time; concurrent
containers sharing a repository or run-state root are out of scope. ~5 new Elixir
modules, `config/runtime.exs` expansion, `mix.exs` `releases:` block, `terminate/2`
on `Coordinator`/`Ledger`, plus the packaging and CI surface

## Constitution Check

*GATE: evaluated against `.specify/memory/constitution.md` v1.1.0. Re-checked
after Phase 1 design — result unchanged.*

| Principle | Assessment |
|---|---|
| **I. Pure Core, Isolated Contracts** | PASS. The pure core (`Feature`, `Config`, `Pipeline`, `Ledger`, `Release`, `Backlog`, `Layout`) is untouched — which is precisely what makes run parity (SC-001) true by construction. New logic follows the same split: `Preflight.collect/1` does IO at the edge, `Preflight.evaluate/1` is pure over a facts map; `Container.Mount.mount_point?/2` takes mountinfo *contents*, not a path to read |
| **II. Fail Loud at Boundaries** | PASS, and materially strengthened. A required env var absent fails the boot; an unparseable number, an unknown model alias, or an unknown phase raises naming the variable and value; path-identity mismatch, a non-durable run-state root, a missing tool, or an unprepared target repo all stop the boot before any spend. Nothing falls back silently to a compiled-in default (FR-020) |
| **III. Least-Privilege Containment (Fail-Closed)** | PASS. The container is the **third** layer, never a replacement: the PreToolUse scope-guard hook and per-phase `PhaseRequest` permissions operate unchanged inside it (FR-017). The red-team suite runs with the hook disabled specifically to prove the OS layer stands alone. `docs/enforcement.md`'s current advisory container note is superseded by an accurate one (FR-037) — including the correction that egress is **not** restricted |
| **IV. Cost-Bounded Autonomy (Drain, Don't Kill)** | PASS. Breaker semantics unchanged. Shutdown is made drain-shaped: `SIGTERM` → `init:stop` → ordered termination, with `Coordinator`/`Ledger` `terminate/2` flushing the manifest and tally; an in-flight phase that outlives the stop grace period is recorded as `interrupted` with its reservation intact, so the tally never under-counts (FR-027, SC-006) |
| **V. Human-in-the-Loop Escalation** | PASS. Gates unchanged. Escalated/halted worktrees are preserved on the durable run-state mount and readable from the host; `resolve/1` and `resume/2` are reachable through the release's remote console (FR-025). FR-030's stay-up-after-drain exists so that post-mortem state remains inspectable |
| **VI. Idiomatic Elixir/OTP & Functional Design** | PASS. `Boot` is a supervised child that does its work in `handle_continue` (never blocking `init`, never blocking a caller's `handle_call`); preflight is a `with` pipeline over tagged tuples; checks are multi-clause pattern matches over a facts map; `@spec` on every public function; `terminate/2` is used for flush-on-shutdown, not defensive rescuing |
| **Technology Stack** | PASS. Zero new Elixir runtime dependencies. `mix release` is core Mix, not a dependency. No JS build step, no CSS framework, no database — the console keeps its vendored assets, which travel in the release's `priv/`. The one stack-adjacent addition (`mise` inside the image) is the toolchain manager this project already mandates |
| **Quality & Test Discipline** | PASS. `warnings_as_errors` stays on. New pure logic is unit-tested in the hermetic suite; every container-dependent scenario sits behind `--include integration`. The red-team suite tests the real hook and the real container, not mocks |
| **Development Workflow** | PASS. Spec-driven through the Spec Kit loop on `feature/015-container-isolation`; the worktree/scaffold rules are unchanged by this feature |

**Result**: no violations. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/015-container-isolation/
├── plan.md                          # This file
├── spec.md                          # Input
├── research.md                      # Phase 0 output
├── data-model.md                    # Phase 1 output
├── quickstart.md                    # Phase 1 output
├── contracts/                       # Phase 1 output
│   ├── container-run.md             # Run invocation, mounts, privileges, lifecycle
│   ├── environment.md               # Boot env config + credentials + git identity
│   ├── preflight-report.md          # Check inventory + persisted JSON schema
│   └── image-publishing.md          # Build recipe, labels, tags, CI workflow
├── checklists/
│   └── requirements.md
└── tasks.md                         # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
Dockerfile                                   # NEW — two-stage build (FR-001..FR-004)
.dockerignore                                # NEW — build-context exclusion (FR-006)

scripts/
└── autonomous-container.sh                  # NEW — launcher; derives mounts + path-identity
                                             #       assertions from host values (FR-018/FR-019)

.github/                                     # NEW directory
└── workflows/
    └── image.yml                            # NEW — build, scan, smoke-test, publish (FR-008..FR-010)

config/
├── config.exs                                # MODIFIED — console bind/check_origin read from env-derived values
└── runtime.exs                               # MODIFIED — full FR-020 config surface; server: true;
                                              #            distribution bound to loopback

mix.exs                                       # MODIFIED — releases: block (ERTS-embedded)

lib/speckit_orchestrator/
├── application.ex                            # MODIFIED — supervise Boot; attach telemetry logger
├── coordinator.ex                            # MODIFIED — trap_exit + terminate/2 manifest flush
├── ledger.ex                                 # MODIFIED — trap_exit + terminate/2 tally flush
├── boot.ex                                   # NEW — idle-by-default; preflight then optional auto-start
├── image_info.ex                             # NEW — read /etc/autonomous/image.json (FR-007)
├── preflight.ex                              # NEW — collect (IO) / evaluate (pure) / persist / run
├── preflight/
│   ├── check.ex                              # NEW — one verified fact
│   └── report.ex                             # NEW — aggregate + JSON serialisation
└── container/
    ├── env.ex                                # NEW — parse + validate the boot environment
    └── mount.ex                              # NEW — pure /proc/self/mountinfo parsing

test/speckit_orchestrator/
├── preflight_test.exs                        # NEW — every failure mode, hermetic, injected seams
├── container/env_test.exs                    # NEW — required/invalid/absent env matrix
├── container/mount_test.exs                  # NEW — fixture mountinfo incl. tmpfs $HOME + nested bind
├── image_info_test.exs                       # NEW — parse, missing file, malformed
└── boot_test.exs                             # NEW — idle default; autostart; preflight-fail stays idle

test/integration/
├── container_run_test.exs                    # NEW — @tag :integration — parity, ownership, restart
└── container_red_team_test.exs               # NEW — @tag :integration — ≥10 hostile cmds, hook disabled

test/fixtures/
├── mountinfo/                                # NEW — durable-mount and tmpfs-only fixtures
└── image_json/                               # NEW — valid and malformed manifests

docs/
├── container.md                              # NEW — operator path: pull, start, preflight, run,
│                                             #       observe, stop; + local build path (FR-036, FR-038)
├── enforcement.md                            # MODIFIED — replace the advisory container note (FR-037)
├── runbook.md                                # MODIFIED — containerized operation cross-reference
└── autonomous.env.example                    # NEW — reference env file
```

**Structure Decision**: single Elixir/OTP project — the existing
`lib/speckit_orchestrator/` layout. This feature adds a packaging and deployment
surface at the repository root (`Dockerfile`, `.dockerignore`, `scripts/`,
`.github/workflows/`) and five new library modules grouped by concern
(`preflight/`, `container/`) alongside the existing flat modules. The pure core is
not restructured — container isolation is a deployment concern, and leaving the
core untouched is what makes run parity (SC-001) provable rather than hoped for.

## Complexity Tracking

*No Constitution Check violations. This section is intentionally empty.*
