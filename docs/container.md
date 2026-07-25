# Running the orchestrator as a container

The container packaging (feature 015) lets an operator drive a full backlog
without ever executing agent-authored commands on their own machine. This is
the first-time operator path; ops details for a run already in flight live in
`docs/runbook.md`, and the containment model (why the container is one of
three layers, not a replacement for the others) lives in `docs/enforcement.md`.

**Platform**: a Linux host with a container engine, only (FR-014). macOS and
other host platforms are unsupported and unverified for this feature.

---

## Prerequisites

- Linux host, container engine installed, operator's own (non-root) account
- A **prepared** target repository: Spec Kit scaffolding, the enforcement
  pack, and a real (non-template) constitution, all committed. The container
  verifies this at preflight; it does not bootstrap it — see
  `docs/enforcement.md`
- Agent credentials — either `ANTHROPIC_API_KEY` or an authenticated host
  `~/.claude`
- `$HOME/.autonomous` exists on the host: `mkdir -p ~/.autonomous`

---

## 1. Pull, configure, start (SC-003)

Three commands, from documentation alone, to a started, preflight-passing
run:

```bash
# 1. pull
docker pull ghcr.io/rzcastilho/autonomous:v<semver>

# 2. configure — fill in SPECKIT_REPO, credentials, git identity
cp docs/autonomous.env.example ./autonomous.env
$EDITOR ./autonomous.env

# 3. start
scripts/autonomous-container.sh start --env-file ./autonomous.env
```

`autonomous.env` at minimum needs:

```dotenv
SPECKIT_REPO=/home/alice/code/ledgerlite
ANTHROPIC_API_KEY=
GIT_AUTHOR_NAME=Alice Example
GIT_AUTHOR_EMAIL=alice@example.com
GIT_COMMITTER_NAME=Alice Example
GIT_COMMITTER_EMAIL=alice@example.com
```

The full reference skeleton — every setting, required and optional — is
`docs/autonomous.env.example` (`contracts/environment.md` §7 in the feature's
spec folder for the field-by-field contract).

`scripts/autonomous-container.sh` derives every mount and path-identity
assertion from **host** values (`$SPECKIT_REPO` from the env file, `$HOME`
from the invoking shell), so the two `-v` flags and the two
`AUTONOMOUS_HOST_*` assertions can never drift apart — the operator never
hand-writes a container path. It emits the canonical invocation:

```bash
docker run -d --name autonomous \
  --user "$(id -u):$(id -g)" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 4096 \
  --stop-timeout 900 \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --tmpfs "$HOME":rw,nosuid,nodev,mode=0700,uid=$(id -u),gid=$(id -g) \
  -v "$REPO:$REPO" \
  -v "$HOME/.autonomous:$HOME/.autonomous" \
  -v "$HOME/.claude:/run/secrets/claude:ro" \
  -p 127.0.0.1:4000:4000 \
  --env-file ./autonomous.env \
  -e HOME="$HOME" \
  -e AUTONOMOUS_HOST_REPO="$REPO" \
  -e AUTONOMOUS_HOST_HOME="$HOME" \
  -e RELEASE_COOKIE="$(head -c 32 /dev/urandom | base64)" \
  ghcr.io/rzcastilho/autonomous:v<semver>
```

**Expected**

- `docker ps` shows `autonomous` running
- `docker logs autonomous` shows a preflight report ending `status=pass` (or
  `status=warn`)
- `http://127.0.0.1:4000/` loads the console and reflects live state
- **No run has started** — the container boots idle by default (FR-029)

**Fails if**: any of the three commands needs an undocumented step; the
operator must read source to resolve a preflight message; or wall-clock
exceeds 15 minutes (SC-003). If preflight fails, see §5.

---

## 2. Launch a run

Either from the console (`http://127.0.0.1:4000/`), or by setting
`AUTONOMOUS_AUTOSTART` in the env file and restarting:

```dotenv
AUTONOMOUS_AUTOSTART=003-widget    # a breakdown slug, or the literal ad-hoc
```

```bash
scripts/autonomous-container.sh stop
scripts/autonomous-container.sh start --env-file ./autonomous.env
```

Or pass it directly at start without editing the file:

```bash
scripts/autonomous-container.sh start --env-file ./autonomous.env --autostart 003-widget
```

With a passing preflight, the named run launches with no further operator
action; the container stays up after it drains (FR-030), so the report,
transcripts, and worktrees remain inspectable. With a failing preflight, no
run starts, the container stays up **idle**, and the failure is visible in
`docker logs` and the console (FR-031) — no success is ever reported for a
run that never started.

---

## 3. Observe and operate

| Need | Command |
|---|---|
| Console | `http://127.0.0.1:4000/` |
| Interactive session | `docker exec -it autonomous bin/speckit_orchestrator remote`, then `SpeckitOrchestrator.print_status/0`, `resolve/1`, `resume/2` |
| Follow a run headlessly | `docker logs -f autonomous` |
| Read artifacts from the host | `$HOME/.autonomous/transcripts/…`, `…/worktrees/…`, `…/preflight/latest.json` |
| Image identity | `docker exec autonomous cat /etc/autonomous/image.json` |

