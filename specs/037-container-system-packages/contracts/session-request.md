# Contract: Session request, preflight, and operator surfaces

## `Autonomous.AgentRoot` (new)

```elixir
@spec advertised?(%{optional(String.t()) => String.t()}) :: boolean()   # default System.get_env()
@spec session_env(boolean()) :: %{String.t() => String.t()}
@spec prompt_note(boolean()) :: String.t()
@spec installs(PhaseResult.t()) :: [%{command: String.t(), packages: [String.t()]}]
@spec log_installs(Feature.t(), atom(), PhaseResult.t()) :: :ok
```

- `advertised?/1` is the module's only env read; the rest is pure.
- `session_env(false) == %{}`; `prompt_note(false) == ""`.
- `prompt_note(true)` = `"\n\n" <> Prompts.load("agent_root")`.

`priv/prompts/agent_root.md` (new, embedded by `Prompts`):

> Agent root is available in this container. If the target cannot build or its
> tests cannot run because an operating-system package is missing (headers,
> `pkg-config`, native libraries), install it with
> `sudo apt-get update && sudo apt-get install -y --no-install-recommends <packages>`
> and continue — do not report the tests as not run for that reason. Only
> `apt-get`/`apt` `update`/`install` and `dpkg` queries are allowed under sudo;
> never remove, purge, or upgrade packages. Installed packages last only for this
> container: name them in your final summary.

## `PhaseRequest`

New option `:agent_root` (boolean; default `AgentRoot.advertised?()`), on
`build/3` and `build_remediation/3`.

| Aspect | `agent_root: false` | `agent_root: true` |
|---|---|---|
| `metadata["claude"][:env]` | today's map | today's map ∪ `AUTONOMOUS_CONTAINER=1`, `AUTONOMOUS_AGENT_ROOT=1` |
| `:implement` prompt (any scope, incl. `nil`) | today's | today's + note, placed after scope/headless rule, before resume/clarify/background-retry blocks |
| `:converge` prompt | today's | today's + note, same placement |
| every other phase / remediation prompt | today's | today's |
| permissions / tools | today's | today's (Bash already granted to implement/converge under strict) |

## Preflight (`Autonomous`)

When `AgentRoot.advertised?()` and the run's profile is `"strict"`, each
preflight path that already calls `TargetPack.verify/2` (`run/1` via
`preflight_stacked/2`, `spec_run_opts/3`) also calls
`TargetPack.agent_root_warning(Config.repo())`:

- `:ok` ⇒ nothing.
- `{:warning, {:pack_below_agent_root_contract, found, 5}}` ⇒ one
  `Logger.warning`: `agent root is available but the committed pack is contract <found>; strict sessions will keep denying sudo until TargetPack.install/2 is re-run and committed`.
  Run starts (not a preflight problem).

Not called when not advertised or under `permissive` (FR-012 "accepted silently").
Test-mode seams (`:runner`/`:executor`) skip it, as they skip `verify/2`.

## `TargetPack`

- `@pack_contract` → `5`; `@permissive_min_contract 4`; `@agent_root_min_contract 5`.
- `check_pack_contract/1` (permissive): passes for committed contract ≥ 4 and no
  `permissions.deny`; result shape unchanged.
- `agent_root_warning/1`: see data-model.md.

## Install log line (FR-018)

Called after each session at `RunFeaturePhase`, `ChunkRunner` (per chunk),
`RunRemediation`, `RunAutoRemediation`:

```text
agent root: feature <spec_label|id> (<phase>) installed system packages: <p1> <p2> — add them to `scripts/autonomous build --apt` to persist
```

One line per qualifying Bash call; nothing when there is none; nothing persisted.

## Console — Configuration page

| State | Render |
|---|---|
| not advertised | nothing new (byte-identical) |
| advertised, pack ≥ 5 | row `Agent root` — `available — strict allows sudo apt-get/apt install` |
| advertised, pack < 5 / unknown | same row + warning text `committed pack is contract <N>; re-run TargetPack.install/2 and commit for the exception to apply` |

Existing classes/tokens only; no `inspect/1`; passes `design_contract_test`.
