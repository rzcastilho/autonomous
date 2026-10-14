# Quickstart: Validate Feature 043

Prereqs: repo on `043-close-recorder-gaps`, `mise trust mise.toml` done.

## 1. Hermetic suite

```bash
mise exec -- mix compile          # warnings_as_errors
mise exec -- mix test             # full default suite
```

Focused runs (names per plan's Project Structure):

```bash
mise exec -- mix test test/autonomous/conversation_entry_test.exs   # R1 result rule, R2 usage, R5 parent id
mise exec -- mix test test/autonomous/stderr_bound_test.exs         # head/tail; 100k lines → 2000 + notice(98000)
mise exec -- mix test test/autonomous/conversation_recorder_test.exs # {:stderr, line} order + close flush before :end
mise exec -- mix test test/autonomous/sdk_proxy_test.exs            # callback logs, collects AND sends to recorder
mise exec -- mix test test/autonomous/web/session_status_test.exs   # token fold, nil-not-zero, result_error footer
mise exec -- mix test test/autonomous/web/design_contract_test.exs  # rule count unchanged
```

Expected: all green; no warnings.

## 2. Scenario checks (map to spec)

| Scenario | How | Expected |
|---|---|---|
| US1 synthetic result (SC-001) | feed `ClaudeAgentSDK.Message.error_result("CLI exited 1")` through a recorder; open file | `result` body `is_error: true`, `error: "CLI exited 1"`; view marker `result · error_during_execution — CLI exited 1`; footer not `done` |
| US1-4 no message | `error_result("")` | `is_error: true`, `error: null`; view shows `no reason given` |
| US2 stderr (SC-002) | send `{:stderr, "warn"}` ×3 between frames | 3 file entries in arrival order; one row `×3` |
| US2-5 flood (SC-006) | 100,000 `{:stderr, …}` then close | 1,000 lines, notice `dropped: 98000`, 1,000 lines, then `end`; session outcome unchanged |
| US3 tokens (SC-003/005) | replay `043_sample.jsonl` live then via Transcripts | figure grows across messages, no double count on repeated deltas; same final `in … · out …` both surfaces; no cost before result |
| US3-2 no usage | open any v1 file | no token field |
| US4 parent id | frames with `parent_tool_use_id` | stored on entries; rendering identical to fixture without it |
| v1 parity (SC-004) | `mise exec -- mix test --only census` (machine-local, opt-in) | every local v1 file renders identically to 042 |
| v3 refusal (FR-019) | header `"version": 3` | `{:error, {:unsupported_version, 3}}`; views show the notice |

## 3. By hand (live, optional)

Run any feature in the container (`scripts/autonomous …`, `docs/container.md`),
open `/live` during implement: the status line shows `in … · out …` moving per
API request; force a CLI warning (e.g. untrusted workspace) and confirm a
`stderr` row appears and the 036 trust warning still logs.
