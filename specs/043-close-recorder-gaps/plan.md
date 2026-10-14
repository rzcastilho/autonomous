# Implementation Plan: Close the Conversation Recorder Gaps

**Branch**: `043-close-recorder-gaps` | **Date**: 2026-10-14 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/043-close-recorder-gaps/spec.md`

## Summary

Feature 040 records every frame of every agent session; 042 classifies it for
display. Four things never reach the record: synthetic SDK error results are
written as successes with their text lost; CLI stderr goes only to the log and
the workspace-trust collector; streamed per-message token usage is dropped with
the rest of `stream_event`; and `parent_tool_use_id` is discarded. 043 fixes the
record and then shows it:

- `ConversationEntry` reads the result's error flag/text from the SDK's parsed
  `data` as well as `raw` (R1), turns `message_start`/`message_delta` stream
  events into a new `:usage` kind (R2), and keeps `parent_tool_use_id` (R5).
- `SdkProxy`'s stderr callback additionally `send/2`s each line to the session's
  recorder (R3); a new pure `StderrBound` keeps the first 1,000 and a rolling
  last 1,000 lines, flushing a dropped-count notice plus the tail at close (R4).
- `ConversationFile` moves to format v2 (existing reader rule already accepts
  ≤ current, refuses newer — R9).
- Display: `SessionStatus` folds usage into `in 12.1k · out 3.1k` (R6) and
  stops showing a clean finish after an error result (R7); `ConversationClass`
  / `ConversationRows` add quiet stderr rows with repeat collapse and the error
  text on the result marker (R8). Attribution is recorded only.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28.5.0.6 (`mise.toml`)

**Primary Dependencies**: Phoenix ~> 1.7, Phoenix LiveView ~> 1.0, Jason; pinned `claude_agent_sdk` (via `jido_claude`, `include_partial_messages: true`); no new deps

**Storage**: conversation file `speckit.conversation` v1 → v2 (JSONL, owner-only, under `transcript_root`); Mnesia unchanged (store schema v8, `ConversationRef` untouched)

**Testing**: ExUnit (`mise exec -- mix test`), `Phoenix.LiveViewTest`, design-contract guard; opt-in `:census` tag for v1 parity on machine-local files

**Target Platform**: orchestrator node (container or host), browser console

**Project Type**: Elixir OTP app with embedded Phoenix LiveView operator console

**Performance Goals**: token figure updates ≤ 2 s after a usage entry (SC-003, same broadcast path as 042); stderr capture O(1) per line; close-time flush ≤ tail cap entries

**Constraints**: capture never blocks/fails/alters the session (bare `send/2`, recorder rescue → capture status only, FR-021); every new text masked via the recorder's single `emit/2`; v1 files render identically (SC-004); no new design tokens/keyframes/breakpoints/guard rules (FR-023)

**Scale/Scope**: sessions up to several thousand entries plus ≤ 2,000 stderr lines + 1 notice; ~2 usage entries per API request. 1 new pure module (`StderrBound`), 5 revised pure modules, 2 revised process/boundary modules, 2 config accessors, 3 LiveView surfaces (via shared components), CSS additions, docs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle / section | Verdict | How |
|---|---|---|
| I. Pure core, isolated contracts | PASS | The SDK/CLI frame contract stays confined to `ConversationEntry` (frame → entry) and `SdkProxy` (stderr callback); field names read are recorded in research R1/R2/R5 from the pinned deps. Head/tail bound, usage fold and placement are pure (`StderrBound`, `SessionStatus`, `ConversationClass`). |
| II. Fail loud at boundaries | PASS | Corrects the one place the record *invents* success (R1). Missing error text is recorded as `null`, not filler prose. Newer file versions refused by name (R9). Bad `conversation_stderr_*` config raises at read. Dropped stderr lines are counted and recorded, never silently discarded. |
| III. Container-bounded execution | N/A | No permission, tool set or launch-env change; the conversation marker is still stripped before the CLI env. |
| IV. Cost transparency | PASS | Cost still only from the result's reported `cost_usd`; tokens are exact counts, no estimate, no gate (clarification 2026-10-14). |
| V. Human-in-the-loop | N/A | No gate change. |
| VI. Idiomatic Elixir/OTP | PASS | Recorder stays a thin GenServer shell delegating to pure `StderrBound`/`ConversationEntry`; new message is fire-and-forget (`send/2`), never awaited; multi-clause matching on kind/event; `@spec`s on new public functions. |
| VII. Operator surfaces tell the truth | PASS | Failed sessions no longer read clean (R7); stderr shown where recorded, with a dropped-count receipt; token figure never `0` for unknown, `≥` when lower bound; real identifiers (`stderr`, `message_delta`, `error_during_execution`); mono for machine text. |
| Tech stack — Persistence | PASS | Conversation file stays the one permitted non-Mnesia artifact, same path/permissions; format versioned explicitly (v2), newer refused; no Mnesia schema change, no migration of old files (none needed — readers accept v1). |
| Tech stack — Frontend | PASS | Server-rendered; no JS; tokens only. |
| Quality | PASS | New pure modules unit-tested (>90%); hermetic fixtures; census opt-in. |

No violations → Complexity Tracking empty.

**Post-design re-check (after Phase 1)**: PASS. Design adds no processes,
dependencies, stored fields, tokens or guard rules. Judgment calls recorded:
R1 (`error: null` vs filler text), R2 (usage from stream events only), R7 (footer
`done` → `failed` when a result error is recorded).

## Project Structure

### Documentation (this feature)

```text
specs/043-close-recorder-gaps/
├── plan.md              # this file
├── research.md          # Phase 0 (R1–R11)
├── data-model.md        # Phase 1 — file v2 kinds/fields, StderrBound, SessionStatus extension
├── quickstart.md        # Phase 1 — validation guide
├── contracts/
│   ├── recording.md          # ConversationEntry, StderrBound, recorder message, SdkProxy, Config, file version
│   └── console-surfaces.md   # delta over 042 console-surfaces contract
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── conversation_entry.ex       # REVISED: result error rule (R1), :usage from stream_event (R2), parent_tool_use_id (R5), stderr/1, stderr_dropped/1
├── stderr_bound.ex             # NEW pure head/tail bound (R4)
├── conversation_recorder.ex    # REVISED: handle_info({:stderr, line}), flush notice+tail before :end
├── sdk_proxy.ex                # REVISED: callback/2 sends {:stderr, line} to recorder; prepare/1 decodes marker
├── conversation_file.ex        # @version 2
├── config.ex                   # + conversation_stderr_head/0, conversation_stderr_tail/0
└── web/
    ├── conversation_class.ex   # + :stderr row class, stderr notice marker, :usage signal
    ├── conversation_rows.ex    # + stderr repeat collapse (Block.repeat), result marker error text
    ├── session_status.ex       # + usage fold, input/output tokens, tokens_text/1, result_error activity/footer rule
    └── components/conversation_components.ex   # stderr row, token field in status_line/1

