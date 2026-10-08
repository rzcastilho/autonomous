# Quickstart: Validating Container Workspace Trust (036)

Contracts: `contracts/container-trust-step.md`, `contracts/untrusted-workspace-gate.md`,
`contracts/operator-surfaces.md`, `contracts/environment.md`. Background:
`research.md`.

## Prerequisites

- `mise trust mise.toml` done; `mise exec -- mix deps.get` run.
- Docker, and an image built with `scripts/autonomous build`.
- `python3` on the host (the hermetic entrypoint test runs the real script step).
- For the agent checks only: credentials in `.env` (a few cents per check).

## 1. Default suite (hermetic, no CLI, no Docker)

```bash
mise exec -- mix test
```

Expected: green. New coverage includes
- `WorkspaceTrust` parsing of captured CLI lines (`test/fixtures/cli_stderr/`);
- `Pipeline.next/3` gate order with the `untrusted_workspace` signal, and
  byte-identical outcomes without it;
- `PhaseStep.retry_reason/1` returns `nil` for it;
- strict vs permissive at each session-driving site (signal set vs warning logged);
- `Report.format_reason/1` / Run Detail rendering;
- `Instance.env_lines/1` emits `AUTONOMOUS_WORKTREE_ROOT` equal to `Layout`'s root;
- the real entrypoint `trust-config` step against temp `HOME`s: create, merge,
  preserve, idempotent (no write on rerun), invalid → non-zero + unchanged,
  exact trusted set.

## 2. Container trust step (no spend)

```bash
scripts/container-smoke.sh trust
```

Expected: every `PASS` line in `contracts/container-trust-step.md` §Smoke
checks except the `SMOKE_AGENT` ones (reported `SKIP`).

Manual spot check on a running instance:

```bash
scripts/autonomous console --target ../some-target   # or release / shell
docker exec <container> python3 -c 'import json,os;print(sorted(k for k,v in json.load(open(os.path.expanduser("~/.claude.json"))).get("projects",{}).items() if v.get("hasTrustDialogAccepted")))'
```

Expected: the target repo realpath and `~/.autonomous/worktrees/<segment>`
(plus any records the host seed already had, if `--with-login`). Restart the
instance twice; the output and the file hash do not change.

## 3. No untrusted warning in orchestrated sessions (SC-001)

```bash
SMOKE_AGENT=1 scripts/container-smoke.sh trust
```

Expected: the agent check reports `PASS` — a session in a worktree of a
scratch target with `permissions.allow` entries prints no
`has not been trusted` on stderr.

End-to-end: drive one phase of a scratch feature in the container; the
console log carries no `CLI stderr: Ignoring … has not been trusted` line.

## 4. Hook-under-untrusted finding (US4, FR-010, SC-005 — under 10 minutes)

```bash
SMOKE_AGENT=1 scripts/container-smoke.sh us-trust-hook
```

Procedure it automates (reproducible by hand):
1. Scratch target with the shipped pack (`TargetPack.install/2`), committed.
2. Container config with **no** trust record; start a session with the
   orchestrator markers (`AUTONOMOUS_ORCHESTRATED=1`,
   `AUTONOMOUS_CONTAINMENT_PROFILE=strict`) asking it to write `/tmp/outside`.
3. Record: untrusted warning present? `scope_guard` deny line present? file written?
4. Add the repo trust record; repeat. Expected: denied.

Record the result, date and `claude --version` in `docs/container.md`
§Workspace trust. Host probe (2.1.294, 2026-10-08): project hooks ran while
untrusted (research R3).

## 5. Untrusted gate (FR-013)

Host, scratch target never trusted on this machine:

```elixir
# iex -S mix (mise exec), containment strict (default)
Autonomous.run()   # AUTONOMOUS_REPO / config :repo = the scratch target
```

Expected: first phase fails; report shows
`untrusted_workspace in :specify — CLI ignored permissions.allow … Trust it, then resume/2.`;
no retry line in the log. Run Detail shows the same text.

Same with `Autonomous.run(containment_profile: "permissive")`: a `Logger.warning("untrusted workspace …")`
line, and the phase proceeds.

Trust the target (`claude` in it, accept the dialog), then `Autonomous.resume/2`
on the failed feature: it proceeds.

## 6. Host untouched (SC-004)

```bash
shasum -a 256 ~/.claude.json
scripts/autonomous console --target ../some-target --with-login   # start, run a phase, stop
shasum -a 256 ~/.claude.json
```

Expected: identical hashes (host CLI not used meanwhile). Automated in the
`trust` smoke section.
