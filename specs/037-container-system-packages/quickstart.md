# Quickstart: Container System Packages — validation guide

Prerequisites: Docker Engine + Compose v2 (Linux), repo root as cwd, toolchain
trusted (`mise trust mise.toml`). Contracts: [build-options](contracts/build-options.md),
[container-start](contracts/container-start.md),
[scope-guard-exception](contracts/scope-guard-exception.md),
[session-request](contracts/session-request.md).

## 1. Hermetic suite (no Docker)

```bash
mise exec -- mix test test/autonomous/scope_guard_test.exs      # red-team matrix rows 1–20 (SC-003)
mise exec -- mix test test/autonomous/agent_root_test.exs       # advertised?/session_env/prompt_note/installs
mise exec -- mix test test/autonomous/phase_request_test.exs    # agent_root: false ⇒ byte-identical
mise exec -- mix test test/autonomous/target_pack_test.exs      # contract 5, permissive ≥4, agent_root_warning
mise exec -- mix test test/autonomous/container_agent_root_step_test.exs  # entrypoint `agent-root` subcommand
mise exec -- mix test                                           # full suite green, unchanged elsewhere (SC-004)
```

Expected: all pass; `python3 priv/target_pack/.claude/hooks/scope_guard.py --contract` prints `5`.

## 2. Wrapper validation (no build started)

```bash
scripts/autonomous build --apt 'pkg-config; rm -rf /'   ; echo $?
```

Expected: `autonomous: invalid package name ';'` (or the first bad token), exit `2`, no `docker` invocation.

## 3. US1 — declared packages (FR-001..FR-003)

```bash
scripts/autonomous build --release --apt "libasound2-dev pkg-config"
scripts/container-smoke.sh sysdeps
```

Expected: `PASS` for `dpkg -s libasound2-dev` and `dpkg -s pkg-config` in the dev
image; repeat against the release image with
`SMOKE_IMAGE=autonomous-release:local scripts/container-smoke.sh sysdeps`.
Agent-root checks `SKIP` (no sudo) and `AUTONOMOUS_AGENT_ROOT=0`.

Unknown package:

```bash
scripts/autonomous build --apt "no-such-package-xyz"; echo $?
```

Expected: build fails, output contains `Unable to locate package no-such-package-xyz`,
non-zero exit; `autonomous-dev:local` still points at the previous image.

No-option build (FR-002): `scripts/autonomous build` then
`docker run --rm --entrypoint sh autonomous-dev:local -c 'command -v sudo; ls /etc/autonomous'`
⇒ both absent.

## 4. US2 — agent root (FR-005..FR-013)

```bash
scripts/autonomous build --agent-root
scripts/container-smoke.sh sysdeps
```

Expected: `PASS sudo -n true`, `PASS agent-root advertises 1`, `PASS sudo apt-get install pkg-config`,
`PASS apt-get remove refused`.

Start an instance against a scratch target whose build needs a missing package
(e.g. the mod-player target with no `--apt`), strict profile:

```bash
scripts/autonomous console --target ../mod-player
# container log: "autonomous: agent root: available (strict allows sudo apt-get/apt install)"
```

- If the target's committed pack is contract 4: preflight logs the
  `committed pack is contract 4` warning, the run starts, and the session's
  `sudo apt-get install` is denied `bash_sudo` (old pack). Configuration page shows
  the warning row.
- After `TargetPack.install/2` + commit (contract 5): resume the feature; the
  implement session installs the packages, tests run (SC-002), and the log shows
  `agent root: feature 003 (implement) installed system packages: libasound2-dev pkg-config — …`.

Negative: run the same image with `--security-opt no-new-privileges` (manually via
`docker run`) and invoke `entrypoint agent-root` ⇒ `AUTONOMOUS_AGENT_ROOT=0` plus the
"not advertised" warning.

## 5. US3 — docs and runbook (FR-015, SC-005)

Read `docs/container.md` → "System packages", `docs/enforcement.md` → strict
package-manager exception, `docs/runbook.md` → "Tests not run: missing system
package". Follow the runbook on a feature that reported tests not run: rebuild
with `--apt` (or `--agent-root`), restart the instance, `Autonomous.resume/2` the
feature. Target: under 10 minutes end to end.

## 6. SC-001 replay

Rebuild with the mod-player audio packages declared, resume feature 003 on
mod-player ⇒ its implement summary reports tests run (no "Tests: not run").
