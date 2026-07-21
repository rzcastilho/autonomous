# Quickstart: Resume Docs & Operator Runbook

Validation guide proving the docs change meets its three Success Criteria. All
checks are read/grep-based — this feature ships no code. Run from repo root on
branch `006-resume-docs` after the implementation phase.

## Prerequisites

- Branch `006-resume-docs` checked out with the docs edits applied.
- `docs/runbook.md` and `CLAUDE.md` edited; `lib/speckit_orchestrator.ex`
  unchanged (source docstring stays).
- Reference: [contracts/resume-doc-surface.md](./contracts/resume-doc-surface.md),
  [data-model.md](./data-model.md).

## Check 1 — SC-003: zero stale "resume is v2/future" framing in markdown

INV-2 from the contract. Excludes `specs/` (design history) and matches only
`.md`, so source docstrings are out of scope by construction.

```bash
rtk grep -rniE 'mid-pipeline resume is v2|v2 concern|resume[^.]*(is|a)[^.]*(future|v2)' \
  --include='*.md' . | grep -v '/specs/'
```

**Expected**: no output (zero matches). In particular `docs/runbook.md:281`'s old
"mid-pipeline resume is v2" is gone.

## Check 2 — SC-002: every runbook example matches the shipped signature

INV-1. Confirm the documented calls use only `resume/2` with valid option keys
and no invented internal opts.

```bash
# Facade signature (source of truth) — eyeball the @spec / @doc:
rtk grep -n -A2 'def resume' lib/speckit_orchestrator.ex

# Every resume example in the runbook uses only :from / :prompt (or run/1 opts):
rtk grep -n 'SpeckitOrchestrator.resume(' docs/runbook.md
# Must NOT appear in runbook examples (internal FeatureRunner opts, not the facade):
rtk grep -n -E 'resume\([^)]*(start_phase:|resume_prompt:)' docs/runbook.md
```

**Expected**: first shows `resume(feature_id, opts \\ [])`; second lists example
calls using `:from`/`:prompt` only; third returns **no** matches.

## Check 3 — SC-001: operator can run the loop from the runbook alone

Manual dry-read. Without opening any source file, a reader of the runbook resume
section can:

1. Identify when to prefer `resume/2` over `resolve/1` (decision criteria present — FR-005).
2. Fix the root cause on the feature branch and commit it.
3. Invoke `SpeckitOrchestrator.resume("NNN", prompt: "…")` to restart at the
   checkpointed phase (FR-002, FR-003).
4. Know that `:from` overrides the start phase for the restart-earlier case,
   and *when* to reach for it (FR-004).

**Expected**: all four are answerable from `docs/runbook.md` text alone.

## Check 4 — INV-3: docs-only change

```bash
rtk git diff --name-only main...006-resume-docs
```

**Expected**: only `.md` files (`docs/runbook.md`, `CLAUDE.md`, and the
`specs/006-resume-docs/` artifacts). No `lib/`, `test/`, `config/`, or `mix.exs`.

## Check 5 — CLAUDE.md names shipped resume (FR-006)

```bash
rtk grep -n 'resume' CLAUDE.md
```

**Expected**: the observability/operability paragraph now mentions
`SpeckitOrchestrator.resume/2` as a shipped mid-pipeline recovery path (alongside
`resolve/1`), with no "v2 concern" / deferred framing.
