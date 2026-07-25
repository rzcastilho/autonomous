# Contract: Run Container Invocation

**Feature**: `015-container-isolation` | Satisfies FR-011, FR-012, FR-013,
FR-014, FR-016, FR-018, FR-024, FR-025, FR-027, FR-029, FR-030.

This is the contract between the operator (or the launcher script
`scripts/autonomous-container.sh`) and the image. Any invocation that omits a
MUST below is rejected at boot by preflight rather than producing artifacts that
are valid on only one side.

**Supported platform**: a Linux container engine, only (FR-014). macOS desktop
engines and other host platforms are unverified for this feature.

---

## 1. Canonical invocation

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
  ghcr.io/rzcastilho/autonomous:v0.1.0
```

`scripts/autonomous-container.sh` emits exactly this, deriving every host value
itself so the two path-identity assertions cannot drift from the two `-v` flags.

---

## 2. Mounts

| Host path | Container path | Mode | Required | Purpose |
|---|---|---|---|---|
| `$REPO` | **identical** | rw | MUST | Target repository — the only place agent-authored code changes land |
| `$HOME/.autonomous` | **identical** | rw | MUST | Run-state root: worktrees, transcripts, run manifests, checkpoints, preflight reports, mise data |
| `$HOME/.claude` | `/run/secrets/claude` | **ro** | optional | Pre-authenticated agent configuration (credential path B) |
| `/etc/passwd`, `/etc/group` | identical | ro | optional | Only if a tool insists on resolving the UID to a name |

**Path identity (FR-018)**: the first two MUST be mounted at the identical
absolute path they occupy on the host. Container paths recorded in run artifacts
are then valid from the host with no translation, and every per-feature worktree
under `$HOME/.autonomous/worktrees/<segment>/…` resolves on both sides.

**Nested mounts**: `$HOME` is a tmpfs and `$HOME/.autonomous` is a bind mounted
*inside* it. The engine applies mounts in path-depth order. Preflight asserts the
result (`:run_state_durable`) rather than trusting the ordering.

---

## 3. Writable surface (FR-012)

| Path | Nature |
|---|---|
| `$REPO` | durable, host-backed |
| `$HOME/.autonomous` | durable, host-backed |
| `$HOME` (excluding the above) | ephemeral tmpfs — `$HOME/.claude`, `$HOME/.config`, tool scratch |
| `/tmp` | ephemeral tmpfs |
| everything else | **read-only** (`--read-only` root filesystem) |

Exactly two durable writable areas. Everything else is read-only or ephemeral.

---

## 4. Privilege posture (FR-011)

| Flag | Effect |
|---|---|
| `--user <uid>:<gid>` | Unprivileged; also makes created files host-owned by the operator (FR-013) |
| `--cap-drop ALL` | No capabilities |
| `--security-opt no-new-privileges` | setuid/setgid escalation cannot raise privileges |
| `--read-only` | System-directory writes fail at the OS layer |
| `--pids-limit` | A runaway fork bomb cannot wedge the host |

**Not restricted**: network egress (FR-016). The isolation claim covers
filesystem writes, privileges, and process scope — **not** exfiltration. This
contract intentionally emits no `--network` restriction.

---

## 5. Ports

| Container | Host publish | Notes |
|---|---|---|
| `AUTONOMOUS_CONSOLE_PORT` (default 4000) | `127.0.0.1:<port>` | FR-024 — loopback publish keeps the unauthenticated console on the operator's machine. The in-container bind is `0.0.0.0` because a loopback bind inside a network namespace is unreachable from the host |

---

## 6. Lifecycle (FR-029, FR-030, FR-031, FR-027)

| Event | Behaviour |
|---|---|
| Start, `AUTONOMOUS_AUTOSTART` unset | Supervision tree + console come up; **no run starts**; container stays up |
| Start, `AUTONOMOUS_AUTOSTART` set, preflight `:pass`/`:warn` | The named run launches with no operator action |
| Start, `AUTONOMOUS_AUTOSTART` set, preflight `:fail` | **No run starts.** Container stays up idle; the failure is in `docker logs` and in the console; the container reports no success |
| Run drains | Container **stays up**. Report, transcripts, and preserved worktrees remain inspectable. Exit is operator-initiated only |
| `docker stop` | `SIGTERM` → release → `init:stop` → supervision tree terminates in order. `Coordinator` and `Ledger` flush the run manifest and the cost tally. An in-flight phase either completes within `--stop-timeout` or is recorded as `interrupted` with its reservation intact — the tally never under-counts |
| `docker kill` | Not supported. Documented as the one path that can lose the in-flight phase's record |

`--stop-timeout` MUST be set well above the longest expected phase (the action
timeout is 45 minutes; the launcher defaults to 900s and documents raising it).
Prefer draining from the console over a hard stop.

---

## 7. Operator surfaces

| Need | Command |
|---|---|
| Console (FR-024) | open `http://127.0.0.1:4000/` |
| Interactive session (FR-025) | `docker exec -it autonomous bin/speckit_orchestrator remote` — then `SpeckitOrchestrator.print_status/0`, `resolve/1`, `resume/2` |
| Follow a run without a session (FR-028) | `docker logs -f autonomous` — carries the existing `[:speckit, :phase, …]` and `[:speckit, :feature, :terminal]` events |
| Read artifacts from the host (FR-026) | `$HOME/.autonomous/transcripts/…`, `…/worktrees/…`, `…/preflight/latest.json` |
| Image identity (FR-007) | `docker exec autonomous cat /etc/autonomous/image.json` |

---

## 8. Rejection matrix

Every row stops the boot before any agent spend (FR-033).

| Misconfiguration | Detected by | Message names |
|---|---|---|
| `SPECKIT_REPO` unset | boot | the variable |
| Repo mounted at a different container path | `:repo_path_identity` | both paths and the `-v` form that fixes it |
| `HOME` not the host home path | `:home_path_identity` | both values |
| Run-state root not a mount point | `:run_state_durable` | the resolved path and the `-v` flag to add |
| Run-state root not writable | `:run_state_writable` | the path and the `--user` value observed |
| Container running as root | `:unprivileged` | the effective UID and `--user` |
| No agent credential | `:credential_agent` | the two supported paths, **no values** |
| Required tool missing/mismatched | `:tool_*` | the tool, the expected pin, the observed version |
| Target repo not prepared | `:target_pack` | the `TargetPack.verify/1` reason and its fix |

---

## 9. Concurrency

One container per target repository at a time. Two containers sharing a target
repository or a run-state root is **not** a supported configuration and is not
guarded against in this feature.
