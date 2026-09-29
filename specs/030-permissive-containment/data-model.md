# Data Model: Permissive Containment Profile

Feature: `030-permissive-containment` | Research: [research.md](research.md)

No new Mnesia table, no schema version, no migration. The profile rides in
two existing free-form maps (`RunSettings.settings`, the checkpoint's
`run_context`).

## ContainmentProfile (value)

| Form | Values | Where |
|---|---|---|
| string | `"strict"` \| `"permissive"` | `RunContext`, `RunSettings.settings`, checkpoint JSON, env var, agent state |
| atom | `:strict` \| `:permissive` | `config :autonomous, containment_profile:` and facade opts only |

Rules:
- Atom → string conversion only (`Atom.to_string/1`). Never string → atom.
- Any value outside the two is refused at the boundary where it enters
  (`run/1` preflight, `Config.containment_profile/0`, Trigger form). The hook
  maps an unknown env value to `strict` (it cannot refuse, only decide).
- Default: `strict` at every layer.

Pure helper module `Autonomous.Containment`:
- `normalize/1 :: atom | String.t() -> {:ok, String.t()} | {:error, {:invalid_containment_profile, term}}`
- `permissive?/1 :: String.t() | nil -> boolean` (`nil` → `false`)
- `session_env/1 :: String.t() -> %{"AUTONOMOUS_ORCHESTRATED" => "1", "AUTONOMOUS_CONTAINMENT_PROFILE" => profile}`
- `pr_note/1 :: String.t() | nil -> String.t()` (`""` unless permissive)
- `report_line/1 :: String.t() | nil -> String.t() | nil` (`nil` unless permissive)

## RunContext (extended)

New field `containment_profile :: String.t() | nil` — the thirteenth key.

| Function | Behaviour |
|---|---|
| `capture/1` | `opts[:containment_profile]` over `Config.containment_profile/0`, stringified |
| `to_map/1` | always writes `"containment_profile"` |
| `from_map/1` | missing key → `"strict"` (pre-030 records were strict); present → as stored |
| `merge/2` | unchanged generic precedence; because `from_map/1` never yields `nil` for this key, a recorded run never falls back to live config |

## FeatureAgent / InitFeature state (extended)

New field `containment :: String.t()`, default `"strict"`. Seeded from
`run_context.containment_profile` by `FeatureRunner` via `feature.init`.
Read by `RunFeaturePhase`, `RunAutoRemediation`, `RunRemediation`, and passed
by `FeatureRunner` to `Describe.run/4`.

## Session origin (hook-side, not persisted)

| Origin | Detected when | Profile applied |
|---|---|---|
| `orchestrated` | env `AUTONOMOUS_ORCHESTRATED == "1"` | env `AUTONOMOUS_CONTAINMENT_PROFILE` if valid, else `strict` |
| `interactive` | marker absent **and** `CLAUDE_CODE_ENTRYPOINT ∈ {"cli"}` | none — pack adds no denial |
| `undecided` | anything else | `strict` |

Checked in that order (marker first). See
[contracts/scope-guard.md](contracts/scope-guard.md).

## Coordinator snapshot and final report (extended)

Optional key `containment_profile: "permissive"`. **Present only when the
run is permissive.** Absent under strict, so every strict snapshot and report
map is unchanged.

## Pack contract (target repo files)

| File | Change |
|---|---|
| `.claude/settings.json` | `permissions.deny` removed; PreToolUse matcher `Write\|Edit\|MultiEdit\|NotebookEdit\|Bash\|WebFetch\|WebSearch` |
| `.claude/hooks/scope_guard.py` | origin/profile decision; `PACK_CONTRACT = 2`; `--contract` flag prints `2` |

`TargetPack.verify(repo, profile: "permissive")` requires the **committed**
(`HEAD:`) hook to report contract `2` and the committed settings to have no
`deny`. See [contracts/pack-preflight.md](contracts/pack-preflight.md).

## State transitions

None. The profile is fixed at run start and never changes for the life of
the run record. Feature statuses and gate outcomes are unaffected (FR-009).
