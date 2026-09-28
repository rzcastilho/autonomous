# Research: Interactive Clarify Answering

All Technical Context unknowns are resolved below. Line references are to the
tree at `baf5ef6`.

## R1 — Where the wait lives

**Decision**: The wait runs inside the feature's own runner process (the
`RunnerSup` task spawned via `Workers.spawn/3` that already runs
`FeatureRunner.run/2`). `FeatureRunner.loop/12` returns `{:escalated,
:needs_human, agent}` for clarify (`feature_runner.ex:389-390`). Before that
return, the runner asks a pure decision function whether to wait. If the
answer is "wait", it enters `ClarifyWait.await/…`: a `receive … after poll_ms`
loop that runs no session and makes no ledger call. After an answer it
re-enters `loop/12` at `:clarify`.

**Rationale**:
- The runner is already registered in `WorkerRegistry`, so the feature stays
  "in flight" for `Workers.in_flight/1` and `guard_active_run/1` with no new
  bookkeeping (FR-004). The same goes for the one-at-a-time release rule once
  the Coordinator maps the new status (R6).
- The runner is a `Task`, not a `GenServer`, so a blocking `receive` does not
  break Principle VI ("no blocking the scheduler" is about GenServer callbacks).
- The worktree, the agent pid and the loop context are all still live, so the
  re-run is a plain `PhaseStep.run(pid, feature, :clarify, …)` with the
  answers attached. There is no re-init and no resume machinery.

**Alternatives considered**:
- *Park the run and auto-resume on answer.* This reuses `continue_run/1`, but
  the worktree is committed and torn down, a new Coordinator starts, and the
  spec's "run never parks" (US1) is violated. Rejected.
- *A separate `ClarifyWaiter` GenServer holding waits.* This is a new process
  plus supervision. The feature would leave the worker registry, so drain,
  guard and in-flight surfaces would each need a second source. Rejected.
- *A new `Pipeline` transition `{:await, …}`.* This would change the pure
  table's type and every consumer of it, and FR-002 demands byte-identical
  behaviour when the mode is off. Rejected: interception sits *after*
  `Pipeline.next/3`, so the table does not change.

## R2 — Pure decision surface

**Decision**: A new pure module `SpeckitOrchestrator.InteractiveClarify`. Its
decision function is:

```elixir
decide(transition, %Settings{}, rounds_used) ::
  :pass | :await | {:escalated, {:needs_human, :rounds_exhausted}}
```

- It returns `:pass` for any transition other than `{:escalated,
  :needs_human}`, or when `settings.enabled? == false`. With the mode off,
  every path returns `:pass`, which is what makes FR-002 hold structurally.
- A second function, `on_exit/1`, maps a wait exit
  (`:answer_timeout | :breaker | :drained | :restart`) to the escalation
  reason (R5).

This is the direct analogue of `Remediation.next/2`, and `Settings` mirrors
`Remediation.Settings` (validate/from_context, never clamps).

**Rationale**: Principle I puts the decision in pure, table-tested code, with
the side effects (receive loop, store writes) in the runner.

## R3 — Answer delivery and exactly-one-outcome

**Decision**: The **store row is the arbiter**. Each round is one
`speckit_clarify_round` row with `outcome: :open` while waiting.

- `Store.Writer.answer_round/3` runs one Mnesia transaction. It reads the
  row and accepts only if the row is `:open`, its `seq` equals the submitted
  `seq`, and `now < deadline_at`. It then writes `outcome: :answered`, the
  answers, `answered_at` and `answered_via`, all in the same transaction.
  - Any other state returns `{:error, {:stale_round, current}}`, where
    `current` is `:answered | :timed_out | :drained | :breaker |
    :interrupted | :superseded_round`.
- Every exit other than an answer (timeout, breaker, drain) goes through
  `Writer.close_round/3`. It flips the row out of `:open` in the same kind of
  guarded transaction, and fails if the row is already `:answered`.
- The runner **acts on the transaction result, not on the triggering
  message**. If its timeout close loses to an answer, it proceeds as
  answered.

After a committed answer, the facade sends `{:clarify_answered, round_key}`
to every pid registered for the repo in `WorkerRegistry` (at most one). The
message is only a wake-up. On every `poll_ms` tick (default 1 000 ms) the
runner also re-reads its row (a transactional read, since it feeds a gate),
so a lost message costs at most one tick (SC-002 < 5 s).

**Rationale**: This satisfies the edge case "exactly one outcome wins" and
SC-006, with no new locking. Principle IV/Persistence already mandates
transactions for mutations. No pid is persisted.

**Alternatives considered**:
- *Message-only delivery with in-process arbitration.* A timeout and an
  answer would race in the mailbox with nothing durable to decide between
  them, and a submission from the console node while the runner is between
  ticks has no durable record. Rejected.

