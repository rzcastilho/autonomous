---

description: "Task list for feature 043 — Close the Conversation Recorder Gaps"
---

# Tasks: Close the Conversation Recorder Gaps

**Input**: Design documents from `/specs/043-close-recorder-gaps/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R11), data-model.md, contracts/recording.md, contracts/console-surfaces.md, quickstart.md

**Tests**: Included. The plan lists a test file per revised module, the constitution requires >90% on pure modules, and the spec's success criteria (SC-001…SC-008) are test-shaped.

**Organization**: Grouped by user story (US1 P1 → US4 P4). Display tasks for each story live in that story's phase so every story is independently shippable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different files, no dependency on an incomplete task
- **[Story]**: US1–US4 (story phases only)
- All Elixir commands run through mise: `mise exec -- mix test <file>`; `warnings_as_errors` is on.
- Paths are relative to the repo root.

## Path Conventions

Single Elixir app: `lib/autonomous/`, `lib/autonomous/web/`, `test/autonomous/`, `test/autonomous/web/`, `priv/static/assets/console.css`, `docs/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Shared test input for every story.

- [X] T001 Create v2 fixture `test/fixtures/conversations/043_sample.jsonl`: header `"version": 2`; usage entries (`message_start` + two `message_delta` for message 1, `message_start` + one `message_delta` for message 2, one with `cache_read_input_tokens`); a stderr burst with three identical consecutive lines, a different line, then a `{"notice":"dropped","dropped":N}` entry followed by two tail lines; assistant/tool entries, some with `parent_tool_use_id` and some without; a final `result` with `is_error: true` and `error: "CLI exited 1"`; an `end` entry. Match field shapes in `data-model.md`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Format version, new entry kinds and config knobs that every story reads.

**⚠️ CRITICAL**: No user story work begins until this phase is complete.

- [X] T002 [P] Bump `@version` to 2 in `lib/autonomous/conversation_file.ex` (`header_of/1`, `page/3`, `fold/4`, `entry/2` accept v1 and v2, refuse ≥ 3 with `{:error, {:unsupported_version, v}}`); extend `test/autonomous/conversation_file_test.exs`: v1 accepted, v2 accepted, v3 refused by name with nothing rendered (FR-018, FR-019).
- [X] T003 [P] Add `conversation_stderr_head/0` and `conversation_stderr_tail/0` to `lib/autonomous/config.ex` (`@spec`, app env keys `:conversation_stderr_head` / `:conversation_stderr_tail`, default 1000 each; non-positive or non-integer raises at read); extend `test/autonomous/config_test.exs` for defaults, override and raise (FR-008).
- [X] T004 Add `:usage` and `:stderr` to `ConversationEntry.kinds/0` and the `kind()` type in `lib/autonomous/conversation_entry.ex`; update any exhaustive kind assertions in `test/autonomous/conversation_entry_test.exs` (042 completeness invariant, SC-007).
- [X] T005 Add placement rows to `lib/autonomous/web/conversation_class.ex` so the new kinds never fall through: `:usage` → `:signal`/`:raw`, label `usage · <event>`; `:stderr` line → `:row`/`:stderr`/`:line`, label `stderr`; `:stderr` notice → `:row`/`:marker`/`:line`, label `stderr` (rendered text `stderr · <n> lines dropped`, produced in T022/T023); extend `test/autonomous/web/conversation_class_test.exs` including the completeness invariant over every kind (depends on T004).

**Checkpoint**: v2 files open, new kinds classify, config readable — stories can begin.

---

## Phase 3: User Story 1 - A failed session never reads as a success (Priority: P1) 🎯 MVP

**Goal**: A synthetic/error SDK result is recorded as `is_error: true` with its text, and every surface shows it as a failure with the reason.

**Independent Test**: Feed `ClaudeAgentSDK.Message.error_result("CLI exited 1")` through a recorder; saved result has `is_error: true`, `error: "CLI exited 1"`; live and Transcripts marker reads `result · error_during_execution — CLI exited 1`; footer is not `done`. `error_result("")` → `error: null`, view says `no reason given`. A genuine success result is byte-identical to before.

### Tests for User Story 1

> Write first; confirm they FAIL before implementation.

- [X] T006 [P] [US1] Result-rule tests in `test/autonomous/conversation_entry_test.exs`: synthetic (`raw: %{}`, `data.is_error: true`, `data.error`) → `is_error: true` + `error` verbatim; blank/absent message → `error: nil`; genuine success body byte-identical (no `error` key); genuine error subtype with `raw.is_error` absent → `is_error: true`.
- [X] T007 [P] [US1] Extend `test/autonomous/web/session_status_test.exs`: error result sets `activity: {:result_error, text}` and `result_error` (`"no reason given"` when `error` is nil); `:end` chip `done` + `result_error` ⇒ chip `failed`, text `<outcome> · result error`; success result unchanged.
- [X] T008 [P] [US1] Extend `test/autonomous/web/conversation_rows_test.exs`: result marker with `is_error` renders `— <error>` / `— no reason given`; success marker unchanged.

