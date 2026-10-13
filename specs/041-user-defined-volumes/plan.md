# Implementation Plan: User-Defined Persistent Volumes

**Branch**: `041-user-defined-volumes` | **Date**: 2026-10-13 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/041-user-defined-volumes/spec.md`

## Summary

Let the operator keep a target's toolchains, caches and build output across
container restarts by declaring named volumes in a host-only, per-target
`volumes.toml` (`${XDG_CONFIG_HOME:-~/.config}/autonomous/targets/<segment>/`).
The wrapper reads it on the host, validates it with a stdlib-only Python
helper (`scripts/volumes.py`, all violations reported, nothing started on
failure), creates labelled, segment-scoped external Docker volumes, makes their
roots writable by the container user, and feeds the container only the applied
result through a generated Compose overlay (mounts + variables + `PATH` prefix
+ `AUTONOMOUS_VOLUMES`). New wrapper commands: `volumes --target <repo>
[--init]` and `reset-cache --target <repo> [--volume <name>]...`; `stop --purge`
also removes declared volumes. The console Configuration page lists the applied
set with space used measured asynchronously at page load. With no declaration
everything is byte-identical to today.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (mise-pinned) for console/env
parsing; POSIX `sh` for `scripts/autonomous` and the entrypoint; Python ≥ 3.11
(stdlib only, host-side) for `scripts/volumes.py`.

**Primary Dependencies**: existing only — Phoenix LiveView (Configuration page),
Docker Engine + Compose v2. Python `tomllib`/`json` (stdlib). No new Hex dep.

**Storage**: Docker named volumes (`autonomous-<segment>_vol-<name>`, labelled);
host-only declaration file + generated overlay. No Mnesia/schema change.

**Testing**: ExUnit default suite (hermetic): `scripts/volumes.py` via
`System.cmd("python3", …)`; wrapper commands against a stub `docker` (pattern
of `container_build_options_test.exs`); entrypoint `PATH` re-prepend via a stub
`mise`; pure `AppliedVolumes`/`VolumesView` unit tests; `ConfigLive` render
tests (with/without `AUTONOMOUS_VOLUMES`); design-contract guard. Hand-run:
`scripts/container-smoke.sh volumes`.

**Target Platform**: Linux container (Debian bookworm image) driven from a
Linux or macOS host via `scripts/autonomous`.

**Project Type**: CLI wrapper + OTP application with LiveView console.

**Performance Goals**: no-declaration start adds 0 docker calls; with entries,
≤ 1 provisioning container per start (all volumes in one run); Configuration
renders immediately, sizes arrive async (30 s timeout → `unknown`).

**Constraints**: declaration never mounted or piped into a container; no host
path mounted or modified; validation completes before any instance container
or volume is created; byte-identical behaviour/output without a declaration;
`warnings_as_errors`.

**Scale/Scope**: unbounded entries (smoke with 1, 5, 20); one declaration per
target; three worked examples (mod-player, fretboard-master, autonomous) +
Python snippet.

No NEEDS CLARIFICATION remain — see [research.md](research.md) R1–R14.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment | Result |
|---|---|---|
| I. Pure core, isolated contracts | Pure core untouched. New Elixir logic split pure (`AppliedVolumes.parse/1`, `VolumesView`) vs boundary (`VolumeUsage` runs `du`; `AppliedVolumes.current/0` is the one env read). Validation is pure functions in a host-side helper (see Complexity Tracking). Docker naming/label contract confined to the wrapper + helper. | PASS |
| II. Fail loud at boundaries | Every invalid/malformed declaration refuses the start before anything is created, reporting *all* violations with entry + reason (FR-009/010). Unknown reset names refused. Unreadable `AUTONOMOUS_VOLUMES` rendered as a refusal, not hidden. Old Python refused by name. Unlabelled lookalike volume never removed. | PASS |
| III. Container-bounded execution | Container stays the boundary: no host mounts (FR-015), declaration host-only, reserved `AUTONOMOUS_*`/credential/start-sequence variables cannot be overridden. Tool set, permission mode, exclusions, deadlines, non-container warning, trust, agent root unchanged (FR-025). | PASS |
| IV. Cost transparency; drain, don't kill | Not touched. Reset refuses while any instance container exists — never stops or kills one. | PASS |
| V. Human-in-the-loop escalation | Not touched. | PASS |
| VI. Idiomatic Elixir/OTP | `start_async` for measurement, no new processes in the supervision tree, pure modules with typespecs. | PASS |
| VII. Operator surfaces tell the truth | Group labelled "as applied at start"; real identifiers (`volumes.toml`, `CARGO_TARGET_DIR`, paths) in mono; unknown size never shown as 0; no group when none; no animation for "measuring"; tokens only (design guard). Start output lists what was applied + override notices. | PASS |
| Tech stack | No new runtime dependency, no frontend build step, no database. Host `python3 ≥ 3.11` needed only once a declaration exists (python3 already required by the wrapper). | PASS |
| Quality & test discipline | Default suite hermetic (stub docker/mise, temp dirs, `XDG_CONFIG_HOME` per test); docker-real checks are hand-run smoke. | PASS |

**Post-design re-check (after Phase 1)**: unchanged — PASS. Design adds no
Mnesia table, no supervision-tree child, no new dependency; constitution
amendment not required.

## Project Structure

### Documentation (this feature)

```text
specs/041-user-defined-volumes/
├── plan.md                         # this file
├── research.md                     # R1–R14 decisions
├── data-model.md                   # declaration, entry, instance volume, applied set, view state
├── quickstart.md                   # mod-player / fretboard-master / autonomous walkthroughs
├── contracts/
│   ├── declaration-format.md       # volumes.toml shape, starter file, validation output
│   ├── wrapper-cli.md              # volumes, reset-cache, start sequence, stop --purge
│   ├── applied-volumes.md          # volumes.py interface, overlay, entrypoint PATH, session visibility
│   └── configuration-surface.md    # Configuration "declared volumes" group
├── checklists/requirements.md
└── tasks.md                        # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
scripts/
├── autonomous                      # + volumes, reset-cache; start steps 2★/4★; stop --purge
├── volumes.py                      # NEW host helper: parse/validate/plan/starter/select (stdlib)
├── container-entrypoint.sh         # dev-shape VM handover re-prepends AUTONOMOUS_VOLUME_PATH
└── container-smoke.sh              # + `volumes` subcommand

