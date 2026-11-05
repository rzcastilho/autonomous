# Research: Multi-Modal Single-Spec Run

Probes ran 2026-11-05 against Claude Code CLI 2.1.318 (`--output-format stream-json`,
`--model haiku`) with synthetic files: a 64x64 PNG, a 1-page PDF and a 12-page PDF.
Everything else was read from the code and `deps/` at this branch's HEAD.

## R1. Delivery channel: files plus prompt text

**Decision**: Sessions open attachments with `Read`, from the worktree. The prompt
names them.

**Rationale**: `Jido.Harness.RunRequest` has an `attachments` field, but no code in
`deps/jido_claude/lib` reads it. Probe confirmed `Read` hands the model real content:
PNG returns an `image` block, PDF a `document` block, and haiku answered correctly
for both.

**Alternatives**: Patching the adapter, rejected: pinned GitHub SHA, and every phase
would need the content resent. Inlining into the prompt, rejected: images cannot go
through a text prompt.

## R2. Validation: stdlib signatures, content before extension

**Decision**: `Attachments.Sniff`, pure over bytes.

| Type | Signature | Structural check |
|---|---|---|
| PNG | `89 50 4E 47 0D 0A 1A 0A` | `IHDR` first, `IEND` chunk at the tail |
| JPEG | `FF D8 FF` | `FF D9` in the tail, tolerating trailing padding |
| GIF | `GIF87a`, `GIF89a` | trailer `3B` |
| WebP | `RIFF....WEBP` | RIFF size consistent with byte size |
| PDF | `%PDF-` | `%%EOF` within the last 1024 bytes |

Order: match a signature and pass the check, the file is that type. Signature with
failed check is `:corrupt`. No signature with an image or PDF extension is
`:content_mismatch`. No signature with a text extension (`.md`, `.markdown`, `.txt`,
`.csv`, `.json`) needs `String.valid?/1` and no NUL byte, else `:not_text`. Anything
else is `:unsupported_type`. Size zero is `:empty` first.

**Rationale**: Covers FR-006 and the corrupt-file edge case without a dependency.
Pixel-level corruption inside a structurally sound file is not detectable here; it
reaches the session, which records `## NEEDS HUMAN` (FR-012a). That is the intended
backstop.

**Alternatives**: ImageMagick or `file(1)`, rejected: new OS dependency for a check
that runs on trusted-operator input. `.json` validity, rejected by FR-006.

## R3. The transport kills a session on a long line (not in the spec)

**Decision**: `SdkProxy.prepare/1` sets `max_buffer_size` to
`Config.session_max_line_bytes/0`, for every session.

**Rationale**: `external_runtime_transport` defaults to `max_buffer_size: 1_048_576`
and `buffer_overflow_mode: :fatal`. `ClaudeAgentSDK.Runtime.CLI` passes
`options.max_buffer_size` through. The probe shows one `user` frame carrying the
base64 **twice**: `message.content[].source.data` and `tool_use_result.file.base64`.
A PDF of under 400 KB already passes 1 MiB, so without this change a routine PDF
attachment ends the session.

The 1 MiB line was derived from the deps, not observed; quickstart V7 proves the
raised limit end to end with a maximum-size PDF (it did not: see below).

Limit: `min(2 * ceil(max_file_bytes * 4 / 3) + 512 KiB, 16 MiB)`, 16.5 MB at defaults.

**Amended after V7 (live probe).** Raising `max_buffer_size` is not enough: the
transport also ends the stream, with no error, on any stdout line past its
`max_recoverable_line_bytes` (16 MiB, not exposed by `ClaudeAgentSDK`). Real PDFs read
with haiku: 5.4 MB (13.7 MiB line) ok, 6.4 MB (16.3 MiB) ends `:incomplete`, 9.6 MB
(25.6 MiB) ends `:incomplete` even with `max_buffer_size` at 81 MB, while the CLI alone reads
the 9.6 MB file. So the per-file default dropped from 10 MB to 6 MB, the largest size whose
line stays under 16 MiB, and `session_max_line_bytes/0` is clamped to that ceiling. A larger
override is accepted by the form and unreadable by the session.

Set for all sessions because it is one line in one place, is unobservable without a
large read, and a text-only session reading a large repo file would otherwise still
die. This is the first of two deliberate reaches past "runs with attachments".

