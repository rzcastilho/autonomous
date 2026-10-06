# Contract: Session Shell Timeouts (US2, FR-006–FR-008)

## 1. `Autonomous.ShellTimeouts` (pure)

```elixir
@spec for_deadline(pos_integer()) :: %{String.t() => String.t()}
```

| `deadline_ms` | result |
|---|---|
| `3_000_000` (50 min, default) | `%{"BASH_MAX_TIMEOUT_MS" => "2700000", "BASH_DEFAULT_TIMEOUT_MS" => "1800000"}` |
| `1_200_000` (20 min) | max `"900000"`, default `"900000"` |
| `900_000` (15 min) | max `"600000"`, default `"600000"` |
| `600_001` | max `"300001"`, default `"300001"` |
| `600_000` (10 min) | max `"600000"`, default `"120000"` (CLI built-ins, pinned) |
| `60_000` | max `"600000"`, default `"120000"` |
| `14_400_000` (big chunk) | max `"2700000"`, default `"1800000"` |

Property (SC-003): for every `d > 600_000`,
`max ≤ d − 300_000 ∧ default ≤ max`.

Constants are module attributes (45 min cap, 30 min default cap, 5 min
headroom, 10 min floor, CLI built-ins 120 000 / 600 000). No config key. They
derive from deadlines, and deadlines are already configurable
(`:phase_timeout`, `:implement_chunk_timeout_per_task`).

## 2. Delivery in `PhaseRequest`

New option on `build/3` and `build_remediation/3`: `:deadline_ms`
(default `Config.phase_timeout/0`).

```elixir
timeouts = ShellTimeouts.for_deadline(deadline_ms)

metadata: %{"claude" => %{
  env: Map.merge(Containment.session_env(containment), timeouts),
  settings: Jason.encode!(%{"env" => timeouts})
}}
```

- The `AUTONOMOUS_*` marker keys and values are unchanged.
- Callers pass the same deadline that `PhaseSession.reduce/2` enforces:
  - `RunFeaturePhase`: `Map.get(params, :deadline_ms) || Config.phase_timeout()`
    (covers phases and chunks: `ChunkRunner` already sends the scaled
    deadline);
  - `RunAutoRemediation` / `RunRemediation`: `Config.phase_timeout()`.
- Applies under both containment profiles and for every phase. This is the
  only change to the requests of phases outside implement/converge (FR-010
  covers prompts; SC-005's "byte-identical requests" is read as "apart from
  the FR-006 timeouts", which the spec mandates for every session).

## 3. Precedence guarantee (research R2)

| source defining the key | wins over the orchestrator? |
|---|---|
| target / pack `.claude/settings.json` `env` | no (`--settings` = flagSettings comes after project/local) |
| target `.claude/settings.local.json` `env` | no |
| user `~/.claude/settings.json` `env` | no |
| managed policy settings | yes (administrator scope, accepted) |

## 4. Test obligations

- `ShellTimeouts` table above, plus the property over a generated deadline
  range.
- `PhaseRequest`: every phase × both profiles carries both channels with equal
  values. A chunk-sized `deadline_ms` changes the values. No `deadline_ms`
  uses `Config.phase_timeout/0`.
- An adapter-level check that `ClaudeAgentSDK.Options.to_args/1` on the built
  options contains `"--settings"` with the JSON. This guards against SDK drift
  at the boundary.
