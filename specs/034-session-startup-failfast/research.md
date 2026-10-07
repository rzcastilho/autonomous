# Research: Fail Fast on Session Startup Failure (034)

All findings come from the incident run (fretboard-master `r000001`, feature
029, 2026-10-07) and from reading the pinned deps. Nothing here is a guess.
Wherever a claim depends on a dependency's internals, the dependency file is
named.

## R1 — Why the runner blocked for the whole deadline

**Finding.** Five links make up the failure chain. Each was checked against
source.

1. `Jido.AgentServer.handle_call({:signal, …})` runs the action in a
   **separate, unmonitored** process: `start_signal_call_task/3` uses
   `Task.Supervisor.start_child` or `spawn`
   (`deps/jido/lib/jido/agent_server.ex:1494`). That process runs the action
   under a `try … catch kind, reason`, then sends
   `{:signal_call_result, ref, result}` to the server. `catch` handles
   raises and throws. It cannot intercept an **exit signal from a linked
   process**: that kills the runner before it can send anything. The server
   does not monitor the runner, so `signal_call_inflight` is never cleared and
   the caller's `GenServer.call` waits for its own timeout.
2. `config :jido_action` `default_timeout: 0` runs the action **inline** in
   that runner (`deps/jido_action/lib/jido_action/exec.ex:488`). This is
   deliberate, per the mod-player 003 post-mortem.
3. `PhaseSession.reduce/2` folds the stream inside `Task.async/1`, which
   **links** the fold Task to the action (runner) process.
4. The SDK starts its control client lazily, **inside the fold Task**:
   `ClientStream.stream/3` calls `Client.start_link` in `Stream.resource`'s
   start function (`deps/claude_agent_sdk/lib/claude_agent_sdk/query/client_stream.ex:62`).
   The client is therefore linked to the fold Task.
5. The CLI exited during initialize. The `Client` returned
   `{:stop, {:initialize_failed, {:channel_exit, %ProcessExit{…}}}}`
   (`client.ex:1820`). That abnormal exit travelled the links:
   Client → fold Task (not trapping) → action runner (not trapping). The
   runner died silently and the `{:signal_call_result, …}` reply was never
   sent.

`PhaseSession.reduce/2` already has a `{:exit, reason}` clause for
`Task.yield`. That clause is unreachable here, because the **caller** dies
together with the Task.

**Consequence.** The worker waited `PhaseSession.call_timeout/1` (deadline +
2 min). After that, `{:ok, agent} = call(...)` at `phase_step.ex:173` would
have raised a `MatchError` and crashed the runner. The incident status matches:
`running`, $0, no transcript, an idle AgentServer, and the worker blocked in
`gen:do_call`.

## R2 — Where to cut the failure chain

**Decision.** In `PhaseSession.reduce/2`, run the fold in a process that is
**monitored, not linked** (`Task.Supervisor.async_nolink/2` under a new
app-level `Autonomous.SessionSup` `Task.Supervisor`). An abnormal exit of the
fold Task, for whatever linked SDK process caused it, then arrives as
`Task.yield/2` → `{:exit, reason}`. That is a value the action folds into a
`PhaseResult` and returns normally.

**Rationale.**
- **One choke point.** Every session-driving site folds through
  `PhaseSession.reduce/2`: `RunFeaturePhase` (phases and implement chunks),
  `RunAutoRemediation`, `RunRemediation`, and `RunPhase`. Fixing it here covers
  FR-008 without touching Jido or the SDK.
- **Deadline cut still works.** `cut/2` reads the fold Task's link set
  (`Process.info(pid, :links)`). `async_nolink` changes only the
  Task↔caller relationship. The SDK still `start_link`s from the Task, so the
  Task's links remain the session's process tree.
- **No orphaned CLI by construction.** Before this change, an outside death of
  the action also killed the fold Task through the link. With `nolink`, the
  fold Task must not outlive its caller. The Task therefore monitors the caller
  and, on `:DOWN`, stops its linked servers (the same `stop_server/1` path the
  deadline cut uses) before it exits. This keeps the old "the session dies with
  its action" guarantee and improves on it: `terminate/2` now runs, so the CLI
  is killed rather than orphaned.