**Alternatives**: `config :claude_agent_sdk, Buffers`, rejected: read by the sync
`Process` path, not shown to reach the runtime session path. Per-session marker,
rejected: more plumbing for no behaviour difference.

## R4. Bytes held in memory until the worktree exists

**Decision**: `load/2` returns `{manifest, payloads}`; the payloads ride in the
`seed_executor` closure. No staging directory.

**Rationale**:

- Spec: a refused start leaves attachments "not written anywhere". Refusals such as
  a parked run happen inside `run/1`, after `load/2`.
- LiveView's temp files disappear when the view navigates away, while the executor
  runs later. Reading first means the run no longer depends on them, even when
  `run_unlinked/1` times out and leaves the task running.
- Validated bytes are the committed bytes: no gap between check and copy.
- Nothing to clean up after a crash. Large binaries are refcounted, so the closure
  costs at most 25 MB and is not copied between processes.

**Alternatives**: A staging directory under `autonomous_root`, rejected: needs
cleanup on every refusal and crash path. Holding paths, rejected: temp-file lifetime.

**Crash window**: A node death after `open_run` and before the attachment commit
loses the bytes while the manifest survives. The seed has the same window today. R5's
check turns it into a named failure instead of a silent lie to sessions.

## R5. Committed by the orchestrator before the seed

**Decision**: New `Worktree.commit_paths/3`: `git add -f -- <paths>`, then commit with
the orchestrator author. Called between `Worktree.create` and `write_seed`, only when
payloads exist. `FeatureRunner.run/2` entry calls `Attachments.verify/2`, comparing
`sha256` for each manifest entry.

**Rationale**:

- `git add -f` meets the ignore-rule edge case. Once tracked, later `git add -A`
  checkpoints keep working.
- `Worktree.restore/1` runs `reset --hard` then `clean -fd`, which keeps committed
  files and would remove uncommitted ones (FR-013).
- `Worktree.squash/3` uses `reset --soft <base>`, so the files land in the feature's
  one final commit.
- All five call sites in `lib/autonomous.ex` go through `FeatureRunner.run/2`, so one
  check covers resume, continue and a `resolve/1` re-run, with no new gate in
  `Pipeline` (FR-024).

A session has write access and could alter a file mid-run. Verifying only at entry
accepts that: the prompt says read-only, and a per-phase check would be the new gate
the clarifications ruled out. The next resume would catch it.

`Worktree.commits_beyond/3` now sees one more commit on the branch. It is still a
sound empty-branch check in practice, because a `:done` feature passed the artifact
gates first.

**Alternatives**: Untracked files plus `info/exclude`, rejected by Clarifications
(they must appear in the PR). A separate commit after specify, rejected: a retry of
specify would lose them.

## R6. The spec directory now exists before `specify`

**Decision**: Keep the location, and tell the specify session the directory already
exists.

**Rationale**: `specs/<spec_id>-<slug>/attachments/` is what the clarification asks
for. This repo's `speckit-specify` skill uses `mkdir -p`, so it is fine. However
`.specify/scripts/bash/create-new-feature.sh` exits 1 on an existing directory
without `--allow-existing-branch`, and targets carry their own Spec Kit version, so a
target whose skill calls that script would fail. The specify block says to reuse the
directory and pass that flag if a script needs it.

Checked the other consumers: `SpecDir.file/3` looks for the file per candidate, so a
directory holding only `attachments/` never satisfies an artifact gate. All gate and
task-plan callers use `file/3`; `SpecDir.resolve/2` has no gate caller. Recovery
evidence does not inspect spec directories.

**Alternatives**: `specs/<id>-<slug>-attachments/`, rejected: makes
`prefix_matches/2` see two matches for `specs/<id>-*` and drop out as ambiguous.
`.specify/attachments/`, rejected: not next to the spec.

## R7. Prompt block: stored names only

**Decision**: One block rendered from three packs, appended after the
container-engine note and before resume guidance, so operator guidance and the retry
note stay last. Contract in
[contracts/session-prompt-block.md](./contracts/session-prompt-block.md).

**Rationale**: `stored_name` is restricted to `[A-Za-z0-9._-]`, so a hostile filename
cannot carry text into a prompt or a PR body. `original_name` shows only on Run
Detail, where HEEx escapes it. All sessions pass through `PhaseRequest.build/3` or
`build_remediation/3` (`RunFeaturePhase`, `Describe`, `RunRemediation`,
`RunAutoRemediation`, implement chunks via `RunFeaturePhase`), and all read
`feature.attachments`, so coverage needs no new option.

