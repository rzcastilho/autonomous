#!/usr/bin/env bash
# Reset a target repo's orchestrator state: git worktrees + transcripts
# under ~/.autonomous/{worktrees,transcripts}/<repo-name>-<shorthash>/.
#
# Never touches feature/NNN-slug branches (those are the durable PR-review
# trail — see docs/runbook.md) or anything inside the target repo itself.
#
# Usage:
#   scripts/reset-target.sh <target-repo-path>          # dry run (list only)
#   scripts/reset-target.sh <target-repo-path> --yes     # actually delete
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <target-repo-path> [--yes]" >&2
    exit 1
fi

REPO=$(cd "$1" && pwd)
YES=false
[ "${2:-}" = "--yes" ] && YES=true

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ask the app itself for the roots — never re-derive the repo-identity hash
# here, that logic lives (and must stay in sync) in RepoIdentity.segment/1.
ROOTS=$(
    cd "$ORCH_ROOT"
    SO_REPO="$REPO" mise exec -- mix run --no-start -e '
      repo = System.get_env("SO_REPO")

      segment =
        case SpeckitOrchestrator.RepoIdentity.resolve(repo) do
          {:ok, seg} -> seg
          {:error, reason} ->
            IO.puts(:stderr, "error: could not resolve repo identity for #{repo}: #{inspect(reason)}")
            System.halt(1)
        end

      root = SpeckitOrchestrator.Config.autonomous_root()
      IO.puts(Path.join([root, "worktrees", segment]))
      IO.puts(Path.join([root, "transcripts", segment]))
    '
)

# `mix run` may print compiler noise ("Compiling N files...") on stdout ahead
# of our two IO.puts lines — keep only absolute-path lines.
PATHS=$(echo "$ROOTS" | grep '^/')
WT_ROOT=$(echo "$PATHS" | sed -n '1p')
TR_ROOT=$(echo "$PATHS" | sed -n '2p')

echo "target repo:       $REPO"
echo "worktree root:      $WT_ROOT"
echo "transcript root:    $TR_ROOT"
echo

# Clean git's own worktree bookkeeping first (rm -rf alone leaves the base
# repo's .git/worktrees pointing at deleted directories).
WORKTREES=$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk -v root="$WT_ROOT" '
  /^worktree / { path = substr($0, 10) }
  path ~ "^" root "/" { print path; path = "" }
')

if [ -n "$WORKTREES" ]; then
    echo "git worktrees to remove:"
    echo "$WORKTREES" | sed 's/^/  /'
else
    echo "no registered git worktrees under $WT_ROOT"
fi

echo
[ -d "$WT_ROOT" ] && echo "worktree dir exists: $WT_ROOT" || echo "no worktree dir on disk"
[ -d "$TR_ROOT" ] && echo "transcript dir exists: $TR_ROOT" || echo "no transcript dir on disk"

# Migration cruft: a pre-partition machine-global transcripts/run.json. Since
# run.json is now per-repo (under $TR_ROOT), an old flat file at the parent is
# obsolete — flag it for removal only when its recorded segment matches THIS
# repo (never another repo's leftover).
SEGMENT=$(basename "$TR_ROOT")
FLAT_MANIFEST="$(dirname "$TR_ROOT")/run.json"
STALE_FLAT=false
if [ -f "$FLAT_MANIFEST" ] && grep -q "\"segment\":\"$SEGMENT\"" "$FLAT_MANIFEST" 2>/dev/null; then
    STALE_FLAT=true
    echo "stale flat run.json for this repo: $FLAT_MANIFEST"
fi

if [ "$YES" != true ]; then
    echo
    echo "Dry run — nothing deleted. Re-run with --yes to apply."
    exit 0
fi

echo
if [ -n "$WORKTREES" ]; then
    while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        echo "removing worktree $wt"
        git -C "$REPO" worktree remove --force "$wt" || true
    done <<<"$WORKTREES"
    git -C "$REPO" worktree prune
fi

if [ -d "$WT_ROOT" ]; then
    echo "rm -rf $WT_ROOT"
    rm -rf "$WT_ROOT"
fi

if [ -d "$TR_ROOT" ]; then
    echo "rm -rf $TR_ROOT"
    rm -rf "$TR_ROOT"
fi

if [ "$STALE_FLAT" = true ]; then
    echo "rm $FLAT_MANIFEST"
    rm -f "$FLAT_MANIFEST"
fi

echo "done."