### Implementation for User Story 1

- [X] T009 [US1] Revise `result/2` in `lib/autonomous/conversation_entry.ex` per R1: `is_error` = `raw["is_error"] == true or data.is_error == true`; add `"error"` (from `data.error`, fallback `raw["error"]`, blank → nil) only when `is_error` (depends on T006).
- [X] T010 [P] [US1] Add `result_error` field, `{:result_error, text}` activity and the footer `done`→`failed` rule (R7) to `lib/autonomous/web/session_status.ex` (depends on T007).
- [X] T011 [P] [US1] Append the error text / `no reason given` to the `:result_error` marker in `lib/autonomous/web/conversation_rows.ex` (depends on T008).
- [X] T012 [US1] Confirm the live panel, Mission Control embed and Transcripts show the new marker text and footer via the shared components in `lib/autonomous/web/components/conversation_components.ex`; add parity assertions to `test/autonomous/web/conversation_live_test.exs` and `test/autonomous/web/transcripts_live_test.exs` (SC-001, SC-005, FR-004).

**Checkpoint**: US1 complete — no failed session reads clean. MVP.

---

## Phase 4: User Story 2 - See why a session complained or died (Priority: P2)

**Goal**: CLI stderr lines are recorded in arrival order, bounded head/tail, masked, and shown as quiet rows with repeat collapse.

**Independent Test**: Send `{:stderr, "warn"}` ×3 between frames → three file entries in order, one row `×3`. Send 100,000 lines then close → 1,000 lines, notice `dropped: 98000`, 1,000 lines, then `end`; session outcome unchanged. `frames=all` toggle does not affect stderr rows.

### Tests for User Story 2

- [X] T013 [P] [US2] Create `test/autonomous/stderr_bound_test.exs`: ≤ head+tail lines → all emitted/held, `flush` dropped 0; exactly head+tail; head+tail+1 → dropped 1; 100,000 lines → 1,000 emitted, `flush` → `{98_000, 1_000 lines in order}`; invariant emitted+held+dropped = pushed.
- [X] T014 [P] [US2] Tests in `test/autonomous/conversation_entry_test.exs` for `stderr/1` (body `{"line": …}`) and `stderr_dropped/1` (body `{"notice":"dropped","dropped":n}`).
- [X] T015 [P] [US2] Extend `test/autonomous/conversation_recorder_test.exs`: `{:stderr, line}` entries interleave in mailbox order with frames; a configured credential value is masked in both a stderr `line` and a synthetic result's `error` text (FR-002, FR-007); 2,500-line burst with head/tail overridden small → notice precedes held tail, both precede `:end`; ≤ cap → no notice; startup-failure case (stderr only, no frames) recorded; a processing fault degrades capture status, never crashes (FR-021); a `{:stderr, line}` sent before `close` is recorded before `:end`, and one sent after `close` is a no-op that does not raise (SC-002).
- [X] T016 [P] [US2] Extend `test/autonomous/sdk_proxy_test.exs`: `callback(collector, recorder)` logs `"CLI stderr: " <> line`, still forwards untrusted-workspace lines to the collector, and `send`s `{:stderr, line}` to a recorder pid; nil/dead recorder is a no-op; `callback/1` unchanged; marker still stripped from CLI env (FR-009).
- [X] T017 [P] [US2] Extend `test/autonomous/web/conversation_rows_test.exs`: consecutive identical stderr lines → one block with `repeat: N` and all `seqs`; a different entry in between ends the run; notice renders `stderr · <n> lines dropped`; `frames=all` leaves stderr rows unchanged.

### Implementation for User Story 2

