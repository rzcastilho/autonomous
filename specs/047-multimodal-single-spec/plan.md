# Implementation Plan: Multi-Modal Single-Spec Run

**Branch**: `047-multimodal-single-spec` | **Date**: 2026-11-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/047-multimodal-single-spec/spec.md`

## Summary

A single-spec run can start with files alongside its description: images, PDF and
text/data. Sessions read them as files with their existing `Read` tool, because the
harness `attachments` field is not forwarded by the `jido_claude` adapter.

1. **Boundary (FR-003–FR-009, R1, R2).** `run_spec/2` gains `:attachments`. A new
   `Autonomous.Attachments.load/2` runs before any taken-id gathering and returns a
   manifest plus the validated bytes, or a refusal naming every bad file. Validation
   is stdlib only: signature and structural checks for images and PDF, UTF-8 and NUL
   checks for text.
2. **Delivery (FR-010, FR-013–FR-015, R4, R5).** Bytes stay in memory, held by the
   `seed_executor` closure, so a refused start writes nothing anywhere. After
   `Worktree.create` they are written to `specs/<spec_id>-<slug>/attachments/` and
   committed with `git add -f` before the seed is written. A commit survives
   `Worktree.restore/1`, retries, resume and `Worktree.squash/3`. `FeatureRunner`
   verifies each `sha256` on entry.
3. **Sessions (FR-011, FR-012–FR-012c, R6, R7).** `PhaseRequest` appends one rendered
   block to every request built from a feature with attachments: list of stored
   names and paths, reference-data rule, plus a phase-specific block for `:specify`
   and `:clarify`. Empty list leaves the prompt byte-identical.
4. **Session plumbing (FR-021, R3, R8).** Two findings the spec did not anticipate.
   The transport kills a session on any stdout line over 1 MiB, and a `Read` of a
   PDF puts its base64 on one line **twice**, so `SdkProxy.prepare/1` raises
   `max_buffer_size`. `ConversationEntry` replaces base64 blocks with a text
   placeholder before masking, windowing or writing.
5. **Surfaces (FR-001, FR-002, FR-016–FR-020, R9, R10).** Trigger gets a LiveView
   upload (no new JS). Run Detail gets a `data-attachments` block. The PR body gets
   `Attachments.pr_note/1`. Store schema v9 appends
   `speckit_feature_run.attachments`.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28, Erlang/OTP 28.5.0.6 (via `mise exec --`)

**Primary Dependencies**: Existing only. Phoenix LiveView 1.2.7 uploads,
`jido_harness`/`jido_claude`, `claude_agent_sdk` 0.17.2. No new dependency.

**Storage**: Attachment bytes in the target's git branch. Manifest in Mnesia,
`speckit_feature_run.attachments`, schema v9 (see [data-model.md](./data-model.md)).

**Testing**: ExUnit, `mise exec -- mix test`. LiveView upload helpers
(`file_input/4`, `render_upload/3`). Real-harness reads stay behind
`--include integration`.

**Target Platform**: Container runtime (`scripts/autonomous`); host for development.

**Project Type**: BEAM control plane with a LiveView console.

**Performance Goals**: Validation of a maximum-size attachment set inside the
console's 5 s `@run_wait_ms`. Conversation views for a session that opened a
maximum-size attachment no slower than a text-only one (SC-007).

**Constraints**: FR-022 (text-only run unchanged, see R3 and R8 for the two
deliberate session-plumbing exceptions). `warnings_as_errors` on. Console styling
through tokens only (`design_contract_test`). No Node, no bundler, no new JS hook.

**Scale/Scope**: 10 files, 10 MB each, 25 MB per run, one feature per run.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I Pure Core | PASS | `Attachment` and the validators are pure over `{name, bytes}`. File reads live in `Attachments.load/2`, git in `Worktree`. `Pipeline` and `Release` are untouched. |
| II Fail Loud | PASS | Every refusal precedes taken-id gathering, branch, worktree and run record. `run/1` refuses an `:attachments` option instead of ignoring it. A changed attachment fails the feature by name. |
| III Container-Bounded | PASS | No tool or permission change. Prompt rules are guidance, the container stays the boundary. `git add -f` touches only the feature's attachment directory. |
| IV Cost; Drain | PASS | Cost accounting untouched. Attachment reads are ordinary session spend. |
| V Human-in-the-Loop | PASS | No new gate. Unreadable and conflicting attachments go through the existing `## NEEDS HUMAN` path; the clarify block forbids clearing a specify-recorded marker unless the file was then read. |
| VI Idiomatic Elixir/OTP | PASS | `with` pipelines, tagged tuples, no process added. Bytes are refcounted binaries in a closure. `@spec` on public functions. |
| VII Surfaces Tell the Truth | PASS | Run Detail shows name, type, size, path, branch and `sha256`. Real identifiers in copy. Tokens only, mono for machine values. Empty case renders nothing (FR-016). |
| Persistence | PASS | Versioned append migration v9, `nil` for older rows. Transactional writes through `Writer`. Bytes never enter Mnesia. |
| Quality | PASS | Pure core covered above 90%. Default suite hermetic: temp git repos, fake SDK. |

**Post-design re-check**: PASS. No amendment needed; the spec's assumption holds.
`git`-tracked attachments are target-repo content, not orchestrator state, so the
"one permitted durable artifact outside Mnesia" rule is not engaged. Attachment
bytes never leave the worktree, and no new top-level stack item is added.

## Project Structure

### Documentation (this feature)

```text
specs/047-multimodal-single-spec/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── run-spec-attachments.md
│   ├── session-prompt-block.md
│   └── operator-surfaces.md
└── tasks.md             # /speckit-tasks, not created here
```

### Source Code (repository root)

```text
lib/autonomous/
├── attachment.ex             # NEW struct, stored-name rules, location
├── attachments.ex            # NEW load/2, validate, commit, verify, prompt_block, pr_note
├── attachments/limits.ex     # NEW limits from Config
├── attachments/sniff.ex      # NEW pure signature and structural checks
├── feature.ex                # attachments field
├── recovery.ex               # to_feature/1 restores attachments
├── worktree.ex               # commit_paths/3 (git add -f -- paths)
├── phase_request.ex          # append block in build/3 and build_remediation/3
├── prompts.ex                # three new packs
├── feature_runner.ex         # verify on entry
├── sdk_proxy.ex              # max_buffer_size in prepare/1
├── conversation_entry.ex     # base64 block placeholder
├── config.ex                 # limits, session_max_line_bytes/0
├── report.ex                 # format_reason clauses
├── store/{schema,records,writer,query,export,migrations}.ex   # v9, pin v5
└── web/
    ├── attachment_form.ex    # NEW pure triage of upload entries into refusals
    ├── attachments_view.ex   # NEW pure Run Detail rows
    └── live/{trigger_live,run_detail_live}.ex
lib/autonomous.ex             # run_spec/2, seed_executor, run/1 refusal, pr_text/2
config/runtime.exs            # env overrides
priv/prompts/{attachments,attachments_specify,attachments_clarify}.md   # NEW
priv/static/assets/console.css
docs/{runbook,workflow,harness-contract,container}.md, CLAUDE.md
test/autonomous/...           # mirrors the above
```

**Structure Decision**: Single project, existing layout. One new `attachments/`
namespace following `container_engine/` and `workspace_trust/`.

## Complexity Tracking

No constitution violation to justify. Two changes reach beyond runs with attachments
and are recorded as exceptions to a strict reading of FR-022: the raised line limit
(R3) and the placeholder for base64 blocks (R8). Neither changes a prompt, a seed, a
commit or a rendered text-only session.
