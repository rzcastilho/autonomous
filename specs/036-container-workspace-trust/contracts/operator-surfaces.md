# Contract: Operator Surfaces for `{:untrusted_workspace, …}`

Principle VII: real identifiers, the receipt visible, mono for machine values.

## `Report.format_reason/1` (final report, `print_status/0`)

`where` follows the existing convention (phase atom, chunk task-phase ref, or
`{:remediation, n}`), rendered by the same helper `:session_died` uses.

```text
untrusted_workspace in <where> — CLI ignored <kinds> from the committed pack; workspace <path> is not trusted (projects["<path>"].hasTrustDialogAccepted). Trust it, then resume/2.
```

- `<kinds>`: comma-joined, e.g. `permissions.allow, permissions.additionalDirectories`;
  `(unknown)` when empty.
- `<path>`: the CLI-named key; when `nil`, the clause reads
  `session had no working directory` instead of `workspace <path> is not trusted (…)`.

## Console (`RunDetailLive.format_reason/1`)

Pass-through to `Report.format_reason/1`, alongside the existing
`:backgrounded_command` / `:session_died` legacy clauses. No raw `inspect/1`
(guard `G-inspect`). Path renders mono, ellipsized, never wrapped. No new
status, color or token: the feature is `:failed`.

## Logs

- Permissive: one `Logger.warning` per session (text in
  `untrusted-workspace-gate.md` §3).
- Container entrypoint: one `autonomous: trusted … ` line per start.

## Documentation

- `docs/container.md` — new section *Workspace trust*: what is trusted and why
  (repo record is load-bearing; worktree keys resolve to the repo), the
  untrusted-hook finding with date and CLI version (research R3), the
  reproducible procedure (`quickstart.md` §4), and that login-seeded trust is
  carried over untouched.
- `docs/runbook.md` — recovery for `untrusted_workspace` on the host: run
  `claude` interactively once in the target repo and accept the dialog (one
  record covers all worktrees), then `resume/2`.
