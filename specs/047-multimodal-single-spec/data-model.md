# Data Model: Multi-Modal Single-Spec Run

Attachments are bytes in git and metadata in Mnesia. No attachment byte is ever
stored in Mnesia, in the conversation file, or in a log.

## Attachment (`Autonomous.Attachment`, pure struct)

One entry of the manifest. Immutable once the run starts.

| Field | Type | Rule |
|---|---|---|
| `original_name` | `String.t()` | As supplied. Display only, on Run Detail. Never put in a prompt, a PR body or a path (it is operator-supplied free text). |
| `stored_name` | `String.t()` | Safe, unique within the feature. See naming rules. The only name a session or a PR sees. |
| `type` | `:png \| :jpeg \| :gif \| :webp \| :pdf \| :markdown \| :text \| :csv \| :json` | Detected, not declared. |
| `media_type` | `String.t()` | `image/png`, `application/pdf`, `text/markdown`, ... |
| `size` | `pos_integer()` | Bytes. |
| `sha256` | `String.t()` | Lowercase hex of the supplied bytes. |

Location is **derived, never stored**: `specs/<spec_id>-<slug>/attachments/<stored_name>`.
`spec_id` is allocated after the manifest is built (`ensure_spec_number`, in the
executor), so storing a path would record the wrong number.

### Naming rules (`stored_name`, FR-015)

1. Take the last segment after splitting on both `/` and `\`.
2. Replace every run of characters outside `[A-Za-z0-9._-]` with `-`.
3. Strip leading `.` and `-`; collapse `..` into `.`.
4. Cap the stem at 80 bytes. Empty stem becomes `attachment`.
5. Set the extension from the **detected** type (`.png`, `.jpg`, `.gif`, `.webp`,
   `.pdf`); a text/data file keeps its supported extension, lower-cased. The CLI's
   `Read` tool picks image or PDF handling from the extension, so a mismatch would
   defeat delivery.
6. On a case-insensitive collision within the manifest, append `-2`, `-3`, ...
   before the extension, in input order.

## Attachment payload (transient)

`{stored_name, bytes}` pairs produced with the manifest by `Attachments.load/2`.
Held only by the `seed_executor` closure until the worktree commit. Never placed
on `Feature`, in run settings, or in `opts` that reach `RunContext.capture/1`.

## Attachment limits (`Autonomous.Attachments.Limits`)

Read from `Config` at the boundary. Not a `RunContext` key: limits gate input and
do nothing after the start, so nothing about them needs reapplying on resume.

| Key | Default | Env override |
|---|---|---|
| `attachment_max_files` | 10 | `AUTONOMOUS_ATTACHMENT_MAX_FILES` |
| `attachment_max_file_bytes` | 10 MB (10_000_000) | `AUTONOMOUS_ATTACHMENT_MAX_FILE_BYTES` |
| `attachment_max_total_bytes` | 25 MB (25_000_000) | `AUTONOMOUS_ATTACHMENT_MAX_TOTAL_BYTES` |

All three go through `positive!/2`, so a bad value raises rather than falling back.

Derived: `Config.session_max_line_bytes/0` =
`2 * ceil(attachment_max_file_bytes * 4 / 3) + 1_048_576`, see research R3.

## Refusal

```elixir
{:attachments, [%{file: String.t(), reason: reason}]}

reason ::
    :not_found | :unreadable | :empty
  | :unsupported_type                     # no supported signature, extension not a text type
  | :content_mismatch                     # image/PDF extension, content is something else
  | :corrupt                              # supported signature, structural check failed
  | :not_text                             # text extension, invalid UTF-8 or NUL bytes
  | {:too_large, size, max_file_bytes}
  | {:too_many_files, max_files}
  | {:total_too_large, total, max_total_bytes}
```

Every problem is collected, not just the first, so the operator fixes them in one
pass. Rendered by `Report.format_reason/1`.

## Feature (`Autonomous.Feature`, extended)

| Field | Type | Default |
|---|---|---|
| `attachments` | `[Attachment.t()]` | `[]` |

Default `[]` means every backlog feature and every text-only feature is unchanged.
`Recovery.to_feature/1` restores it from the record, so a resume, continue or
rebuild sees the same list without any new plumbing to `PhaseRequest`.

## Store: `speckit_feature_run` (schema v9)

| Attribute | Type | Meaning |
|---|---|---|
| `attachments` | `[map()] \| nil` | Appended last. `nil` = written before 047. `[]` = no attachments. |

Each map holds the `Attachment` fields under atom keys, `type` as an atom.

- **Migration 9** is a plain append transform: every v8 row gets `nil`.
- **Migration 5 must be pinned.** `add_spec_number/0` transforms to
  `Schema.table(:speckit_feature_run).attributes`, the *current* shape. Adding an
  attribute makes that list one longer than the tuple v5 builds, so an upgrade from
  v4 or below would fail. Add `@feature_run_v5_attributes` and use it there.
  Migration 9 pins its own list too.
- `Writer.open_run/2` writes the row in **two** places (lines 83 and 133); both set
  `attachments: f.attachments`.
- `Query` exposes `attachments: f.attachments || []`.
- `Store.Export` adds an `attachments` key only when the list is non-empty, so a
  text-only export is byte-identical.

## State transitions

```text
supplied --load/2--> refused (start returns {:error, {:attachments, _}}; nothing exists)
    |
    v
validated (manifest on Feature, payload in closure)
    |  run/1 refused -> dropped with the closure; nothing written anywhere
    v
Worktree.create -> files written -> commit_paths/3 on the feature branch
    |  commit fails -> feature :failed {:attachments, reason}
    v
committed (immutable; verified by sha256 at every FeatureRunner entry)
    |  mismatch or missing -> feature :failed {:attachments_changed, [stored_name]}
    v
squashed with the feature on :done / kept on the local branch otherwise
```
