# Contract: Boot Environment Configuration

**Feature**: `015-container-isolation` | Satisfies FR-020, FR-021, FR-022, FR-023,
FR-015, FR-019.

Environment configuration evaluated at boot is the **single** configuration
surface for a containerized run. `config/config.exs` values are baked into the
release and act only as defaults for non-required settings; a required setting
that is absent fails the boot loudly rather than falling back.

Consumers: `config/runtime.exs` (Application env) and
`SpeckitOrchestrator.Container.Env` (validation + the settings runtime.exs cannot
express).

---

## 1. Orchestrator settings

| Variable | Type | Required | Default | Failure when invalid |
|---|---|---|---|---|
| `SPECKIT_REPO` | absolute path | **yes** | — | boot raises `SPECKIT_REPO is not set` |
| `AUTONOMOUS_ROOT` | absolute path | no | `~/.autonomous` | must be absolute |
| `SPECKIT_SPECS_ROOT` | repo-relative path | no | `specs/autonomous` | must be relative |
| `SPECKIT_MAX_CONCURRENCY` | positive integer | no | `2` | raises naming var + value |
| `SPECKIT_BUDGET_USD` | float > 0 | no | `74.0` | raises naming var + value |
| `SPECKIT_IMPLEMENT_MAX_TURNS` | positive integer | no | `80` | raises |
| `SPECKIT_PHASE_MAX_RETRIES` | non-negative integer | no | `1` | raises |
| `SPECKIT_PLAN_STACK` | free text | no | *(empty — plan derives it)* | — |
| `SPECKIT_VERSION` | Spec Kit tag | no | `v0.12.11` | preflight compares to installed `specify` |
| `SPECKIT_PR_WORKFLOW` | `1\|true\|yes\|on` | no | `false` | anything else ⇒ `false` |
| `SPECKIT_PR_BASE` | branch name | no | `main` | — |
| `SPECKIT_PR_REMOTE` | remote name | no | `origin` | — |
| `SPECKIT_MODEL_<PHASE>` | `opus` \| `sonnet` | no | per `config.exs` `:models` | unknown alias ⇒ raises listing `Config.valid_models/0`; unknown `<PHASE>` ⇒ raises listing known phases |

`<PHASE>` ∈ `SPECIFY`, `CLARIFY`, `PLAN`, `TASKS`, `ANALYZE`, `IMPLEMENT`,
`CONVERGE`, `DESCRIBE`.

---

## 2. Lifecycle

| Variable | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `AUTONOMOUS_AUTOSTART` | `""` \| `ad-hoc` \| `<breakdown-slug>` | no | `""` | `""` ⇒ boot idle (FR-029). Otherwise launch that run once preflight passes (FR-030). Unrecognised value ⇒ boot raises |
| `AUTONOMOUS_CONSOLE_IP` | IPv4 literal | no | `0.0.0.0` | Bind **inside** the container; host exposure is the engine's `-p 127.0.0.1:…` (FR-024) |
| `AUTONOMOUS_CONSOLE_PORT` | port | no | `4000` | Also drives `check_origin` for `http://localhost:<port>` and `http://127.0.0.1:<port>` |
| `RELEASE_COOKIE` | opaque string | **yes in-container** | — | Erlang distribution cookie for `bin/speckit_orchestrator remote` (FR-025). Generated per container by the launcher; never baked into an image (FR-005) |
| `RELEASE_DISTRIBUTION` | `sname` | set by image | `sname` | Node bound to loopback |

---

## 3. Path identity assertions (FR-018, FR-019)

Supplied by the launcher from **host** values. These are assertions, not
configuration — preflight compares them to what it observes inside.

| Variable | Asserted equality | Failure |
|---|---|---|
| `AUTONOMOUS_HOST_REPO` | `== SPECKIT_REPO` | `:repo_path_identity` fails; no run starts |
| `AUTONOMOUS_HOST_HOME` | `== $HOME` | `:home_path_identity` fails; no run starts |
| `HOME` | must be the operator's **host** home path | `Config.autonomous_root/0` is `Path.expand("~/.autonomous")`; a wrong `HOME` silently relocates all run state |

---

## 4. Credentials (FR-021, FR-005, FR-035)

At least one agent credential path MUST be present or preflight's
`:credential_agent` check fails.

**Path A — direct secret value** (forwarded to the `claude` CLI by the harness's
known-key set):

| Variable | Notes |
|---|---|
| `ANTHROPIC_API_KEY` | |
| `ANTHROPIC_AUTH_TOKEN` | alternative to the above |
| `ANTHROPIC_BASE_URL` | optional gateway |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | pins the `opus` alias to a full model id |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | pins the `sonnet` alias |

**Path B — mounted pre-authenticated agent configuration**: the host's `~/.claude`
bind-mounted **read-only** at `/run/secrets/claude`. The entrypoint copies it to
the ephemeral `$HOME/.claude` and exports `CLAUDE_CONFIG_DIR=$HOME/.claude`.
No write reaches the host.

**Repository hosting** (PR workflow only):

| Variable | Notes |
|---|---|
| `GH_TOKEN` | Required when `SPECKIT_PR_WORKFLOW` is on; `:credential_gh` warns otherwise |

**Rules**

- Secrets MUST be supplied via `--env-file`, never inline on the command line.
- No credential value appears in the preflight report, the image manifest, logs,
  or any error message — only its **source**: `:env`, `:mounted_config`,
  `:absent` (FR-035).

---

## 5. Git identity and trust (FR-015)

| Variable | Required | Purpose |
|---|---|---|
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | **yes in-container** | Commit identity without a `~/.gitconfig` (the tmpfs `$HOME` has none) |
| `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | **yes in-container** | Same |
| `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=safe.directory`, `GIT_CONFIG_VALUE_0=*` | set by the entrypoint | Removes git's `dubious ownership` refusal on a bind-mounted repo without the operator hand-configuring trust |

---

## 6. Toolchain manager (FR-004)

Set by the image; overridable only for development.

| Variable | Value | Why |
|---|---|---|
| `MISE_DATA_DIR` | `$HOME/.autonomous/mise/data` | Acquired target toolchains persist across runs, inside a permitted writable area |
| `MISE_CACHE_DIR` | `$HOME/.autonomous/mise/cache` | Safe to delete to reclaim disk (FR-038) |
| `MISE_TRUSTED_CONFIG_PATHS` | `$SPECKIT_REPO` | No interactive trust prompt in a headless run |
| `MISE_YES` | `1` | Non-interactive installs |

---

## 7. Reference `.env` skeleton

```dotenv
# --- required ---
SPECKIT_REPO=/home/alice/code/ledgerlite
ANTHROPIC_API_KEY=

# --- git identity (required in-container) ---
GIT_AUTHOR_NAME=Alice Example
GIT_AUTHOR_EMAIL=alice@example.com
GIT_COMMITTER_NAME=Alice Example
GIT_COMMITTER_EMAIL=alice@example.com

# --- optional ---
SPECKIT_MAX_CONCURRENCY=2
SPECKIT_BUDGET_USD=74.0
AUTONOMOUS_AUTOSTART=
AUTONOMOUS_CONSOLE_PORT=4000
ANTHROPIC_DEFAULT_OPUS_MODEL=
ANTHROPIC_DEFAULT_SONNET_MODEL=
GH_TOKEN=
```

`AUTONOMOUS_HOST_REPO`, `AUTONOMOUS_HOST_HOME`, `HOME`, and `RELEASE_COOKIE` are
emitted by the launcher script, not written by hand.
