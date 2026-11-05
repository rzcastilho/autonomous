# Contract: operator surfaces

All styling through `console.css` tokens; `design_contract_test` must stay clean.
File names, types, sizes and paths render in mono. No status color, no new keyframe.

## Trigger, single-spec form

Added inside `#single-spec-form`, after the description refusal:

```text
[data-attachments-drop]   <.live_file_input class="console-input"> with phx-drop-target
[data-attachment-list]    one [data-attachment={ref}] per entry
                            name · size · progress while uploading
                            button phx-click="remove_attachment" phx-value-ref
[data-error="attachment"] <.form_refusal> per refused file, naming file and limit
[data-attachments-notice] shown once a file is added (FR-019):
                            attachments are committed to the feature branch and
                            pushed to the target's remote; visible to anyone who can
                            read that repository; remain in its history
```

Behaviour:

| Event | Result |
|---|---|
| Valid file added | Listed, start enabled once all uploads finish. |
| Invalid file added | Cancelled, refusal shown, other files and description unaffected. |
| `remove_attachment` | `cancel_upload/3`, list and total update. |
| Start with an upload in flight | `start_error`, nothing dispatched. |
| Blank description with attachments | Existing `Description is required`, files kept. |
| Start refused for any reason | Files stay listed; retry needs no re-adding. |
| Page left before start | Temp files go with the upload channel; nothing in the target. |
| Description typed | `preview` unaffected by attachments (FR-009). |

`format_start_error({:attachments, refusals})` renders through `Report.format_reason/1`,
not `inspect/1`. `start_opts/1` is shared with backlog, so `:attachments` is added only
inside `start_single_spec/2` (FR-023).

## Run Detail

Inside the feature card, next to `data-advanced-with-findings`. Rendered only when
`f.attachments != []`; a run without attachments produces unchanged markup (FR-016).

```text
[data-attachments]
  name (original_name, with stored_name when they differ) · media_type · size ·
  location · sha256 (first 12 hex, full value in title)
  branch: f.branch
```

`Web.AttachmentsView.rows/1` is pure and derives location from `spec_number` and
`slug`. `original_name` is shown here only.

Failure reasons render on the existing terminal-reason line:
`{:attachments, reason}` and `{:attachments_changed, names}` through
`Report.format_reason/1`.

## PR body

`Attachments.pr_note/1`, appended in `pr_text/2` after `Remediation.pr_note/1`, on both
the described and template branches. Empty list renders `""`.

```markdown

## Attachments

This feature was built from these files:

- `specs/012-checkout-screen/attachments/mockup.png` (image/png, 1.2 MB)
```

The path depends on the allocated `spec_number`. `handle_publish/6` already passes the
publisher a feature from `with_allocated_spec_number/1`, so `pr_text/2` is safe; a test
pins that, including the publish-only continue route.
Paths are plain code spans: a relative link in a PR body does not resolve.

## Report and export

`Report.format_reason/1` gains `{:attachments, _}` and `{:attachments_changed, _}`.
`Store.Export` includes `attachments` on a feature only when non-empty.
