# Phase 1 Data Model: Resume Facade

This feature introduces no new persisted entity and does not change any existing
struct. It reads one existing record and shapes one transient request. Entities
below are described at the contract level (fields + validation + transitions),
per the spec's Key Entities.

## Checkpoint (existing — read-only here)

The durable resume pointer written by `Checkpoint.write/1`, read by
`Checkpoint.read/1`. Shape is owned by feature 002 and **not changed** by this
feature.

| Field | Type (on disk) | Used by resume |
|---|---|---|
| `feature_id` | string | matched to the resume target |
| `last_phase` | string (an `Atom.to_string` of a pipeline phase) | default start phase (parsed→atom, validated) |
| `status` | string (`escalated`/`halted`/`failed`) | informational; not a gate here |
| `reason` | string (`inspect`ed) | informational |
| `session_id` | string \| null | informational |

**Read outcomes** (from `Checkpoint.read/1`):
- `{:ok, record}` — proceed to phase resolution.
- `{:error, :no_checkpoint}` — absent file → facade returns `{:error, :no_checkpoint}`.
- `{:error, :corrupt}` — unreadable/undecodable → facade returns `{:error, :corrupt_checkpoint}`.

**Validation applied by this feature**: `record["last_phase"]` MUST resolve to a
member of `Pipeline.phases/0`; if not, resume returns `{:error, {:unknown_phase, phase}}`
and starts no run (guards a hand-corrupted checkpoint).

## Resume request (transient — this feature)

Not a struct; the argument surface of `resume/2`. Assembled and fully validated
at the facade before any run starts.

| Field | Source | Type | Default | Validation |
|---|---|---|---|---|
| `feature_id` | positional arg | string | — (required) | MUST match a feature in the backlog, else `{:error, {:unknown_feature, id}}` |
| `start_phase` | `opts[:from]` else `checkpoint.last_phase` | atom | checkpoint's `last_phase` | MUST be in `Pipeline.phases/0`, else `{:error, {:unknown_phase, phase}}` |
| `prompt` | `opts[:prompt]` | string \| nil | `nil` | none — passed through unchanged; `nil` ⇒ runner runs with no note (no placeholder) |
| run opts | remaining `opts` | keyword | — | passed through to `run/1` unchanged (e.g. `:runner`, `:max_concurrency`, `:features`, `:owner`) |

## Feature (existing — read-only)

Looked up by id from the backlog (`Keyword.get_lazy(opts, :features, &load_backlog/0)`,
same as `resolve/1`). No field changes. Used to locate/create the worktree and to
form the one-element wave.

## Resolution flow (state, no persistence)

```text
resume(id, opts)
  │
  ├─ feature = find(backlog, id)      ── nil ─▶ {:error, {:unknown_feature, id}}
  │
  ├─ Checkpoint.read(id)
  │       ├─ {:error, :no_checkpoint} ─▶ {:error, :no_checkpoint}
  │       ├─ {:error, :corrupt}       ─▶ {:error, :corrupt_checkpoint}
  │       └─ {:ok, record} ──┐
  │                          │
  ├─ start_phase = opts[:from] || parse(record["last_phase"])
  │       └─ start_phase ∉ Pipeline.phases ─▶ {:error, {:unknown_phase, start_phase}}
  │
  └─ run(features: [feature], runner: resume_runner(start_phase, opts[:prompt]), <passthrough opts>)
          └─ resume_runner:
               reuse kept worktree OR Worktree.create (branch reuse)
                 └─ create fails ─▶ notify(:failed, {:worktree, reason})   # branch gone
               FeatureRunner.run(start_phase:, resume_prompt:)
        ──▶ {:ok, coordinator_pid}   (on_start tuple, same as run/1)
```

Every left-branch terminates with a distinct `{:error, …}` and **no** run
started (SC-005). Only the bottom path reaches `run/1`.