priv/static/assets/console.css  # .conv-stderr (existing tokens only)

test/autonomous/
├── conversation_entry_test.exs     # REVISED
├── stderr_bound_test.exs           # NEW
├── conversation_recorder_test.exs  # REVISED
├── sdk_proxy_test.exs              # REVISED
├── conversation_file_test.exs      # REVISED (v2 accepted, v3 refused)
├── config_test.exs                 # REVISED
└── web/
    ├── conversation_class_test.exs     # REVISED
    ├── conversation_rows_test.exs      # REVISED
    ├── session_status_test.exs         # REVISED
    ├── conversation_live_test.exs      # REVISED (token figure, stderr rows, result error)
    ├── transcripts_live_test.exs       # REVISED (parity SC-005)
    ├── census_test.exs                 # REVISED (:census — v1 render unchanged)
    └── design_contract_test.exs        # unchanged rule count
test/fixtures/conversations/043_sample.jsonl   # NEW v2 fixture
```

**Structure Decision**: single Elixir app. Recording changes stay in the 040
boundary modules (`ConversationEntry`, `ConversationRecorder`, `SdkProxy`,
`ConversationFile`); the one new pure helper sits beside `ConversationWindow`.
Display changes stay in the 042 pure modules so live/Transcripts parity remains
structural. Docs touched at implement time: `docs/runbook.md` (new rows, token
figure, stderr cap, format v2 — FR-024), `CLAUDE.md` (one paragraph after
"Classified conversation output"), 040 `conversation-file.md` contract
cross-reference.

## Complexity Tracking

None.
