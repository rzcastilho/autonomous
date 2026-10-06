# Research: Headless Background-Wait Hardening (032)

All facts about the CLI below were read from the installed, pinned binary
(`claude --version` → `2.1.287 (Claude Code)`) and from the vendored
`deps/claude_agent_sdk` and `deps/jido_claude`. No Technical Context item is
left as NEEDS CLARIFICATION.

---

## R1. Does the pinned CLI honour `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS`?

**Decision**: Yes. Use both variables.

**Evidence** (2.1.287 bundle):

```js
var Me=120000,Ne=600000;                       // built-in default 2 min, max 10 min
function nbe(e=process.env){let n=e.BASH_DEFAULT_TIMEOUT_MS; if(n){...r>0) return r} return Me}
function rbe(e=process.env){let n=e.BASH_MAX_TIMEOUT_MS;  if(n){...r>0) return Math.max(r,nbe(e))}
                            return Math.max(Ne,nbe(e))}
```

- The 10-minute cap the spec describes is `Ne = 600000`, the built-in maximum.
- The effective maximum is `max(BASH_MAX_TIMEOUT_MS, default)`. Our formula
  always has default ≤ maximum, so the pair is honoured exactly.
- A separate `CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS` exists. It can only
  **lower** the point at which a command auto-backgrounds
  (`Math.min(requested, max(p, 2000))`). The orchestrator never sets it. The
  harness-contract doc records it so nobody sets it by accident.

**Alternatives considered**: a PreToolUse hook that rewrites the Bash `timeout`
argument. Rejected: the hook belongs to the target pack (not guaranteed
installed, US2 scenario 4) and rewriting tool input is a heavier contract than
two documented env vars.

## R2. How do the timeouts reach the session, and who wins against `settings.json`?

**Decision**: deliver the pair through **two channels with identical values**:

1. the launch environment, next to the existing `AUTONOMOUS_*` markers
   (`RunRequest.metadata["claude"][:env]`);
2. a flag-settings object, `RunRequest.metadata["claude"][:settings]` =
   `{"env":{"BASH_DEFAULT_TIMEOUT_MS":"…","BASH_MAX_TIMEOUT_MS":"…"}}`, which
   the SDK turns into `--settings '<json>'`.

**Evidence**:

- The CLI applies every settings layer's `env` with
  `Object.assign(process.env, …)`, in source order
  `userSettings → projectSettings → localSettings → flagSettings`, then
  `policySettings`. So a target's `.claude/settings.json` `env` **overrides**
  the launch environment. Launch env alone cannot guarantee FR-006 against a
  target (or a contract-4 pack) that defines the same keys.
- `flagSettings` (`--settings`) comes after project and local settings, so it
  wins over both. Only managed policy settings beat it. That is correct:
  policy belongs to the machine administrator.
- `filterSettingsEnv` also has a "host-orchestrated" path that can drop
  settings keys already present in the launch env. Sending the same value
  through both channels makes the result identical whichever path the CLI
  takes.
- `jido_claude`'s adapter merges `metadata["claude"]` straight into
  `ClaudeAgentSDK.Options` (`:settings` is a declared field).
  `Options.build_settings_value/1` passes a JSON string through as
  `--settings`.

**Alternatives considered**: launch env only. Rejected: project settings beat
it, so the pack's own defaults (US5) or a target's values would silently
replace the per-deadline values. `--settings` only. Rejected as needlessly
fragile against the host-orchestrated filter, which we cannot fully read.

## R3. Timeout formula and the ≤ 10-minute deadline case

**Decision**: one pure function, `Autonomous.ShellTimeouts.for_deadline/1`:

| deadline `d` | maximum | default |
|---|---|---|
| `d > 10 min` | `min(45 min, d − 5 min)` | `min(30 min, maximum)` |
| `d ≤ 10 min` | CLI built-in `10 min` (pinned) | CLI built-in `2 min` (pinned) |

Default phase deadline 50 min → 45 / 30 min (FR-008). A 6-task chunk at the
default per-task rate scales its deadline up, and the cap holds at 45 / 30.

**The ≤ 10-minute case (refinement of FR-008, flagged for the spec)**: FR-008
says "set no override, so the CLI's built-in defaults apply". After R2, *not*
setting an override no longer makes the CLI defaults apply once a target has
the contract-4 pack: the pack's 30 / 45-minute `env` would govern a session
whose deadline is ≤ 10 min, which defeats the purpose of the rule. The plan
therefore **pins the CLI's own built-in values (120000 / 600000)** through the
same two channels. The effective result is what FR-008 and SC-003 want: the
CLI defaults apply. The difference is only in mechanism. The spec text should
be updated from "MUST NOT set either override" to "MUST pin the CLI built-in
defaults". `/speckit-analyze` will surface this.

