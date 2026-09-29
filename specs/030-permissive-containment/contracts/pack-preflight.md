# Contract: pack install and preflight

## `TargetPack.install/2`

Unchanged signature and return. It writes:

- `.claude/settings.json` — the same `defaultMode` and `allow` list as
  today, **no** `permissions.deny`, PreToolUse matcher
  `Write|Edit|MultiEdit|NotebookEdit|Bash|WebFetch|WebSearch`.
- `.claude/hooks/scope_guard.py` — contract 2, mode `0755`.
- the template constitution only if none exists (unchanged).

The operator commits the result. Worktrees are created from committed state.

## `TargetPack.verify/2`

New option `profile:` — `"strict"` (default) or `"permissive"`.

| profile | Checks |
|---|---|
| `"strict"` | exactly today's checks. An un-upgraded pack passes, and still enforces today's rules through its own settings deny + old hook |
| `"permissive"` | today's checks **plus** `check_pack_contract/2` |

`check_pack_contract/2`:

1. `git -C repo show HEAD:.claude/hooks/scope_guard.py` → run it with
   `--contract` (via a temp file) → stdout must be `2`.
2. `git -C repo show HEAD:.claude/settings.json` → decoded JSON must have
   no non-empty `permissions.deny`.

Either failure →
`{:pack_outdated, ".claude/hooks/scope_guard.py" | ".claude/settings.json", "re-run TargetPack.install/2 and commit"}`.
A `git show` failure (file not committed) → the same problem, named for that
path. The run does not start (edge case: "not silently under strict rules").

## Call sites

`preflight_stacked/1` and the second `TargetPack.verify/2` call in
`lib/speckit_orchestrator.ex` pass `profile: run_context.containment_profile`.
