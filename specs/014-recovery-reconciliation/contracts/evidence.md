# Contract: `Recovery.Evidence` (durable-evidence collector, edge I/O)

Gathers the per-feature `%Evidence{}` the pure `Reconcile` table consumes. This
is the only place git/file/CLI I/O happens for recovery. Every source is read
independently and defensively: a single absent/corrupt source degrades to its
unknown value, never a raise (FR-011). Offline-first: no source read blocks on the
network except the fallback remote query, which tolerates unreachability (FR-018).

## `collect/3`

```elixir
@spec collect(feature :: Feature.t(), Layout.t() | nil, opts :: keyword()) :: Evidence.t()
```

`opts`:
- `:remote` — the remote-PR query seam. Default: local-only (returns `:unknown`,
  never touches the network). Tests inject a stub; production may inject a `gh`
  probe used **only** when the local PR record is absent/corrupt.
- `:git` — git-read seam (branch existence + boundary-commit log). Default: real
  `Worktree`/`git`; tests inject a fake log.

### Source-by-source rules

| Field | How collected | Absent/corrupt → |
|-------|---------------|------------------|
| `branch_committed?` | git: branch `feature/NNN-slug` exists and has commits | `false` |
| `last_boundary_phase` | git log newest subject matching `~r/^speckit: <id> checkpoint after (?<phase>\w+)$/`, mapped via `Pipeline.parse/1` | `nil` (no boundary parsed) |
| `pr_record?` | `Describe.read_pr(id, layout)` returns `{:ok, %{pr_title, pr_body}}` | `false` |
| `pr_remote?` | only if `pr_record? == false`: `opts[:remote].(id)`; else `:unknown` | `:unknown` (also on any remote error/timeout) |
| `checkpoint` | `Checkpoint.read(id, layout)` `{:ok, map}` | `nil` |
| `final_marker?` | read durable `07-converge.md`, test for `## CONVERGE: READY` | `false` |

### Boundary-commit parse (FR-005 authority)

- Match ONLY the per-phase boundary subject
  `"speckit: <id> checkpoint after <phase>"` (written by `FeatureRunner` at each
  `{:cont, next}`). The `:done` squash and non-`:done` terminal commits use
  different subjects and MUST NOT be parsed as a boundary phase.
- Take the newest matching commit's `<phase>`; unparseable/absent → `nil`.
- The git boundary is authoritative over the checkpoint's `last_phase`: when they
  disagree, the collector still reports the git-derived `last_boundary_phase`
  (checkpoint is corroboration only).

### Remote fallback (offline-first)

- Attempted at most once per feature, and only when the local `pr.json` is
  absent/corrupt.
- Any failure — no network, `gh` missing, non-zero exit, timeout — maps to
  `pr_remote? = :unknown`. Remote-unreachable is NEVER a collection error and
  NEVER fails recovery (FR-018, SC-009).

## Invariants

- **Total**: `collect/3` returns a fully-populated `%Evidence{}` for every input,
  never raises on a single bad source.
- **Hermetic default**: with no seams injected and the network down, `collect/3`
  still returns local-derived evidence (branch/boundary/pr_record/checkpoint/
  final_marker) with `pr_remote? = :unknown`.
- **Scope-safe**: reads only within the feature's `Layout` roots and its own
  branch; performs no write and no repository mutation (Principle III).
- **Stale-run guard**: honors 009 FR-017 — evidence is collected only for the run
  the manifest and artifacts consistently identify; a different run's artifacts in
  the same slot are not mixed in.
