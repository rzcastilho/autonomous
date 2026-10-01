# Contract: Environment variables and build args

## Build args (`Dockerfile`)

| Arg | Default | Purpose |
|---|---|---|
| `UID`, `GID` | `1000` | Container user ids (FR-006) |
| `GH_VERSION` | pinned | `gh` CLI version |
| `NODE_MAJOR` | `22` | Node.js major (tool runtime for the CLI) |
| `CLAUDE_CODE_VERSION` | pinned | `@anthropic-ai/claude-code` version (FR-011) |
| `WITH_WEB`, `WITH_DESKTOP`, `WITH_ANDROID` | `0` | Testing capabilities (FR-023) |
| `PLAYWRIGHT_VERSION` | pinned | Browser build set (web) |
| `ANDROID_SYSTEM_IMAGE` | pinned | e.g. `system-images;android-34;google_apis;x86_64` |

Erlang/Elixir versions are **not** build args: they come from `mise.toml` (FR-010).
No build arg carries a secret (FR-015).

## Set by the image (`ENV`)

| Var | Value | Reader |
|---|---|---|
| `AUTONOMOUS_CONTAINER` | `1` | `ContainerGuard` (FR-004) |
| `AUTONOMOUS_CONSOLE_IP` | `0.0.0.0` | `runtime.exs` |
| `PLAYWRIGHT_BROWSERS_PATH` | `/opt/ms-playwright` | Playwright (web) |
| `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` | `1` | Playwright (web) |
| `ANDROID_HOME` | `/opt/android` | Android tools |

## Set by the wrapper / entrypoint

| Var | Source | Reader |
|---|---|---|
| `AUTONOMOUS_REPO` | `--target` realpath | `runtime.exs` → `Config.repo/0` |
| `AUTONOMOUS_ROOT` | host `$HOME/.autonomous` | `runtime.exs` → `:autonomous_root` |
| `AUTONOMOUS_HOST_PORT` | `--port` or empty (random) | Compose port mapping |
| `AUTONOMOUS_INSTANCE_SEGMENT`, `AUTONOMOUS_NODE_NAME`, `AUTONOMOUS_STORE_DIR`, `AUTONOMOUS_COOKIE_PATH`, `AUTONOMOUS_INSTANCE_LOCK` | `Instance` derivation | entrypoint, `runtime.exs` (`:store_dir`), `rel/env.sh.eex` |
| `AUTONOMOUS_INSTANCE_LOCKED` | entrypoint after `flock` | `Instance.verify!/0` |
| `PHX_SERVER` | `true` for every service | `runtime.exs` → endpoint `server: true` |
| `DISPLAY` | `:99` when `AUTONOMOUS_DISPLAY=1` | sessions (desktop) |

## Operator-supplied (`.env`, from `.env.example`)

| Var | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | one of them, or `--with-login` | token wins over login; warn if none (FR-016) |
| `GH_TOKEN` | for publishing | push + `gh pr create` (FR-013) |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | optional | override `Worktree`'s `-c user.*` defaults (FR-014) |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL` | recommended | warn if unset (FR-016) |
| `AUTONOMOUS_SECRET_KEY_BASE` | **release: required** | release refuses without it (FR-022) |
| `AUTONOMOUS_CONSOLE_HOST` | optional, default `localhost` | endpoint `url.host` |
| `AUTONOMOUS_CONSOLE_PORT` | optional, default `4000` | container-side port |
| `AUTONOMOUS_BUDGET_USD`, `AUTONOMOUS_PR_BASE`, `AUTONOMOUS_PR_REMOTE`, `AUTONOMOUS_PLAN_STACK` | optional | unchanged semantics |
| `AUTONOMOUS_DISPLAY`, `AUTONOMOUS_DISPLAY_VIEWER` | optional | desktop capability |
| `ADB_SERVER_SOCKET` | optional | Android host fallback, e.g. `tcp:host.docker.internal:5037` |
| `AUTONOMOUS_PR_WORKFLOW`, `AUTONOMOUS_MAX_CONCURRENCY` | **must be absent** | still refused at boot (Principle II) |

`AUTONOMOUS_REPO` and `AUTONOMOUS_ROOT` in `.env` are ignored by the wrapper (it sets
them from `--target` and the host home) and the wrapper says so if present.