## R4 — Drain and breaker responsiveness (SC-005)

**Decision**: On each tick the wait loop checks, in order:

1. `Workers.drain_requested?()`
2. `Ledger.breaker_tripped?(ledger)`
3. the round row
4. the deadline

This matches the discipline at `feature_runner.ex:359-367`.

On entering the wait, and on every tick, the runner calls a new
`Workers.waiting(poll_ms)`. It writes `deadline_at = now + poll_ms` to
`Workers.Deadlines`, so `Workers.Bound.wait_ms/3` for a waiting worker is
`poll_ms + call_grace + 30 s`. That is independent of the answer timeout, and
far below the session bound the drainer already tolerates.

**Rationale**: `drain_requested?/0` is self-scoped ETS, so the worker must
poll it. There is no push channel, and adding one would duplicate the latch.
Calling `Workers.session_started(answer_timeout)` would make the drainer wait
the full answer window, which violates FR-011 and SC-005.

## R5 — Exit reasons and records

**Decision**:

| Exit | Round outcome | Feature terminal | Reason term |
|---|---|---|---|
| answered → clean re-run | `:answered` | continues to plan | — |
| answered → still NEEDS HUMAN, rounds left | `:answered` | new round | — |
| re-run still NEEDS HUMAN, rounds used up | (last round `:answered`) | `:escalated` | `{:needs_human, :rounds_exhausted}` |
| timeout | `:timed_out` | `:escalated` | `{:needs_human, :answer_timeout}` |
| breaker tripped | `:breaker` | `:escalated` | `{:needs_human, :breaker}` |
| supersession drain | `:drained` | `:escalated` (recorded, not the `drained?` skip) | `{:needs_human, :drained}` |
| orchestrator restart | `:interrupted` | `:escalated` (on reconcile) | `{:needs_human, :restart}` |

- Every fallback goes through the **existing** terminal path
  (`call "feature.finalize"`, `handle_worktree` non-done branch,
  `record_feature_terminal`, `record_escalation`, notify). The records
  therefore match today's except for the reason (FR-010).
- `Report.format_reason/1` renders `{:needs_human, sub}` via one new
  `PublishOutcome.describe/1`-style clause. Plain `:needs_human` (mode off)
  renders exactly as before.
- A drained wait records the escalation instead of taking the silent
  `drained?(:halted, :superseded)` skip. The constitution requires "every
  exit … MUST fall back to the unconditional escalation exactly", and
  `supersede_in_flight!` only sweeps non-terminal rows, so the escalated row
  survives the sweep.
- Exhaustion is not a waiting episode, so it creates no round row. The final
  unanswered question block is carried on the escalation's `evidence`
  (`%{questions: raw, rounds_used: n}`), which the run-detail round history
  renders as its closing entry (FR-015).

## R6 — Status: `:awaiting_answers`

**Decision**: Add `:awaiting_answers` to `Feature.status` (non-terminal) and
`FeatureRun.status`. The runner marks it three ways:

- **Store:** `Writer.record_feature_awaiting/3` sets the status and opens the
  round in one transaction. `record_feature_resumed/2` sets `:running` again
  when an answer is taken.
- **Coordinator:** `notify` sends `{:feature_awaiting, id}` /
  `{:feature_resumed, id}`, and the Coordinator updates `statuses`. The status
  is never terminal, so `classify/1` and the final report are unaffected.
- **Telemetry:** `[:speckit, :clarify, :awaiting | :answered | :closed]`.
  `ConsoleProjection` adds these to `@events` and broadcasts
  `:feature_updated`, so every LiveView refreshes live (FR-006).

`Release.next/3`'s one-at-a-time clause becomes `status in [:running,
:awaiting_answers] ⇒ :none` (US1-1, the stacked-backlog edge case).

**Alternatives considered**: keep `:running` everywhere and show "awaiting"
as an annotation. This violates FR-014 ("a distinct status in every
surface"). Rejected.

## R7 — Carrying answers into the clarify re-run

**Decision**: The `"phase.run"` signal params gain an optional
`:operator_answers` (a rendered string). `RunFeaturePhase` passes it to
`PhaseRequest.build/3` as `clarify_answers:`, and only for `:clarify`. A new
`append_clarify_answers/2` appends:

```
---
Operator answers (authoritative, round N):
Q1: …
Q2: …
Fold every answer into `## Clarifications` as a resolved decision, realign stale
requirement text, and remove each answered item from `## NEEDS HUMAN`. Delete the
`## NEEDS HUMAN` heading entirely when no unanswered material question remains.
Do not re-ask an answered question.
```

This block is separate from `append_resume_prompt/2`, so the existing resume
guidance is untouched. Both may appear. The re-run is a fresh clarify
session: the spec on disk already carries round-N questions, which the
reviewer resolves.

**Rationale**: `resume_prompt_for/3` is gated on `state.resume_phase`, which
is fixed at `feature.init`. Re-initialising the agent to smuggle answers
through would reset run state. A per-call param is the narrowest seam, and the
spec's assumption ("the existing mechanism for adding operator guidance … is
suitable") holds: it is the same append-to-prompt mechanism, with a
dedicated header.

The removal instruction is load-bearing. The gate also scans `spec.md`
(`spec_has_needs_human?/2`), so a stale heading would re-trigger a round on
every re-run.

## R8 — Single NEEDS HUMAN rule and question format (FR-012, FR-013, FR-018)

**Decision**: A new pure module `SpeckitOrchestrator.NeedsHuman`:

- `present?/1`: the one regex, `~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m`.
- `extract/1`: the block text up to the next `## ` heading. This is today's
  `EscalationsLive.extract_needs_human/1`, moved here.
