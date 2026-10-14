---

description: "Task list for 042 — classify conversation output"
---

# Tasks: Classify Conversation Output — Scroll Rows, Header Fields, Footer Signals

**Input**: Design documents from `/specs/042-classify-conversation-output/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/classification.md, contracts/console-surfaces.md, quickstart.md

**Tests**: Included. The plan lists ExUnit/LiveViewTest files for every module and the constitution requires >90% coverage on new pure modules.

**Organization**: Grouped by user story (US1 P1 … US4 P4). All Elixir commands run via `mise exec -- mix …`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4; Setup/Foundational/Polish carry no label

## Path Conventions

Single Elixir app: `lib/autonomous/`, `lib/autonomous/web/`, `test/autonomous/`, `priv/static/assets/console.css`.

---

## Phase 1: Setup

- [X] T001 Create synthetic fixture `test/fixtures/conversations/042_sample.jsonl` (conversation file v1 JSONL) covering every sub-kind in research.md R1: start, prompt, init, status, thinking_tokens, hook_started/hook_progress/hook_response (success and failing), assistant_text, thinking, parallel tool_calls (Bash, Read, Write, Edit, Glob, Grep, Skill, one unknown tool) with results (short, 40-line, `is_error`), tool_progress, rate_limit_event (allowed and limited), task_started/task_notification, api_retry, injected `other · text`, result (success) and end
- [X] T002 [P] Exclude the `:census` tag by default in `test/test_helper.exs`

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Pure classifier, tool summary, and block-model revision that every story renders through.

- [X] T003 [P] Write `test/autonomous/web/conversation_class_test.exs`: one assertion per row of the data-model.md placement table, unknown kind/sub-kind → raw row, totality (never raises), `visible?/2` with `all_frames?` true for every entry, `sub_kind/1`
- [X] T004 [P] Write `test/autonomous/web/tool_summary_test.exs`: Bash/Read/Write/Edit/Glob/Grep/Skill/NotebookEdit keys, multi-line `…`, 200-char cap, unknown tool first string by sorted key, empty input → name only, nil name → `tool`
- [X] T005 [P] Implement `lib/autonomous/web/conversation_class.ex` (`classify/1`, `visible?/2`, `sub_kind/1`, `@spec`s, placement table per data-model.md)
- [X] T006 [P] Implement `lib/autonomous/web/tool_summary.ex` (`summary/2` per contracts/classification.md)
- [X] T007 Revise `test/autonomous/web/conversation_rows_test.exs`: blocks via `rows/3`, call+result grouping re-emitted under the same key, parallel calls `[A+rA][B+rB]` with rB first, hidden entries still advance pairing, `unfinished?` at end, orphan result block, stream equivalence (batch vs one-at-a-time), SC-002 identity with `all_frames: true`, `expand/2` of a result seq returns owning call block
- [X] T008 Revise `lib/autonomous/web/conversation_rows.ex`: `new/1` (`all_frames:`), `rows/3` returning `{[block], ctx}`, block struct per data-model.md (key, class, label, summary, body, omitted, result part with 5-line preview/`more_lines`, flag, unfinished?, outcome/chip), `result_owner` in ctx, `expand/2`; keep 040 truncation and pairing guarantees (depends on T005, T006, T007)
- [X] T009 Update every 040 caller of the old row API (`conversation_live.ex`, `transcripts_live.ex`, `conversation_components.ex`) to compile against the new block shape with minimal markup so `mise exec -- mix compile` and the existing suite stay green (warnings_as_errors) (depends on T008)

**Checkpoint**: classifier + blocks tested; suite compiles.

---

## Phase 3: User Story 1 — Read the transcript, watch the signals (P1) 🎯 MVP

**Goal**: Progress frames leave the scroll and drive a sticky bottom status line (live, embedded, saved).

**Independent Test**: Replay `042_sample.jsonl`; no status/thinking_tokens/hook_started/successful hook_response/tool_progress/rate_limit entry is a row, each updates the status line; prompt/prose/thinking/calls/results are rows in order.

### Tests for US1

- [X] T010 [P] [US1] Write `test/autonomous/web/session_status_test.exs`: each FR-015 activity transition, turn counting (R6), tool-call count, open_calls pairing, `open_tasks` floor at 0, open_hooks, thinking-token latest-not-accumulated, rate-limit set/clear, cost/duration nil until result, idempotence by seq, freeze after `end` (activity/ended_at/outcome), `mark_lower_bound/1`, `activity_text/1`, `status_name/2`, `elapsed_s/2` (live vs frozen vs nil), `count_text/2`, announce only on end and rate-limit onset, `apply_all` == incremental fold (SC-004)
- [X] T011 [P] [US1] Add `fold/4` tests to `test/autonomous/conversation_file_test.exs`: streamed fold, `through_seq` stops without reading past it, errors for missing / unreadable / unsupported version / malformed line before `through_seq`
- [X] T012 [P] [US1] Add `file_path/1` test (live registry identity → `{:ok, path}`, unknown → `:not_live`) to `test/autonomous/conversation_identity_test.exs`
- [X] T013 [P] [US1] Revise `test/autonomous/web/conversation_live_test.exs`: no raw rows for signal entries by default; status-line groups `[data-activity]`, `[data-turns]`, `[data-tools]`, `[data-tasks]`, `[data-rate-limit]`, `[data-cost]`, `[data-duration]` update from broadcasts; join to a 600-entry session seeds exact counters from file, `≥` when file removed; `:tick` advances `[data-elapsed]` and stops at `end`; `[data-announce]` set only at end and rate-limit onset; role=region aria-label; SC-006: a broadcast entry is reflected in `[data-activity]` on the very next render, without waiting for a `:tick`
- [X] T014 [P] [US1] Revise `test/autonomous/web/transcripts_live_test.exs` (static status line over loaded pages, no tick/pulse, parity with live end state — SC-004) and `test/autonomous/web/mission_control_live_test.exs` (embedded status line present)

### Implementation for US1

- [X] T015 [P] [US1] Implement `lib/autonomous/web/session_status.ex` (struct, `new/0`, `apply/2`, `apply_all/2`, `mark_lower_bound/1`, `activity_text/1`, `status_name/2`, `elapsed_s/2`, `count_text/2`; `session_id` moved from 040 `session_id_of/1`) per data-model.md
- [X] T016 [P] [US1] Add `ConversationFile.fold/4` (streamed, `through_seq:`, tagged errors) in `lib/autonomous/conversation_file.ex`
- [X] T017 [P] [US1] Add `Conversation.file_path/1` in `lib/autonomous/conversation.ex`
- [X] T018 [US1] Add `status_line/1` component in `lib/autonomous/web/components/conversation_components.ex` per contracts/console-surfaces.md (`section.conv-status`, `data-conv-status`, groups, `data-status` name on activity dot, pulse only while live, sr-only `aria-live="polite" data-announce`) (depends on T015)
- [X] T019 [US1] Add `.conv-status` styles (sticky bottom, flex-wrap, mono, tokens only, existing `.sr-only`, existing 760px breakpoint, existing pulse keyframe) to `priv/static/assets/console.css`, plus a `.mc-live-panel .conv-status` rule pinning it to the embedded panel's bottom edge (mirrors `.mc-live-panel .conv-toolbar`); run design-contract guard (depends on T018)
- [X] T020 [US1] Wire `lib/autonomous/web/live/conversation_live.ex`: status seed on attach (subscribe → catch_up → `file_path/1` → `fold(through_seq: last_seq)`; error ⇒ window seed + `mark_lower_bound`), apply broadcasts `seq > last_seq` to both rows and status, `:tick` every 1000 ms only while live and not ended, render status line (depends on T008, T015, T016, T017, T018)
- [X] T021 [US1] Ensure `lib/autonomous/web/live/conversation_panel_live.ex` / Mission Control embed renders the status line inside the `.mc-live-panel` scroll area so the T019 rule pins it (panel delegates to `ConversationLive`; verify, no new logic) (depends on T019, T020)
- [X] T022 [US1] Wire `lib/autonomous/web/live/transcripts_live.ex`: fold `SessionStatus` over all loaded pages, render static status line, load-more updates it (depends on T008, T015, T018)

**Checkpoint**: US1 fully functional and independently testable (quickstart §1–2, steps 2, 4–6).

---

## Phase 4: User Story 2 — Scan tool calls and results at a glance (P2)

**Goal**: One-line `Tool(summary)` calls, nested 5-line results, folded prompt/context/thinking, marker rows, divider.

**Independent Test**: Render sample with six tools + unknown tool and short/long/failed results; verify summary line, fold, nesting, error flag.

### Tests for US2

- [X] T023 [P] [US2] Extend `test/autonomous/web/conversation_live_test.exs` with block markup assertions: `.conv-call` summary line `Bash(...)`, no JSON by default, `.conv-result` 5 lines + `+N lines` button (`phx-click="expand"`), `.conv-flag` for `is_error`/`unfinished`/hook failed/result error without `data-status`, prompt/context/thinking `<details>` with first line, marker one-liners, divider `session opened · <model>`, end chip, raw unknown row folded, standalone result block with tool name, expand replaces owning call block in place

### Implementation for US2

- [X] T024 [US2] Revise block markup per class in `lib/autonomous/web/components/conversation_components.ex` per contracts/console-surfaces.md (prose sans via `TranscriptMarkup`, context/thinking details, call + result part, marker, divider, end, raw; 040 truncation still applies inside folded bodies; no raw `inspect/1`) (depends on T009)
- [X] T025 [US2] Add `.conv-call`, `.conv-result`, `.conv-marker`, `.conv-divider`, `.conv-flag`, `.conv-prose` styles (tokens only, single-line ellipsis for call summary, mono/sans roles) to `priv/static/assets/console.css` (depends on T024)
- [X] T026 [US2] Handle `expand` for result seq in `conversation_live.ex` and `transcripts_live.ex` (re-emit owning call block via `ConversationRows.expand/2`) (depends on T024)

**Checkpoint**: US2 independently verifiable; design-contract guard green.

---

## Phase 5: User Story 3 — Show all frames, same view in review (P3)

**Goal**: `frames=all` toggle restores every entry; Transcripts uses same classification.

**Independent Test**: Toggle off/on for sample; blocks == entries − paired results; URL carries `frames=all`; Transcripts parity.

### Tests for US3

- [X] T027 [P] [US3] Extend `conversation_live_test.exs`, `transcripts_live_test.exs`, `mission_control_live_test.exs`: `toggle_frames` flips `data-frames`, signals appear as folded raw rows labelled `<kind> · <sub-kind>` in recorded order, `?frames=all` param honoured and combined with `follow=1`, embedded toggle has no URL, status line unchanged by toggle, mid-session toggle rebuilds from window

### Implementation for US3

- [X] T028 [US3] Add `show all frames` switch (`.pr-toggle` + `.switch-input`, `phx-click="toggle_frames"`, `data-frames`) to the toolbar component in `conversation_components.ex` (depends on T024)
- [X] T029 [US3] Implement `toggle_frames` + `frames=all` param handling and row rebuild from window in `conversation_live.ex` (URL patch except embedded) (depends on T028)
- [X] T030 [US3] Implement `toggle_frames` + `frames=all` param and rebuild from loaded pages in `transcripts_live.ex` (depends on T028)

**Checkpoint**: US3 verifiable; SC-002 holds in tests.

---

## Phase 6: User Story 4 — Model and CLI in the header (P4)

**Goal**: Header shows model alias, resolved model, CLI version.

**Independent Test**: Sample with `init` shows all three; without `init` shows alias only and fills in on arrival.

### Tests for US4

- [X] T031 [P] [US4] Add header assertions to `conversation_live_test.exs`: `[data-header-model]`, `[data-header-resolved]`, `[data-header-cli]` present after `init`, alias-only before, nothing placeholder

### Implementation for US4

- [X] T032 [US4] Render model alias · resolved model · `cli <version>` (mono, each only when known) in the toolbar header from `SessionStatus` in `conversation_components.ex` / `conversation_live.ex` (depends on T015, T024 — not on US3)
- [X] T033 [US4] Same header fields on `transcripts_live.ex` where the toolbar is shown (depends on T022, T032)

**Checkpoint**: all stories complete.

---

## Phase 7: Polish & Cross-Cutting

- [X] T034 [P] Add `test/autonomous/web/census_test.exs` (`@moduletag :census`, `AUTONOMOUS_CENSUS_DIR`): default blocks ≤ 35% of entries (SC-001), every prompt/text/thinking/call/result visible, every entry visible-or-signal (SC-003), live fold == saved fold per file (SC-004)
- [X] T035 [P] Update `docs/runbook.md` live-view section (status line, `frames=all`, header fields, lower-bound `≥` fallback)
- [X] T036 [P] Add one paragraph under "Live agent conversation (feature 040)" in `CLAUDE.md` and a cross-reference in the 040 console-surfaces contract
- [X] T037 Run full suite `mise exec -- mix test` (warnings_as_errors, design-contract guard rule count unchanged — SC-008) and `mise exec -- mix test --cover` for >90% on the new pure modules
- [ ] T038 Run quickstart.md §1–2 and the by-hand checklist §4, including SC-006 by hand (status line follows a live session within 2 s) (record result in the PR description)

---

## Dependencies & Execution Order

- Phase 1 → Phase 2 (T003–T006 parallel; T007 → T008 → T009) → stories.
- US1 (MVP) needs Phase 2. US2 needs T009. US3 needs T024 (toolbar/markup). US4 needs T015 and T024 (independent of US3).
- US1 and US2 touch `conversation_components.ex` and `console.css`: sequence their edits (T018 → T024; T019 → T025) or coordinate if parallel.
- Polish after desired stories.

## Parallel Examples

- Phase 2: T003, T004, T005, T006 together.
- US1: T010–T014 tests together; then T015, T016, T017 together.

## Implementation Strategy

**MVP = Phase 1 + 2 + US1** (signals out of the scroll, live status line). Then US2 (scan-ability), US3 (completeness toggle + review parity), US4 (header). Validate each checkpoint with the quickstart commands before moving on.