lib/autonomous/
├── applied_volumes.ex              # NEW pure parse of AUTONOMOUS_VOLUMES (+ current/0)
├── volume_usage.ex                 # NEW `du -sk -x` with timeout → {:ok, bytes} | {:unknown, reason}
└── web/
    ├── volumes_view.ex             # NEW pure view state + formatting
    └── live/config_live.ex         # + declared volumes group, start_async measurement

priv/static/assets/console.css      # only if a new class is needed; tokens only

test/autonomous/
├── volumes_py_test.exs             # NEW validator/plan/starter/select via python3
├── container_volumes_cli_test.exs  # NEW wrapper volumes/reset-cache/start/purge vs stub docker
├── container_volume_path_test.exs  # NEW entrypoint PATH re-prepend vs stub mise
├── applied_volumes_test.exs        # NEW
├── volume_usage_test.exs           # NEW (temp dir, timeout path)
└── web/
    ├── volumes_view_test.exs       # NEW
    └── config_live_volumes_test.exs # NEW render with/without, unknown size, refusal

docs/
├── container.md                    # declaration format, rules, reserved list, reset, purge, examples;
│                                   #   worktrees stay host bind-mounted, volumes hold only out-of-worktree data (FR-025a)
└── runbook.md                      # operator flow + quickstart (FR-027/028)
CLAUDE.md                           # feature 041 paragraph
```

**Structure Decision**: single project, existing layout. Host-side behaviour in
`scripts/` (wrapper + new Python helper), container-side visibility in
`lib/autonomous/` + the Configuration LiveView, tests in `test/autonomous/`.

## Complexity Tracking

| Deviation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Validation logic in a host-side Python helper (`scripts/volumes.py`), not an Elixir pure module | FR-005/005a: the declaration must be read on the host and never enter a container; Elixir only runs inside the image. Kept as pure, unit-tested functions. | Elixir via the bootstrap container would pipe the declaration into a container and needs a TOML dependency (none in stdlib; constitution bars new deps). Plain `sh` cannot reliably normalize/nest-check paths or report every violation. |
| Host `python3 ≥ 3.11` (for `tomllib`) when a declaration exists | Commented TOML declaration (FR-005c); stdlib parser. | JSON has no comments; INI cannot report duplicate entries without silent merging. Requirement only applies once a declaration exists, refused by name otherwise. |
