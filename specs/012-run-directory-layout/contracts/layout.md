# Contract: Layout

The single resolution surface for the four run roots (FR-011). Built once per
run at the IO boundary; pure given `(repo, segment, scope)`.

## Struct

```elixir
%Layout{
  worktree_root:   String.t(),        # ~/.autonomous/worktrees/<segment>
  transcript_root: String.t(),        # ~/.autonomous/transcripts/<segment>/<scope-seg>
  breakdown_root:  String.t() | nil,  # <repo>/specs/autonomous/breakdown/<slug> | nil (ad-hoc)
  ad_hoc_root:     String.t() | nil   # <repo>/specs/autonomous/ad-hoc | nil (breakdown)
}
```

## `build/3`

```elixir
@spec build(repo :: String.t(), segment :: String.t(), scope) ::
        {:ok, %Layout{}} | {:error, term()}
      when scope: {:breakdown, String.t()} | :ad_hoc
```

Resolution (pure path joins):

| Field | `{:breakdown, slug}` | `:ad_hoc` |
|-------|----------------------|-----------|
| `worktree_root` | `<autonomous>/worktrees/<segment>` | same |
| `transcript_root` | `<autonomous>/transcripts/<segment>/<slug>` | `<autonomous>/transcripts/<segment>/ad-hoc` |
| `breakdown_root` | `<repo>/specs/autonomous/breakdown/<slug>` | `nil` |
| `ad_hoc_root` | `nil` | `<repo>/specs/autonomous/ad-hoc` |

where `<autonomous>` = `Config.autonomous_root/0` (default `Path.expand("~/.autonomous")`)
and the in-repo base is `Config.specs_root/0` (default `specs/autonomous`).

## `in_repo_rel/1`

```elixir
@spec in_repo_rel(%Layout{} | scope) :: String.t()
```

Returns the **repo-relative** in-repo suffix for the run's scope —
`"specs/autonomous/breakdown/<slug>"` or `"specs/autonomous/ad-hoc"` — i.e.
`breakdown_root`/`ad_hoc_root` with the leading `<repo>/` stripped.

Why it exists (resolves analyze finding I1): `breakdown_root`/`ad_hoc_root` are
**base-repo absolute**, correct for loading a committed breakdown package
(`Backlog.load!/1`) and for the read-only LiveViews. But a pipeline **phase runs
with `cwd = <worktree>`**, not the base repo, so it must be handed a *relative*
path (resolved under the worktree) — and the single-spec seed must be written
**into the worktree** (Principle III containment), never the base tree:

- `PhaseRequest.breakdown_ref(feature, layout)` → `Path.join(in_repo_rel(layout), Path.basename(feature.path))`.
- seed write → `Path.join([worktree.path, in_repo_rel(layout), Path.basename(feature.path)])`.

Breakdown files are pre-committed and already present at that relative path in
every worktree; the ad-hoc seed is generated there and committed on the branch.

Failures (fail loud, FR-010):
- `{:error, {:reserved_slug, "ad-hoc"}}` when `scope` is `{:breakdown, "ad-hoc"}` —
  a breakdown package named `ad-hoc` would collide with the ad-hoc transcript
  segment.
- `{:error, {:home_unavailable, reason}}` when `autonomous_root` cannot be
  resolved (user home unavailable) — never falls back to a repo-internal path.

## `ensure/1`

```elixir
@spec ensure(%Layout{}) :: :ok | {:error, {:mkdir, path :: String.t(), reason :: term()}}
```

Create any missing directory among the resolved roots before writing (FR-009);
fail loud if a root cannot be created (FR-010). MUST NOT delete or overwrite an
existing sibling run's directory — only `mkdir -p` the roots this run needs.

## Threading

`build/3` runs once at `run/1`/`run_spec/1` preflight (after
`RepoIdentity.resolve/1`). The `%Layout{}` is placed on the run and threaded:

```
run/1 ──▶ Coordinator ──▶ FeatureRunner(layout:) ──▶ Transcripts.write(layout, …)
                                                 └──▶ Checkpoint.{write,read,delete}(layout, …)
                                                 └──▶ RunManifest.*(layout, …)
Worktree.create(feature, worktree_root: layout.worktree_root)
PhaseRequest.breakdown_ref(feature, layout)   # in_repo_rel + basename (worktree-relative)
```

Writers receive resolved roots — they perform no identity IO and stay
side-effect-free given inputs (Constitution I). Test callers pass an explicit
`%Layout{}` pointing at a tmp dir, keeping the suite hermetic.