**Alternatives considered**: no override plus a statement that the pack's
values govern. Rejected: a 45-min max on a 10-min deadline is exactly the
mismatch US2 forbids. Scaling to `d − 5 min` below 10 min: rejected by the
operator at clarify.

## R4. Background markers and identifiers in the event stream

**Decision**: the pure detector matches these four tool-result shapes
(2.1.287 template strings):

| mode | tool-result text |
|---|---|
| `:timeout` | `Command did not complete within its <N>s timeout and was moved to the background (ID: <id>). Output is being written to: <path>.` |
| `:message` | `Command was moved to the background (ID: <id>) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: <path>` |
| `:manual` | `Command was manually backgrounded by user with ID: <id>. Output is being written to: <path>` |
| `:explicit` | `Command running in background with ID: <id>. Output is being written to: <path>.` |

It also matches explicit background mode from the **call** side: a `:tool_call`
whose `input["run_in_background"] == true`. That covers wording drift (spec
edge case "Marker text changes"). An explicit-mode call whose result carries no
recognisable `ID:`/path yields a backgrounded command with no identifiers.
Under FR-001 such a command can never be resolved, so it counts as stranded.

The CLI also tells the model "it is terminated when you give your final
response". So a stranded command is already dead when the orchestrator
evaluates the session. Nothing will finish it later.

**Resolution rule (FR-001, clarification Q1)**: a backgrounded command is
*resolved* when **any later** tool event (call input or result output, any
tool, `Read` included) contains its task id **or** its output path as a
substring. "Later" means strictly after the backgrounding result's position in
`tool_events`. The marker result itself never resolves its own command.

**Where the wording lives (Principle I)**: the regexes are CLI contract, so
they sit in one boundary module, `Autonomous.BackgroundMarker`. They are
recorded in `docs/harness-contract.md` next to the CLI version, so a CLI bump
re-checks them. `PhaseResult` calls it. `Pipeline` and `Chunking` only ever
see the extracted signal.

**Alternatives considered**: matching on tool name `Bash` only. Rejected: the
id/path match is name-agnostic, the same way `outstanding_work?/1` is.
Treating any later tool call as resolution: rejected at clarify (Q1).

## R5. Which tools to exclude (FR-011)

**Decision**: add `Monitor` to `@headless_disallowed`. Add no output-reader
tool.

**Evidence**: 2.1.287 defines tool-name constants `var Ua="Monitor"`,
`var kc="TaskStop"` (aliases `KillShell`, `KillBash`) and `var Ue="Bash"`.
`TaskOutput`/`BashOutput` appear only in a legacy-name list, not as a
registered tool. The CLI tells the model to check interim output by `Read`ing
the output path. So the pinned CLI **exposes no separate background-output
reader tool**, and FR-011's second clause has nothing to exclude in this
version. The harness-contract doc records that, so a future bump re-checks.

`TaskStop` stays allowed. Stopping a background task is never a wait, and a
model that backgrounded by accident should be able to clean up. `Read` stays
allowed: it is the resolution path in R4.

**Alternatives considered**: also listing `TaskOutput`/`BashOutput`
pre-emptively. Rejected: a blocking output read is a *foreground* wait, which
is the correct behaviour after an auto-background. Excluding it would remove
the model's only in-turn way to wait.

## R6. Where the incomplete-session gate actually runs today (FR-005)

**Finding**: the spec says the detection applies "at every site that already
applies the incomplete-session gate: phase sessions, implement chunks, and
remediation sessions". The code differs:

- `RunFeaturePhase.classify_after_drift/4` applies `outstanding_work?`, but
  `gate_satisfied?(:implement, _, scope)` returns `true` for every scoped
  implement session. **Chunks are therefore never flagged today**, and every
  implement run is chunked (`FeatureRunner` delegates `:implement` to
  `ChunkRunner`; `:whole_list` is a scope too). That is exactly why the
  fretboard-master stall surfaced as `{:stuck_task_phase, …}`.
- `RunAutoRemediation` / `RunRemediation` classify only branch drift and
  status. They have no incomplete-session gate.

**Decision**: apply the backgrounding check at **all three** sites. That
follows the spec's evident intent (the three named sites), not its premise.

- Phase sessions (`RunFeaturePhase`, non-implement): backgrounding is checked
  before `outstanding_work?`. It is suppressed only for `:plan`/`:tasks` when
  their artifact gate is satisfied, the same "filled artifact is positive
  evidence" rule as today.
