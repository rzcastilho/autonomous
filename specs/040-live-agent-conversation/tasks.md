---

description: "Task list for feature 040 — Live and Durable Agent Conversation View"
---

# Tasks: Live and Durable Agent Conversation View

**Input**: Design documents from `/specs/040-live-agent-conversation/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R15), data-model.md, contracts/{conversation-capture,conversation-file,console-surfaces}.md, quickstart.md

**Tests**: INCLUDED. The spec mandates them (FR-003 coverage guard, SC-004 isolation, SC-006 seam, FR-022 design guard) and the plan lists the test files. Write each test first, see it fail, then implement.

**Organization**: Grouped by user story. US1 = live view (P1), US2 = saved review (P2), US3 = mid-session catch-up (P3).

**Toolchain**: every Elixir command through `mise exec -- mix …` (never bare `mix`); `warnings_as_errors` is on. Prefix git with `rtk`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different files, no dependency on an incomplete task
- **[Story]**: US1 / US2 / US3 (user-story phases only)
- All paths relative to repo root `/Users/castilho/code/github.com/rzcastilho/autonomous`

---

## Phase 1: Setup

**Purpose**: shared test scaffolding and supervised subtree skeleton

- [X] T001 [P] Create scripted fake SDK `test/support/fake_sdk.ex` (`Autonomous.FakeSdk`): configured via `:sdk_proxy_inner`, `query/2` + `resume/3` emit a scripted `%ClaudeAgentSDK.Message{}` frame list (system init, assistant text, tool_use, user tool_result, result), expose an option to stall/never-end, and **fail the test loudly if `AUTONOMOUS_CONVERSATION` is absent from `options.env`** when the test sets `require_marker: true`
- [X] T002 [P] Add `ConversationRegistry` (`{Registry, keys: :unique, name: Autonomous.ConversationRegistry}`) and `ConversationSup` (`{DynamicSupervisor, name: Autonomous.ConversationSup, strategy: :one_for_one}`) to the app tree in `lib/autonomous/application.ex`, placed before `RunnerSup`/`SessionSup`

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: pure modules, file boundary, recorder, facade, tap, schema v8. No user story can start until this is done.

**⚠️ CRITICAL**: complete before Phase 3+

### Pure modules (tests first, all parallel — distinct files)

- [X] T003 [P] Test `test/autonomous/credential_mask_test.exs`: `names/0` is the explicit list (`CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GH_TOKEN GITHUB_TOKEN`); `pairs/1` drops values < 8 chars and unset vars; `mask/2` replaces every exact occurrence with `[masked:NAME]`, longest value first, recursively over all strings in maps/lists (keys and values), leaves non-strings untouched
- [X] T004 [P] Implement `lib/autonomous/credential_mask.ex` (`Autonomous.CredentialMask`, pure except `pairs/1` reading `System.get_env/1` once) per R9 — make T003 pass
- [X] T005 [P] Test `test/autonomous/conversation_window_test.exs`: cap 500, `push/2` evicts oldest, `dropped` counts, `snapshot/1 → {entries, last_seq, truncated?}`, empty window
- [X] T006 [P] Implement `lib/autonomous/conversation_window.ex` (`:queue`-based ring, `new/1` default cap 500) — make T005 pass
- [X] T007 [P] Test `test/autonomous/conversation_outcome_test.exs`: `from_result/1` maps `PhaseResult` to `:completed | {:error, r} | :exhausted | :deadline_exceeded | {:session_died, :start_failed|:ended_early}` and passes `{:backgrounded_command, …}`/`:incomplete_session` through; `encode/decode` round-trip using the string vocabulary (`"deadline_exceeded"`, `"session_died:start_failed"`, `"error:<reason>"`); `capture_status/1` → `:captured | :partial | :not_captured` per R6
- [X] T008 [P] Implement `lib/autonomous/conversation_outcome.ex` — make T007 pass
- [X] T009 [P] Test `test/autonomous/conversation_entry_test.exs`: `from_frame/1` for system, assistant (N blocks → N entries: text/thinking/tool_use), user tool_result, result, unknown type → `:other` with whole raw; `stream_event` → `[]`; `encode/decode` round-trip incl. unknown `kind` → `:other`; no frame dropped (FR-013)
- [X] T010 [P] Implement `lib/autonomous/conversation_entry.ex` (`from_frame/1`, `encode/1`, `decode/1`, struct `seq/at/kind/body`) per data-model — make T009 pass
- [X] T011 [P] Implement `lib/autonomous/conversation_identity.ex` (struct + `validate/1` returning `{:error, {:bad_identity, field}}`; required: `run_id feature_id phase ordinal transcript_root`; fields per data-model) with test `test/autonomous/conversation_identity_test.exs`

### File boundary

- [X] T012 Test `test/autonomous/conversation_file_test.exs` (`@moduletag :tmp_dir`): `open/…` creates dirs `0700` and file `0600` before first byte, `[:exclusive]` collision → `:eexist`; header line 1 per contract; `append/2`; `resolve/2`; `page/3` streams `from_seq`/`limit` and returns `next_seq | :eof`; `entry/2`; errors `:missing`, `{:unreadable, posix}`, `{:malformed, line_no}` (bad JSON and `seq` gap) with preceding lines still returned; header `version > 1` refused by name
- [X] T013 Implement `lib/autonomous/conversation_file.ex` (IO boundary; path `<transcript_root>/conversations/<run_id>/<feature_id>/<conversation_id>.jsonl`; `File.stream!/1` reads, never whole-file) — make T012 pass (depends on T010, T011)

### Recorder, facade, tap

- [X] T014 Test `test/autonomous/conversation_recorder_test.exs` (`:tmp_dir`, fake pubsub subscriber): frame → mask → seq → window → append → broadcast `{:conversation, id, :entry, entry}` in one callback; `catch_up` returns window + `last_seq` + `truncated?`; `{:entry, seq}`; `close` writes single `:end` entry, closes file, deregisters, broadcasts `:ended`, stops `:normal`; file write error → `:partial` with `{:write_failed, posix}` while window/broadcast continue; kill recorder → `close/2` yields `:partial` `:recorder_down`; unwritable root → `{:not_captured, ref, request}` with request unchanged; **SC-006**: subscribe → catch_up → apply `seq > last_seq` has zero gaps/dupes vs saved file; **SC-008**: command output echoing every masked env value leaves zero occurrences in broadcast and file
- [X] T015 Implement `lib/autonomous/conversation_recorder.ex` (`GenServer`, `restart: :temporary`, registered in `ConversationRegistry` with identity-minus-root + `opened_at`; thin shell over `ConversationEntry`/`CredentialMask`/`ConversationWindow`/`ConversationFile`) — make T014 pass (depends on T004, T006, T008, T010, T013)
- [X] T016 Implement `lib/autonomous/conversation.ex` facade: `open/2` (allocate `conversation_id = "<phase>-<ordinal>-<base36 stamp>"` with `System.unique_integer`, start recorder under `ConversationSup`, write `:start` + `:prompt`, add `AUTONOMOUS_CONVERSATION` to `metadata["claude"].env`, on any failure `{:not_captured, ref, request_unchanged}`); `close/2` (`GenServer.call` 30 s, exit-safe, `:partial` on timeout/`:noproc`/crash, one `:warning` log when not `:captured`, returns `ConversationRef`); `subscribe/1` (topic `"conversation:" <> id`); `catch_up/1` and `entry/2` (1 s timeout → `:not_live`/`:not_found`); `in_flight/1` via `Registry.select/2` newest first; broadcast `{:console, :conversation_opened | :conversation_closed, …}` on `"console:run"` — covered by T014 (depends on T015)
- [X] T017 [P] Add helper in `lib/autonomous/phase_request.ex` to add the marker to `metadata["claude"].env` (used by `Conversation.open/2`); extend `test/autonomous/phase_request_test.exs`
- [X] T018 Extend `test/autonomous/sdk_proxy_test.exs`: `prepare/1` pops `AUTONOMOUS_CONVERSATION` (and 036 marker) so the CLI never sees it (FR-026); frames are forwarded unchanged and `send/2`ed to the recorder; no marker ⇒ stream returned untouched; dead recorder pid ⇒ no raise, no delay; the tap never awaits
- [X] T019 Implement tap in `lib/autonomous/sdk_proxy.ex` (`query/2` and `resume/3`: pop marker in `prepare/1`, `Stream.each(&send(recorder, {:frame, &1}))`; never awaits/raises/alters) — make T018 pass (depends on T015)

### Schema v8 and store

- [X] T020 Test `test/autonomous/store/migration_v8_test.exs`: from a v7 fixture table, rows load with `conversations: nil`; no row dropped; `current_version/0 == 8`; extend `test/autonomous/store/schema_shape_test.exs` and `records_test.exs` for the new field
- [X] T021 Implement schema v8: `lib/autonomous/store/schema.ex` (`conversations` appended last, frozen `@phase_attempt_v8_attributes`), `lib/autonomous/store/records.ex` (`ConversationRef` type, `PhaseAttempt.conversations`), `lib/autonomous/store/migrations.ex` (`transform_table` via `Tuple.insert_at(…, nil)`, `current_version` 8, moduledoc paragraph) — make T020 pass
- [X] T022 Test then implement writer persistence + prune in `lib/autonomous/store/writer.ex`: `record_phase_attempt/2` / `record_remediation_attempt/2` / chunk path persist `conversations`; prune deletes the conversation files of attempts it deletes **after** the transaction commits (extend `test/autonomous/store/writer_test.exs`, `prune_test.exs`)
- [X] T023 [P] Test then implement export in `lib/autonomous/store/export.ex`: per-attempt conversation status/reason/entries/bytes only — no path, no content (extend `test/autonomous/store/export_test.exs`, `export_run_test.exs`)
- [X] T024 [P] Add capture-reason and outcome rendering to `lib/autonomous/report.ex` `format_reason/1` (e.g. `{:open_failed, posix}`, `:recorder_down`, `:close_timeout`, `{:write_failed, posix}`) with tests in `test/autonomous/report_test.exs`

**Checkpoint**: pure core, recorder, tap and schema v8 green (`mise exec -- mix test`); nothing yet calls `Conversation.open/2`.

---

## Phase 3: User Story 1 — Watch a running session live (P1) 🎯 MVP

**Goal**: every session type is recorded and its live view appends entries as they arrive, from Mission Control / Run Detail.

**Independent Test**: start a fixture-target run with the fake SDK, open `/live`, see entries in arrival order and an end marker with the outcome when the session finishes.

### Tests for US1 (write first)

- [X] T025 [P] [US1] Test `test/autonomous/web/conversation_rows_test.exs`: one row per entry; tool result paired to its call by `tool_use_id`; call with no result at `:end` tagged `unfinished`; truncation at 40 lines / 4,000 chars with `omitted: %{lines:, chars:}` and untouched underlying entry; thinking collapsed; end marker carries outcome term; outcome rendered through `Report.format_reason/1` (no `inspect/1`)
- [X] T026 [P] [US1] Test `test/autonomous/conversation_coverage_test.exs` (FR-003): (a) **source guard** scans `lib/**/*.ex` for `Jido.Harness.run_request` / `Jido.Harness.run`, every hit must be in an explicit allowlist of session sites and each allowlisted file must reference `Conversation.open`; (b) **behavioural** with `FakeSdk` (`require_marker: true`): drive phase, implement chunk, auto-remediation, remediation and describe and assert a closed `:captured` file plus a ref on the recorded attempt
- [X] T027 [P] [US1] Test `test/autonomous/conversation_isolation_test.exs` (SC-004/FR-005): zero viewers / one viewer / a never-reading subscriber ⇒ identical outcome and `duration_ms` within 1 %; killed recorder ⇒ session outcome unaffected; deadline and drain checks unchanged
- [X] T028 [P] [US1] Test `test/autonomous/web/conversation_live_test.exs` (`Phoenix.LiveViewTest`, synthetic frames): `/live` follows newest in-flight session; entries stream in order; tool call and result are separate rows; long result truncated + `expand` replaces row in place; `:ended` shows end marker with outcome chip and stops live dot; follow mode shows `next session: <id>` link without auto-navigating; empty state `No agent session in flight`; pinned unknown id → `Conversation <id> is not live and has no saved record`; view never calls the Coordinator (uses `ConsoleProjection.last_known/1`)
- [X] T029 [P] [US1] Extend `test/autonomous/web/mission_control_live_test.exs` and `test/autonomous/web/run_detail_live_test.exs`: `live session` mono link appears on `{:console, :conversation_opened, …}` and disappears on `…_closed`; no link when nothing open (SC-001 ≤ 2 clicks)
- [X] T030 [P] [US1] Extend `test/autonomous/describe_test.exs` and `test/autonomous/feature_runner_test.exs`: PR describe session opens/closes a conversation; recorded as `:describe` attempt (ordinal 1, `label: "describe"`, outcome, duration, session id, refs) with **no cost entry** (run spend unchanged, FR-002a); describe failure/empty/unparseable still falls back to the default commit message and never changes feature status

### Implementation for US1

- [X] T031 [P] [US1] Implement `lib/autonomous/web/conversation_rows.ex` (pure `rows/2`, truncation, pairing, unfinished) — make T025 pass
- [X] T032 [US1] Build `ConversationIdentity` per step in `lib/autonomous/feature_runner.ex` (holds `run_key`; kinds `:phase | :implement_chunk | :auto_remediation | :remediation | :describe`; `transcript_root` from `Layout`) and pass it in the signal data of every `"phase.run"` / `"remediation.run"` / auto-remediation signal and to `Describe.run/4`
- [X] T033 [P] [US1] `lib/autonomous/actions/run_feature_phase.ex`: `open → run_request → PhaseSession.reduce → close`; return `conversations: [ref]` in the state update; absent identity opens nothing
- [X] T034 [P] [US1] `lib/autonomous/actions/run_auto_remediation.ex`: same open/close wrap and refs in state update
- [X] T035 [P] [US1] `lib/autonomous/actions/run_remediation.ex`: same open/close wrap and refs in state update
- [X] T036 [US1] `lib/autonomous/phase_step.ex` and `lib/autonomous/session_retry.ex`: accumulate refs across the session-died retry (two refs per retried phase, FR-020); `close/2` has returned before the attempt is recorded (FR-012)
- [X] T037 [P] [US1] `lib/autonomous/chunk_runner.ex` and `lib/autonomous/chunking.ex`: identity per implement chunk; refs written on the `:implement_chunk` row; `:implement` roll-up row gets `conversations: []`
- [X] T038 [P] [US1] `lib/autonomous/analyze_runner.ex`: identity per analyze run and per auto-remediation attempt; refs on their rows
- [X] T039 [US1] `lib/autonomous/describe.ex`: open/close around `run_request`; return the ref with the message; in `lib/autonomous/feature_runner.ex` `commit_message_and_pr` record the `:describe` attempt through the no-cost-entry path (`model_for_record(:describe, …)` → `Config.model_for(:describe)`); non-blocking (depends on T032)
- [X] T040 [US1] Pass `attempt.conversations` through every `record_attempt/9` / `record_remediation_attempt` / chunk call site in `lib/autonomous/feature_runner.ex` (depends on T033–T039)
- [X] T041 [P] [US1] Delete dead module `lib/autonomous/actions/run_phase.ex` and `test/autonomous/run_phase_test.exs` (R12: no production caller); fix any reference so `mix compile` stays warning-free
- [X] T042 [P] [US1] Implement `lib/autonomous/web/components/conversation_components.ex` (timeline, row, end marker; mono for machine values, sans prose via `TranscriptMarkup`; `.transcript-live[data-live=true]` dot only while recorder runs; thinking collapsed; `is_error: true` shown as text, not status color)
- [X] T043 [US1] Implement `lib/autonomous/web/live/conversation_live.ex` per contracts/console-surfaces.md: header (mono ids), `stream/3` + `phx-update="stream"`, subscribe → catch_up → apply `seq > last_seq`, `expand` event via `Conversation.entry/2`, end marker, follow mode, empty states, exit-safe (depends on T016, T031, T042)
- [X] T044 [US1] Add routes `/live` and `/live/:conversation_id` to `lib/autonomous/web/router.ex`; pinned id not live → redirect to its Transcripts entry when a saved ref exists
- [X] T045 [P] [US1] `lib/autonomous/web/live/mission_control_live.ex`: `live session` link on the in-flight feature card, updated on `{:console, :conversation_opened | :conversation_closed, …}`
- [X] T046 [P] [US1] `lib/autonomous/web/live/run_detail_live.ex`: `live session` link on the in-flight row, same events
- [X] T047 [P] [US1] `priv/static/assets/console.css`: conversation timeline rules using tokens only (no new keyframe; animated selectors contain `live` and are listed in `prefers-reduced-motion: reduce`); add the new LiveView, component and `ConversationRows` files to `@surfaces` in `test/support/design_contract.ex`; keep `test/autonomous/web/design_contract_test.exs` green (FR-022)

**Checkpoint**: US1 works end-to-end and independently: all five session kinds produce a `:captured` file, `/live` streams them, coverage guard green.

---

## Phase 4: User Story 2 — Review a finished session (P2)

**Goal**: any ended session's full conversation is readable from Transcripts / Run Detail, surviving container rebuild, with explicit fallbacks.

**Independent Test**: run one phase to completion and one cut at a short deadline; open both from Transcripts (also after restarting the app) and read the full conversation ending with the outcome.

### Tests for US2 (write first)

- [X] T048 [P] [US2] Extend `test/autonomous/web/transcripts_live_test.exs`: captured ref renders `ConversationRows` timeline from `ConversationFile.page/3`, 500 at a time with `load next 500`; `session` param selects ref (default last) and retried phases list `session 1`/`session 2` (FR-020); `:partial` → rows then `ended without an end marker — <reason>`; `:not_captured` → final text under `No full conversation captured: <reason>`; `conversations: nil` → final text under `No full conversation was recorded for this attempt (recorded before feature 040).`; missing file → `Saved conversation missing at <relative path>` (or `unreadable: <posix>`) plus final text; deadline-cut file shows last tool call `unfinished` and `deadline_exceeded` end marker; viewing one attempt reads no other attempt's file and listings do no file I/O (FR-021)
- [X] T049 [P] [US2] Extend `test/autonomous/web/run_detail_live_test.exs`: per-attempt `conversation` column — `captured` link, `partial` link + reason, `not_captured` + reason, `not recorded (pre-040)` for `nil`; one link per session for multi-ref attempts; `:describe` row renders like any attempt
- [X] T050 [P] [US2] Extend `test/autonomous/legacy_records_039_test.exs` (or add `test/autonomous/legacy_records_040_test.exs`): every pre-040 attempt still opens on Transcripts with its final-text transcript (SC-007)

### Implementation for US2

- [X] T051 [US2] `lib/autonomous/web/live/transcripts_live.ex`: conversation pane per attempt reusing `ConversationComponents`/`ConversationRows`; `session` query param; paged load via `ConversationFile.page/3`; all five fallbacks with their exact messages (depends on T031, T042)
- [X] T052 [US2] `lib/autonomous/web/live/run_detail_live.ex`: `conversation` column per attempt row and one link per session; reads refs only, no file I/O (depends on T046)
- [X] T053 [P] [US2] `priv/static/assets/console.css` / `test/support/design_contract.ex`: any rules for the review pane and `load next 500` control, tokens only; guard stays green

**Checkpoint**: US1 and US2 both independently functional.

---

## Phase 5: User Story 3 — Join a long session mid-way (P3)

**Goal**: joining late shows the recent window then the live tail with no gap/duplicate; truncation notice; reconnect resumes.

**Independent Test**: start a steady-output session, open the view part-way, compare shown entries to the saved file — identical order, no gaps or duplicates.

### Tests for US3 (write first)

- [X] T054 [P] [US3] Extend `test/autonomous/web/conversation_live_test.exs`: join mid-session shows earlier entries then tail, zero dupes/gaps vs saved file (SC-006); > 500 entries shows `Showing the most recent 500 entries; earlier entries are in the full conversation once the session ends.`; remount (reconnect) re-runs subscribe → catch_up → `seq > last_seq` without duplicates; `catch_up` timeout/dead recorder shows "not reachable live" and links the saved conversation instead of crashing (FR-010)
- [X] T055 [P] [US3] Extend `test/autonomous/conversation_recorder_test.exs`: console restart (new viewer process) mid-session still gets the window while the recorder runs; two overlapping sessions never cross entries

### Implementation for US3

- [X] T056 [US3] `lib/autonomous/web/live/conversation_live.ex`: catch-up notice when `truncated?`; dedupe on `seq > last_seq` across remount; graceful `:not_live` path linking the saved record (depends on T043)

**Checkpoint**: all three stories independently functional.

---

## Phase 6: Polish & Cross-Cutting

- [X] T057 Amend `.specify/memory/constitution.md` 7.0.0 → **7.1.0** (Technology Stack → Persistence names the conversation file as the one permitted durable artifact outside Mnesia; owner-only; never in a target working tree; never loaded by a listing; recorded-but-missing reported as missing) with Sync Impact Report prepended (FR-015, R13)
- [X] T058 [P] Update `docs/runbook.md` (live view, where files live, masking list, permissions, partial/not-captured reasons), `docs/container.md` (transcript root survives rebuild), `docs/workflow.md` (conversation capture in the phase flow), and `CLAUDE.md` (feature 040 paragraph)
- [X] T059 [P] Add a smoke subcommand (or documented manual step) to `scripts/container-smoke.sh` that echoes `$GH_TOKEN` and `$CLAUDE_CODE_OAUTH_TOKEN` in a session for quickstart §2 step 6
- [X] T060 Pure-module coverage ≥ 90 %: `mise exec -- mix test --cover` for `ConversationEntry`, `CredentialMask`, `ConversationWindow`, `ConversationOutcome`, `Web.ConversationRows`; add cases for gaps
- [ ] T061 Full gate: `mise exec -- mix compile` (no warnings) and `mise exec -- mix test` green, including `design_contract_test.exs` and `conversation_coverage_test.exs`
- [ ] T062 Run quickstart.md §2–§4 in the container (live check, deadline post-mortem after rebuild, pre-040 and missing-file fallbacks, `:describe` row with unchanged spend) and record results

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1** → no dependencies (T001, T002 parallel)
- **Phase 2** → after Phase 1; **blocks all stories**
- **Phase 3 (US1)** → after Phase 2; MVP
- **Phase 4 (US2)** → after Phase 2; needs `ConversationRows`/components (T031, T042) from US1, else independent (the file is written by Phase 2 + T033–T040)
- **Phase 5 (US3)** → after T043 (extends `ConversationLive`)
- **Phase 6** → after desired stories; T057 can start any time

### Within Phase 2

T003→T004, T005→T006, T007→T008, T009→T010, T011 (parallel group) → T012→T013 → T014→T015 → T016; T017 parallel; T018→T019 (needs T015); T020→T021→T022; T023, T024 parallel after T021.

### Within US1

T031 / T042 parallel → T043 → T044. T032 first among wiring; T033–T038 parallel (distinct files) after T032 and T016; T036 after T033–T035; T039 after T032; T040 after T033–T039; T041 anytime after T040; T045, T046, T047 parallel after T044.

### Same-file serialization

`feature_runner.ex` (T032, T039, T040), `conversation_live.ex` (T043, T056), `run_detail_live.ex` (T046, T052), `transcripts_live.ex` (T051), `conversation_recorder_test.exs` (T014, T055), `conversation_live_test.exs` (T028, T054), `console.css`/`design_contract.ex` (T047, T053) — do not run these in parallel with each other.

## Parallel Examples

```text
Phase 2 pure core (all at once):
  T003 credential_mask_test   T005 conversation_window_test
  T007 conversation_outcome_test   T009 conversation_entry_test   T011 conversation_identity

