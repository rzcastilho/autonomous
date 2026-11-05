# Contract: `run_spec/2` attachments

## Option

```elixir
Autonomous.run_spec("Build the screen in the attached mockup",
  attachments: ["/path/mockup.png", {"/tmp/live_view_upload-abc", "flow.pdf"}]
)
```

`:attachments` is a list of `path` or `{path, display_name}`. A bare path uses
`Path.basename/1`. The tuple exists for the console, whose temp paths have no useful
name. Absent or `[]` is today's behaviour, byte-identical.

## Preflight order

1. `reject_retired_opts/1`
2. blank description: `{:error, :empty_description}`
3. `Attachments.load/2`: `{:error, {:attachments, refusals}}`
4. `gather_taken_ids/1`, `SingleSpec.build/3`
5. attach the manifest to the feature
6. `spec_run_opts/4`, then `run/1` with `:attachments` removed from opts

Steps 2 and 3 create nothing and touch no git state. A later refusal from `run/1`
(preflight, parked run, drain timeout) returns unchanged and writes nothing, because
the payloads exist only in the executor closure.

## Errors

```elixir
{:error, {:attachments, [%{file: "song.mp3", reason: :unsupported_type},
                         %{file: "huge.png", reason: {:too_large, 12_000_000, 6_000_000}}]}}
```

Reasons are listed in [data-model.md](../data-model.md#refusal). `Report.format_reason/1`
renders each as `<file>: <reason with the limit that was broken>`. Every bad file is
reported in one call.

## `run/1` and others

`run/1` returns `{:error, {:unsupported_option, :attachments}}` when it receives the
option directly. `run_spec/2` strips it first. `resume/2` and `continue_run/1` accept
no such option: attachments are supplied at start only, and restored from the record.

## Test seams

With a caller `:runner` or `:executor`, `load/2` still runs and the manifest still
reaches the record, but nothing is committed, the same way the seed is not written.

## Commit

```text
author:  autonomous <orchestrator@speckit.local>
message: speckit: <feature.id> attachments (<n> files)
paths:   specs/<spec_id>-<slug>/attachments/
```

Made with `git add -f`, before the seed is written, only when the manifest is
non-empty. A failure ends the feature `:failed` with `{:attachments, reason}`.

## Verification

`FeatureRunner.run/2` entry, only when `feature.attachments != []`: each file is read
and its `sha256` compared. Mismatch or absence ends the feature `:failed` with
`{:attachments_changed, [stored_name]}`, before any session. The kept worktree stays
for post-mortem.
