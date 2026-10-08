# Data Model: Container Workspace Trust (036)

No store schema change. Nothing new is persisted by the orchestrator beyond the
existing failure reason already recorded on a phase attempt / feature run.

## 1. Container CLI configuration (`$HOME/.claude.json`, in the container)

External file owned by the agent CLI. This feature touches only:

```json
{
  "...every other key": "preserved byte-for-value",
  "projects": {
    "<realpath AUTONOMOUS_REPO>":          { "...existing keys": "kept", "hasTrustDialogAccepted": true },
    "<realpath AUTONOMOUS_WORKTREE_ROOT>": { "...existing keys": "kept", "hasTrustDialogAccepted": true },
    "<any other path>":                    "untouched (carried over from the seed, never added)"
  }
}
```

Validation (trust step):

| Input state | Result |
|---|---|
| file absent | created with only `projects` holding the two records, mode `0600` |
| valid JSON object, records absent / `false` | records set `true`, all else kept, atomic replace |
| valid JSON object, both records already `true` | no write (file byte-identical) |
| not JSON, not an object, or `projects` not an object | startup fails naming the file; file unchanged |

Invariant: after the step, the set of paths *this feature* marked trusted is
exactly `{repo, worktree_root}` (FR-003). Pre-existing trusted paths from a
seeded host config remain as they were (US2 scenario 2).

## 2. Trusted location

| Field | Source | Notes |
|---|---|---|
| target repository | `AUTONOMOUS_REPO`, realpath | **load-bearing**: covers the repo, its subdirectories, and every `git worktree` of it (research R1) |
| instance worktree root | `AUTONOMOUS_WORKTREE_ROOT`, realpath | `<AUTONOMOUS_ROOT>/worktrees/<segment>`, derived in Elixir (R7); may not exist yet |

## 3. Instance identity environment (`Autonomous.Instance.env_lines/1`)

Adds one line to the existing five (contract: `contracts/environment.md`):

| Variable | Value |
|---|---|
| `AUTONOMOUS_WORKTREE_ROOT` | `Path.join([autonomous_root, "worktrees", segment])` — same function `Layout` uses |

## 4. Untrusted-workspace observation (per session, in memory)

Produced by the pure parser `Autonomous.WorkspaceTrust` from CLI stderr lines.

```elixir
%{
  workspace: String.t() | nil,   # the projects[...] key the CLI named; nil for "no working directory"
  kinds: [String.t()]            # e.g. ["permissions.allow", "permissions.additionalDirectories"], deduped, in order seen
}
```

`nil` observation = no untrusted line seen. Lines that do not match are
ignored (they are still logged as `CLI stderr: …`).

## 5. Gate signal and failure reason

| Name | Shape | Where |
|---|---|---|
| signal | `untrusted_workspace: observation` in the phase's `last_signals` | set by the session-driving site **only** when the run's containment profile is `strict` |
| reason | `{:untrusted_workspace, phase, observation}` | `Pipeline.next/3`, after `:session_died`, before `:backgrounded_command` |

State transition: a phase carrying the signal ends the feature `:failed` with
that reason (no retry). Under `permissive` the site emits
`Logger.warning("untrusted workspace …")` naming `workspace`, sets no signal,
and the phase proceeds through the normal gates.

Recorded where today's failure reasons already go (phase attempt / feature
run reason term); rendered by `Report.format_reason/1` and the console via the
shared describer (`contracts/operator-surfaces.md`).