- [X] T018 [P] [US2] Create pure `lib/autonomous/stderr_bound.ex` (`new/2`, `push/2`, `flush/1`, `@spec`s, `:queue` tail, per `data-model.md` transitions) (depends on T013).
- [X] T019 [US2] Add `stderr/1` and `stderr_dropped/1` constructors to `lib/autonomous/conversation_entry.ex` (depends on T004, T014).
- [X] T020 [US2] Revise `lib/autonomous/conversation_recorder.ex`: state gains `stderr: StderrBound.t()` built from `Config.conversation_stderr_head/0` / `_tail/0`; `handle_info({:stderr, line})` → `push`, `{:emit, …}` goes through `emit/2`; on `:close`, before `:end`, `flush`, emit `stderr_dropped/1` when dropped > 0 then each held line; rescue → capture-status degradation (depends on T003, T015, T018, T019).
- [X] T021 [US2] Revise `lib/autonomous/sdk_proxy.ex`: `prepare/1` decodes the marker for the recorder pid; add `callback/2`, keep `callback/1` as `callback(collector, nil)`; add `send(recorder, {:stderr, line})` after the existing log + collector effects (depends on T016).
- [X] T022 [P] [US2] Add `repeat` (default 1) to `Block` and consecutive-identical stderr collapse in `lib/autonomous/web/conversation_rows.ex` (depends on T005, T017).
- [X] T023 [US2] Render the stderr row (`stderr` label, mono line, `×N` when `repeat > 1`) in `lib/autonomous/web/components/conversation_components.ex` and add `.conv-stderr` to `priv/static/assets/console.css` using existing tokens only (no new token/keyframe/breakpoint) (depends on T022).
- [X] T024 [US2] Add live + Transcripts assertions (stderr row visible by default, `×3`, notice row, tail after last frame) to `test/autonomous/web/conversation_live_test.exs` and `test/autonomous/web/transcripts_live_test.exs`; run `mise exec -- mix test test/autonomous/web/design_contract_test.exs` — rule count unchanged (SC-002, SC-006, SC-008).

- [X] T025 [US2] Full-size flood test in `test/autonomous/conversation_recorder_test.exs` with the default caps (1,000 / 1,000): a separate sender process interleaves a few `{:frame, …}` messages with 100,000 `{:stderr, "line <i>"}` messages, then the site calls `close/2`. Assert the file holds exactly 2,000 stderr line entries — `line 1`…`line 1000` in arrival order among the frames, then one notice `{"notice":"dropped","dropped":98000}`, then `line 99001`…`line 100000`, then `:end` last; capture status `captured`; every sender `send/2` returned without waiting on the recorder; `close/2` completes within the session's close grace and the observed session outcome is unchanged (SC-006, FR-008, FR-021) (depends on T020).

**Checkpoint**: US2 complete — stderr diagnosable in the conversation; 036 trust check and log unchanged.

---

## Phase 5: User Story 3 - Watch tokens move while the session runs (Priority: P3)

**Goal**: Streamed per-message usage is recorded and folded into `in 12.1k · out 3.1k` on the status line, live and from Transcripts; no cost until the result reports it.

**Independent Test**: Replay `043_sample.jsonl`: figure increases across messages before any result; repeated cumulative deltas don't double count; cache tokens don't change the figure; same final figure live and in Transcripts; no figure for files without usage; no cost before the result.

### Tests for User Story 3

- [X] T026 [P] [US3] Tests in `test/autonomous/conversation_entry_test.exs`: `stream_event` `message_start` and `message_delta` → one `:usage` entry with only the integer fields present (absent never 0, `event`, `message_id` on start); other stream events → `[]`.
- [X] T027 [P] [US3] Extend `test/autonomous/web/session_status_test.exs`: usage fold — delta replaces per field, new `message_start` closes the previous message, scopes by `parent_tool_use_id` don't cross-contaminate, cache fields excluded from figure, `nil` (not 0) with no usage, `≥` prefix on lower bound, `tokens_text/1` (`12.1k`, under 1,000 as integer), no cost before result, usage after outcome ignored.

### Implementation for User Story 3

- [X] T028 [US3] Emit `:usage` entries for `message_start` / `message_delta` stream events in `lib/autonomous/conversation_entry.ex` (R2); other stream events still `[]` (depends on T004, T026).
- [X] T029 [US3] Add `usage` fold state, derived `input_tokens`/`output_tokens` and `tokens_text/1` to `lib/autonomous/web/session_status.ex` (R6 fold rules in `data-model.md`) (depends on T010, T027).
- [X] T030 [US3] Add the token field (after turns, before cost, mono) to `status_line/1` in `lib/autonomous/web/components/conversation_components.ex`; extend `test/autonomous/web/conversation_live_test.exs` (figure updates per entry, absent for v1 files) and `test/autonomous/web/transcripts_live_test.exs` (final figure equals live end state) (SC-003, SC-005) (depends on T029).

**Checkpoint**: US3 complete — live tokens visible, cost still result-only.

---

## Phase 6: User Story 4 - Keep subagent attribution in the record (Priority: P4)

**Goal**: `parent_tool_use_id` is stored on entries that carry it; views unchanged.

**Independent Test**: Frames with `parent_tool_use_id` → saved entries keep it; frames without → field absent (never empty); rendering identical with or without.

### Tests for User Story 4

- [X] T031 [P] [US4] Tests in `test/autonomous/conversation_entry_test.exs`: `parent_tool_use_id` present on `assistant_text`, `thinking`, `tool_call`, `tool_result`, `other`, and `usage` when `raw` carries a non-empty binary; absent (no key) when nil or `""`.
- [X] T032 [P] [US4] Render-parity test in `test/autonomous/web/conversation_rows_test.exs`: entries with and without the id produce identical blocks (FR-016, FR-017).

