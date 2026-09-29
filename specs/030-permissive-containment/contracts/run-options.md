# Contract: run options, config, and session requests

## Configuration

```elixir
config :speckit_orchestrator, containment_profile: :strict   # shipped default
```

`Config.containment_profile/0 :: :strict | :permissive`. Any other value
raises `ArgumentError` naming the key and the value.

## Facade

### `SpeckitOrchestrator.run/1`

New option `:containment_profile` — `:strict | :permissive | "strict" | "permissive"`.
Absent → `Config.containment_profile/0`.

Preflight, before any store write:

| Condition | Result |
|---|---|
| unknown value | `{:error, {:preflight, [{:invalid_containment_profile, value}]}}` |
| `permissive` and committed pack is not contract 2 | `{:error, {:preflight, [{:pack_outdated, path, hint}]}}` |

The resolved value is captured into `RunContext.containment_profile` and
recorded with the run.

### `resume/2`, `continue_run/1`, `resume_run/1`, publish-only resume

The profile always comes from the recorded run (`RunContext.from_map/1`;
missing ⇒ `"strict"`).

| Explicit `:containment_profile` opt | Result |
|---|---|
| absent | recorded profile |
| equal to recorded | recorded profile (no-op) |
| different | `{:error, {:preflight, [{:containment_profile_locked, recorded}]}}`, no side effect |

A changed `Config.containment_profile/0` never affects these paths (SC-005).

## Trigger Run page

A two-option control (`strict` / `permissive`), initial value from
`Config.containment_profile/0`. The selection is passed as
`containment_profile:` to `run/1`. Selecting `permissive` shows a one-line
consequence under the control: the pack adds no deny list, and running in
the container recipe is recommended.

## `PhaseRequest`

`build/3` and `build_remediation/3` accept `containment: "strict" | "permissive"`
(default `"strict"`).

| | `strict` | `permissive` |
|---|---|---|
| `permission_mode` | today's per-phase value | `:bypass_permissions` |
| `allowed_tools` | today's per-phase set | `Read Write Edit MultiEdit NotebookEdit Bash Grep Glob WebFetch WebSearch` |
| `disallowed_tools` | today's per-phase set | `Agent Task ScheduleWakeup` |
| `metadata["claude"][:env]` | `Containment.session_env("strict")` | `Containment.session_env("permissive")` |

Every other `RunRequest` field (prompt, cwd, model, max_turns, session_id)
is independent of the profile.

Callers that must pass it: `RunFeaturePhase` (covers implement chunks),
`RunAutoRemediation`, `RunRemediation`, `Describe.run/4`. A test asserts that
every `RunRequest` reaching the harness from these sites carries
`SPECKIT_ORCHESTRATED=1`.
