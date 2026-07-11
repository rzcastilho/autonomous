# Harness contract — observed (Phase 0)

**Date:** 2026-07-11 · **Method:** deps resolved + iex spikes against the real
adapters (no paid Claude call yet — that is Phase 2). All structs below are
*observed*, not guessed.

## Resolved dependency pins

| Dep | Source | Pin |
|---|---|---|
| `jido` | Hex | `~> 2.2` → resolved **2.3.2** |
| `jido_harness` | GitHub `agentjido/jido_harness` | `ae3751d7d0464a3097cb119ffbac98ccbedf607c` (HEAD 2026-07-11) |
| `jido_claude` | GitHub `agentjido/jido_claude` | `51f8b6e30cbf3839533d307399e12a136baf734f` (HEAD 2026-07-11) |

`jido_harness` and `jido_claude` are **not on Hex** (404) as of this date —
GitHub deps with pinned SHAs, `override: true` on the harness. Re-check Hex
monthly (plan §2). `mix deps.get` + `mix compile` both succeed; the only
warnings come from a transitive dep (`jido_shell`), not our code.

> Note: `mix deps.get` reported "packages with security advisories" in the
> transitive tree. Not triaged in Phase 0 — revisit before any production use.

## CONFIRM #1 — provider registration — **RESOLVED (overturns the plan)**

The plan assumed auto-discovery ("likely unnecessary"). **False for this
version.** `Jido.Harness.providers/0` returns `[]` until providers are
configured explicitly; `capabilities(:claude)` errors with
`ProviderNotFoundError: "explicit config required in :jido_harness, :providers"`.

Required config (now in `config/config.exs`):

```elixir
config :jido_harness,
  providers: %{claude: Jido.Claude.Adapter},
  default_provider: :claude
```

Adapter module = **`Jido.Claude.Adapter`** (CONFIRM #1's guessed name was
correct). It must satisfy the harness adapter conformance callbacks
(`id/0`, `capabilities/0`, `run/2`, `runtime_contract/0`) — it does. After
config, `providers/0` → `%{claude: Jido.Claude.Adapter}` and
`default_provider/0` → `:claude`.

## CONFIRM #2 — RunRequest fields + permission pass-through — **RESOLVED**

`%Jido.Harness.RunRequest{}` struct fields (observed):

```
prompt, cwd, session_id, model, max_turns, timeout_ms, system_prompt,
allowed_tools, disallowed_tools, permission_mode, add_dirs, attachments,
mcp_config, metadata
```

**There is no `provider_options` field.** Claude-native permission controls are
**first-class RunRequest fields**: `permission_mode`, `allowed_tools`,
`disallowed_tools`, `add_dirs`. This is *better* than the plan feared —
`RunPhase` can set per-phase permissions (analyze = read-only tool set,
implement = scoped write set) directly on the RunRequest. The committed
`.claude/settings.json` (Phase 5) remains the belt-and-suspenders layer.

Entry points: `run/2`, `run/3`, `run_request/1..3`, `cancel/2`,
`capabilities/1`, `default_provider/0`. `RunRequest.new/1` / `new!/1` build it.

## CONFIRM #3 — event shapes + streaming — **RESOLVED**

`run(:claude, prompt, opts)` returns `{:ok, Enumerable.t(Jido.Harness.Event.t())}`
— a lazy **Stream** (`Stream.map(&ensure_event!/1)`). **Streaming, not
buffered.** `RunPhase.reduce/1` folds this enumerable uniformly (works for both
stream and buffered adapters).

`Jido.Harness.Event` is a Zoi-schema struct keyed by a `type` atom. Normalized
harness events: `Jido.Harness.Event`, `Jido.Harness.Event.Usage`.

Provider-extended Claude signals (captured, not required by `reduce/1`):
`Jido.Claude.Signals.{SessionStarted, SessionSuccess, SessionError, TurnText,
TurnToolUse, TurnToolResult}` — session id rides in these.

### Adapter capabilities (`%Jido.Harness.Capabilities{}`)

```
streaming?: true    tool_calls?: true    tool_results?: true    thinking?: true
resume?: true       usage?: false        file_changes?: false   cancellation?: false
```

Consequences for later phases:
- **`usage?: false`** is a *conservative capability flag*, but Phase 2 source
  reading corrected this: `Jido.Claude.Mapper` **does** emit a `:usage` event
  (`%Jido.Harness.Event{type: :usage, payload: %{"cost_usd" => ..., "input_tokens",
  "output_tokens", ...}}`) on `result:success` **when the CLI reports
  `total_cost_usd`**. So cost extraction is **opportunistic**: `PhaseResult`
  folds the actual `cost_usd` when present, and `Cost.for_phase/2` falls back to
  the per-phase config estimate only when it is absent. Because the flag says
  `false`, never *require* the usage event — always keep the estimate path.
- **`cancellation?: false`** → no hard mid-phase cancel via the adapter. Fine:
  the breaker uses drain-don't-kill (finish current phase, then halt), never a
  hard cancel.
- **`resume?: true`** → session resume is available (session ids in the Claude
  signals) — enables mid-pipeline escalation resume (a v2 goal).

### Runtime contract (`Jido.Claude.Adapter.runtime_contract/0`)

- Invokes the `claude` CLI with `-p --output-format stream-json
  --include-partial-messages --no-session-persistence --verbose
  --dangerously-skip-permissions`, wrapped in a `timeout 180` guard.
  - ⚠️ **`--dangerously-skip-permissions` is in the template.** In-tree scope
    enforcement therefore leans entirely on the committed `.claude/settings.json`
    + PreToolUse hook (Phase 5) and/or container isolation. Flag for Phase 5.
- Auth: one of `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` /
  `CLAUDE_CODE_API_KEY` must be in the host env.
- Compatibility probe: `claude --help` must show `--output-format`,
  `stream-json`. Bake into orchestrator preflight.
- `runtime_tools_required: ["claude"]`.

## Deferred to Phase 2 (needs org allowlist + spend approval)

- One real end-to-end `run(:claude, "/speckit.specify …", cwd: repo)` to observe
  the live event stream ordering, the terminal result struct, and where the
  session id lands (for `cancel/2`).
- Verify per-phase model **full strings** resolve on the org allowlist
  (`claude --model <string> -p "print your model id"`).
- Confirm `analyze` JSON-tail parsing against a real transcript.
