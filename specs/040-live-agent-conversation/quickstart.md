# Quickstart: validating feature 040

Contracts: [conversation-capture](contracts/conversation-capture.md) ·
[conversation-file](contracts/conversation-file.md) ·
[console-surfaces](contracts/console-surfaces.md) · model: [data-model](data-model.md)

## 1. Default suite (host)

```bash
mise exec -- mix compile          # warnings_as_errors
mise exec -- mix test             # includes the new suites below
```

Expected green, in particular:

| Test | Proves |
|---|---|
| `conversation_coverage_test.exs` | FR-003: every `Jido.Harness.run_request` site opens a conversation; all five session kinds produce a `:captured` ref through the fake SDK |
| `conversation_entry_test.exs`, `conversation_rows_test.exs`, `credential_mask_test.exs`, `conversation_window_test.exs`, `conversation_outcome_test.exs` | pure core: normalization, truncation (40 lines / 4,000 chars), masking (≥ 8 chars, longest first), window cap 500, outcome mapping |
| `conversation_recorder_test.exs` | seam: subscribe → catch_up → tail has zero gaps/duplicates against the saved file (SC-006); file `0600`, dirs `0700` (FR-025); `:partial` on recorder kill; `:not_captured` on unwritable root |
| `conversation_isolation_test.exs` | SC-004: zero / one / never-reading viewer ⇒ identical outcome, `duration_ms` within 1 %; dead recorder ⇒ session unaffected |
| `store/migration_v8_test.exs` | v7 rows load with `conversations: nil`; no row dropped (FR-016) |
| `conversation_live_test.exs`, `transcripts_live_test.exs` | US1/US2/US3 acceptance scenarios incl. fallbacks and missing-file message |
| `design_contract_test.exs` | FR-022: guard green with the new surfaces enumerated |

## 2. Live check in the container

Prereqs: image built (`scripts/autonomous build`), a fixture target with a
committed contract-6 pack, `GH_TOKEN` set.

1. `scripts/autonomous console` and start a run on the target from Trigger.
2. Mission Control → in-flight feature card → `live session`. **Expect**:
   header with `run_id`, feature, phase atom, ordinal; entries appear while
   the agent works (≤ 2 s); tool calls and results as separate rows.
3. Leave the view open across an implement chunk boundary. **Expect** an end
   marker for chunk N and a `next session:` link to chunk N + 1.
4. Open `/live` 10+ minutes into a long chunk. **Expect** catch-up rows then
   the tail; if > 500 entries, the catch-up notice.
5. Reload the browser tab mid-session. **Expect** no duplicated rows.
6. Run a printing command in a session (or the smoke subcommand added for
   this feature) that echoes `$GH_TOKEN` and `$CLAUDE_CODE_OAUTH_TOKEN`.
   **Expect** `[masked:GH_TOKEN]` etc. in the view and:
   ```bash
   grep -rF "$GH_TOKEN" ~/.autonomous/transcripts/*/*/conversations | wc -l   # 0
   ```
7. `ls -l` a saved file. **Expect** `-rw-------`; its directories `drwx------`.

## 3. Deadline post-mortem without shell access (SC-005)

1. Start a run with a short phase deadline (e.g. `phase_timeout` 2 min) on a
   feature whose implement chunk runs a long command.
2. Let it be cut. `scripts/autonomous stop`, then `scripts/autonomous build`
   and start the console again.
3. Transcripts → the cut attempt. **Expect** the full conversation, the last
   tool call tagged `unfinished`, end marker `deadline_exceeded`.

## 4. Pre-040 records and failure fallbacks

- Open any attempt from a run recorded before this feature. **Expect** the
  final-text transcript under "No full conversation was recorded for this
  attempt (recorded before feature 040)." (SC-007)
- Delete one saved file by hand, reopen its attempt. **Expect** "Saved
  conversation missing at `<path>`" plus the final text (US2-4).
- A PR describe attempt appears in Run Detail as `:describe` with its own
  conversation; run spend is unchanged versus before (FR-002a).
