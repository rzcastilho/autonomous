# Contract: Runner wait protocol

The wait runs in the feature's runner process (a `RunnerSup` task registered
in `WorkerRegistry`). See research R1–R5.

## Entry

The entry point is in `FeatureRunner.loop/12` when phase `:clarify` produced
`{:escalated, :needs_human}`:

```elixir
case InteractiveClarify.decide(transition, settings, rounds_used) do
  :pass -> # today's path, unchanged
  {:escalated, reason} -> # terminal via existing finalize path
  :await -> await_answers(...)
end
```

`await_answers` does the following, in order:

1. Read `spec.md` / the final text and run `NeedsHuman.extract` +
   `parse_questions`.
2. Write the escalated checkpoint at `:clarify` (R12).
3. Call `Writer.record_feature_awaiting(run_key, feature_id, round_attrs)`
   (one transaction). It opens the round and sets the status.
4. Send `notify {:feature_awaiting, id}` to the Coordinator, and emit
   `[:speckit, :clarify, :awaiting]` with `%{feature_id, seq, round,
   max_rounds, deadline_at}`.
5. Enter `tick/…`.

## Tick (every `poll_ms`, default 1 000; also woken by `{:clarify_answered, key}`)

| order | check | action |
|---|---|---|
| 1 | `Workers.waiting(poll_ms)` | refresh the drain bound (R4) |
| 2 | `Workers.drain_requested?()` | `close_round(:drained)` → escalate `{:needs_human, :drained}` |
| 3 | `Ledger.breaker_tripped?(ledger)` | `close_round(:breaker)` → escalate `{:needs_human, :breaker}` |
| 4 | round row `outcome == :answered` | → **answered path** |
| 5 | `now >= deadline_at` | `close_round(:timed_out)` → escalate `{:needs_human, :answer_timeout}` |
| 6 | otherwise | `receive {:clarify_answered, ^key} -> tick; after poll_ms -> tick` |

If `close_round/3` returns `{:error, {:stale_round, :answered}}`, the answer
won the race, so the runner takes the **answered path** (SC-006).

A drain or breaker exit escalates **without** starting a session.

## Answered path

1. Check `Ledger.breaker_tripped?` and `Workers.drain_requested?`. If either
   has tripped, escalate (`:breaker` / `:drained`) and leave the round
   `:answered` with `applied_at: nil`, so a later resume reuses it (R12).
2. Call `Writer.record_feature_resumed` (status `:running`) and
   `Writer.mark_round_applied`, emit `[:speckit, :clarify, :answered]`, and
   send `notify {:feature_resumed, id}`.
3. Call `PhaseStep.run(pid, feature, :clarify, operator_answers:
   AnswerSet.render(...))`. Retry and failure semantics are unchanged: a
   non-question failure goes through the existing handling, and no new round
   opens.
4. Evaluate `Pipeline.next(:clarify, …)` again, then `decide/3` with
   `rounds_used + 1`:
   - `:pass` → continue to `:plan`
   - `:await` → a new round (`seq + 1`, `round + 1`)
   - `{:escalated, {:needs_human, :rounds_exhausted}}` → terminal

## Escalation (every non-answer exit)

The existing terminal path, unchanged except for the reason:
`call "feature.finalize"` → `handle_worktree` (non-done: commit +
keep_for_inspection) → `record_feature_terminal` → `record_escalation` →
`emit_terminal` → `notify {:feature_finished, id, :escalated, reason}`.

The Coordinator then parks the run exactly as for today's `:needs_human`. The
drained case reaches the same records; the Coordinator is already stopped,
so the notify is a no-op.

## Invariants

- No `Ledger.reserve/commit` and no `PhaseStep` call happens between wait
  entry and the answered path (FR-004).
- The drain bound for a waiting worker is `poll_ms + call_grace + 30 s`.
  It never depends on `answer_timeout_s` (SC-005).
- With the mode off, `decide/3` returns `:pass` and none of this code runs
  (FR-002).