**Alternatives considered.**
- *Trap exits in the fold Task.* Rejected. The SDK's `stream_next/1` only
  `receive`s `{:claude_message, …}`/`{:claude_error, …}`, so a trapped
  `{:EXIT, …}` would sit in the mailbox and the fold would block until the
  deadline. That is the same symptom as before.
- *Trap exits in the action process.* Rejected. The process is Jido's runner,
  not ours, and trapping there changes Jido semantics for every action.
- *Monitor the Jido runner from `PhaseStep`.* Rejected. The runner pid is
  private to `AgentServer` and there is no public API for it.
- *Patch the SDK or Jido.* Rejected. They are GitHub-pinned deps
  (Principle I keeps their contracts at arm's length). The fix belongs at our
  boundary.

## R3 — Telling "failed to start" apart from "ended without a result"

**Decision.** The fold Task notifies the parent once, on the **first event**
it pulls from the stream (`send(parent, {ref, :session_started})` through a
`Stream.transform` wrapper ahead of `PhaseResult.reduce/1`). On
`{:exit, reason}`, `PhaseSession` checks its mailbox for that marker:

- no marker → `:start_failed`
- marker present → `:ended_early`

**Rationale.** The fold state dies with the Task, so the parent cannot
inspect it. A one-shot message costs nothing and needs no ETS or atomics.
"First event" is the right line: the SDK emits the CLI's `system/init` message
as the first stream element only after a successful initialize, so a
pre-initialize death never produces one.

**Alternative.** Parse the exit reason (`:initialize_failed` vs others).
Rejected as the **primary** signal because it encodes SDK internals into the
classification. It is kept only to enrich the excerpt (R4).

## R4 — The stderr excerpt

**Decision.** The new pure module `Autonomous.SessionExit` takes any exit
term and returns `%{kind, excerpt}`. It walks the term generically (tuples,
lists, maps, structs) for the first binary under a `:stderr` key. If none is
found, it uses `inspect(reason, limit: 50)`. It trims to **2,000 characters**
(FR-003) and collapses whitespace runs. An empty result renders as
`"no output captured"`.

**Rationale.** In the incident, the stderr lived in
`%ExternalRuntimeTransport.ProcessExit{stderr: …}` nested three tuples deep.
A generic walk avoids naming SDK structs (Principle I): the only contract it
encodes is "a `stderr` field holds the CLI's message", and
`docs/harness-contract.md` records that fact.

## R5 — Gate, retry and terminal reason

**Decision.** The design mirrors 032's background-wait path, which is the
established pattern for a session-level failure.

- `PhaseSession` returns
  `%PhaseResult{status: :error, error: {:session_died, kind, excerpt}}`.
- Each action's classifier adds the signal
  `session_died: %{kind:, excerpt:}` to `last_signals`.
- **`Pipeline.next/3`.** A new clause
  `next(phase, :error, %{session_died: d})` returns
  `{:failed, {:session_died, phase, d}}`. It sits after branch-drift (a
  session that never started cannot have drifted, but drift keeps its
  "checked first" invariant from 027) and ahead of backgrounded and
  incomplete-session.
- **`PhaseStep.retry_reason/1`.** A new clause after branch-drift returns
  `"failed to start"` or `"ended without a result"`. It uses the existing
  `phase_max_retries` budget (default 1), which satisfies FR-006 with no new
  knob.
- **Chunks.** A new `Chunking.next/2` row re-dispatches the same scope once
  (`session_died_retried?` on `ChunkState`, the same shape as
  `background_retried?`) and counts against the frozen session ceiling. A
  second death returns `{:failed, {:session_died, ref, d}}`.
- **Remediation and auto-remediation.** These sites (`AnalyzeRunner`,
  `FeatureRunner` `"remediation.run"`) call `AgentServer` directly, not through
  `PhaseStep`. Each gets the same one-retry treatment through a small shared
  helper, `SessionRetry.once/2`, a pure decision over the outcome plus the
  breaker and drain predicates.
- **Drain and breaker (FR-010).** Every retry site already checks
  `Ledger.breaker_tripped?/1` and `Workers.drain_requested?/0` before starting
  a session. The retry passes through the same check, so a draining feature
  fails promptly and does not retry.

## R6 — Cost (FR-011)

**Finding.** Per-phase cost is only **recorded** after the fact
(`RunFeaturePhase.record_cost/2` → `Ledger.record/3`). The phase path makes no
upfront reservation. `Cost.for_phase/2`, however, falls back to the per-phase
**estimate** when a result has no `cost_usd`, so today a dead session would be
charged the estimate.

**Decision.** A new clause
`Cost.for_phase(_, %PhaseResult{error: {:session_died, :start_failed, _}})`
returns `{0.0, :actual}`. For `:ended_early`, the session may have spent
tokens before dying but reported no usage, so the existing estimate fallback
stays. This is conservative and matches Principle IV's "prefer actual, fall
back to estimate". FR-011's reservation clause is vacuous on this path (no
reservation exists) and is recorded as such.

