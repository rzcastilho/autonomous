# Data Model: Orchestrator-Owned Target Pack (044)

No persisted state changes. No Mnesia schema bump, no run-record field: the pack is
derived from the target's committed tree and the worktree on every check (spec
Assumptions). Entities below are in-memory values and files.

## Orchestrator pack (files)

| File (worktree-relative) | Owner | Tracked? | Content |
|---|---|---|---|
| `.claude/autonomous-pack.json` | orchestrator (or target, if committed) | untracked when supplied | `{"contract": 6}` — the stamp |
| `.claude/settings.local.json` | orchestrator | never tracked (tracked ⇒ refused) | pack settings minus tracked `env` keys (below) |
| `.claude/settings.json` | target | optional, never written | operator's own; examined only for removed constructs |

Source: `priv/target_pack/.claude/{settings.json,autonomous-pack.json}` (unchanged
bytes; the pack's `settings.json` is the template for the local file).

### Local settings derivation (pure)

```
local_settings(pack :: map, tracked :: map | nil) :: map
  env' = Map.drop(pack["env"], Map.keys(tracked["env"] || %{}))
  pack |> put("env", env') |> drop "env" when env' == %{}
```

Invariant: for every key `k` in tracked `env`, the effective value is the tracked one
(local outranks project, so local must not restate `k`). All non-`env` keys are the
pack's verbatim. Written as `Jason.encode!(map, pretty: true) <> "\n"`; written only
when bytes differ.

## Shared exclude block

Location: `<git-common-dir>/info/exclude` of the target (shared by the checkout and
every linked worktree).

```
# autonomous: orchestrator-supplied pack (feature 044) — do not edit this block
/.claude/autonomous-pack.json
/.claude/settings.local.json
```

Rules: each pattern line appended only when not already present as an exact line;
header written once with the first appended line; never removes or reorders existing
lines; creates `info/` when missing.

## Pack source (value)

```
@type pack_source :: %{source: :supplied | :committed, contract: pos_integer()}
TargetPack.source(repo) :: {:ok, pack_source} | {:error, reason}
```

| Target `HEAD` state | Result |
|---|---|
| no marker tracked, no removed constructs | `{:ok, %{source: :supplied, contract: 6}}` |
| tracked marker `contract >= 6`, no removed constructs | `{:ok, %{source: :committed, contract: n}}` |
| tracked marker `< 6` / undecodable, scope-guard hook, `deny`, stale hook file | `{:error, {:pack_outdated, rel, hint}}` |
| tracked `settings.json` not a JSON object | `{:error, {:invalid_settings, rel}}` |
| tracked `settings.local.json` | `{:error, {:pack_local_tracked, rel, hint}}` |

Check order (first failure wins, matches today's `with` chain): marker → settings.json →
stale hook → settings.local.json.

## Supply report (value)

```
TargetPack.supply(worktree_path) ::
  {:ok, %{source: :supplied | :committed, wrote: [rel], excluded: [pattern]}}
  | {:error, {:pack_outdated, rel, hint} | {:pack_local_tracked, rel, hint}
             | {:invalid_settings, rel} | {:exclude_failed, reason}}
```

`wrote: []` and `excluded: []` on a current worktree (idempotent).

## Refusal reasons (new / changed)

| Term | Where | Rendered by |
|---|---|---|
| `{:pack_outdated, rel, hint}` | preflight, supply | `Report.format_reason/1` (hint now names both remedies) |
| `{:pack_local_tracked, ".claude/settings.local.json", hint}` | preflight, supply | new `Report.format_reason/1` clause |
| `{:invalid_settings, ".claude/settings.json"}` | preflight, supply, `install/2` | new `Report.format_reason/1` clause |
| `{:worktree, {:pack_supply, reason}}` | feature failure when supply fails at create/restore | `Report.format_reason/1` |

Preflight wraps as today: `{:error, {:preflight, problems}}`.

## Console view state

```
Web.PackView.state({:ok, %{source: s, contract: n}}) :: {:supplied, n} | {:committed, n}
Web.PackView.state({:error, reason})                 :: {:refused, String.t()}
Web.PackView.summary(state)                          :: String.t()
```

Pure, never calls `inspect/1` (G-inspect).