US1 wiring after T032 (distinct files):
  T033 run_feature_phase.ex   T034 run_auto_remediation.ex   T035 run_remediation.ex
  T037 chunk_runner.ex/chunking.ex   T038 analyze_runner.ex

US1 tests (all at once):
  T025 rows_test   T026 coverage_test   T027 isolation_test   T028 live_test   T029 MC/RD tests   T030 describe tests
```

## Implementation Strategy

### MVP first (US1)

1. Phase 1 → Phase 2 (checkpoint: recorder + tap + v8 green)
2. Phase 3 US1 → **stop and validate**: coverage guard, isolation test, `/live` against the fake SDK; quickstart §2 in the container
3. Demo/ship if wanted — Transcripts still shows final text (saved files already written)

### Incremental

1. + US2 (Transcripts review, Run Detail column, fallbacks) → quickstart §3–§4
2. + US3 (catch-up polish, notices, reconnect) → SC-006 verification
3. Polish: constitution 7.1.0, docs, coverage, full gate, container check

### Notes

- Capture must never change a session: the tap only `send/2`s; `open/2` failure returns the request unchanged; `close/2` never raises.
- Behaviour/semantic changes beyond this spec require a new speckit feature, not an in-place edit.
- Commit after each task or logical group; verify tests fail before implementing.
