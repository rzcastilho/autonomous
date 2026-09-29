# Quickstart: validate the permissive containment profile

Run every Elixir command through mise (`mise exec -- …`).

## Prerequisites

- Constitution 6.0.0 ratified on this branch (FR-014). Implementation must
  not merge before it.
- A scratch target repo with Spec Kit bootstrapped, a customized and
  committed constitution, and an `origin` remote.

## 1. Automated suite

```bash
mise exec -- mix test test/autonomous/scope_guard_test.exs      # red-team, strict parity, permissive matrix
mise exec -- mix test test/autonomous/phase_request_test.exs    # per-profile permissions + env markers
mise exec -- mix test test/autonomous/run_context_test.exs      # capture/from_map/merge, missing key ⇒ strict
mise exec -- mix test test/autonomous/target_pack_test.exs      # contract-2 preflight
mise exec -- mix test                                                     # full suite, design guard included
```

Expected: all green. The existing strict cases in `scope_guard_test.exs`
pass without edits to any assertion (SC-003).

## 2. Upgrade the pack in the scratch target

```elixir
Autonomous.TargetPack.install("/path/to/scratch")
```

Commit `.claude/`. Check that `settings.json` has no `deny` and that
`python3 .claude/hooks/scope_guard.py --contract` prints `2`.

Before you commit, a permissive run must fail preflight with
`{:pack_outdated, …}` (see [contracts/pack-preflight.md](contracts/pack-preflight.md)).

## 3. Human session (US1, SC-001)

In the scratch repo, start `claude` yourself. Ask it to:

1. `git push` a throwaway branch,
2. fetch a web page (`WebFetch`) and run `curl -I https://example.com`,
3. write a file in `../sibling/`.

Expected: none is denied by the pack. Your own Claude Code prompts still
appear.

## 4. Strict run is unchanged (US2 scenario 4, SC-003)

```elixir
# with config :autonomous, repo: "/path/to/scratch"
Autonomous.run()
```

Expected: same denials as today in transcripts (now prefixed
`scope_guard[strict|orchestrated]`). No containment marker on the report,
`print_status/0`, Mission Control, Run Detail, Configuration, or the PR
body.

## 5. Permissive run (US2, US3, SC-002, SC-004)

Use a one-feature backlog whose breakdown asks the phases to fetch a doc
page and write a note in a sibling directory.

```elixir
Autonomous.run(containment_profile: :permissive)
```

Expected:
- The fetch and the sibling write succeed, and the feature reaches `:done`.
- `print_status/0` shows `containment: permissive (no pack deny list)`.
- The topbar chip `containment: permissive` is on every console view, and
  Run Detail shows the CONTAINMENT block.
- The PR body ends with the "Containment: permissive" note.
- The branch-drift, artifact, incomplete-session, analyze and clarify gates
  behave as before (FR-009).

## 6. Profile lock on resume (FR-004, SC-005)

1. Start a permissive run that escalates or halts.
2. Set `config :autonomous, containment_profile: :strict`.
3. Run `resume/2` on the feature.

Expected: the resumed phases run permissive (check the transcript env
marker / Run Detail). `resume(id, containment_profile: :strict)` is refused
with `{:containment_profile_locked, "permissive"}`.

## 7. Docs

Check that `docs/runbook.md`, `docs/enforcement.md` and `CLAUDE.md` describe
both profiles, human-session behaviour, the `cli`-only entrypoint limitation,
and the container recommendation for permissive runs (FR-017).