Because the target repository and the run-state root are mounted at their
**identical host paths** (FR-018/FR-019), every artifact the container
produces — commits, branches, transcripts, checkpoints, the preflight report
— is directly readable and editable from the host with no path translation.
See `docs/runbook.md` for day-to-day operator usage once a run is in flight,
including stop/restart guidance.

---

## 4. Stop

```bash
scripts/autonomous-container.sh stop
```

Sends `SIGTERM`, giving the release up to `--stop-timeout` (default 900s) to
drain: `Coordinator` and `Ledger` flush the run manifest and the cost tally
on shutdown, and an in-flight phase either finishes within the grace period
or is recorded `interrupted` with its `Ledger` reservation intact, so the
tally never misreports spend (FR-027). Prefer draining from the console over
a hard stop where possible. `docker kill` is not supported — it is the one
path that can lose an in-flight phase's record.

---

## 5. Preflight failure modes (SC-007)

Every row below stops the boot **before any agent spend**. This is the full
FR-033/SC-007 rejection matrix — every requirement omission preflight can
detect, each naming the specific missing item and the single action that
fixes it (matches `contracts/container-run.md` §8 and quickstart.md
Scenario G; the complete check inventory with `:warn` conditions too is
`contracts/preflight-report.md` §3, feature 015 spec folder):

| Omission | Check that fails | Message names |
|---|---|---|
| `SPECKIT_REPO` unset | boot itself | the variable |
| Repo mounted at a different container path | `repo_path_identity` | both paths and the `-v` form that fixes it |
| `HOME` not the host home path | `home_path_identity` | both values |
| Missing `-v "$HOME/.autonomous:$HOME/.autonomous"` | `run_state_durable` | the resolved path and the `-v` flag to add |
| Run-state root mounted but not writable by `--user` | `run_state_writable` | the resolved path and the observed `--user` value |
| Container started without `--user <uid>:<gid>` (running as root) | `unprivileged` | the effective UID (`0`) and the `--user` value to set |
| No agent credential (`ANTHROPIC_API_KEY` unset and no mounted `~/.claude`) | `credential_agent` | the two supported paths — **never a credential value** |
| Required tool missing or version-mismatched | `tool_*` | the tool, expected pin, observed version |
| Target repo not prepared (template constitution, missing hook, uncommitted) | `target_pack` | the `TargetPack.verify/1` reason and its fix |

Assert additionally (FR-035): no failing check's message ever contains a
credential value, prefix, suffix, or length — credential checks record
**source** only (`env` / `mounted_config` / `absent`).

If `AUTONOMOUS_AUTOSTART` is set alongside any of the above, the container
still starts and stays up **idle** — the failure is in the logs and the
console, no run begins, and no success is ever reported (FR-031).

A passing or warning report additionally records `resolved_versions` for
every resolved tool and runtime (including a target repo's own pinned
runtime, resolved via `mise` — see §6), so the run stays reproducible and
later drift diagnosable (FR-034). The report is always written, pass or
fail, to `$HOME/.autonomous/preflight/<iso8601>-<status>.json`, with the
newest copied to `preflight/latest.json`.

---

## 6. Target repositories with their own toolchain pin

The image carries `mise` alongside the pipeline's own tools, so a single
image drives target repositories of different stacks. The first run against
a target pinning an unfamiliar runtime acquires it and caches it under
`$HOME/.autonomous/mise/data` (durable, persists across runs and restarts);
subsequent runs reuse the cache. Verify what was actually resolved —
never assume the base image's own version — via
`resolved_versions.target_toolchain` in `preflight/latest.json`.

---

## 7. Local development build

The normal operator path is pulling a published image (`docker pull
ghcr.io/rzcastilho/autonomous:v<semver>`). For development, the identical
`Dockerfile` and build args build locally, without a registry:

```bash
docker build \
  --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t autonomous:dev .
```

```bash
scripts/autonomous-container.sh start --env-file ./autonomous.env \
  --image autonomous:dev
```

`autonomous:dev` carries **no version identity** — its
`/etc/autonomous/image.json` and OCI labels record whatever `SOURCE_REVISION`
was passed at build time, but the tag itself is not immutable and is
**not reproducible across machines**. Use a published `v<semver>` tag for
anything that needs to be reproduced later.

---

## 8. Disk reclaim (FR-038)

Acquired toolchains, dependency caches, and transcripts accumulate under
`$HOME/.autonomous` across runs. What is safe to delete:

| Path | Safe to delete |
|---|---|
| `$HOME/.autonomous/mise/cache` | always — re-fetched on demand |
| `$HOME/.autonomous/mise/data` | yes, at the cost of re-downloading target toolchains on the next run |
| `$HOME/.autonomous/preflight/*.json` | yes, except `latest.json` while diagnosing a failure |
| `$HOME/.autonomous/transcripts/<segment>/…` | yes, once that feature's post-mortem is done |
| `$HOME/.autonomous/worktrees/<segment>/…` | **no** — not while a feature is escalated or halted awaiting resolution |
