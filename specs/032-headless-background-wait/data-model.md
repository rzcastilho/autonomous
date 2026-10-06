# Data Model: Headless Background-Wait Hardening (032)

No Mnesia schema change. Every entity below is either an in-memory value
derived from a session's `PhaseResult`, or a term stored inside existing
records (failure reason, signals) whose shape is already open.

## 1. BackgroundedCommand

Derived purely from `PhaseResult.tool_events` by
`PhaseResult.backgrounded_commands/1` (marker parsing in `BackgroundMarker`,
research R4).

| field | type | source | notes |
|---|---|---|---|
| `call_id` | `String.t() \| nil` | `:tool_call` / `:tool_result` `"call_id"` | links the result back to its call |
| `command` | `String.t()` | call `input["command"]`, else `input["description"]`, else `"(unknown command)"` | shown to the operator and in the corrective note |
| `mode` | `:timeout \| :message \| :manual \| :explicit` | which marker matched, or `run_in_background: true` on the call | |
| `task_id` | `String.t() \| nil` | `ID: <id>` in the result | resolution key 1 |
| `output_path` | `String.t() \| nil` | `Output is being written to: <path>` (trailing `.` stripped) | resolution key 2 |
| `position` | `non_neg_integer()` | index of the backgrounding result in `tool_events` | "later" means index > position |
| `resolved?` | `boolean()` | resolution rule | see below |

**Validation / rules**

- **Resolution (FR-001)**: `resolved?` is true iff some tool event at an
  index `> position` contains `task_id` or `output_path` as a substring of its
  call input (JSON-encoded) or result output (flattened to text). An event at
  `position` (the marker itself) never counts.
- **No identifiers**: `task_id == nil and output_path == nil` →
  `resolved? == false` forever (spec edge case "No identifier in the
  marker").
- **Explicit mode**: a call with `input["run_in_background"] == true` yields a
  `BackgroundedCommand` even when its result has no recognised marker. Its
  ids then come from the result if present, else they are `nil`.
- **One entry per call**: a call matched both explicitly and by marker
  produces one entry, with the mode taken from the marker.

**Stranded set**: `PhaseResult.stranded_background/1` → the `command` strings
of the unresolved entries, in call order. It is `[]` unless `status == :ok`
(FR-004).

## 2. Background signal (gate signal)

Added to the existing `last_signals` map by every session-driving action.

```elixir
%{outstanding_work?: true, backgrounded: [String.t(), ...]}
```

- Present only when the stranded set is non-empty and not suppressed
  (research R6). `outstanding_work?: true` rides along, so the existing
  retry/fail path is reused and both gates firing is one classification.
- Absent otherwise. The signal maps of untouched sessions stay byte-identical.
- Precedence: `branch_drift` > `backgrounded` > plain `outstanding_work?` >
  phase gates.

## 3. Failure reason

| site | reason term |
|---|---|
| phase (`Pipeline.next/3`) | `{:backgrounded_command, phase :: atom(), commands :: [String.t()]}` |
| chunk (`Chunking.next/2`) | `{:backgrounded_command, TaskPhaseRef.t() \| :sweep \| :whole_list, [String.t()]}` |
| remediation attempt | attempt `:error` whose `last_signals` carries `backgrounded` (no new terminal reason; the analyze loop's existing handling applies) |

Rendered by `Report.format_reason/1` (contracts/background-detection.md §5).

## 4. ChunkState (extended)

| new field | type | default | rule |
|---|---|---|---|
| `background_retried?` | `boolean()` | `false` | set when a scope is re-dispatched for backgrounding. A second backgrounding on the same scope fails it. Reset to `false` whenever the cursor advances or the sweep starts. |

Still frozen in shape otherwise. `ceiling` still bounds the re-dispatch.

## 5. SessionShellTimeouts

A value returned by `ShellTimeouts.for_deadline/1`.

```elixir
%{"BASH_DEFAULT_TIMEOUT_MS" => String.t(), "BASH_MAX_TIMEOUT_MS" => String.t()}
```

| deadline `d` (ms) | `BASH_MAX_TIMEOUT_MS` | `BASH_DEFAULT_TIMEOUT_MS` |
|---|---|---|
| `d > 600_000` | `min(2_700_000, d − 300_000)` | `min(1_800_000, max)` |
| `d ≤ 600_000` | `600_000` (CLI built-in, pinned) | `120_000` (CLI built-in, pinned) |

Invariants (SC-003):

- for `d > 600_000`: `max ≤ d − 300_000`, `default ≤ max`, `max > 300_000`;
- values are decimal strings (settings/env are string-valued).

Delivered twice with identical values (research R2):
`metadata["claude"][:env]` (merged with `Containment.session_env/1`) and
`metadata["claude"][:settings]` = `Jason.encode!(%{"env" => timeouts})`.

## 6. Pack contract

| item | before | after |
|---|---|---|
| `scope_guard.py` `PACK_CONTRACT` | `3` | `4` |
| `TargetPack` `@pack_contract` | `"3"` | `"4"` |
| `settings.json` `env` | absent | `BASH_DEFAULT_TIMEOUT_MS=1800000`, `BASH_MAX_TIMEOUT_MS=2700000` |
| install of `settings.json` | overwrite | pack keys overwrite, except `env`: `Map.merge(pack_env, target_env)` |
| permissive preflight | requires `3` + no deny | requires `4` + no deny |
| strict preflight | unchanged | unchanged |

## State transitions touched

```text
Phase session (non-implement):
  :ok + stranded (not suppressed) ──► outcome :error, signals{outstanding_work?, backgrounded}
     ├─ retries left ──► PhaseStep retry (prompt + corrective note)
     │     ├─ clean ──► normal Pipeline.next
     │     └─ stranded again ──► {:failed, {:backgrounded_command, phase, cmds}}
     └─ (branch_drift present) ──► {:failed, {:branch_drift, …}}  (never retried)

Implement chunk (scope S):
  :ok + stranded ──► Chunking row "B":
     ├─ background_retried? == false and ceiling not reached
     │     ──► {:dispatch, S, state{background_retried?: true}} (prompt + note)
     ├─ background_retried? == true ──► {:failed, {:backgrounded_command, ref(S), cmds}}
     └─ ceiling reached ──► {:failed, {:session_ceiling, n}}  (existing row 6)
```
