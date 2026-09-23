# Research: Drain the Superseded Runner

**Branch**: `026-drain-superseded-runner` | **Date**: 2026-09-23 |
**Spec**: [spec.md](./spec.md)

The spec carries no `NEEDS CLARIFICATION` markers. Research here resolves the
*how*: where a worker lives today, where it can be stopped cleanly, and what
the new run must wait on. Every finding is from the code on this branch
(merged with `main` at `29714d0`, i.e. after 025).

---

## R1. What exactly is "the worker", and why nothing stops it

**Finding.** Every feature is driven by a `Task.Supervisor.start_child(
SpeckitOrchestrator.RunnerSup, fn -> … FeatureRunner.run(…) end)` child. Five
spawn sites in `lib/speckit_orchestrator.ex` create one: `default_executor/5`,
`seed_executor/3`, `resume_executor/8`, `resume_run_executor/5`, and
`split_resume_executor/6` (the non-target branch). The child is not linked to
the Coordinator — deliberately (see the comment on `start_coordinator/1`: a
Coordinator started from a transient console Task used to die with it and
strand its runner).

Supersession today is two independent acts:

1. `Store.open_run/2` → `Writer.supersede_in_flight!/2` flips the prior
   `:in_flight` run to `:superseded` and every non-terminal feature row to
   `:ended_by_supersession` — a **record** change only.
2. `start_run/2` → `stop_previous_run/0` → `GenServer.stop(@coordinator)` — stops
   the **control process** only.

Nothing enumerates or signals `RunnerSup` children. The worker keeps holding
its `FeatureAgent` and its `claude` session, and the new run releases the same
feature into the same worktree/branch — the `r000002` incident.

**Decision.** Introduce a first-class notion of a *registered worker*: each
spawn site goes through one helper that registers the child, keyed by
repository, before it does anything else (worktree creation included). The
five `Task.Supervisor.start_child` call sites collapse into that one helper.

**Rationale.** A worker that is not findable cannot be drained, and cannot be
seen by the active-run guard (FR-005, FR-013). Registering at the spawn helper
— not inside `FeatureRunner.run/2` — also covers the window between spawn and
the first phase (worktree creation, spec-number allocation), where a second
worker would otherwise already be racing on the same branch.

**Alternatives considered.**
- *Enumerate `Task.Supervisor.children(RunnerSup)`.* Rejected: children carry
  no repository or feature identity, so FR-007 (per-repository scoping) is
  unanswerable, and a test-mode run's children are indistinguishable.
- *Link the worker to the Coordinator again.* Rejected outright by FR-009 —
  that is the bug the independence fixed.
- *Register inside `FeatureRunner.run/2`.* Rejected: misses the pre-phase
  window above, and `FeatureRunner` is also called directly by unit tests with
  no run.

---

## R2. Process lookup: `Registry`, keyed by repository

