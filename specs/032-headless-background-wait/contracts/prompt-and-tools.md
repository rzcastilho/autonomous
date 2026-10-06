# Contract: Headless Prompt Rule, Corrective Note, Tool Exclusion (US3, US4, FR-002a, FR-009–FR-011)

## 1. Headless rule: `priv/prompts/headless_rule.md`

Loaded with `Prompts.load("headless_rule")`. Normative content (wording may be
tightened in implement; these four obligations MUST remain):

```text
This session is headless. Ending your turn ends the session; nothing resumes it
and nothing collects background work afterwards.

- Run every command in the foreground. For long commands (test suites, builds,
  screenshot runs) pass an explicit long `timeout` on the Bash call.
- Never use `run_in_background`, never start a background watcher, and never
  plan to "wait for" a command to finish later.
- Never end your turn while a command is still running.
- If a command is moved to the background anyway, read its output file until
  it has finished before doing anything else.
```

### Placement

| prompt | rule appended? |
|---|---|
| implement `{:task_phase, _}` block | yes, after the existing block text |
| implement `{:sweep, _}` block | yes |
| implement `:whole_list` | **yes** (research R8; broader than FR-009's list, flagged) |
| implement `scope: nil` | no (byte-identical) |
| `:converge` | yes, between `converge.md` and the feature tag |
| specify, clarify, plan, tasks, analyze, describe, remediation | no (byte-identical, FR-010) |

Separator: `"\n\n---\n"` before the rule, the same as the other appended
blocks.

## 2. Corrective note (FR-002a)

New option `:background_retry` on `PhaseRequest.build/3` (a list of command
strings). `nil` or `[]` → no-op, byte-identical. A non-empty list appends,
**last** (after resume guidance and clarify answers):

```text
---
Retry note: the previous session for this step ended while waiting on a
backgrounded command, so its result was never seen. Run each of these in the
foreground with an explicit long `timeout`, and do not end your turn until it
returns:
- <command 1, truncated to 200 chars>
- <command 2 …>
```

Only a backgrounding retry sets it: `PhaseStep` on reason
"ended waiting on a backgrounded command", and `ChunkRunner` on row B. No
other retry path passes it.

## 3. Tool exclusion (FR-011)

```elixir
@headless_disallowed ~w(Agent Task ScheduleWakeup Monitor)
```

- Applies to every `strict_permissions/1` clause, `permissive_permissions/0`,
  and both `remediation_permissions/1` clauses. All of them already
  reference the attribute.
- No output-reader tool is added: the pinned 2.1.287 registers none
  (research R5). `TaskStop` and `Read` stay available.
- Test: for every phase in the pipeline plus remediation, under both
  profiles, `"Monitor" in request.disallowed_tools`.
