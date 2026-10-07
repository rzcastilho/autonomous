# Data Model: Fail Fast on Session Startup Failure (034)

No Mnesia schema change. Everything below is an open term carried by
existing records: `PhaseResult.error`, `last_signals`, the history entry, and
the feature's failure `reason`.

## SessionDeath (`%{kind:, excerpt:}`)

| Field | Type | Rule |
|---|---|---|
| `kind` | `:start_failed \| :ended_early` | `:start_failed` when the fold Task exited abnormally **before** the stream yielded its first event. `:ended_early` when it exited after one or more events and before a result (research R3). |
| `excerpt` | `String.t()` | The first `stderr` binary found in the exit term, or else `inspect(reason, limit: 50)`. Whitespace is collapsed and the value is trimmed to at most 2,000 chars. An empty value becomes `"no output captured"` (FR-003). |

Produced only by `Autonomous.SessionExit.classify(reason, started?)`, which is pure.

## PhaseResult (existing) — new error shape

```elixir
%PhaseResult{status: :error, error: {:session_died, kind, excerpt}, cost_usd: nil}
```

- `PhaseResult.transient?/1` stays `false` for this shape. The retry is
  driven by the dedicated signal below, not by the transient-marker scan.
  This keeps the two retry budgets from double-counting.
- `PhaseResult.deadline_exceeded?/1` is `false`. A deadline cut keeps its
  own shape, so the two never overlap.

## Signal (existing `last_signals` map) — new key

| Key | Value | Set by |
|---|---|---|
| `:session_died` | `SessionDeath` | Every action classifier that folds a `PhaseResult` (`RunFeaturePhase`, `RunAutoRemediation`, `RunRemediation`, `RunPhase`) when `error` matches `{:session_died, _, _}` |

## Failure reasons (feature terminal `reason`)

| Reason | Where it arises |
|---|---|
| `{:session_died, phase, SessionDeath}` | `Pipeline.next/3`, after the phase's retry is exhausted |
| `{:session_died, %TaskPhaseRef{}, SessionDeath}` | `Chunking.next/2`, after the chunk's re-dispatch is exhausted |
| `{:session_died, {:remediation, attempt}, SessionDeath}` | `AnalyzeRunner` and the remediation step, after `SessionRetry.once/2` |

Each of these leads to the `:failed` terminal. No new lifecycle status
exists. The existing non-done-terminal rules apply: a backlog run parks with
`stopped_by`, and an ad-hoc feature finishes `:failed` (FR-007).

## ChunkState (existing) — new field

| Field | Type | Default | Rule |
|---|---|---|---|
| `session_died_retried?` | `boolean()` | `false` | Set by the retry row. Reset when the current task-phase advances, using the same lifecycle as `background_retried?` |

## History entry (existing)

`%{phase:, outcome: :error, error: {:session_died, kind, excerpt}}` is
appended for **every** dead attempt, including a retried one. This satisfies
acceptance scenario US1-2 ("first attempt remains visible") and keeps
`PhaseStep.ensure_recorded/3` satisfied.

## Cost

| Kind | Charged |
|---|---|
| `:start_failed` | `0.0`, source `:actual` (new `Cost.for_phase/2` clause) |
| `:ended_early` | Actual cost if one was reported, otherwise the per-phase estimate (unchanged fallback) |

## Container CLI config (US2)

| Path (in container) | Kind | Lifetime |
|---|---|---|
| `/home/autonomous/.claude.host.json` | read-only bind of the host `~/.claude.json` (`--with-login` only) | the host's file |
| `/home/autonomous/.claude.json` | regular file in the container layer, never a mount | re-seeded from the host file at every container start; container writes stay local |
| `/home/autonomous/.claude/` | read-write bind (unchanged) | the host's directory |

Seeding rule: the file must parse as a JSON **object**. On a parse failure
the seed is retried up to 5 times, 200 ms apart. If it still fails, the
entrypoint dies with a message naming the seed path (FR-016).
