# Quickstart & Validation: Always-Containerized Runtime

Run from the repository root on a Linux host with Docker Engine + Compose v2.
Contracts: [wrapper-cli](contracts/wrapper-cli.md),
[environment](contracts/environment.md), [compose-services](contracts/compose-services.md).

## Prerequisites

- `docker compose version` reports v2.
- A prepared sibling target, e.g. `../ledgerlite` (pack installed and committed,
  `origin` set, `TargetPack.verify/1` passes).
- `cp .env.example .env`, then fill `ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN`),
  `GH_TOKEN`, model pins, and — for the release — `AUTONOMOUS_SECRET_KEY_BASE`.

## 1. Operator shell (US1, SC-001, SC-004)

```bash
scripts/autonomous shell --target ../ledgerlite     # builds on first use
```

Expect the four start lines (target, instance, console, budget). In `iex`:

```elixir
Autonomous.status()
Autonomous.run()            # one backlog feature end to end
```

Expect phases to advance, a worktree under `~/.autonomous/worktrees/<segment>/`, and a
PR URL in the report.

## 2. Host refusal and host dev loop (US1 sc. 3–4, SC-002, SC-003)

```bash
mise exec -- iex -S mix          # expect the ContainerGuard refusal text; exit non-zero
mise exec -- mix phx.server      # same refusal
ls ~/.autonomous/instances       # unchanged by the two attempts
mise exec -- mix compile && mise exec -- mix test    # pass on host
scripts/autonomous test                               # pass in container
```

## 3. Persistence across recreation (US2, SC-005, SC-006)

1. In the shell, start a run until a feature halts or escalates; note its id.
2. Exit; `scripts/autonomous build`; `scripts/autonomous shell --target ../ledgerlite`.
3. Expect boot with no `schema_node_mismatch`; `Autonomous.status()` lists the run;
   `Autonomous.resume(<id>)` resumes at the checkpointed phase.
4. From the host: `git -C ../ledgerlite worktree list` shows the kept worktree, not
   `prunable`.

## 4. Console (US3, SC-007)

```bash
scripts/autonomous console --target ../ledgerlite --port 4100
curl -sf http://127.0.0.1:4100/ >/dev/null && echo ok
scripts/autonomous port --target ../ledgerlite
```

From a second machine on the LAN: `curl http://<host-lan-ip>:4100/` ⇒ connection
refused. Start with no `--port` ⇒ a random port is printed. Start with a busy port ⇒
exit 76 naming it.

## 5. Concurrent instances (SC-007a)

```bash
scripts/autonomous console --target ../ledgerlite
scripts/autonomous console --target ../other-target         # both run, different ports
scripts/autonomous shell   --target ../ledgerlite            # exit 75, names the live instance
```

Each instance has its own `~/.autonomous/instances/<segment>/mnesia`.

## 6. Release (US4, SC-008)

```bash
scripts/autonomous release --target ../ledgerlite
scripts/autonomous remote  --target ../ledgerlite    # Autonomous.status() works
docker compose -p autonomous-<segment> restart release
scripts/autonomous remote  --target ../ledgerlite    # history still listed
```

Unset `AUTONOMOUS_SECRET_KEY_BASE` ⇒ the release refuses, naming the variable.

## 7. Testing capabilities (US5, US6, SC-009, SC-010)

```bash
scripts/autonomous build --web --desktop --android
scripts/container-smoke.sh capabilities      # runs the sample tests below from a strict orchestrated session
```

- web: sample Playwright test in chromium, firefox, webkit — passes offline.
- desktop: `AUTONOMOUS_DISPLAY=1`; sample Electron/X app, `xdotool` click, `import`
  screenshot written.
- android: with `compose.android.yaml` (`/dev/kvm`) — `android-emulator` boots, sample
  instrumented test passes; without KVM, `ADB_SERVER_SOCKET=tcp:host.docker.internal:5037`
  against a host emulator — passes; with neither — fails naming both options.
- `mise exec -- mix test test/autonomous/scope_guard_test.exs` — all red-team cases
  pass (SC-010).
- `scripts/autonomous build` (no flags) then `container-smoke.sh absent` — no
  Playwright browsers, Xvfb, Android SDK in the image.

## 8. Credentials and secrets (SC-011, SC-012)

- Repeat step 1 with `--with-login` and no token in `.env` ⇒ run succeeds.
- `scripts/container-smoke.sh secrets` ⇒ no `.env` value found in any image layer or in
  `git grep`.
- Unset both agent credentials ⇒ start warns naming both options.

## Smoke script summary

`scripts/container-smoke.sh [all|refusal|persistence|concurrency|capabilities|absent|secrets]`
automates sections 2, 3 (except resume), 5, 7 and 8; sections 1, 3-resume, 4
(second machine) and 6 stay manual.
