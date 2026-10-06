# Contract: Enforcement Pack Contract 4 (US5, FR-012–FR-014)

## 1. Shipped `priv/target_pack/.claude/settings.json`

Adds a top-level `env` object; `permissions` and `hooks` unchanged:

```json
"env": {
  "BASH_DEFAULT_TIMEOUT_MS": "1800000",
  "BASH_MAX_TIMEOUT_MS": "2700000"
}
```

`scope_guard.py`: `PACK_CONTRACT = 4`; the module docstring records
"4: settings.json env shell timeouts (feature 032)". No decision-logic change,
so `scope_guard_test`'s origin × profile matrix is untouched apart from the
contract probe.

## 2. `TargetPack.install/2`

```elixir
@spec merge_settings(pack :: map(), existing :: map()) :: map()
```

- No existing target `settings.json` → write the pack file as-is (scenario 1).
- Existing file that parses as a JSON object → write
  `Map.put(pack, "env", Map.merge(pack["env"], existing["env"] || %{}))`.
  In words: everything except `env` keeps today's overwrite semantics (the
  pack file replaces the target file). In `env`, the target's keys and values
  win, so only absent pack keys are added (scenario 2, SC-004).
- Existing file that does not parse, or is not an object → return
  `{:error, {:invalid_settings, ".claude/settings.json"}}` and write nothing
  (Principle II). This is a behaviour change from "silently overwrite" and is
  deliberate. `install/2`'s spec widens to `{:ok, map()} | {:error, term()}`,
  and callers (`scripts/`, the runbook) are updated.
- Output is written with stable key order (`Jason.encode!(…, pretty: true)`),
  so a re-install is idempotent: the second install produces a byte-identical
  file.

## 3. Preflight

| profile | committed pack | result |
|---|---|---|
| `permissive` | contract 4, no deny | `:ok` |
| `permissive` | contract 3 (or uncommitted upgrade) | `{:error, [{:pack_outdated, ".claude/hooks/scope_guard.py", "re-run TargetPack.install/2 and commit"}]}` |
| `strict` | contract 3 or 4 | unchanged from pre-032 |

## 4. Interaction with session timeouts

The pack's `env` covers the operator's **interactive** sessions in the
target. In orchestrated sessions it is always overridden by the
orchestrator's `--settings` values (contracts/session-timeouts.md §3). So a
target-side value never weakens the deadline invariant.
