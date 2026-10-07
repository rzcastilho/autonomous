# Contract: Session Death Detection and Handling (US1)

## C1 — `PhaseSession.reduce/2`

```elixir
@spec reduce(Enumerable.t(), pos_integer()) :: PhaseResult.t()
```

The spec is unchanged. The behavior changes:

| Fold outcome | Return | Timing |
|---|---|---|
| The stream ends in time | `PhaseResult.reduce/1` of the stream (unchanged) | when the stream ends |
| The fold Task exits abnormally, with no event yielded | `%PhaseResult{status: :error, error: {:session_died, :start_failed, excerpt}}` | **≤ 30 s** after the SDK process exits (FR-001) |
| The fold Task exits abnormally after ≥ 1 event | `%PhaseResult{status: :error, error: {:session_died, :ended_early, excerpt}, session_id: <if seen>}` | ≤ 30 s |
| The deadline expires | `PhaseResult.deadline_exceeded/2` (unchanged) | deadline + shutdown grace |

The following invariants hold.

- **I1.** `reduce/2` never lets an exit from an SDK-linked process
  propagate into the calling process. The fold Task is spawned with
  `Task.Supervisor.async_nolink` under `Autonomous.SessionSup`.
- **I2.** When the caller dies before the fold finishes, the fold Task stops
  its linked SDK servers through `GenServer.stop(pid, :normal, grace)` and
  then exits. No CLI subprocess outlives its action.
- **I3.** `cut/2` (the deadline path) still stops exactly the fold Task's
  link set.
- **I4.** `reduce/2` logs one `Logger.warning` per death, naming the kind and
  the excerpt (FR-013).

## C2 — `SessionExit.classify/2` (new, pure)

```elixir
@spec classify(term(), boolean()) :: %{kind: :start_failed | :ended_early, excerpt: String.t()}
```

- The second argument is `started?`: `false` gives `:start_failed`, `true`
  gives `:ended_early`.
- `excerpt` comes from the first `stderr: <binary>` found by a depth-first
  walk of tuples, lists, maps and structs. If no such field exists, it is
  `inspect(reason, limit: 50, printable_limit: 2000)`. Whitespace runs are
  collapsed to one space, the value is trimmed, and it is sliced to 2,000
  graphemes. An empty value becomes `"no output captured"`.
- The function is total and never raises.

## C3 — Gate order (`Pipeline.next/3`, `:error` clauses)

1. `%{branch_drift: d}` → `{:failed, {:branch_drift, phase, d}}` (027, still first)
2. **`%{session_died: d}` → `{:failed, {:session_died, phase, d}}`** (new)
3. `%{backgrounded: [_|_]}` → `{:failed, {:backgrounded_command, …}}` (032)
4. `%{outstanding_work?: true}` → `{:failed, {:incomplete_session, phase}}`
5. otherwise → `{:failed, {phase, :error}}`

## C4 — Retry (one fresh session, FR-006 / FR-010)

| Site | Mechanism | Budget |
|---|---|---|
| Whole phase | `PhaseStep.retry_reason/1` returns `"failed to start"` / `"ended without a result"` (checked after branch drift, before background) | `phase_max_retries` (default 1) |
| Implement chunk | A new `Chunking.next/2` row re-dispatches the same scope once (`session_died_retried?`) | one per task-phase, counted against the session ceiling |
| Auto-remediation / remediation | `SessionRetry.once/2` | one per attempt |

At every site, the retry is skipped when `Ledger.breaker_tripped?/1` or
`Workers.drain_requested?/0` is true. The attempt then ends with its
`session_died` reason, and drain completes without waiting on a deadline.

## C5 — Rendering

`Report.format_reason/1`:

```
{:session_died, :specify, %{kind: :start_failed, excerpt: e}}
  → "specify session failed to start: " <> e
{:session_died, %TaskPhaseRef{…}, %{kind: :ended_early, excerpt: e}}
  → ~s(task-phase 3 "Title" session ended without a result: ) <> e
{:session_died, {:remediation, n}, d}
  → "remediation attempt #{n} session …: " <> e
```

`RunDetailLive.format_legacy_reason/1` and `Chunking.failure_sentence/1`
delegate to it. The console never calls `inspect/1` on these reasons
(G-inspect).

## C6 — Cost

`Cost.for_phase(_, %PhaseResult{error: {:session_died, :start_failed, _}})`
returns `{0.0, :actual}`. Every other shape is unchanged.
