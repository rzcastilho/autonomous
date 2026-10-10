# Implementation Plan: Live and Durable Agent Conversation View

**Branch**: `040-live-agent-conversation` | **Date**: 2026-10-10 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/040-live-agent-conversation/spec.md`

## Summary

Every agent session gets a **conversation recorder**: a per-session process
that receives every raw CLI frame, masks known credentials, numbers each
entry, keeps a 500-entry catch-up window, broadcasts it live, and appends it
to an owner-only JSONL file under the repository's transcript root. The
phase-attempt record (schema v8) stores one ref per session it drove (where,
captured / partial / not captured and why), and the console renders the same
entry timeline live (`/live`) and after the fact (Transcripts) (research
R1–R15):

1. **One tap, all sessions (FR-001–003).** The tap sits in
   `Autonomous.SdkProxy` — the `:jido_claude, :sdk_module` seam every session
   passes through, including the PR describe session that bypasses
   `PhaseSession`. It sees frames *before* the lossy mapper and only
   `send/2`s them, so it cannot block, fail or slow a session (FR-005). The
   recorder pid rides in the request env (`AUTONOMOUS_CONVERSATION`),
   stripped before launch like the 036 stderr marker.
2. **Live (US1, US3).** `ConversationRecorder` (GenServer per session under
   `ConversationSup`, in `ConversationRegistry`) assigns `seq`, pushes to the
   window, appends to the file and broadcasts on `"conversation:<id>"` in one
   callback; a viewer subscribes → `catch_up` → applies `seq > last_seq`, so
   the seam has no gap or duplicate. New `ConversationLive` at `/live`
   (follows the in-flight session) and `/live/:conversation_id`; links from
   Mission Control and Run Detail.
3. **Durable (US2).** The file *is* the saved conversation — written as frames
   arrive, closed with an `:end` entry on every outcome by
   `Conversation.close/2` before the attempt is recorded (FR-012). Schema v8
   adds `PhaseAttempt.conversations` (`nil` for pre-040 rows); PR describe is
   recorded as a `:describe` attempt with no cost entry. Transcripts renders
   the conversation, falling back to the final text with the reason.
4. **Governance.** Constitution 7.0.0 → **7.1.0** (Persistence names the
   conversation file as the one durable artifact outside Mnesia), shipped with
   the feature (FR-015).

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28.5.0.6 (`mise.toml`; `mise exec --`)

**Primary Dependencies**: Jido ~> 2.2, jido_harness/jido_claude (SHA-pinned, unchanged), ClaudeAgentSDK (via `SdkProxy`), Phoenix LiveView ~> 1.0 (first use of `stream/3`), Phoenix.PubSub, Jason — **no new dependency**

**Storage**: Mnesia schema **v7 → v8** (`speckit_phase_attempt.conversations`); conversation bodies as JSONL files under `Layout.transcript_root` (constitution 7.1.0)

**Testing**: ExUnit, `Phoenix.LiveViewTest`, fake SDK via `:sdk_proxy_inner`, `tmp_dir`; hermetic default suite; `design_contract_test.exs`; container live check by hand (quickstart §2–3)

**Target Platform**: single-node BEAM in the `scripts/autonomous` container; host for `mix compile|test`

**Project Type**: OTP application (control plane) + embedded LiveView console

**Performance Goals**: live entry visible ≤ 2 s after the frame (SC-002); session wall time within 1 % with 0/1/stalled viewers (SC-004)

**Constraints**: the session path never awaits the recorder (only `send/2`); `close/2` bounded at 30 s and after the fold; listings never read files (FR-021); `warnings_as_errors`; no JS hooks, no build step

**Scale/Scope**: ~10 new modules (6 pure), ~15 lib files touched, 1 module deleted (`Actions.RunPhase`), 1 migration, ~12 new test files, constitution + 3 docs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against 7.0.0; FR-015 requires the 7.1.0 Persistence amendment,
recorded in Complexity Tracking.

| Principle | Assessment |
|---|---|
| I. Pure Core, Isolated Contracts | ✅ Decisions are pure: `ConversationEntry` (frame → entries), `CredentialMask`, `ConversationWindow`, `ConversationOutcome`, `Web.ConversationRows`. The CLI frame shape is confined to `ConversationEntry` + `SdkProxy`; the CLI's own session-log layout is deliberately **not** depended on (R2). Pipeline/gates untouched. |
| II. Fail Loud at Boundaries | ✅ Capture failures are recorded with a reason and shown, never silent (FR-017); a recorded-but-missing file is reported missing; a newer file `version` is refused by name; a malformed line is reported with its number and nothing is invented. Fail-loud does **not** extend into the session: capture never fails a session (spec FR-005/017). |
| III. Container-Bounded Execution | ✅ No change to permissions/tools. Marker stripped before launch; the agent sees nothing new (FR-026). |
| IV. Cost Transparency; Drain, Don't Kill | ✅ Describe row carries `cost_usd` for display but no cost entry → run spend unchanged (FR-002a). Drain checks, deadlines and retries untouched; the recorder is outside the fold Task and is never killed by drain — `close/2` records `drain_requested`. |
| V. Human-in-the-Loop | ✅ Gates unchanged; clarify reviewer and answer rounds are just covered sessions. |
| VI. Idiomatic OTP | ✅ `DynamicSupervisor` + `Registry` + temporary GenServer per session; recorder is a thin shell over pure modules; file I/O is in the recorder (its own process), never in a GenServer others await on the session path. |
| VII. Operator Surfaces Tell the Truth | ✅ Real identifiers (`run_id`, phase atoms, `conversation_id`, outcome terms) in mono; live dot only while the recorder runs; every claim traceable to a path/ref; empty states are status reports; fallbacks say *why*. Guard extended to the new surfaces. |
| Persistence | ⚠️ → amended. Mnesia stays authoritative for *whether/where*; body is a file (FR-015) — 7.1.0 amendment. v8 migration is an ordered `transform_table`, no lossy rewrite; no dirty writes; listings load no bodies. |
| Quality | ✅ Pure modules ≥ 90 % coverage; hermetic suite (fake SDK, `tmp_dir`); FR-003 enforced by a source guard + behavioural test. |

**Result**: PASS with the recorded amendment. **Post-design re-check**: PASS —
one new supervised subtree (`ConversationRegistry`, `ConversationSup`), no new
dependency, no new table; the only cross-boundary artifact is the file the
amendment names.

## Project Structure

### Documentation (this feature)

```text
specs/040-live-agent-conversation/
├── plan.md              # This file
├── research.md          # Phase 0 (R1–R15)
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── conversation-capture.md   # Conversation API, tap, recorder messages, PubSub
│   ├── conversation-file.md      # speckit.conversation v1 JSONL
│   └── console-surfaces.md       # /live, Mission Control, Run Detail, Transcripts
├── checklists/
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── conversation.ex                  # NEW facade: open/2, close/2, subscribe/1, catch_up/1, entry/2, in_flight/1
├── conversation_recorder.ex         # NEW GenServer per session (temporary)
├── conversation_identity.ex         # NEW struct + validation
├── conversation_entry.ex            # NEW pure: from_frame/1, encode/decode
├── conversation_window.ex           # NEW pure: bounded ring, snapshot
├── conversation_outcome.ex          # NEW pure: from_result/1, capture_status/1, encode/decode
├── conversation_file.ex             # NEW IO boundary: path/resolve, open 0600/0700, append, page/3, entry/2
├── credential_mask.ex               # NEW pure: names/0, pairs/1, mask/2
├── application.ex                   # + ConversationRegistry, ConversationSup (before RunnerSup/SessionSup)
├── sdk_proxy.ex                     # pop AUTONOMOUS_CONVERSATION, Stream.each tap
├── phase_request.ex                 # helper to add the marker to metadata["claude"].env
├── feature_runner.ex                # build ConversationIdentity per step; :describe attempt row; refs → record_attempt/9
├── phase_step.ex / session_retry.ex # accumulate refs across the retry
├── chunk_runner.ex / chunking.ex    # identity per chunk; refs on :implement_chunk rows
├── analyze_runner.ex                # identity per analyze run / auto-remediation attempt; refs on rows
├── describe.ex                      # open/close around run_request; return ref with message
├── actions/run_feature_phase.ex     # open → run_request → PhaseSession.reduce → close; refs in state update
├── actions/run_auto_remediation.ex  # same
├── actions/run_remediation.ex       # same
├── actions/run_phase.ex             # DELETE (no production caller; R12)
├── store/schema.ex, records.ex      # conversations field, ConversationRef type
├── store/migrations.ex              # v8 transform, current_version 8
├── store/writer.ex                  # persist conversations; prune deletes files after commit
├── store/export.ex                  # per-attempt conversation status (no path, no body)
├── report.ex                        # render capture reasons / outcome terms
└── web/
    ├── router.ex                    # /live, /live/:conversation_id
    ├── conversation_rows.ex         # NEW pure: rows/2, truncation, pairing, unfinished
    ├── components/conversation_components.ex  # NEW: timeline, row, end marker
    └── live/
        ├── conversation_live.ex     # NEW
        ├── mission_control_live.ex  # live-session link
        ├── run_detail_live.ex       # live link + conversation column
        └── transcripts_live.ex      # conversation pane, session selector, fallbacks
