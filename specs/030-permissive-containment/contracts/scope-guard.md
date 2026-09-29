# Contract: scope_guard.py (pack contract 2)

The PreToolUse hook in `priv/target_pack/.claude/hooks/scope_guard.py`.
Claude Code runs it with the tool call as JSON on stdin and the `claude`
process's environment.

## Inputs

**stdin** (Claude Code PreToolUse JSON): `tool_name`, `tool_input`, `cwd`.
Other fields are ignored.

**environment**:

| Variable | Set by | Meaning |
|---|---|---|
| `AUTONOMOUS_ORCHESTRATED` | orchestrator (`Containment.session_env/1`) | `"1"` ⇒ orchestrated session |
| `AUTONOMOUS_CONTAINMENT_PROFILE` | orchestrator | `"strict"` \| `"permissive"` |
| `CLAUDE_CODE_ENTRYPOINT` | Claude Code | `"cli"` for an interactive session |

## Decision order

1. stdin is not JSON → **deny** `unparseable`. Every origin, every profile
   (FR-010).
2. Resolve origin and profile:
   - `AUTONOMOUS_ORCHESTRATED == "1"` → orchestrated; profile from
     `AUTONOMOUS_CONTAINMENT_PROFILE`, anything else → `strict`.
   - else `CLAUDE_CODE_ENTRYPOINT == "cli"` → interactive → **allow**.
   - else → undecided → `strict`.
3. `permissive` → **allow**. No rule list (FR-006).
4. `strict` → apply the strict rule set. First match → **deny**; no match →
   **allow**.

## Strict rule set

Decision-identical to today's `settings.json` deny ∪ hook rules. `rule_id`s
and matches are listed in [research.md](../research.md) R4. Tools
`WebFetch` / `WebSearch` are denied by tool name. File tools are
`Write`, `Edit`, `MultiEdit`, `NotebookEdit` (`file_path` / `notebook_path`).

## Output

- **allow**: exit 0, no stdout.
- **deny**: exit 0, stdout:

```json
{"hookSpecificOutput": {
  "hookEventName": "PreToolUse",
  "permissionDecision": "deny",
  "permissionDecisionReason": "scope_guard[<profile>|<origin>]: <rule_id>: <detail>"
}}
```

`<profile>` is `strict` or `permissive`; `<origin>` is `orchestrated`,
`interactive` or `undecided`. For unparseable input the prefix is
`scope_guard[unknown|unknown]: unparseable: unparseable hook input`.
`<detail>` keeps today's wording (`write outside worktree denied: <path>`,
`dangerous bash denied: <name>`, `redirect outside worktree: <path>`).

## Contract probe

`python3 scope_guard.py --contract` prints `2` and exits 0, reading no stdin.
`TargetPack.verify/2` uses it against the committed file (see
[pack-preflight.md](pack-preflight.md)).

## Test obligations

- `scope_guard_test.exs` runs the real hook with a **pinned** environment
  (`AUTONOMOUS_*` and `CLAUDE_CODE_ENTRYPOINT` cleared). That is the undecided
  origin, which resolves to `strict`. Every existing case and assertion stays
  as it is (SC-003). Only the helper's env is pinned, so the suite does not
  flip when run from inside a Claude Code shell.
- New matrix: {orchestrated-strict, orchestrated-permissive, interactive,
  undecided, bad profile value} × {each strict rule, a benign command,
  unparseable input}.
- Parity test: every input denied by the old `settings.json` deny list
  (`sudo …`, `git push …`, `curl …`, `wget …`, `WebFetch`, `WebSearch`) is
  denied by the new hook under orchestrated-strict and undecided.
- SC-002 probe: under orchestrated-permissive, one input per action class
  plus `rm -rf /` → allow. The command is checked by the guard only, never
  executed.
