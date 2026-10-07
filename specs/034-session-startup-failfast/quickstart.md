# Quickstart: Validating 034

Run all commands from the repo root. Elixir commands go through mise.

## 1. Hermetic suite (default, no CLI)

```bash
mise exec -- mix test
```

Expected: green, with new coverage for the cases below.

- `SessionExit` (pure): stderr extraction from a nested
  `ProcessExit`-shaped term, the inspect fallback, the 2,000-char bound, and
  `"no output captured"`.
- `PhaseSession`: a stub stream whose start function `start_link`s a
  GenServer that stops with `{:initialize_failed, …}` returns
  `{:session_died, :start_failed, _}` in well under the deadline. Use a
  60 s deadline and assert under 5 s. **The calling test process stays
  alive.**
- `PhaseSession`: a stub that yields one event and then dies returns
  `:ended_early`.
- `PhaseSession`: kill the caller mid-fold. The stub server's `terminate/2`
  runs (I2).
- `Pipeline.next/3`: gate order per contracts/session-death.md C3.
- `PhaseStep`: death, retry, success leaves the feature advancing with two
  history entries. Death, retry, death fails with
  `{:session_died, phase, _}`. With the breaker tripped or a drain
  requested, there is no retry.
- `Chunking.next/2`: the re-dispatch row, then the failure row.
- `Cost.for_phase/2`: `:start_failed` costs 0.0.
- `Report.format_reason/1` / Run Detail: readable sentence, and the
  design-contract guard stays clean.

## 2. Reproduce the incident (manual, local, no spend)

1. Start a console with `--with-login` against a scratch target.
2. Before triggering, corrupt the **container's** copy:
   `scripts/autonomous shell` then `echo '{' > ~/.claude.json`.
3. Trigger a single spec.

Expected:

- Within about 30 s, Run Detail shows the specify attempt failed with
  "specify session failed to start: … corrupted …".
- One retry is logged.
- The feature ends `failed` (or the backlog run parks).
- `Autonomous.workers/0` is empty.
- Spend stays $0.

Restart the container. The copy is re-seeded from the host, and the run
resumes normally.

## 3. Race stress (US2, SC-005)

With a `--with-login` console running, rewrite the host file in a loop:

```bash
while :; do cp ~/.claude.json /tmp/cj && cp /tmp/cj ~/.claude.json; done
```

Drive 50 short sessions (for example, `Autonomous.Describe` probes, or a
small ad-hoc spec through specify). Expected: zero
`configuration file … is corrupted` lines in `docker logs`.

## 4. Container smoke

```bash
scripts/container-smoke.sh us1                # seed checks (no spend)
SMOKE_AGENT=1 scripts/container-smoke.sh us1  # + real login (a few cents)
```

Expected: the new seed checks pass, and the invalid-seed check reports the
seed path.