priv/static/assets/console.css       # conversation timeline rules (tokens only)

test/support/design_contract.ex      # @surfaces += new files
test/support/fake_sdk.ex             # NEW scripted frame stream, asserts marker
test/autonomous/
├── conversation_{entry,window,outcome,recorder,isolation,coverage}_test.exs  # NEW
├── credential_mask_test.exs                                                  # NEW
├── store/migration_v8_test.exs                                               # NEW
├── web/conversation_rows_test.exs, web/conversation_live_test.exs            # NEW
├── run_phase_test.exs                                                        # DELETE with the module
└── sdk_proxy_test.exs, transcripts_live_test.exs, run_detail_live_test.exs, feature_runner/describe tests  # extend

.specify/memory/constitution.md      # 7.1.0 (R13)
docs/runbook.md, docs/container.md, docs/workflow.md, CLAUDE.md  # live view, file location, masking, permissions
```

**Structure Decision**: Single OTP app. Order for tasks: (1) pure modules +
`ConversationFile` (no callers), (2) recorder, registry/supervisor, facade,
`SdkProxy` tap, (3) schema v8 + writer/export/prune, (4) identity threading
through `FeatureRunner` → actions → `PhaseStep`/chunks/analyze/describe and
the FR-003 guard, (5) `ConversationLive` + Mission Control/Run Detail links
(US1/US3), (6) Transcripts review + fallbacks (US2), (7) constitution, docs,
container live check.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Constitution 7.0.0 Persistence ("all durable run state … including transcripts … in Mnesia") — conversation bodies live in files; amended to 7.1.0 in this change | Clarification 2026-10-10 and FR-015: conversations are multi-MB, appended live, must survive the BEAM dying mid-session, and must never grow the heap or hit the DETS 2 GB ceiling of `disc_only_copies` | Storing bodies in `speckit_transcript` (`disc_only_copies`): per-entry transactional appends for every frame, a DETS size ceiling the constitution forbids handling by truncation, and nothing on disk if the BEAM dies before the session ends. |
| Saved conversation built from the stream, not from the CLI's own session log (refines spec Assumption "Source of truth") | R2: the stream frames are the CLI's own records; reading `~/.claude/projects/<encoded-cwd>/` encodes a guessed external contract (Principle I), is absent unless `--with-login` mounts `~/.claude`, and makes SC-006 a cross-source comparison | Copy the CLI log at session end with a stream fallback: two sources, two normalizers, two failure modes for the same content. |
| Capture never fails the session (an exception to "fail loud") | FR-005/FR-017: observability must not change outcomes | Failing the phase on a capture error would turn a disk-full on the transcript root into feature failures — the console would change what it observes. Failures are still recorded and shown. |
