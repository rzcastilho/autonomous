# Quickstart: Container Isolation for Autonomous Runs

**Feature**: `015-container-isolation` | **Spec**: [spec.md](./spec.md)

Runnable validation scenarios that prove the feature works end to end. Details
live in the contracts — this file is the run/validate guide, not an
implementation description.

**Platform**: a Linux host with a container engine. macOS and other host
platforms are unsupported and unverified for this feature (FR-014).

---

## Prerequisites

- Linux host, container engine installed, operator's own (non-root) account
- A **prepared** target repository: Spec Kit scaffolding, the enforcement pack,
  and a real (non-template) constitution, all committed. The container verifies
  this; it does not bootstrap it. See `docs/enforcement.md`
- Agent credentials — either `ANTHROPIC_API_KEY` or an authenticated host
  `~/.claude`
- `$HOME/.autonomous` exists on the host (`mkdir -p ~/.autonomous`)

---

## Scenario A — Operator onboarding (SC-003, User Story 1)

Target: a started, preflight-passing run in ≤3 commands and ≤15 minutes, from
documentation alone.

```bash
# 1. pull
docker pull ghcr.io/rzcastilho/autonomous:v<semver>

# 2. configure — fill in SPECKIT_REPO, credentials, git identity
cp docs/autonomous.env.example ./autonomous.env && $EDITOR ./autonomous.env

# 3. start
scripts/autonomous-container.sh start --env-file ./autonomous.env
```

**Expected**

- Container reaches `running`
- `docker logs autonomous` shows a preflight report ending `status=pass`
- `http://127.0.0.1:4000/` loads the console and reflects live state
- No run has started (idle boot — FR-029)

Start a run from the console, or set `AUTONOMOUS_AUTOSTART=<breakdown-slug>` in
the env file and restart to have it launch on boot.

**Fails if**: any of the three commands needs an undocumented step; the operator
must read source to resolve a preflight message; or wall-clock exceeds 15 min.

---

## Scenario B — Run parity (SC-001, User Story 1)

Run the reference backlog twice against a fixture target — once on-machine, once
containerized — and diff the outcomes.

```bash
# on-machine
mise exec -- mix run -e 'SpeckitOrchestrator.run(...)'   # see docs/runbook.md

# containerized
scripts/autonomous-container.sh start --env-file ./autonomous.env \
  --autostart <breakdown-slug>
```

**Expected**: identical per-feature terminal statuses and identical set of
`feature/NNN-slug` branches, across 100% of features. Artifacts present in
`$HOME/.autonomous/transcripts/<segment>/…` from the host.

**Also assert** (User Story 1, scenario 3 / SC-008): a target repository pinning
a runtime different from the orchestrator's resolves and uses **its** pinned
version — verified from `resolved_versions.target_toolchain` in
`$HOME/.autonomous/preflight/latest.json`, not from whatever the base image
carries.

---

## Scenario C — Red team (SC-002, User Story 2)

Blast-radius proof with the in-repo guard hook **deliberately disabled**, so only
the OS layer is under test.

```bash
mise exec -- mix test --include integration \
  test/integration/container_red_team_test.exs
```

The suite checksums the host tree outside the declared mounts, then executes ≥10
hostile commands in the container — out-of-tree writes, writes to `$HOME`
outside `.autonomous`, `sudo`, setuid escalation, system-directory writes,
package installs into system paths, writes to `/etc` and `/usr`.

**Expected**: 100% of attempts fail; the host checksum is byte-for-byte
unchanged; the container is still healthy afterwards.

**Not tested, by design**: network egress. FR-016 scopes the guarantee to
filesystem, privileges, and process scope.

---

## Scenario D — File ownership (SC-004, User Story 2 scenario 3)

After any run that wrote to the target repository:

```bash
find "$REPO" -newermt '-1 hour' -printf '%u:%g %p\n' | sort -u
```

**Expected**: every entry is the invoking operator's user:group. Editing and
deleting them requires no elevation.

---

## Scenario E — Survive stop and restart (SC-006, User Story 3)

```bash
# with a run in flight
docker stop --time 900 autonomous
docker start autonomous
```

**Expected**

- Transcripts, run manifests, checkpoints, and per-feature worktrees from that
  run are all present and readable — from the host, without entering the
  container
- Recorded spend after restart equals the spend recorded before the stop
- The in-flight phase either completed or is recorded as `interrupted` with its
  reservation intact — the tally never under-counts (FR-027)

---

## Scenario F — Operator surface while in flight (User Story 3)

```bash
docker exec -it autonomous bin/speckit_orchestrator remote
```

```elixir
SpeckitOrchestrator.print_status()
SpeckitOrchestrator.resolve("003-slug")
SpeckitOrchestrator.resume("003-slug", from: :plan)
```

**Expected**: status, resolution, and resume behave exactly as on-machine. No
build tooling is present or required (FR-025).

Also: `docker logs -f autonomous` shows phase and terminal-state events without
any interactive session (FR-028).

---

## Scenario G — Preflight failure modes (SC-007, User Story 4)

Start the container with each requirement omitted in turn and confirm the
message names the missing item **and** the single fix, and that no feature work
begins. Full matrix in
[`contracts/container-run.md` §8](./contracts/container-run.md#8-rejection-matrix).

| Omission | Expect |
|---|---|
| Drop `-v "$HOME/.autonomous:$HOME/.autonomous"` | `run_state_durable` fails naming the `-v` flag to add |
| Mount the repo at a different container path | `repo_path_identity` fails naming both paths |
| Remove agent credentials | `credential_agent` fails naming both supported paths — **no credential value printed** |
| Set `AUTONOMOUS_AUTOSTART` with any of the above | Container stays up **idle**, failure in logs and console, no run, no success reported (FR-031) |
| Unprepared target repo (template constitution) | `target_pack` fails with the `TargetPack.verify/1` reason |

Assert additionally: no output of any failing scenario contains a credential
value, prefix, or length (FR-035).

---

## Scenario H — Publishing (SC-010, SC-011)

```bash
git tag v<semver> && git push origin v<semver>
```

**Expected**

- The workflow builds, secret-scans, smoke-tests, and pushes with **zero** manual
  build-or-push steps
- Re-running the workflow for an existing `v<semver>` **fails at the immutability
  guard** rather than overwriting
- `docker pull …:v<semver>` twice yields the same digest
- `docker exec … cat /etc/autonomous/image.json` reports the source revision,
  orchestrator version, and pinned tool versions (FR-007)

Local development build parity:

```bash
docker build --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" -t autonomous:dev .
```

---

## Scenario I — Overhead budget (SC-009)

Wall-clock the reference backlog on-machine and containerized on the same Linux
host.

**Expected**: containerized end-to-end wall-clock within 110% of on-machine.
First-run target-toolchain acquisition is excluded from the comparison (it is
cached into the run-state mount and amortised — see FR-038 and
[`contracts/environment.md` §6](./contracts/environment.md#6-toolchain-manager-fr-004)).

---

## Disk reclaim (FR-038)

| Path | Safe to delete |
|---|---|
| `$HOME/.autonomous/mise/cache` | always — re-fetched on demand |
| `$HOME/.autonomous/mise/data` | yes, at the cost of re-downloading target toolchains |
| `$HOME/.autonomous/preflight/*.json` | yes, except `latest.json` while diagnosing |
| `$HOME/.autonomous/transcripts/<segment>/…` | yes once the feature's post-mortem is done |
| `$HOME/.autonomous/worktrees/<segment>/…` | **no** while a feature is escalated/halted awaiting resolution |
