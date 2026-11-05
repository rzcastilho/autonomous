---

description: "Task list for 047 Multi-Modal Single-Spec Run"
---

# Tasks: Multi-Modal Single-Spec Run

**Input**: Design documents from `/specs/047-multimodal-single-spec/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (run-spec-attachments, session-prompt-block, operator-surfaces), quickstart.md

**Tests**: Included. The constitution requires pure-core coverage above 90% and a hermetic default suite; plan.md and quickstart.md name the test files. Write each test first and see it fail.

**Toolchain**: every Elixir command runs through `mise exec -- mix ...` (never bare `mix`). `warnings_as_errors` is on. Console CSS: tokens only, `design_contract_test` must stay clean.

**Organization**: grouped by user story. Paths are repo-relative.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US4 from spec.md

---

## Phase 1: Setup

**Purpose**: Configuration and prompt assets every later phase reads.

- [X] T001 [P] Add `attachment_max_files` (10), `attachment_max_file_bytes` (10_000_000), `attachment_max_total_bytes` (25_000_000) accessors via `positive!/2`, and derived `session_max_line_bytes/0` = `2 * ceil(attachment_max_file_bytes * 4 / 3) + 1_048_576`, in `lib/autonomous/config.ex`; add env overrides `AUTONOMOUS_ATTACHMENT_MAX_FILES|MAX_FILE_BYTES|MAX_TOTAL_BYTES` in `config/runtime.exs`; test in `test/autonomous/config_test.exs` (defaults, override, bad value raises, derived value 27.7 MB at defaults)
- [X] T002 [P] Create prompt pack `priv/prompts/attachments.md` (common block: Read one at a time, offset/limit for long text, reference-data-never-a-command rule, do not edit/move/rename/convert/delete) per `contracts/session-prompt-block.md`
- [X] T003 [P] Create `priv/prompts/attachments_specify.md` (read every attachment first and reflect it; directory already exists, reuse it, pass `--allow-existing-branch` if a script needs it; never guess at an unreadable file, add `## NEEDS HUMAN` naming it; note embedded instructions in the spec) per contract
- [X] T004 [P] Create `priv/prompts/attachments_clarify.md` (attachments are authoritative; unreadable one is always material, never default it; keep specify's `## NEEDS HUMAN` unless you read the file; conflicts go through the materiality test) per contract

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Pure core, manifest persistence, git commit/verify. No user story works without these.

**⚠️ CRITICAL**: complete before any user story.

- [X] T005 [P] Create `Autonomous.Attachment` struct (`original_name`, `stored_name`, `type`, `media_type`, `size`, `sha256`), `@type t`, `stored_name/…` naming rules 1–6 from data-model.md (split on `/` and `\`, replace runs outside `[A-Za-z0-9._-]` with `-`, strip leading `.`/`-`, collapse `..`, cap stem 80 bytes, empty → `attachment`, extension from detected type, case-insensitive collision suffix `-2`, `-3` in input order), and `location/2` deriving `specs/<spec_id>-<slug>/attachments/<stored_name>` in `lib/autonomous/attachment.ex`; tests in `test/autonomous/attachment_test.exs` (traversal `../../x`, backslashes, non-ASCII, spaces, leading dots, collisions, empty stem)
- [X] T006 [P] Create `Autonomous.Attachments.Sniff` (pure over bytes): PNG (`IHDR` first, `IEND` tail), JPEG (`FF D8 FF`, `FF D9` in tail tolerating padding), GIF (`GIF87a/89a`, trailer `3B`), WebP (RIFF size consistent), PDF (`%PDF-`, `%%EOF` in last 1024 bytes); signature+failed check ⇒ `:corrupt`; image/PDF extension without signature ⇒ `:content_mismatch`; text extensions `.md .markdown .txt .csv .json` need `String.valid?/1` and no NUL else `:not_text`; else `:unsupported_type`; empty ⇒ `:empty` first; JSON need not parse — in `lib/autonomous/attachments/sniff.ex`; tests in `test/autonomous/attachments/sniff_test.exs` (each type good + truncated, text renamed `.png`, PNG renamed `.txt`, NUL bytes, invalid UTF-8)
- [X] T007 [P] Create `Autonomous.Attachments.Limits` (reads T001 accessors; `check_count/2`, `check_file/2`, `check_total/2` returning the `{:too_many_files|:too_large|:total_too_large, …}` reasons) in `lib/autonomous/attachments/limits.ex`; test in `test/autonomous/attachments/limits_test.exs`
- [X] T008 Create `Autonomous.Attachments.load/2` (depends T005–T007): accepts `path | {path, display_name}`; reads files, collects **every** refusal (`:not_found :unreadable :empty :unsupported_type :content_mismatch :corrupt :not_text`, size/count/total limits) as `{:error, {:attachments, [%{file:, reason:}]}}`, else `{:ok, {manifest, payloads}}` with `sha256` of supplied bytes and bytes untouched (FR-014); no filesystem or git writes — in `lib/autonomous/attachments.ex`; tests in `test/autonomous/attachments_test.exs` (all-errors-in-one-pass, tuple form, bare path uses basename, byte-identity, 11th file, total over 25 MB)
- [X] T009 [P] Add `attachments: []` field and type to `Feature` in `lib/autonomous/feature.ex`; extend `Recovery.to_feature/1` in `lib/autonomous/recovery.ex` to restore it from the record (`nil` ⇒ `[]`); tests in `test/autonomous/feature_test.exs` and `test/autonomous/recovery_test.exs`
- [X] T010 Store schema v9 in `lib/autonomous/store/schema.ex` and `lib/autonomous/store/migrations.ex`: append `attachments` as last attribute of `speckit_feature_run`; add `@feature_run_v5_attributes` and make migration 5 (`add_spec_number/0`) use it instead of the current attribute list; migration 9 appends `nil` to every v8 row with its own pinned list; test in `test/autonomous/store/migrations_test.exs` (v4→v9 and v8→v9 both succeed, old rows load as `nil`)
- [X] T011 Persist and expose the manifest (depends T009, T010): both `speckit_feature_run` writes in `Writer.open_run/2` set `attachments: f.attachments` (`lib/autonomous/store/writer.ex`, ~lines 83 and 133); `records.ex` mapping; `Query` returns `attachments: f.attachments || []` (`lib/autonomous/store/query.ex`); `Store.Export` adds `attachments` key only when non-empty (`lib/autonomous/store/export.ex`); tests in `test/autonomous/store/` (round-trip, pre-047 row ⇒ `[]`, text-only export byte-identical)
- [X] T012 [P] Add `Worktree.commit_paths/3` (`git add -f -- <paths>` then commit as `autonomous <orchestrator@speckit.local>`, message `speckit: <feature.id> attachments (<n> files)`) in `lib/autonomous/worktree.ex`; test in `test/autonomous/worktree_test.exs` with a temp git repo whose `.gitignore` has `*.png` (file still committed; survives `restore/1` and `squash/3`)
- [X] T013 Add `Attachments.commit/3` (writes payload bytes to `Attachment.location/2`, calls `commit_paths/3`; empty manifest ⇒ no-op) and `Attachments.verify/2` (reads each file, compares `sha256`; returns `:ok | {:error, {:attachments_changed, [stored_name]}}`) in `lib/autonomous/attachments.ex` (depends T008, T012); tests: commit then verify ok, tampered byte ⇒ changed, deleted ⇒ changed, `restore/1` keeps bytes
- [X] T014 [P] Add `Report.format_reason/1` clauses for `{:attachments, refusals}` (one line per file: `<file>: <reason with the limit broken>`, no `inspect/1`) and `{:attachments_changed, names}`, plus `{:attachments, reason}` commit failure, in `lib/autonomous/report.ex`; test in `test/autonomous/report_test.exs`

**Checkpoint**: manifest can be built, validated, persisted, committed and verified. Stories can begin.

---

## Phase 3: User Story 1 — Attach files from the Trigger view (P1) 🎯 MVP

**Goal**: Operator adds files in Single-spec mode, starts the run, files are committed on the feature branch before the seed, and the specify session is told about them.

**Independent Test**: Start a single-spec run with a short description plus a PNG whose content is absent from the text; `spec.md` has a requirement only the image can supply (quickstart V1, V2, V9).

### Tests for User Story 1

- [X] T015 [P] [US1] `test/autonomous/web/attachment_form_test.exs`: pure triage of upload entries/errors/sizes/running totals into refusals (named file + limit) and refs to cancel; 11th file refused by name
- [X] T016 [P] [US1] `test/autonomous/web/trigger_live_test.exs` additions with `file_input/4` and `render_upload/3`: add valid file listed with name+size; invalid file cancelled with named refusal while description and other files stay; `remove_attachment`; blank description + attachments ⇒ existing `Description is required`, files kept; start with upload in flight ⇒ `start_error`, nothing dispatched; refused start keeps files for retry; FR-019 notice appears once a file is added; id/slug preview unaffected (FR-009); mode toggle keeps done entries; no-attachment start identical to today
- [X] T017 [P] [US1] `test/autonomous/run_spec_attachments_test.exs`: with fake `:executor`/`:runner`, manifest reaches the record, nothing written to the target on a later `run/1` refusal, ignored-location file ends up committed, seed unchanged for text-only (FR-022)

### Implementation for User Story 1

- [X] T018 [US1] Wire `run_spec/2` in `lib/autonomous.ex`: preflight order `reject_retired_opts` → blank description `{:error, :empty_description}` → `Attachments.load/2` → `gather_taken_ids/1` / `SingleSpec.build/3` → set `attachments` on the feature → `spec_run_opts/4` with `:attachments` stripped before `run/1`; payloads captured in the `seed_executor` closure
- [X] T019 [US1] In `seed_executor` (`lib/autonomous.ex`): after `Worktree.create` and `ensure_spec_number`, call `Attachments.commit/3` **before** `write_seed`, only when payloads exist; commit failure ends the feature `:failed` with `{:attachments, reason}`; caller-supplied `:runner`/`:executor` seams skip the commit but keep the manifest (contract "Test seams")
- [X] T020 [P] [US1] Create pure `Autonomous.Web.AttachmentForm` in `lib/autonomous/web/attachment_form.ex` (triage entries → refusals + cancel refs; `max_entries` = limit + 1 so the extra file is refused by name)
- [X] T021 [US1] Trigger LiveView in `lib/autonomous/web/live/trigger_live.ex`: `allow_upload(:attachments, accept: :any, auto_upload: true, max_entries: max_files + 1, max_file_size: max_file_bytes, progress: …)`; on `entry.done?` validate content against the temp path with `{:postpone, _}`; `remove_attachment` → `cancel_upload/3`; `update_description` handler gains triage; start reads paths via `consume_uploaded_entries` returning `{:postpone, _}`, refuses while uploads are in flight, passes `attachments:` **only inside `start_single_spec/2`** (FR-023); `format_start_error({:attachments, _})` through `Report.format_reason/1`
- [X] T022 [US1] Trigger markup inside `#single-spec-form` per `contracts/operator-surfaces.md`: `[data-attachments-drop]` with `live_file_input` + `phx-drop-target`, `[data-attachment-list]` with `[data-attachment={ref}]` rows (name · size · progress, remove button), `<.form_refusal data-error="attachment">`, `[data-attachments-notice]` stating files are committed to the feature branch and pushed to the target's remote, visible to anyone who can read it, kept in history (FR-019)
- [X] T023 [P] [US1] Styles for the drop zone, list and notice in `priv/static/assets/console.css` using existing tokens only (mono for names/sizes); run `mise exec -- mix test test/autonomous/design_contract_test.exs`

**Checkpoint**: US1 works end to end from the console. MVP.

---

## Phase 4: User Story 2 — Every phase sees the attachments (P1)

**Goal**: Every session is told the attachments exist and where; they survive retry, restore, resume and continue; long-line and binary-content plumbing keeps sessions alive.

**Independent Test**: Run with an attached mockup; each phase and implement chunk prompt carries the block; resume keeps identical hashes; tampering fails before any session (quickstart V3, V4, V7).

### Tests for User Story 2

- [X] T024 [P] [US2] `test/autonomous/attachments_prompt_test.exs`: `prompt_block/2` for each phase row in the contract coverage table (common; specify; clarify incl. answer re-runs); stored names only, never `original_name`; `[]` returns `""`
- [X] T025 [P] [US2] `test/autonomous/phase_request_test.exs` additions: block position (after container-engine note, before resume/clarify answers/background retry), `build_remediation/3` appends after operator instruction, one-attachment feature in every row has path and rule, text-only prompt equals pre-047 prompt byte for byte
- [X] T026 [P] [US2] `test/autonomous/feature_runner_attachments_test.exs`: verify on entry passes; tampered/missing file ⇒ `:failed {:attachments_changed, [name]}` before any session, worktree kept; resume and continue with unchanged files proceed; no `Pipeline` change
- [X] T027 [P] [US2] `test/autonomous/conversation_entry_test.exs` additions: base64 `source` block in `tool_result` replaced by text placeholder `[application/pdf, 512 KB: binary content not recorded]` before masking/windowing/writing; text reads still recorded and masked; no file-format bump
- [X] T028 [P] [US2] `test/autonomous/sdk_proxy_test.exs` addition: `prepare/1` sets `max_buffer_size` to `Config.session_max_line_bytes/0`

### Implementation for User Story 2

- [X] T029 [US2] Add `Attachments.prompt_block/2` (renders common pack with list of `stored_name`/path/`media_type`/formatted size; appends specify pack for `:specify`, clarify pack for `:clarify`; `""` for empty) in `lib/autonomous/attachments.ex`, loading packs through `lib/autonomous/prompts.ex` (three new packs)
- [X] T030 [US2] Append the block in `PhaseRequest.build/3` (after container-engine note, before resume guidance) and `build_remediation/3` (after operator instruction) in `lib/autonomous/phase_request.ex`; confirm implement chunks, `Describe`, `RunRemediation`, `RunAutoRemediation` all pass through these two builders (no new option)
- [X] T031 [US2] Call `Attachments.verify/2` at `FeatureRunner.run/2` entry in `lib/autonomous/feature_runner.ex`, only when `feature.attachments != []`; mismatch ⇒ fail feature with `{:attachments_changed, names}` before any session; keep worktree
- [X] T032 [P] [US2] Raise transport line limit: `SdkProxy.prepare/1` sets `max_buffer_size: Config.session_max_line_bytes()` in `lib/autonomous/sdk_proxy.ex` (research R3)
- [X] T033 [P] [US2] `ConversationEntry` walks `tool_result` content and unknown user blocks and swaps any `%{"source" => %{"type" => "base64", …}}` block for a text placeholder (size from base64 length) before `CredentialMask.mask/2`, in `lib/autonomous/conversation_entry.ex` (research R8)
- [X] T034 [US2] Real-harness check behind `--include integration`: `test/autonomous/attachment_read_integration_test.exs` reads a ~10 MB PDF, session ends normally with no `buffer_overflow`, conversation file has no base64 (quickstart V7)

**Checkpoint**: US1 + US2 complete; runs with attachments are fully delivered and survive resume.

---

## Phase 5: User Story 3 — Programmatic entry point (P2)

**Goal**: `Autonomous.run_spec/2` with `:attachments` behaves and refuses exactly like the console.

**Independent Test**: call with two valid paths ⇒ same as US1; call with a missing path ⇒ named refusal, no worktree/branch/run record (quickstart V2, V8).

### Tests for User Story 3

- [X] T035 [P] [US3] `test/autonomous/run_spec_attachments_test.exs` additions: bare path vs `{path, display_name}`; `[{:attachments, [two refusals]}]` in one call; refusal leaves no branch, worktree or run record (assert via `git branch` / store); `Autonomous.run(attachments: […])` ⇒ `{:error, {:unsupported_option, :attachments}}`; `resume/2` and `continue_run/1` accept no such option and restore from the record

### Implementation for User Story 3

- [X] T036 [US3] Make `run/1` refuse a direct `:attachments` option with `{:error, {:unsupported_option, :attachments}}` in `lib/autonomous.ex`; ensure `resume/2` / `continue_run/1` neither accept nor forward it
- [X] T037 [US3] Document `:attachments` in the `run_spec/2` `@doc`/`@spec` (path | {path, display_name}, error shape) in `lib/autonomous.ex`

**Checkpoint**: facade and console share one rule set.

---

## Phase 6: User Story 4 — See what a run was given (P2)

**Goal**: Run Detail and the PR body list the attachments.

**Independent Test**: Run Detail of an attachment run lists name, type, size, location; text-only run page unchanged; PR body lists files (quickstart V6).

### Tests for User Story 4

- [X] T038 [P] [US4] `test/autonomous/web/attachments_view_test.exs`: pure rows (original and stored name when they differ, media_type, size, location derived from `spec_number`+`slug`, sha256 first 12 hex with full value in title, branch); empty list ⇒ no rows
- [X] T039 [P] [US4] `test/autonomous/web/run_detail_live_test.exs` additions: `[data-attachments]` present with attachments, absent (markup unchanged) without; hostile `original_name` is escaped; pre-047 record renders unchanged
- [X] T040 [P] [US4] `test/autonomous/attachments_pr_note_test.exs` and publisher test: `pr_note/1` renders heading + code-span paths with type and size, `""` for empty; appended after `Remediation.pr_note/1` on both described and template branches of `pr_text/2`; allocated `spec_number` is used on the publish-only continue route

### Implementation for User Story 4

- [X] T041 [P] [US4] Create pure `Autonomous.Web.AttachmentsView.rows/1` in `lib/autonomous/web/attachments_view.ex`
- [X] T042 [US4] Render `[data-attachments]` block in the feature card beside `data-advanced-with-findings` in `lib/autonomous/web/live/run_detail_live.ex`, only when `f.attachments != []`; failure reasons use the existing terminal-reason line via `Report.format_reason/1`
- [X] T043 [P] [US4] Add `Attachments.pr_note/1` in `lib/autonomous/attachments.ex` and append it in `pr_text/2` in `lib/autonomous.ex` after `Remediation.pr_note/1` (both branches)
- [X] T044 [P] [US4] Run Detail styles for `[data-attachments]` in `priv/static/assets/console.css`, tokens only; run `design_contract_test`

**Checkpoint**: all four stories independently functional.

---

## Phase 7: Polish & Cross-Cutting

- [X] T045 [P] Update `docs/runbook.md` (attachments at start only, limits and env overrides, tamper failure, committed/pushed warning), `docs/workflow.md`, `docs/harness-contract.md` (adapter does not forward `attachments`; Read-based delivery), `docs/container.md` (nothing new needed, state so)
- [X] T046 [P] Add a "Multi-modal single-spec (feature 047)" section to `CLAUDE.md` summarising Attachment/Attachments/Sniff/Limits, schema v9, R3 and R8 exceptions to FR-022, console surfaces
- [X] T047 Regression guards (FR-022/023/024): text-only single-spec prompts/seed/commits unchanged; backlog run unaffected; gates unchanged — add assertions in the existing pipeline/phase_request/run_spec tests
- [X] T048 Full suite and coverage: `mise exec -- mix test` zero warnings; `mise exec -- mix test --cover` pure-core modules (`Attachment`, `Attachments.Sniff`, `Attachments.Limits`, `AttachmentForm`, `AttachmentsView`) above 90%
- [ ] T049 Run `quickstart.md` validation V1–V9 against a real target (manual; V1, V3–V5, V7 need a live harness)

---

## Dependencies & Execution Order

- **Phase 1** → none. **Phase 2** → Phase 1 (T001 for Limits). Phase 2 blocks everything.
- Inside Phase 2: T005, T006, T007, T009 (feature field only), T012, T014 parallel; T008 needs T005–T007; T010 → T011 (T011 also needs T009); T013 needs T008 + T012.
- **US1** needs Phase 2. T018 → T019; T020 → T021 → T022; T023 after T022.
- **US2** needs Phase 2; independent of US1 code paths but exercised end to end after US1. T029 → T030; T031 needs T013.
- **US3** needs T018 (run_spec wiring from US1). Small.
- **US4** needs Phase 2; T043 touches `lib/autonomous.ex` (sequence after T018/T019/T036 edits to avoid conflicts); T042 needs T041.
- **Polish** after desired stories.
- Same-file serialisation: `lib/autonomous.ex` (T018, T019, T036, T037, T043), `lib/autonomous/attachments.ex` (T008, T013, T029, T043), `console.css` (T023, T044), `trigger_live.ex` (T021, T022), `report.ex` (T014).

## Parallel Examples

```text
Phase 1:   T001 T002 T003 T004 together
Phase 2:   T005 T006 T007 T009 T012 T014 together, then T008, T010→T011, T013
US1 tests: T015 T016 T017 together
US2 tests: T024–T028 together; impl T032 T033 together with T029
US4:       T038 T039 T040 together; T041 T043 T044 together
```

## Implementation Strategy

1. **MVP**: Phase 1 → Phase 2 → US1 (console attach + commit). Validate with quickstart V1/V2/V9.
2. Add **US2** (prompt block, verify, long-line + placeholder). Without it attachments only reach no session; ship US1+US2 together as the real P1 deliverable.
3. Add **US3** (facade hardening), then **US4** (surfaces).
4. Polish, full suite, quickstart.

## Notes

- Deliberate FR-022 reaches (plan, Complexity Tracking): T032 (line limit, all sessions) and T033 (base64 placeholder, all sessions).
- `original_name` appears only on Run Detail (HEEx-escaped); prompts and PR body use `stored_name`.
- Commit after each task or logical group; behaviour changes beyond this spec need a new speckit feature, not an in-place amendment.