The block must also protect the `## NEEDS HUMAN` flow. Specify writes the marker, but
the gate reads `spec.md` after the clarify reviewer has edited it, and `clarify.md`
tells the reviewer to default anything that fails the materiality test. An unreadable
attachment would fail that test and be defaulted away. So the clarify block makes it
explicit: an attachment nobody could read is material by definition.

Size guidance goes in the common block: open files one at a time, only when relevant,
and page through large text with `offset`/`limit`.

**Alternatives**: Seed file carrying the list, rejected: FR-022 needs the seed
unchanged, and only `specify` and `clarify` reference it.

## R8. Conversation placeholder at the entry boundary

**Decision**: `ConversationEntry` walks `tool_result` content and unknown user blocks,
and replaces any `%{"source" => %{"type" => "base64", ...}}` block with
`%{"type" => "text", "text" => "[application/pdf, 512 KB: binary content not recorded]"}`.
Size is computed from the base64 length.

**Rationale**:

- `user/1` reads `message.content` only, so the second copy in `tool_use_result` is
  never kept. One scrub point is enough.
- Runs before `CredentialMask.mask/2`, which would otherwise scan megabytes per pair.
- A text block needs no new kind, no change to `ConversationRows` or `ToolSummary`,
  and no conversation file format bump (FR-021, SC-007).
- Text/data reads return plain text and stay recorded and masked as today.

Applied to every session, without consulting a manifest: the recorder does not know
about attachments, and `ConversationEntry` is pure and should stay so. A text-only
session that reads an image from the target repo now records a placeholder. This is
the second deliberate reach, and it is an improvement over storing the base64.

**Alternatives**: Filtering in `ConversationRows`, rejected: base64 would still reach
the file and the 500-entry window. Dropping the block, rejected: Principle VII needs a
receipt that a read happened.

## R9. Console upload: LiveView uploads, postponed consume

**Decision**: `allow_upload(:attachments, accept: :any, auto_upload: true,
progress: ..., max_entries: max_files + 1, max_file_size: max_file_bytes)` on the
existing `single-spec-form`.

- `live_file_input` plus `phx-drop-target` give picker and drag-and-drop with no JS.
- The form's `phx-change="update_description"` already satisfies LiveView's change
  binding. The handler matches on `description`, which the form always sends, and
  gains the triage step.
- `accept: :any`, because the server rule is content-based. One rule for facade and
  console (US3). An extension filter would refuse a JPEG named `.bin` differently.
- `Web.AttachmentForm` (pure) turns LiveView errors, sizes and running totals into
  refusals plus refs to `cancel_upload/3`, so `render_upload` tests stay simple.
  `max_entries` is one above the limit so an extra file arrives and can be refused by
  name, not as a generic upload-level error.
- On `entry.done?`, `handle_progress` runs content validation against the temp path
  with `{:postpone, _}`.
- Start reads paths with `consume_uploaded_entries` returning `{:postpone, _}`. That
  keeps the entries, which is what lets a refused start retry without re-adding
  (edge case). In-flight entries refuse the start, since consuming them raises.

Mode toggle unmounts the input; a task must prove done entries survive switching.

**Alternatives**: A custom JS hook, rejected: no need, and Principle "server-rendered
by default". `{:ok, _}` consume, rejected: loses files on a refused start.

## R10. Limits on what the model can take

**Finding**: A 12-page PDF read whole with no `pages` argument on a host without
`pdftoppm`, so the image needs no `poppler-utils`. Behaviour for a very long PDF was
not probed. If the CLI or API refuses it, `Read` returns an error, the session cannot
read the file, and FR-012a applies at specify and clarify. Later phases are covered
by the spec's assumption: anything read at specify is byte-identical later.

**Decision**: No extra limit beyond the spec's three. No Dockerfile change.

**Addendum (V7).** When the model passes `pages` to `Read` on a larger PDF, the CLI needs
`pdftoppm` (poppler) and errors without it ("pdftoppm is not installed"). That happened
on some runs of 7-10 MB files. The session then cannot read the file, so FR-012a applies
(`## NEEDS HUMAN`); nothing is silently lost. Adding `poppler-utils` to the image would
make those reads work, and is left for an operator who attaches long PDFs
(`scripts/autonomous build --apt poppler-utils`).

## Resolved unknowns

No `NEEDS CLARIFICATION` remains in Technical Context.
