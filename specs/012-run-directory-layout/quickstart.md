# Quickstart: Standardized Run Directory Layout

**Feature**: 012-run-directory-layout

Validation scenarios proving the four roots resolve to the standardized layout,
keyed by repository identity and run scope. All Elixir commands run through mise.

## Prerequisites

- `mise exec -- mix deps.get && mise exec -- mix compile` (clean, warnings = errors)
- Two throwaway git repos with **different** `origin` remotes for the isolation
  scenarios (or override `autonomous_root` at a tmp path in tests).

## Run the suite

```bash
mise exec -- mix test                              # hermetic: pure layout/identity units
mise exec -- mix test --include integration        # + git-origin read & fs create/write
mise exec -- mix test --cover                       # RepoIdentity + Layout > 90%
```

## Scenario 1 — Repository isolation (User Story 1 / SC-001)

**Goal**: two repos with different remotes never share a run subpath.

Unit (pure, hermetic):
```elixir
{:ok, c1} = RepoIdentity.canonicalize("git@github.com:acme/ledgerlite.git")
{:ok, c2} = RepoIdentity.canonicalize("https://github.com/acme/ledgerlite.git")
assert c1 == c2                                     # SSH ≡ HTTPS (Scenario 1.2)
assert RepoIdentity.segment(c1) == RepoIdentity.segment(c2)

{:ok, other} = RepoIdentity.canonicalize("git@github.com:beta/ledgerlite.git")
refute RepoIdentity.segment(c1) == RepoIdentity.segment(other)  # different owner ⇒ distinct
```

**Expected**: same repo (any URL form) → one segment; different repo → different
segment. Worktree/transcript roots built from the segment share no subpath.

## Scenario 2 — No `origin` is refused (User Story 1 / SC-004)

```elixir
# a repo with no origin remote
assert {:error, :no_origin} = RepoIdentity.resolve(repo_without_origin)
# facade preflight
assert {:error, {:preflight, problems}} = SpeckitOrchestrator.run(repo: repo_without_origin)
assert Enum.any?(problems, &match?({:no_origin, _}, &1))
```

**Expected**: run refused before any worktree/transcript is created; message
names the missing `origin` remote.

## Scenario 3 — Breakdown package organization (User Story 2 / SC-002)

**Goal**: two packages with overlapping feature ids stay separate.

```
<repo>/specs/autonomous/breakdown/alpha/001-....md
<repo>/specs/autonomous/breakdown/beta/001-....md
```

```elixir
{:ok, la} = Layout.build(repo, "ledgerlite-a3f9c2", {:breakdown, "alpha"})
{:ok, lb} = Layout.build(repo, "ledgerlite-a3f9c2", {:breakdown, "beta"})
refute la.transcript_root == lb.transcript_root
refute la.breakdown_root  == lb.breakdown_root
```

**Expected**: `alpha/001` and `beta/001` resolve under distinct slug segments
for both feature files and transcripts — 0 overwrites.

## Scenario 4 — Ad-hoc separation (User Story 3 / SC-003)

```elixir
{:ok, adhoc} = Layout.build(repo, "ledgerlite-a3f9c2", :ad_hoc)
assert String.ends_with?(adhoc.ad_hoc_root, "specs/autonomous/ad-hoc")
assert String.ends_with?(adhoc.transcript_root, "/ad-hoc")
# reserved-name guard
assert {:error, {:reserved_slug, "ad-hoc"}} =
         Layout.build(repo, "ledgerlite-a3f9c2", {:breakdown, "ad-hoc"})
```

**Expected**: ad-hoc feature files and transcripts land outside every breakdown
package; a breakdown package named `ad-hoc` is rejected loud.

## Scenario 5 — Fail loud on unwritable machine-global root (FR-010)

```elixir
Application.put_env(:speckit_orchestrator, :autonomous_root, "/nonexistent/unwritable")
{:ok, l} = Layout.build(repo, "seg", {:breakdown, "alpha"})
assert {:error, {:mkdir, _, _}} = Layout.ensure(l)
```

**Expected**: no silent fallback to a repo-internal path; preflight fails loud.

## Scenario 6 — Observability continuity (FR-012)

Start the console and confirm existing views resolve the new layout:
```bash
mise exec -- mix phx.server         # http://127.0.0.1:4000
```
- Transcripts view lists features under `<segment>/<scope>/<feature_id>`.
- Pipeline DAG / trigger views list breakdown packages under
  `specs/autonomous/breakdown/<slug>`.

## Migration note (FR-013/014)

Old data under `../.speckit-worktrees`, `<repo>/.speckit-transcripts`, and
`docs/breakdown` is **not** migrated. Drain in-flight runs before upgrading — a
checkpoint written under the old transcript path cannot be resumed after the
layout change.

## Definition of done

- [X] Scenarios 1–6 pass.
- [X] `RepoIdentity` + `Layout` coverage > 90%; default suite stays hermetic.
- [X] `mise exec -- mix compile` clean (warnings = errors).
- [X] SC-001..SC-005 demonstrated.