### Implementation for User Story 4

- [X] T033 [US4] In `lib/autonomous/conversation_entry.ex`, add `"parent_tool_use_id"` to every entry built from `:assistant` / `:user` frames and to `:usage` entries when `raw["parent_tool_use_id"]` is a non-empty binary (R5) (depends on T028, T031).

**Checkpoint**: All four stories complete.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T034 [P] Document the new stderr rows, error-text marker, status-line token figure, stderr cap config keys and v2 format behaviour in `docs/runbook.md` (FR-024).
- [X] T035 [P] Add one paragraph after "Classified conversation output (feature 042)" in `CLAUDE.md`; add a cross-reference to 043 in the 040 `conversation-file.md` contract under `specs/040-live-agent-conversation/contracts/`.
- [X] T036 [P] Extend the opt-in `:census` test `test/autonomous/web/census_test.exs`: every local v1 file renders identically to 042 output (SC-004).
- [X] T037 [P] Add a regression assertion to `test/autonomous/conversation_recorder_test.exs`: after a session that records usage, stderr (with a dropped-count notice) and an error result, `close/2` returns a `ConversationRef` with exactly the pre-043 struct fields and a capture status in `captured | partial | not_captured`; no Mnesia schema bump (store stays v8) (FR-020).
- [X] T038 Run `mise exec -- mix compile` and full `mise exec -- mix test`; confirm zero warnings, `design_contract_test` rule count unchanged, >90% coverage on `StderrBound`, `ConversationEntry`, `SessionStatus` (`mix test --cover`).
- [X] T039 Run through `specs/043-close-recorder-gaps/quickstart.md` scenarios (§2 table; §3 live check optional) and tick results.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (1)** → **Foundational (2)** → stories → **Polish (7)**.
- Foundational blocks all stories (kinds, classification, config, version).

### User Story Dependencies

- **US1 (P1)**: after Foundational; no story dependencies. MVP.
- **US2 (P2)**: after Foundational; independent of US1 except `session_status.ex` untouched here, `conversation_rows.ex` and `conversation_components.ex` shared with US1 (sequence edits, no logical dependency).
- **US3 (P3)**: after Foundational; T029 builds on US1's T010 (same `session_status.ex`, shared fold state). Otherwise independent.
- **US4 (P4)**: after T028 (same function in `conversation_entry.ex`); logically independent.

### Same-file serialization

- `lib/autonomous/conversation_entry.ex`: T004 → T009 → T019 → T028 → T033.
- `lib/autonomous/web/session_status.ex`: T010 → T029.
- `lib/autonomous/web/conversation_rows.ex`: T011 → T022.
- `lib/autonomous/web/components/conversation_components.ex`: T012 (check) → T023 → T030.
- `test/autonomous/conversation_entry_test.exs`: T004, T006, T014, T026, T031 — write sequentially even though marked [P] against other files.

### Within Each Story

Tests first (must fail) → pure modules → process/boundary → display → live/Transcripts parity.

### Parallel Opportunities

- T002 ∥ T003 (Foundational).
- US2 tests T013–T017 touch different files except T014/T017 sharing files with other stories — batch per file.
- T018 (StderrBound) ∥ T021 (SdkProxy) ∥ T022 (rows) once their tests exist.
- T034 ∥ T035 ∥ T036 ∥ T037 (Polish).

---

## Parallel Example: User Story 2

```bash
# Tests in distinct files together:
Task: "T013 StderrBound unit tests in test/autonomous/stderr_bound_test.exs"
Task: "T015 recorder stderr tests in test/autonomous/conversation_recorder_test.exs"
Task: "T016 SdkProxy callback tests in test/autonomous/sdk_proxy_test.exs"

# Then independent implementations:
Task: "T018 StderrBound in lib/autonomous/stderr_bound.ex"
Task: "T021 SdkProxy callback/2 in lib/autonomous/sdk_proxy.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 → Phase 2 → Phase 3.
2. **Stop and validate**: synthetic-error fixture reads as failed everywhere; v1 files unchanged.

### Incremental Delivery

1. Setup + Foundational → v2 format accepted, kinds classified.
2. US1 → correctness fix shipped (MVP).
3. US2 → stderr diagnosability.
4. US3 → live token figure.
5. US4 → attribution recorded.
6. Polish → docs, census, full suite.

### Notes

- Capture paths never block or alter the session (bare `send/2`, rescue → capture status only).
- Every new text goes through the recorder's single `emit/2` (masking, seq, window, append, broadcast).
- No store/Mnesia change, no new design tokens/keyframes/guard rules.
- Behaviour is specified in `spec.md`; do not amend it in place — new semantics go through a new speckit feature.