**Decision.** A `Registry` (`keys: :duplicate`, name
`SpeckitOrchestrator.WorkerRegistry`) under the application supervisor,
started before `RunnerSup`. Key = `repo_id` (the partition already used as the
first element of every `run_key`); value = the worker's
[entry](./data-model.md#worker-entry) (`feature_id`, `run_id`, `deadline_at`).

**Rationale.** Constitution VI names `Registry` as *the* tool for process
lookup. Registration is automatically removed when the worker exits — including
a crash — so "is a worker in flight?" can never be answered stale. `:duplicate`
keys keep the several-workers edge case representable without assuming the
one-at-a-time rule (spec Edge Cases).

**Alternatives considered.** A GenServer holding a map with monitors —
rejected as a hand-rolled `Registry`. `:global`/`:pg` — rejected, single-node.

---

## R3. How to ask a worker to stop without killing it

**Finding.** The worker spends almost all its life blocked inside
`AgentServer.call/3`, waiting on a `PhaseSession` that owns the only clean
shutdown of the `claude` subprocess (its in-action deadline — see
`jido-agentserver-swallows-action-errors` / the 003 post-mortem). An outside
`Process.exit/2` on the worker orphans the CLI; that path is forbidden (spec
Assumptions, FR-002).

The system already has exactly the shape this needs — the cost breaker's
drain. The breaker is a predicate (`Ledger.breaker_tripped?/1`) consulted at
**every point where a new session would otherwise start**:

| Site | Where | Today's breaker row |
|------|-------|---------------------|
| Phase boundary | `FeatureRunner.loop/12`, `{:cont, next}` branch, *after* `record_attempt/9` | `{:halted, :breaker, agent}` |
| Chunk boundary | `ChunkRunner` → `Chunking.next/2` signals `breaker?:` | `{:halted, :breaker, state}` |
| Remediation boundary | `AnalyzeRunner` → `Remediation.next/2` signals `breaker?:` | `{:halted, :breaker, state}` |

At all three the preceding session has already ended and its attempt,
checkpoint, and transcript are already written (phase boundary:
`record_attempt/9` precedes the `cond`; chunk boundary: `record_chunk_attempt`
+ the 025 per-task-phase checkpoint precede the next `Chunking.next/2`;
remediation: `record_analyze_run` precedes the corrective step).

**Decision.** A **drain request** is a second predicate, `drain_requested?/0`,
consulted at those same three sites, immediately after the breaker check and
yielding a distinct reason `:superseded`. The drainer sets the request; the
worker observes it at its next boundary and stops *there*, never mid-session.

The request is held in a public ETS table owned by the registry's module
(`SpeckitOrchestrator.Workers`), keyed by worker pid, deleted by the drainer
once the worker is down. Not a mailbox message: the worker only reads its
mailbox selectively inside `AgentServer.call`, and the three boundary checks
live in three modules; a latched lookup is idempotent across them where a
consumed message is not.

**Rationale.** Reuses the one "drain, don't kill" mechanism the constitution
already names (Principle IV) instead of inventing a second stop path — the
spec's "the drain never becomes a second, competing way to kill a session".
FR-003 and FR-008 then hold by construction: no check sits between a session's
end and its record.

**Alternatives considered.**
- *Fold drain into the `breaker?` signal.* Rejected by FR-011: the operator
  must be able to tell a supersession drain from a budget drain.
- *Drain only at the phase boundary.* Rejected: `implement` is many chunk
  sessions and can run for hours; the spec's bound is "at most one phase
  session", and the chunk boundary is already a recorded, resumable position
  (025).
- *Process dictionary latch.* Rejected: invisible to the drainer.

---

## R4. Pure decision tables get one new row each; `Pipeline.next/3` untouched

**Decision.** `Chunking.next/2` and `Remediation.next/2` each accept a
`drain?` signal (absent ⇒ `false`) and gain one row:
`drain? -> {:halted, :superseded, state}`, evaluated **after** the breaker row
(a tripped breaker wins — it is the stronger statement about the run). The
runners map it through their existing halt path, setting
`terminal_reason: {:halted, :superseded}`, which `FeatureRunner`'s
`terminal_override/1` already honours. `FeatureRunner.loop/12`'s `cond` gains
the same check after `breaker_tripped?/1`.

**Rationale.** Principle I: the decision stays in the pure tables, the
predicate read stays upstream (the runners pass `drain?:` in, as they pass
`breaker?:`). Absent signal ⇒ today's rows, byte-identical — every existing
table test holds unchanged.

---

## R5. What the drained worker writes (and does not)

**Finding.** A normal `:halted` exit runs, in order: `feature.finalize`,
`commit_message_and_pr`, `record_feature_terminal`,
`record_diversion_escalation`, `handle_worktree` (keep + commit),
`emit_terminal`, `notify`, `stop_agent`. If a supersession-drained worker did
all of that, it would (a) write `:halted` to its feature row, which
`supersede_run!` then skips (terminal statuses are left alone) — changing the
recorded supersession outcome, violating FR-010; (b) open an escalation for a
feature nobody diverted; (c) notify a Coordinator that is being replaced — if
still alive, `Release.next/3` would read a non-`:done` terminal and **park**
the run, and a parked run then makes `open_run/2` abort.

**Decision.** On `{:halted, :superseded}` the worker takes a *drained* exit:

| Step | Drained exit |
|------|--------------|
| boundary attempt + checkpoint + transcript | **already written** (R3) — unchanged |
| `feature.finalize` | runs (agent-local state only) |
| worktree | kept, final state committed — same as any non-`:done` exit |
| `record_feature_terminal` | **skipped** — the row stays `:running` so supersession marks it `:ended_by_supersession` exactly as today (FR-010) |
| `record_diversion_escalation` | **skipped** — nothing was diverted |
| `[:speckit, :feature, :terminal]` | **not emitted**; `[:speckit, :feature, :drained]` emitted instead (FR-011 distinguishability) |
| `notify` | **skipped** — the Coordinator is already stopped (R6) |
| `stop_agent` | runs |

The checkpoint written at the boundary is the `{:cont, next}` one at a phase
boundary (resume starts at `next` — nothing re-run, nothing skipped, US3 AS2),
or the diverted-terminal one at `implement`/`analyze` carrying the chunk
position — the same record the breaker halt at those sites already leaves.

---

## R6. Ordering inside `run/1` and the drain bound

**Finding.** Today `open_or_continue_run/3` (which supersedes the record) runs
*before* `run_stacked/4` → `preflight_stacked` (TargetPack) → `start_run/2`
(which stops the old Coordinator).

**Decision.** For a fresh run (no `:run_key`), the order becomes:

1. every refusing preflight that exists today, unchanged and in order
   (retired opts → remediation → parked run → layout → store writable →
   store capacity);
2. **stop the prior Coordinator** (moved earlier; `start_run/2`'s own call
   stays, now a no-op) — so a draining worker's outcome can never be read by
   a live `Release.next/3` and park the run;
3. **drain** every worker registered for this repository (FR-001) — no-op,
   no wait, when none is registered (FR-012/SC-005);
4. on drain timeout → return `{:error, {:drain_timeout, stuck}}`; the record is
   **not** superseded and no Coordinator is started (FR-004, SC-006);
5. `Store.open_run/2` (supersedes the now-quiet record) → `run_stacked/4` as
   today.

The drain bound, per worker, is `(deadline_at − now)⁺ +
PhaseSession.call_timeout` grace `+` a fixed finalize margin (commit + agent
stop). `deadline_at` is published by the worker into its registry entry each
time it starts a session (phase call, chunk call, remediation call); unset ⇒
`Config.phase_timeout/0` from now. Several workers are drained concurrently;
the overall wait is the max of their bounds. This is exactly the spec's
assumption: the session's own deadline governs, no second, shorter timer.

**Rationale.** Draining after the refusing preflights keeps "a refused start
supersedes nothing" true. Draining before `open_run/2` is what makes
"timeout ⇒ new run not started, nothing left half-started" (SC-006) free.

**Alternatives considered.** A short fixed bound then refuse — rejected by the
spec (every supersession during `implement` would refuse).

---

## R7. The active-run guard

**Finding.** `guard_active_run/1` (used by `continue_run/1`, `resume/2`,
`resume_run/1`) checks only `Process.whereis(@coordinator)`. With `:force` it
returns `:ok` immediately.

**Decision.**
- Without `:force`: refuse `{:error, {:active_run, pid}}` if the Coordinator
  is alive and unfinished **or** any worker is registered for this
  repository (then `pid` is the worker's). Same shape, so the console's
  `format_resume_error({:active_run, _})` and both existing guard tests hold
  (FR-005).
- With `:force`: bypass the refusal, then stop the Coordinator and drain
  exactly as R6 steps 2–4 (FR-006; spec edge case "the override bypasses the
  refusal, not the drain"). Drain timeout surfaces as
  `{:error, {:drain_timeout, stuck}}` and starts nothing.

**FR-013.** `SpeckitOrchestrator.workers/0` (and `/1` for an explicit repo)
returns the registered entries — read-only, no side effect. `status/0` is left
alone (it is the Coordinator's snapshot and returns nothing when no
Coordinator lives — precisely the state this feature is about).

---

## R8. Scoping and the test seam

- Registration requires a `run_key` (its `repo_id` is the key). A test-mode
  run with an injected `:runner` spawns no registered worker; an injected
  `:executor` spawns through the tests' own code. The drain and the extended
  guard are therefore exercised directly against `Workers` with stub worker
  processes, plus facade tests that inject an executor built on the
  registration helper — no CLI, no spend (spec Independent Tests).
- A worker registered under another `repo_id` is never looked up (FR-007).