- `parse_questions/1`: `{:numbered, [%Question{}]} | {:freeform, text}`.

`RunFeaturePhase` (gate + spec scan) and `EscalationsLive` delete their local
copies and call this module.

The format that `priv/prompts/clarify.md` teaches under the heading is:

```markdown
### Q1: <one-line question>
**Context**: <why it matters / what depends on it>
**Options**: A) … · B) … · C) …
**Recommended**: B — <one-line reason>
```

- The parser splits on `^### Q(\d+)[:.]`.
- `**Options**` and `**Recommended**` are optional per item, but one of the
  two is required by the prompt.
- If any item is malformed, or ids are non-contiguous, the whole block falls
  back to `{:freeform, block}`. It never returns a partial parse
  (Principle II: salvage, don't invent).
- An empty block gives `{:freeform, ""}`, and an empty submission is refused
  (edge case).

## R9 — Answer set normalization (US3-5)

**Decision**: A pure function `InteractiveClarify.AnswerSet.build(parsed,
raw_params)`:

- **Numbered questions:** a blank answer with a recommended default takes the
  default, recorded as `{:default, text}` so the history shows it was
  accepted, not typed. A blank answer with no default returns
  `{:error, {:missing_answer, "Qn"}}`.
- **Freeform:** a blank submission returns `{:error, :empty_answer}`.

The console validates before submit, and the facade re-validates (Principle
II). `render/2` produces the prompt block in R7.

## R10 — Settings (FR-001, FR-017)

**Decision**: Three new `RunContext` keys (`@keys`), captured from opts with
Config defaults:

| key | type | range | default |
|---|---|---|---|
| `interactive_clarify` | boolean | — | `false` |
| `clarify_answer_timeout_s` | integer | 60..86 400 | 1 800 |
| `clarify_max_rounds` | integer | 1..5 | 3 |

- `InteractiveClarify.Settings.validate/1` errors are
  `{:invalid_answer_timeout, v} | {:invalid_max_rounds, v}`, and a
  non-boolean switch is an `ArgumentError`, the same shape as remediation.
- `run/1` preflight adds `preflight_interactive_clarify/1` next to
  `preflight_remediation/1`, producing `{:error, {:preflight, [reason]}}`.
- `RunSettings.settings` is a free-form string-keyed map, so **no migration
  is needed for settings**.
- `RunContext.merge/2` already gives "explicit opt > recorded > live Config",
  which is FR-017 for free. A run recorded before 029 lacks the keys and
  falls back to Config defaults (mode off), which is logged by
  `log_context_fallback` like any pre-existing key.
- The trigger form takes the timeout in **minutes** (1..1 440) and converts it
  to seconds at `start_opts/1`. Seconds are the stored unit so tests and iex
  can set short values.

Wait-loop tuning is not a run setting: `clarify_poll_ms` is a Config key
(default 1 000), and tests may inject `:clarify_clock` / `:clarify_poll_ms`
through `FeatureRunner.run/2` opts.

## R11 — Persistence: new table, schema v6

**Decision**: Add a new table `speckit_clarify_round` (`disc_copies`, since
the table is small and hot), registered in `Schema.tables/0` and
`Records`. A migration `{6, "create speckit_clarify_round",
&create_clarify_round/0}` creates it with a frozen attribute list. This is a
create, not a transform, so no existing row is touched.

`FeatureRun.status` gains `:awaiting_answers`, which needs no shape change.
`Writer.@terminal_statuses` is unchanged: awaiting is non-terminal.

`export_run`, `prune` and `run_detail` (`Query.build_run_detail`) include the
table's rows. Question text is short, so it is not bulk content, and
`disc_copies` is the right storage type under the Persistence rules.

## R12 — Restart recovery (FR-016)

**Decision**: Nothing new runs at boot (unchanged policy, `recovery.ex:5-7`).

- **Checkpoint at wait entry.** When the wait begins, the runner writes the
  same escalated checkpoint today's terminal path writes
  (`checkpoint_for({:escalated, :needs_human}, :clarify, st)`). A crash
  mid-wait therefore always leaves a resumable checkpoint.
- **Reconciliation.** `Recovery.Reconcile.status/3` gains one row: a
  persisted `:awaiting_answers` with no live worker becomes
  `{:escalated, {:needs_human, :restart}}`. `reconcile_run/2` closes the open
  round `:interrupted` and records the escalation in one transaction, and the
  questions stay on the round row.
- **Supersession.** `Writer.supersede_in_flight!` applies the same mapping to
  `:awaiting_answers` rows instead of `:ended_by_supersession`. That can only
  happen when the worker is already dead, because a live worker was drained
  and recorded its own escalation (R5).
- **Resuming.** `resume/2` on such a feature works unchanged. If the latest
  round is `:answered` but was never applied (the breaker tripped between
  answer and re-run), `resume/2` defaults `:clarify_answers` to that round's
  rendered answers, unless the operator passes `:prompt`/`:clarify_answers`
  explicitly (edge case "answers preserved … a later resume can reuse
  them"). An `applied_at` field on the round marks consumption.

## R13 — Console surfaces and the design contract (FR-014, SC-008)

**Decision**:

- **New status token.** Add `--awaiting` (orange-400 `#fb923c`), placed
  between `--escalated` (amber) and `--halted` (rose) on the attention
  scale. Amend `docs/design-constitution.md` (status table + fenced `:root`
  block, "seven" → "eight") under the Governance procedure, as flagged in the
  5.0.0 sync report.
- **Code changes for the status.**
  - `console.css`: one `:root` token and one `[data-status="awaiting_answers"]`
    block.
  - `CoreComponents`: extend `@labels` ("awaiting answers"), the
    `status_class/1` guard, and `statuses/0`.
  - `phase_cell_state/2` treats it as an active-attention cell.
  - `test/support/design_contract.ex`: extend `@contract_colors`,
    `@status_hexes` and `@status_names`.
- **No new keyframe.** The chip is static, and `scPulse` stays reserved for
  `running`.
- **Answer panel.** Add `EscalationsLive` "Awaiting answers" section above the
  diverted list (`data-awaiting-answers`):
  - one `<textarea>` per `Question`, with context/options rendered, a
    "use recommended" button that fills the field, and `data-question="Qn"`
  - or a single textarea for freeform
  - a hidden `seq`, submitted via `phx-submit="answer"` →
    `SpeckitOrchestrator.answer/3`
  - stale/refusal errors render through the existing `<.form_refusal>`
- **Trigger form.** A switch plus timeout (minutes) and rounds inputs, copying
  the auto-remediation block (`trigger_live.ex:430-497`), all `disabled`
  while the switch is off.
- **Status surfaces.** MissionControl, the DAG, Runs, RunDetail and the
  feature drawer take the new pill with no per-view code. Elapsed wait and
  time left come from the open round (`started_at`, `deadline_at`) and are
  shown next to the pill. MissionControl links the row to
  `/escalations#awaiting-<id>`.
- **RunDetail.** A `data-clarify-rounds` block per feature: round n/max,
  questions, answers (with defaults marked), outcome, and timestamps.
  Settings chips already render `detail.settings`, so the three keys appear
  automatically.

## R14 — iex surface

**Decision**: New facade functions:

- `SpeckitOrchestrator.pending_questions/0,1`: a list of `%{feature_id,
  spec_label, round, max_rounds, seq, questions, started_at, deadline_at}` for
  the current repo.
- `SpeckitOrchestrator.answer/3`: `answer(feature_id, seq, answers)`, where
  `answers` is `%{"Q1" => "…"}`, a keyword list, or a string (freeform). It
  returns `:ok | {:error, {:stale_round, current} | {:missing_answer, qid} |
  :empty_answer | :not_awaiting}`.

`print_status/0` shows `awaiting_answers` in STATUS. A new `awaiting:` line
(`feature  round n/m  waited Xm  Ym left`) appears only when some feature
awaits, so with the mode off the output is byte-identical.

Resume while awaiting: `guard_active_run/1` returns
`{:error, {:awaiting_answers, feature_id}}` ahead of `{:active_run, pid}`
when the in-flight feature awaits answers, and `format_resume_error/1` points
the operator to the answer panel.

## R15 — Report (FR-015)

**Decision**: The Coordinator's final report gains `clarify_rounds:
%{feature_id => [round_summary]}`, which is empty when the mode is off.
`Report` prints a `clarify:` block only when it is non-empty (the same
byte-identical discipline as `advanced_line/1`).
