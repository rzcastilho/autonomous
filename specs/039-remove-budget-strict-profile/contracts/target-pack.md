# Contract: Target pack, contract 6 (039)

Supersedes pack contracts 2–5 (`scope_guard.py` `PACK_CONTRACT`). Decisions:
research R5, R6, R7.

## Pack contents (`priv/target_pack/.claude/`)

| Path | Contract 6 |
|---|---|
| `settings.json` | `env` (032 shell timeouts), `permissions.defaultMode`, `permissions.allow`. **No** `hooks` key. **No** `permissions.deny`. |
| `autonomous-pack.json` | `{"contract": 6}` — the only contract marker |
| `hooks/scope_guard.py` | **removed** |
| everything else (commands, skills, constitution template) | unchanged |

## `TargetPack.install(repo, opts)`

- Writes `autonomous-pack.json`.
- Merges `settings.json` as today (`merge_settings/2`: pack wins every key but
  `env`) — so a target's old `hooks.PreToolUse` scope-guard entry is dropped.
- Deletes `.claude/hooks/scope_guard.py` in the target if present (and the
  `hooks/` dir if then empty).
- Never clobbers the target constitution (unchanged).
- Idempotent: a second install is a no-op (same bytes).

## `TargetPack.verify(repo, opts)`

No `:profile` option (passing one is a programmer error and is not
accepted). Checks, in order, all reading the **committed** tree
(`git show HEAD:<path>`):

1. existing checks (template constitution marker, committed scaffold) — unchanged;
2. `.claude/autonomous-pack.json` exists, decodes, and `contract >= 6`;
3. `.claude/settings.json` has no `hooks.PreToolUse` entry whose command
   references `scope_guard.py`, and no `permissions.deny`;
4. `.claude/hooks/scope_guard.py` is not committed.

Failure of 2–4 → problem `{:pack_outdated, path, hint}` where `path` is the
offending file and `hint` contains: `contract 6`, `TargetPack.install/2`, and
"commit the result". Runs for every run, resume, continue and `run_spec/2`.

Removed: `@permissive_min_contract`, `@agent_root_min_contract`,
`contract_of/1` (python probe), `parse_contract/1`, `agent_root_warning/1`,
`:pack_below_agent_root_contract`, the `"strict"` no-op clause.

## Sessions

`PhaseRequest.build/…` for every phase, remediation and describe:
- `permission_mode: :bypass_permissions`;
- `allowed_tools: @allowed_tools` (the former permissive full set, incl.
  `WebFetch`/`WebSearch`, `Bash`, file writes);
- `disallowed_tools: ~w(Agent Task ScheduleWakeup Monitor)` (headless
  exclusions — unchanged, not containment);
- launch env: shell timeouts (032) + `AgentRoot.session_env/1` when advertised;
  **no** `AUTONOMOUS_ORCHESTRATED`, **no** `AUTONOMOUS_CONTAINMENT_PROFILE`.

## Agent root (037, FR-015)

- Kept: image `sudo` + `APT::Get::Remove "false"`, entrypoint `agent_root`
  step exporting `AUTONOMOUS_AGENT_ROOT=1` only after `sudo -n true`,
  `AgentRoot.advertised?/1`, `session_env/1`, `prompt_note/1` (on
  `:implement`/`:converge`), `log_installs/3` after every session site.
- Removed: the closed `sudo` grammar (lived in `scope_guard.py`),
  `AgentRoot.denied?/1` `scope_guard[` filter, the agent-root pack warning.
- `priv/prompts/agent_root.md`: the "only apt-get/apt update/install and dpkg
  queries are allowed" line becomes guidance (never remove, purge, or upgrade),
  not a stated enforcement.
- Console Configuration "agent root" row: `:hidden | :available` only.