- Implement chunks: **never suppressed**. The implement artifact gate ("any
  code changed") says nothing about whether the verification gate that was
  backgrounded ever passed.
- Remediation sessions: a stranded command makes the attempt an `:error`
  carrying the same signal. Remediation keeps its own bounded attempt loop and
  gains no new retry.

## R7. Retry and failure plumbing

**Decision**:

- **Phases** (`PhaseStep`): the signal map carries
  `%{outstanding_work?: true, backgrounded: [cmd, …]}`. That is one
  classification, and both gates firing still means one retry (spec edge
  case). `retry_reason/1` names it ("ended waiting on a backgrounded
  command"). The retry passes `background_retry: cmds` in the `"phase.run"`
  signal data. `PhaseRequest.build/3` appends the corrective note only when
  that option is non-empty (FR-002a). If the retry ends the same way,
  `Pipeline.next/3` gains a clause *ahead of* the `outstanding_work?` one:
  `{:failed, {:backgrounded_command, phase, commands}}` (FR-003).
- **Chunks** (`ChunkRunner` + `Chunking`): `ChunkRunner` lifts
  `last_signals[:backgrounded]` into the Chunking signals. `Chunking.next/2`
  gains a row after row 0 (branch drift) and before row 2:
  - the first backgrounding for the current scope → re-dispatch the same
    scope (subject to the session ceiling, like rows 1/3/5), and set
    `ChunkState.background_retried?`;
  - the second → `{:failed, {:backgrounded_command, scope_ref, commands}}`.
  The flag resets when the cursor advances. `ChunkRunner` passes
  `background_retry: cmds` on the re-dispatch so the prompt carries the note.
- Branch drift keeps first place everywhere (spec edge case).
- **Renderer**: `Report.format_reason/1` gains
  `{:backgrounded_command, where, cmds}` →
  `"<where> ended waiting on backgrounded command: <cmd>"` (first command,
  truncated to 120 chars, "+N more"). The console renders reasons through the
  same function, so no new console code is needed.

**Persistence**: failure reasons are already stored as terms. A new tuple
needs no Mnesia schema change and no migration.

**Alternatives considered**: a new `Pipeline` outcome atom
(`:backgrounded`). Rejected: it would widen the outcome type everywhere for
something that is, by the clarified spec, the same retry path as
incomplete-session.

## R8. Prompt rule text and placement (FR-009/FR-010)

**Decision**: one versioned prompt file, `priv/prompts/headless_rule.md`,
loaded through `Prompts.load/1`. It is appended to:

- `task_phase_block/1` and `sweep_block/1` (the spec's named blocks);
- the `:whole_list` implement scope, which today is a no-op. It is an
  implement chunk session with the same risk, and US3 says "every implement
  … prompt". **Flagged** as a deliberate reading of US3 that is broader than
  FR-009's list;
- the `:converge` prompt (after `converge.md`, before the feature tag).

Every other phase, and an implement build with `scope: nil`, stays
byte-identical (FR-010, SC-005).

The corrective note (FR-002a) is a separate, short block appended last (after
resume/answers). It names each command, truncated to 200 chars, and says:
run it in the foreground with an explicit long `timeout`, and do not end the
turn until it returns.

## R9. Pack contract 4 and the settings merge (US5)

**Decision**:

- `priv/target_pack/.claude/settings.json` gains
  `"env": {"BASH_DEFAULT_TIMEOUT_MS": "1800000", "BASH_MAX_TIMEOUT_MS": "2700000"}`.
  These are the default-deadline values (R3), so interactive sessions get the
  same 30 / 45 min.
- `scope_guard.py`: `PACK_CONTRACT = 4` and a docstring line; no
  decision-logic change. `@pack_contract "4"` in `TargetPack`.
- `TargetPack.install/2`: if the target's `.claude/settings.json` exists and
  parses, then pack keys overwrite, *except* `env`, which is
  `Map.merge(pack_env, target_env)` (target wins on conflict). This is a pure
  `TargetPack.merge_settings/2`. An unparseable existing file fails loud
  (`{:error, {:invalid_settings, path}}`) rather than being overwritten
  (Principle II).
- `check_pack_contract/1` (permissive only) requires `"4"`. The strict
  preflight is unchanged (FR-014).

**Alternatives considered**: merging every key. Rejected: FR-013 keeps
overwrite semantics for pack-owned keys, and the hook wiring must stay the
pack's.

## R10. Constitution fit

Principle III (permissive bullet): "the only tool exclusions left are the
headless subagent and scheduling tools, which exist to keep sessions from
ending while they wait on background work". `Monitor` is a background-wait
tool, which is that stated purpose exactly. No MUST is relaxed. A **PATCH
clarification (6.0.1)** naming the background-watcher tool in that bullet
keeps the text literal. It is included as a task. It is a clarification, not
an amendment of substance.

## R11. SC-001 replay fixture

The raw transcript of fretboard-master 014 session `3e935ca9` is not on this
machine. It lives in the container's state, outside the repository. The test
suite uses a **synthetic event-stream fixture** with that session's shape:
Bash call, `:timeout` marker result with ID and path, `Monitor`-style
follow-up unrelated to the id, then `:session_completed` success. Its marker
text is copied verbatim from the 2.1.287 template. If the operator exports the
real transcript later (`.speckit_logs/` or a run export), it can replace the
fixture without code changes.
