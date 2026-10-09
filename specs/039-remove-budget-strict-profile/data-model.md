# Data Model: Remove Cost Budget Breaker and Strict Containment Profile

**Feature**: 039 | **Date**: 2026-10-09 | Decisions: [research.md](research.md)

This feature only removes fields and states. No Mnesia table, column, or
schema version changes (store stays at **v7**, R10).

## Ledger state (`Autonomous.Ledger`, process state) — R1

| Field | Before | After |
|---|---|---|
| `committed` | float, summed by `record/3` | **kept**: informational spend total |
| `budget` | float, from `Config.budget_usd/0` / `set_budget/2` | **removed** |
| `reservations` / `reserved` | map/float, `reserve/2` | **removed** (never used in production) |
| `tripped?` | derived `committed >= budget` | **removed** |

Public API after: `record/3`, `spent/1`, `restore/2`, `snapshot/1 :: %{committed: float()}`.
No validation: a non-number amount stays a programmer error (crash).

## RunContext (`Autonomous.RunContext`, stored inside `speckit_run_settings.settings`) — R10

| Key | Before | After |
|---|---|---|
| `budget_usd` | captured from opt/Config, written by `to_map/1` | **removed** from struct, `@keys`, `capture/1`, `to_map/1`, `from_map/1` |
| `containment_profile` | captured, written, default `"strict"` on read | **removed** |
| all other keys | — | unchanged |

**Legacy read rule**: a stored settings map holding `"budget_usd"` or
`"containment_profile"` decodes; `from_map/1` ignores both keys;
`RunSettingsView` hides them (`@dropped`). They never reach behaviour (FR-017).

## Feature agent state (`FeatureAgent`, `InitFeature`) — R7

| Field | Before | After |
|---|---|---|
| `containment` | `"strict" \| "permissive"`, default `"strict"` | **removed** |
| `ledger` | Ledger server | kept (cost recording) |

## Coordinator status / final report maps — R11

| Key | Before | After |
|---|---|---|
| `breaker_tripped` | boolean | **removed** |
| `containment_profile` | present only when permissive | **removed** |
| `spend` | `Ledger.spent/1` | kept |
| `stopped_by`, tallies | — | unchanged; no tally or reason for "breaker" |

## Terminal / exit reasons

| Value | Before | After |
|---|---|---|
| `{:halted, :breaker, _}` (runner/chunk/analyze) | produced on trip | **never produced** |
| `{:needs_human, :breaker}` terminal reason | produced on trip during clarify wait | never produced; **still rendered** for old records |
| clarify round `outcome: :breaker` | written on trip | never written; still accepted by decoder and `close_clarify_round` guard, still labelled in Run Detail |
| `{:untrusted_workspace, phase, obs}` failure | strict only | **never produced**; still rendered by `Report.format_reason/1` |
| `{:containment_profile_locked, _}` resume refusal | profile mismatch | **removed** |
| `{:preflight, [{:retired_option, key}]}` | keys `:pr_workflow`, `:max_concurrency` | **+ `:budget_usd`, `:containment_profile`** |
| `{:pack_outdated, path, hint}` | permissive runs only, contract < 4 | **every run**, contract < 6 (see contracts/target-pack.md) |
| `:pack_below_agent_root_contract` warning | strict + agent root | **removed** |

## Release decision input — R2

`Release.next(features, statuses, blocked?)` — third argument renamed
`breaker_tripped?` → `blocked?`; now true only when `Store.Health` reports the
store unwritable. Truth table otherwise unchanged.

## Session-retry / decision signals — R3

| Signal map | Before | After |
|---|---|---|
| `SessionRetry.once/2` | `%{breaker?:, drain?:}` | `%{drain?:}` |
| `Chunking.decide_next/…` | `breaker?`, `drain?` | `drain?` (Row 7 deleted) |
| `Remediation.next/2` | row 4 `breaker?: true → halt` | row deleted; rows renumbered |
| `AnalyzeRunner` signals | `breaker?:` | removed |

## Target pack (committed in target repo) — R5/R6

| Path | Before (contract 5) | After (contract 6) |
|---|---|---|
| `.claude/hooks/scope_guard.py` | PreToolUse hook, `PACK_CONTRACT = 5` | **absent** (install deletes a stale copy) |
| `.claude/settings.json` `hooks.PreToolUse` | registers scope_guard | **absent** |
| `.claude/settings.json` `env`, `permissions.defaultMode`, `permissions.allow` | — | unchanged |
| `.claude/settings.json` `permissions.deny` | absent (030) | absent (checked) |
| `.claude/autonomous-pack.json` | — | **new**: `{"contract": 6}` |

## Session launch env — R7

| Variable | Before | After |
|---|---|---|
| `AUTONOMOUS_ORCHESTRATED` | `"1"` on every orchestrated session | **removed** (no reader) |
| `AUTONOMOUS_CONTAINMENT_PROFILE` | run's profile | **removed**; as a host env var it now aborts boot (retired) |
| `AUTONOMOUS_CONTAINER` / `AUTONOMOUS_AGENT_ROOT` (via `AgentRoot.session_env/1`) | when advertised | **kept** (FR-015) |
| shell-timeout vars (032) | — | unchanged |

## Configuration keys

| Key / variable | After |
|---|---|
| `config :autonomous, budget_usd:` | **retired** — boot raises naming it |
| `config :autonomous, containment_profile:` | **retired** — boot raises naming it |
| `AUTONOMOUS_BUDGET_USD` | **retired** — `runtime.exs` raises naming it |
| `AUTONOMOUS_CONTAINMENT_PROFILE` (host env) | **retired** — `runtime.exs` raises naming it |
| `cost_estimates` | kept (informational fallback) |
| `LiveConfig` field `:budget_usd` | **retired** — validation error naming it |
