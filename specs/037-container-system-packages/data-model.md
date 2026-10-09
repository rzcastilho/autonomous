# Data Model: Container System Packages

**Feature**: 037-container-system-packages

No store schema change and no new persisted field (Clarifications: nothing on
the run record). The entities below live in the image, the process environment,
or memory only.

## Declared package list (image build time)

| Field | Type | Source | Rules |
|---|---|---|---|
| tokens | list of strings | `scripts/autonomous build --apt …` (repeatable; whitespace/comma split) | each matches `^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$`, else exit 2 before any build (FR-004) |
| `EXTRA_APT_PACKAGES` | build arg (string) | tokens joined by one space | empty ⇒ Dockerfile block is a no-op (FR-002) |
| `/etc/autonomous/apt-packages` | file in image | one token per line | present **only** when the list is non-empty; read by `sysdeps` smoke |

Lifecycle: fixed per image. Rebuilding without `--apt` drops the list (documented).
Unknown package ⇒ `apt-get` non-zero ⇒ build fails, no tag (FR-003).

## Agent-root capability

| Field | Type | Where | Rules |
|---|---|---|---|
| `WITH_AGENT_ROOT` | build arg `0`/`1` | `--agent-root` | `1` installs `sudo`, sudoers drop-in, apt no-remove drop-in; `0` = nothing (FR-006) |
| `/etc/sudoers.d/autonomous-agent-root` | file `0440` | image | `Defaults env_keep += "DEBIAN_FRONTEND"`; `ALL ALL=(root) NOPASSWD: ALL` |
| `/etc/apt/apt.conf.d/99autonomous-no-remove` | file | image | `APT::Get::Remove "false";` |
| `AUTONOMOUS_AGENT_ROOT` | process env | exported by entrypoint | always `unset` first; set to `1` **only** after `sudo -n true` succeeds (FR-007) |
| `AUTONOMOUS_CONTAINER` | process env | image `ENV` (existing) | `1` inside the image |

State (per container start):

```text
image without sudo ───────────────────────────────► not advertised (silent)
image with sudo ──► sudo -n true ok ──────────────► advertised (AUTONOMOUS_AGENT_ROOT=1)
                └─► sudo -n true fails ───────────► not advertised (+ warning line)
```

`AgentRoot.advertised?(env)` ⇔ `env["AUTONOMOUS_CONTAINER"] == "1" and
env["AUTONOMOUS_AGENT_ROOT"] == "1"`.

## Session launch env (per session, in memory)

`PhaseRequest` `metadata["claude"][:env]` = existing
`Containment.session_env(profile)` ∪ shell timeouts ∪ collector ∪
`AgentRoot.session_env(agent_root?)`, where the last is `%{}` when not
advertised (request byte-identical to today) and
`%{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_AGENT_ROOT" => "1"}` when it is.

## Hook decision matrix (pack contract 5)

| origin | profile | both markers | privileged command shape | decision |
|---|---|---|---|---|
| interactive | — | any | any | allow (unchanged) |
| orchestrated/undecided | permissive | any | any | allow (unchanged) |
| orchestrated/undecided | strict | no | any `sudo` | deny `bash_sudo` / `sudo` (unchanged) |
| orchestrated/undecided | strict | yes | every `sudo` segment matches the R5 grammar | `bash_sudo` skipped; other rules still apply |
| orchestrated/undecided | strict | yes | any `sudo` segment outside the grammar | deny `bash_sudo` / extended detail |

## Pack contract version

| Constant | Value | Meaning |
|---|---|---|
| hook `PACK_CONTRACT` | 5 | installed by `TargetPack.install/2` |
| `@permissive_min_contract` | 4 | permissive preflight passes at ≥ 4 and no `permissions.deny` (unchanged meaning) |
| `@agent_root_min_contract` | 5 | below it, with agent root advertised under `strict`: warning, run starts |

`TargetPack.agent_root_warning(repo) :: :ok | {:warning, {:pack_below_agent_root_contract, integer() | :unknown, 5}}`
— reads the **committed** hook; `:unknown` when git show / probe fails.

## Install observation (in memory, logged only)

`AgentRoot.installs(PhaseResult.t()) :: [%{command: String.t(), packages: [String.t()]}]`
— one entry per Bash tool call carrying ≥1 `sudo … apt(-get) install <pkgs>`
segment whose tool result is not a `scope_guard[` denial. Each entry ⇒ one
`Logger.info` line naming feature, phase, and packages (FR-018). Not persisted.

## Configuration page view state (in memory)

`AgentRootView.state(advertised?, warning) :: :hidden | :available | {:pack_outdated, found}`
— `:hidden` renders nothing (page byte-identical).
