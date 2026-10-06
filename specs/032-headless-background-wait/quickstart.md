# Quickstart: Validating 032 (Headless Background-Wait Hardening)

Prerequisites: a repo checkout on `032-headless-background-wait`, a trusted
`mise.toml`, and `claude --version` → `2.1.287` (the version the markers and
the env precedence were verified against; see research.md R1, R2, R4).

## 1. Hermetic suite (default)

```bash
mise exec -- mix compile          # warnings_as_errors
mise exec -- mix test
```

Expected: green. The deliberately updated cases are the request-metadata
assertions (timeouts added), the `@headless_disallowed` list, the pack
contract probe (`"4"`), and the implement/converge prompt snapshots.

Focused runs per user story:

| story | command | proves |
|---|---|---|
| US1 detection | `mise exec -- mix test test/autonomous/phase_result_test.exs test/autonomous/background_marker_test.exs` | table in contracts/background-detection.md §2, rows 1–10 (row 10 = SC-001 fixture) |
| US1 retry/fail | `mise exec -- mix test test/autonomous/phase_step_test.exs test/autonomous/pipeline_test.exs test/autonomous/chunking_test.exs test/autonomous/chunk_runner_test.exs` | one retry with the corrective note, then `{:backgrounded_command, …}`; branch drift still wins; chunk row B |
| US2 timeouts | `mise exec -- mix test test/autonomous/shell_timeouts_test.exs test/autonomous/phase_request_test.exs` | formula table and SC-003 property; both delivery channels on every phase/profile |
| US3 prompts | `mise exec -- mix test test/autonomous/phase_request_test.exs` | rule present in task-phase/sweep/whole_list/converge; byte-identical elsewhere |
| US4 tools | same file | `Monitor` excluded for every phase × profile, remediation included |
| US5 pack | `mise exec -- mix test test/autonomous/target_pack_test.exs test/autonomous/scope_guard_test.exs` | env merge preserves target keys (SC-004), idempotent re-install, permissive refuses contract 3, strict unchanged |

## 2. Opt-in real-CLI checks (`--include integration`)

```bash
mise exec -- mix test --include integration test/autonomous/integration/background_wait_test.exs
```

Two probes against the real `claude` binary in a temp git repo:

1. **Timeouts reach the CLI and beat project settings.** Write a target
   `.claude/settings.json` with `env.BASH_MAX_TIMEOUT_MS = "60000"`. Run a
   one-turn session built by `PhaseRequest.build/3` with a 50-min deadline.
   Ask the model to run `echo $BASH_MAX_TIMEOUT_MS` in Bash. Expected: the
   output is `2700000`, the orchestrator value, not the target's.
2. **Marker shape still matches.** Run a session that executes
   `sleep 5` with `run_in_background: true` and then ends. Fold its stream
   with `PhaseResult.reduce/1`. Expected: `stranded_background/1` returns one
   command, so the live wording still parses. Re-run this after every CLI
   bump.

## 3. Manual: pack install into a sample target

```bash
mise exec -- iex -S mix
iex> File.mkdir_p!("/tmp/t032/.claude"); File.write!("/tmp/t032/.claude/settings.json", ~s({"env":{"FOO":"1","BASH_MAX_TIMEOUT_MS":"999"}}))
iex> Autonomous.TargetPack.install("/tmp/t032")
iex> File.read!("/tmp/t032/.claude/settings.json") |> Jason.decode!() |> Map.get("env")
# => %{"FOO" => "1", "BASH_MAX_TIMEOUT_MS" => "999", "BASH_DEFAULT_TIMEOUT_MS" => "1800000"}
```

## 4. Field validation (SC-006, operator)

Upgrade the fretboard-master pack (`TargetPack.install/2` + commit), then run
its next wave unattended through `scripts/autonomous`. Expected: the final
implement task-phase (Polish) completes. Or, if a model still backgrounds a
gate, the feature fails once-retried with
`implement … ended waiting on backgrounded command: …`, never
`{:stuck_task_phase, …}`. Record the outcome in tasks.md the way 031's T063
was recorded.
