# Implementation Plan: Classify Conversation Output — Scroll Rows, Header Fields, Footer Signals

**Branch**: `042-classify-conversation-output` | **Date**: 2026-10-13 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/042-classify-conversation-output/spec.md`

## Summary

Feature 040 renders every recorded conversation entry as an identical JSON
card; ~60% of them are progress noise. 042 adds one pure classifier
(`ConversationClass`) that places each entry as a transcript **block**, a
**header field**, a **footer signal**, or row+signal; a pure tool-summary
(`ToolSummary`) for one-line `Tool(summary)` calls; and a pure footer fold
(`SessionStatus`). `ConversationRows` is revised to emit blocks with the tool
result grouped inside its call's block (re-emitted under the same stream key,
so parallel calls keep call order). `ConversationLive` (page + Mission Control
embed) and `TranscriptsLive` gain a sticky bottom status line, header model/CLI
fields, and a `frames=all` toggle. On live join the status is seeded by
streaming the session's conversation file up to the catch-up `last_seq`
(exact counters past the 500-entry window), falling back to window-only
lower bounds. Display-only: recorder, entry kinds, file format, window and
store schema are untouched.

## Technical Context

**Language/Version**: Elixir 1.20.2 / OTP 28.5.0.6 (`mise.toml`)

**Primary Dependencies**: Phoenix ~> 1.7, Phoenix LiveView ~> 1.0 (streams), Jason; no new deps

**Storage**: none new — reads 040 `speckit.conversation` v1 JSONL (`ConversationFile`); Mnesia untouched

**Testing**: ExUnit (`mise exec -- mix test`), `Phoenix.LiveViewTest`, design-contract guard; opt-in `:census` tag for machine-local re-measure

**Target Platform**: orchestrator node (container or host), browser console

**Project Type**: Elixir OTP app with embedded Phoenix LiveView operator console

**Performance Goals**: status line reflects a new signal ≤ 2 s after recording (SC-006); elapsed at 1 s resolution; default DOM ≤ 35% of entries (SC-001, measured 34.1%)

**Constraints**: display-only (FR-021); hand-authored CSS, tokens only, no new keyframes/breakpoints/tokens, no JS beyond existing `FollowTail` (FR-023); file seed read once per join, bounded memory (streamed), never past `last_seq`

**Scale/Scope**: sessions up to several thousand entries (census max ≈ 3k; spec cites 5k); 3 new pure modules, 1 revised pure module, 2 read helpers, 3 LiveView surfaces, 1 component file, CSS additions

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle / section | Verdict | How |
|---|---|---|
| I. Pure core, isolated contracts | PASS | Classification, summary, status fold are pure modules over 040 entries; the CLI frame contract stays isolated in `ConversationEntry` (unchanged). The sub-kind field names this feature reads are recorded in `research.md` R1. |
| II. Fail loud at boundaries | PASS | `ConversationFile.fold/4` returns tagged errors (missing / unreadable / unsupported version / malformed line); the view states the fallback visibly (`≥` counters) instead of inventing exact numbers. Unknown kinds render as raw rows, never dropped. |
| III. Container-bounded execution | N/A | No session, permission or launch-env change. |
| IV. Cost transparency | PASS | Cost/duration shown only from the recorded `result`; never zero-filled, never a budget. |
| V. Human-in-the-loop | N/A | No gate change. |
| VI. Idiomatic Elixir/OTP | PASS | Pure folds, multi-clause pattern matching on kind/sub-kind, `@spec`s; LiveViews stay thin (assigns + calls into pure modules); the file read happens in the LiveView process on attach (one streamed read; same place 040's Transcripts reads pages) — no GenServer awaited by others blocks. |
| VII. Operator surfaces tell the truth | PASS | Real identifiers (`Bash(...)`, `hook_name`, sub-kind labels, `frames=all`); mono for machine values, sans for prose; status colour by `data-status` name only on the end chip and the activity dot; pulse only while live; elapsed is a clock against the recorded `start.at`, not progress; every signal traceable via `frames=all` (show the receipt); empty thinking shows `thinking`, not invented text. |
| Tech stack — Persistence | PASS | Conversation file read by a single-session view only, never by a listing; format/version unchanged; no Mnesia change. |
| Tech stack — Frontend | PASS | Server-rendered; native `<details>` for folds; server `:tick` instead of new JS; tokens only; existing 760px breakpoint; existing `.sr-only`. |
| Quality | PASS | New pure modules unit-tested (>90%); hermetic fixtures; census test opt-in. |

No violations → Complexity Tracking empty.

**Post-design re-check (after Phase 1)**: PASS — design adds no tokens,
keyframes, breakpoints, dependencies, stored fields or processes. One
judgment call recorded in research R7: server tick vs client hook (server
chosen; stack default).

## Project Structure

### Documentation (this feature)

```text
specs/042-classify-conversation-output/
├── plan.md              # this file
├── research.md          # Phase 0 (R1–R12)
├── data-model.md        # Phase 1 — placement table, Block, SessionStatus
├── quickstart.md        # Phase 1 — validation guide
├── contracts/
│   ├── classification.md     # pure API: ConversationClass, ToolSummary, ConversationRows, SessionStatus, read helpers
│   └── console-surfaces.md   # delta over 040 console-surfaces contract
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── conversation.ex                         # + file_path/1 (viewer side, from registry identity)
├── conversation_file.ex                    # + fold/4 (streamed, through_seq)
└── web/
    ├── conversation_class.ex               # NEW pure classifier (placement table)
    ├── tool_summary.ex                     # NEW pure Tool(summary)
    ├── session_status.ex                   # NEW pure footer/header fold + view helpers
    ├── conversation_rows.ex                # REVISED: blocks, call+result grouping, visibility, expand/2
    ├── components/conversation_components.ex   # REVISED: block markup per class; + status_line/1
    └── live/
        ├── conversation_live.ex            # status seed on attach, :tick, toggle_frames, header fields
        ├── conversation_panel_live.ex      # unchanged (delegates)
        └── transcripts_live.ex             # status fold over pages, frames=all, static status line

priv/static/assets/console.css              # .conv-status, .conv-call, .conv-result, .conv-marker, .conv-divider (tokens only)

test/autonomous/web/
├── conversation_class_test.exs             # NEW
├── tool_summary_test.exs                   # NEW
├── session_status_test.exs                 # NEW
├── conversation_rows_test.exs              # REVISED (blocks, parallel calls, SC-002)
├── conversation_live_test.exs              # REVISED (status line, seed, tick, toggle, header)
├── transcripts_live_test.exs               # REVISED (parity, static status, pages)
├── mission_control_live_test.exs           # REVISED (embedded status line)
├── census_test.exs                         # NEW, @moduletag :census (excluded by default)
└── design_contract_test.exs                # unchanged rule count
test/autonomous/conversation_file_test.exs  # + fold/4
test/fixtures/conversations/042_sample.jsonl  # NEW synthetic fixture covering every R1 sub-kind
test/test_helper.exs                        # exclude :census
```

**Structure Decision**: single Elixir app; new pure modules sit beside
`ConversationRows` under `lib/autonomous/web/` (display logic), read helpers
extend the existing 040 IO boundary modules. Docs touched at implement time:
`docs/runbook.md` (live view section), `CLAUDE.md` (one paragraph under
"Live agent conversation"), 040 contract cross-reference.

## Complexity Tracking

None.
