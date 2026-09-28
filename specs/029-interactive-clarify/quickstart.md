# Quickstart: Validating Interactive Clarify

## Prerequisites

- Toolchain: `mise exec --` (Elixir 1.20.2-otp-28).
- For the live scenarios: the sibling target `../ledgerlite` with the target
  pack installed, and the `claude` CLI authenticated.

## 1. Automated suite (default, hermetic)

```bash
mise exec -- mix compile                       # warnings_as_errors
mise exec -- mix test                          # full suite, incl. design guard
mise exec -- mix test test/speckit_orchestrator/interactive_clarify_test.exs
mise exec -- mix test test/speckit_orchestrator/needs_human_test.exs
mise exec -- mix test test/speckit_orchestrator/feature_runner_clarify_wait_test.exs
```

The suite must show the following:

| Scenario | Proves |
|---|---|
| Mode off + NEEDS HUMAN → `{:escalated, :needs_human}`, same records/report as before | FR-002, SC-003 |
| Mode on → status `:awaiting_answers`, run not parked, `Release.next` → `:none`, no `Ledger` calls while waiting | US1-1, US1-3, FR-004 |
| `answer/3` → clarify re-run with an `Operator answers` block → `:plan` | US1-2, SC-002 |
| Short timeout (injected clock) → `{:needs_human, :answer_timeout}`, run parks | US2-1 |
| Breaker tripped while waiting → escalated, no `PhaseStep` call | US2-2 |
| `Workers.drain/1` while waiting returns within `poll + grace + 30 s` whatever `answer_timeout_s` is | US2-3, SC-005 |
| Re-run keeps asking → rounds 1..max, then `{:needs_human, :rounds_exhausted}` | US2-4, US2-5 |
| A second `answer/3` for the same `seq`, an answer racing the timeout, and an old `seq` → exactly one outcome; the stale one is refused | US3-3, SC-006 |
| `NeedsHuman.parse_questions/1` on numbered, malformed and empty blocks | US3-4, FR-018 |
| `AnswerSet.build/2` on blank-with-default and blank-without-default | US3-5 |
| `run/1` with timeout 30 / rounds 6 → `{:error, {:preflight, _}}` | US4-1 |
| Reconcile of a persisted `:awaiting_answers` row → escalated `{:needs_human, :restart}`, round `:interrupted`, questions kept | FR-016 |
| Design guard with the `awaiting_answers` token | SC-008 |

## 2. iex walk-through (live, attended)

```elixir
# iex: mise exec -- iex -S mix
SpeckitOrchestrator.run(repo: "../ledgerlite",
  features: ["007"], interactive_clarify: true,
  clarify_answer_timeout_s: 900, clarify_max_rounds: 2)

SpeckitOrchestrator.print_status()
# expect: 007 … awaiting_answers   and   awaiting: 007 round 1/2 …

[p] = SpeckitOrchestrator.pending_questions()
p.questions                      # {:numbered, [%Question{id: "Q1", ...}, ...]}

SpeckitOrchestrator.answer("007", p.seq, %{"Q1" => "Apply from next period", "Q2" => ""})
# Q2 blank → accepted recommended (or {:error, {:missing_answer, "Q2"}} if it has none)

SpeckitOrchestrator.answer("007", p.seq, %{"Q1" => "x"})
# → {:error, {:stale_round, :answered}}
```

Expected results (SC-001, SC-007):

- The clarify re-run starts within 5 s.
- `specs/*/spec.md` on the feature branch has the answers under
  `## Clarifications` and no `## NEEDS HUMAN` heading.
- The feature reaches `:plan`, and the run never parks.

## 3. Console walk-through

1. `/trigger`: switch Interactive clarify on, set the timeout to 15 minutes
   and rounds to 2, then start. Out-of-range values are refused inline
   before the run starts.
2. `/`: the feature pill shows **awaiting answers**, with waited and left
   times. Clicking the row opens `/escalations#awaiting-007`.
3. `/escalations`: there is one field per `Qn`. "Use recommended" fills the
   field. Submitting re-runs clarify, and the section disappears live.
4. `/runs/:run_id`: the settings chips show the three keys, and the
   `data-clarify-rounds` block shows the round, answers (typed or accepted
   recommended) and timestamps.

## 4. Fallback drills (live)

| Drill | Setup | Expect |
|---|---|---|
| Timeout | `clarify_answer_timeout_s: 60`; don't answer | escalated "answer window expired"; run parks; `resume/2` works |
| Breaker | small `budget_usd` so the next reservation trips | escalated `{:needs_human, :breaker}`; no new session |
| Supersession | while waiting, start `run/1` on the same repo | the prior feature escalates `{:needs_human, :drained}`; new run starts within the drain bound |
| Restart | kill the node while waiting; restart; `resumable()` → `resume_run()` | feature escalated `{:needs_human, :restart}`; questions on the round row; resume continues |