## R7 — Operator rendering

**Decision.** Add `Report.format_reason({:session_died, where, %{kind:, excerpt:}})`:

- `"specify session failed to start: <excerpt>"`
- `"implement task-phase 3 \"…\" session ended without a result: <excerpt>"`

It reuses `background_where/1`. `RunDetailLive.format_legacy_reason/1`
delegates to it, as it already does for `:backgrounded_command`, and
`Chunking.failure_sentence/1` gains the matching clause. The console renders
the excerpt as text in the existing mono reason component: no `inspect/1`
(G-inspect) and no new token.

Logging (FR-013) emits a `Logger.warning` in `PhaseSession` with the kind and
excerpt, plus the existing retry warning in `PhaseStep`, which names the
feature, phase and attempt.

## R8 — US2: how the container config gets shared

**Finding.** `compose.claude-login.yaml` (added by `--with-login`) bind-mounts
the host's `~/.claude/` **and** the single file `~/.claude.json` read-write
into the container. The CLI rewrites `~/.claude.json` often (project trust,
counters, caches) and not atomically from a reader's point of view. Host
sessions plus the container sessions are concurrent readers and writers of one
inode. The host had an interactive session and the claude-mem worker spawning
headless sessions running at the time. The container CLI's
`.claude/backups/.claude.json.corrupted.*` file confirms a torn read.

Authentication itself sits in the `~/.claude/` directory (credentials file) or
in tokens from `.env`. `~/.claude.json` carries account metadata, onboarding
flags and per-project trust/settings.

**Decision.**
- Mount the host file **read-only at a seed path**:
  `${HOME}/.claude.json:/home/autonomous/.claude.host.json:ro`.
- In `container-entrypoint.sh`, before starting the BEAM, **snapshot** the seed
  into the container-private `$HOME/.claude.json`. The snapshot:
  - reads the seed, validates it as a JSON object (python3 is in the image),
    retries up to 5 × 200 ms on a parse failure (a torn read is transient),
  - writes to a temp file in the same directory and `mv`s it into place
    (atomic),
  - `die`s naming the seed path if it is still invalid after the retries
    (FR-016).
- `$HOME/.claude.json` then lives only in the container's writable layer,
  re-seeded on every container start. Container writes never reach the host
  (FR-017), and host writes can no longer tear a container read (FR-014).
- `~/.claude/` stays a read-write mount, so credentials refresh keeps working
  (FR-015). Only the single hot file is isolated.

**Alternatives considered.**
- *Copy once into a named volume.* Rejected. It goes stale silently across
  host re-logins, and re-seeding per start is cheap.
- *`flock` both sides.* Rejected. The host CLI does not lock.
- *Point the CLI at another config path via env.* Rejected. The CLI has no
  documented override for `~/.claude.json`'s location, and `HOME` would also
  move `~/.claude/`.

**Trade-off (documented, FR-019).** Trust or settings accepted on the host
after the container started reach the container only on restart.

## R9 — Smoke check

**Decision.** In `scripts/container-smoke.sh`, the "mounted login only" agent
check changes its `-v` to the new read-only seed mount, so it exercises the
real entrypoint path. A new non-agent check (no spend) does two things:

1. Starts the image with the seed mount, asserts that `$HOME/.claude.json` is
   a regular file and not a mount point, and asserts that it is byte-equal to
   the seed.
2. Starts it with an invalid seed (`{`), asserts a non-zero exit, and asserts
   the seed path appears in the error.
